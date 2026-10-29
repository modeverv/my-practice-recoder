import XCTest
import AVFoundation
import CoreVideo
import PracticeRecorderCore
@testable import PracticeRecorderMedia

// Synthetic media only: no camera, microphone, or Core Audio device settings are touched.
enum WriterFixtures {
    static func video(pts: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard status == kCVReturnSuccess, let pixel else { throw RecorderError("test pixel buffer: \(status)") }
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 64, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var f: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescriptionOut:&f)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),
            presentationTimeStamp:CMTime(seconds:pts,preferredTimescale:600_000),decodeTimeStamp:.invalid)
        let r = CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,
            formatDescription:f!,sampleTiming:&timing,sampleBufferOut:&sample)
        guard r == noErr, let sample else { throw RecorderError("test video sample: \(r)") }; return sample
    }
    static func audio(pts: Double, frames: Int = 1024, rate: Int = 48_000) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate:Double(rate),mFormatID:kAudioFormatLinearPCM,
            mFormatFlags:kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,
            mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        var f: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,layoutSize:0,layout:nil,
            magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&f)
        var b: CMBlockBuffer?
        let size = frames * 8
        CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:size,
            blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:size,flags:0,blockBufferOut:&b)
        var data = [Float](repeating:0,count:frames * 2)
        for i in 0..<frames { data[i*2] = Float(sin(Double(i) * 0.08) * 0.2); data[i*2+1] = -data[i*2] }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:b!,offsetIntoDestination:0,dataLength:size) }
        var sample: CMSampleBuffer?
        let r = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator:kCFAllocatorDefault,dataBuffer:b!,
            formatDescription:f!,sampleCount:frames,presentationTimeStamp:CMTime(seconds:pts,preferredTimescale:Int32(rate)),
            packetDescriptions:nil,sampleBufferOut:&sample)
        guard r == noErr, let sample else { throw RecorderError("test audio sample: \(r)") }; return sample
    }
    static func request(root: URL, offset: Int = 0) -> RecordingRequest {
        .init(instrument:.guitar,selection:.init(cameraID:"synthetic",audioDeviceID:"synthetic",leftChannel:0,rightChannel:1,
              video:QualityProfile.p720_30.video),settings:.init(root:root,quality:.p720_30,audioOffsetMs:offset))
    }
}
final class WriterTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("PracticeRecorder-tests-\(UUID())") }
    func testArmingStopAndDuplicateStopFinishOnlyOnce() async throws {
        let w = MediaWriter(); let r = WriterFixtures.request(root:root())
        let done = expectation(description:"single finish"); done.expectedFulfillmentCount = 1; done.assertForOverFulfill = true
        w.arm(r,onStarted:{ _ in XCTFail("must not start without buffers") },onFinished:{ result in
            if case .success = result { XCTFail("arming cancellation must not claim saved") }; done.fulfill()
        })
        DispatchQueue.concurrentPerform(iterations:32) { _ in w.stop(id:r.id,reason:nil) }
        await fulfillment(of:[done],timeout:2)
    }
    func testAudioMissingArmingTimeout() async throws {
        let w = MediaWriter(); let r = WriterFixtures.request(root:root()); let done = expectation(description:"timeout")
        w.arm(r,onStarted:{ _ in XCTFail() },onFinished:{ result in
            if case .failure(let e) = result { XCTAssertTrue(e.localizedDescription.contains("3秒")) } else { XCTFail() }; done.fulfill()
        })
        w.appendVideo(try WriterFixtures.video(pts:100))
        await fulfillment(of:[done],timeout:5)
    }
    func testShortHardwareHEVCAACFileAndIdempotentStop() async throws {
        let w = MediaWriter(); let r = WriterFixtures.request(root:root())
        let started = expectation(description:"started"), done = expectation(description:"finished")
        done.assertForOverFulfill = true
        var output: Result<RecordingResult,Error>?
        w.arm(r,onStarted:{ _ in started.fulfill() },onFinished:{ result in output=result; done.fulfill() })
        w.appendAudio(try WriterFixtures.audio(pts:100))
        w.appendVideo(try WriterFixtures.video(pts:100))
        await fulfillment(of:[started],timeout:4)
        // Timestamp order is deterministic; pacing only lets hardware consume a bounded queue.
        var a = 1024.0 / 48_000; var v = 1.0 / 30
        while min(a,v) < 1.2 {
            if a < v { w.appendAudio(try WriterFixtures.audio(pts:100+a)); a += 1024.0/48_000 }
            else { w.appendVideo(try WriterFixtures.video(pts:100+v)); v += 1.0/30 }
            try await Task.sleep(nanoseconds:2_000_000)
        }
        // Allow accepted pending encoder input to drain before testing simultaneous stop causes.
        try await Task.sleep(nanoseconds:100_000_000)
        DispatchQueue.concurrentPerform(iterations:32) { i in w.stop(id:r.id,reason:i % 2 == 0 ? nil : "synthetic input interruption") }
        await fulfillment(of:[done],timeout:20)
        let value = try XCTUnwrap(output).get()
        XCTAssertEqual(value.context.startPTS.seconds,100,accuracy:1e-8)
        XCTAssertGreaterThan(value.duration,1)
        XCTAssertLessThan(value.duration,1.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath:value.partialURL.path))
        let duration = try await MediaWriter.validate(value.partialURL)
        XCTAssertEqual(duration,value.duration,accuracy:1e-8)
        print("HARDWARE HEVC/AAC SYNTHETIC: \(value.partialURL.path) duration=\(duration)")
    }
    func testAutomaticSyncKeepsCommonPTSInsteadOfZeroingEachStream() async throws {
        // An audio stream genuinely starts 125ms after the first video PTS.
        // Auto must preserve that relationship, even if a legacy manual offset was stored.
        let plan = AVSynchronizationPlan(mode: .automaticPTS, manualOffsetMs: -240)
        let w = MediaWriter(); let r = WriterFixtures.request(root: root(), offset: plan.effectiveAudioOffsetMs)
        let started = expectation(description: "common PTS start"), done = expectation(description: "common PTS saved")
        var output: Result<RecordingResult, Error>?
        w.arm(r, onStarted: { _ in started.fulfill() }, onFinished: { output=$0; done.fulfill() })
        w.appendAudio(try WriterFixtures.audio(pts: 100.125, frames: 4800))
        w.appendVideo(try WriterFixtures.video(pts: 100))
        await fulfillment(of: [started], timeout: 4)
        for frame in 1..<19 {
            if frame % 3 == 0 { w.appendAudio(try WriterFixtures.audio(pts: 100.125 + Double(frame)/30, frames: 4800)) }
            w.appendVideo(try WriterFixtures.video(pts: 100 + Double(frame)/30))
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        w.stop(id: r.id, reason: nil)
        await fulfillment(of: [done], timeout: 20)
        let result = try XCTUnwrap(output).get()
        XCTAssertEqual(result.context.startPTS.seconds, 100, accuracy: 1e-8)
        XCTAssertEqual(result.context.request.settings.audioOffsetMs, 0)
        XCTAssertNil(result.interruptedReason)
        let early = try await Self.meanMagnitude(url: result.partialURL, from: 0.005, to: 0.06)
        let audible = try await Self.meanMagnitude(url: result.partialURL, from: 0.16, to: 0.21)
        XCTAssertLessThan(early, 0.001)
        XCTAssertGreaterThan(audible, 0.02)
    }

    func testOffsetActualTrackPresentationStarts() async throws {
        for offset in [-100, 100] {
            let w = MediaWriter(); let r = WriterFixtures.request(root:root(),offset:offset)
            let started = expectation(description:"offset started"), done = expectation(description:"offset saved")
            var output: Result<RecordingResult,Error>?
            w.arm(r,onStarted:{ _ in started.fulfill() },onFinished:{ output=$0; done.fulfill() })
            w.appendAudio(try WriterFixtures.audio(pts:100,frames:4800))
            w.appendVideo(try WriterFixtures.video(pts:100))
            await fulfillment(of:[started],timeout:4)
            for frame in 1..<19 {
                if frame % 3 == 0 { w.appendAudio(try WriterFixtures.audio(pts:100+Double(frame)/30,frames:4800)) }
                w.appendVideo(try WriterFixtures.video(pts:100+Double(frame)/30))
                try await Task.sleep(nanoseconds:3_000_000)
            }
            try await Task.sleep(nanoseconds:100_000_000)
            w.stop(id:r.id,reason:nil)
            await fulfillment(of:[done],timeout:20)
            let result = try XCTUnwrap(output).get()
            let audios = try await AVURLAsset(url:result.partialURL).loadTracks(withMediaType:.audio)
            let audio = try XCTUnwrap(audios.first)
            let range = try await audio.load(.timeRange)
            // AAC may expose an edit from zero and encode the leading gap as silence.
            // Inspect decoded PCM to verify the offset's audible meaning, not track metadata.
            XCTAssertGreaterThanOrEqual(range.start.seconds,0)
            let early = try await Self.meanMagnitude(url:result.partialURL,from:0.005,to:0.06)
            let audible = try await Self.meanMagnitude(url:result.partialURL,from:0.13,to:0.18)
            if offset > 0 { XCTAssertLessThan(early,0.001) }
            else { XCTAssertGreaterThan(early,0.02) }
            XCTAssertGreaterThan(audible,0.02)
            XCTAssertGreaterThan(range.duration.seconds,0.45)
            XCTAssertNil(result.interruptedReason)
        }
    }
    private static func meanMagnitude(url: URL, from: Double, to: Double) async throws -> Double {
        let asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.audio).first else { throw RecorderError("test: missing audio") }
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false,
            AVSampleRateKey:48_000,AVNumberOfChannelsKey:2])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError("test: reader start failed") }
        var sum = 0.0; var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating:0,count:bytes / 4)
            let status = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:$0.baseAddress!) }
            guard status == noErr else { throw RecorderError("test: audio read failed") }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for f in stride(from:0,to:floats.count,by:2) {
                let pts = start + Double(f / 2) / 48_000
                if pts >= from && pts < to { sum += Double(abs(floats[f])); count += 1 }
            }
        }
        guard reader.status == .completed, count > 0 else { throw reader.error ?? RecorderError("test: no decoded PCM in window") }
        return sum / Double(count)
    }
    func testInvalidInputRateAndUnwritableDestinationNeverClaimSaved() async throws {
        for invalidRate in [true, false] {
            let destination = root()
            if !invalidRate { try Data("existing-user-file".utf8).write(to:destination) }
            let w = MediaWriter(); let r = WriterFixtures.request(root:destination)
            let done = expectation(description:"explicit failure")
            w.arm(r,onStarted:{ _ in XCTFail("must fail before recording starts") },onFinished:{ result in
                if case .success = result { XCTFail("must not claim saved") }; done.fulfill()
            })
            w.appendAudio(try WriterFixtures.audio(pts:100,rate:invalidRate ? 96_000 : 48_000))
            w.appendVideo(try WriterFixtures.video(pts:100))
            await fulfillment(of:[done],timeout:4)
            if !invalidRate { XCTAssertEqual(try String(contentsOf:destination,encoding:.utf8),"existing-user-file") }
        }
    }
    func testSparseMediaBoundaryAt300Seconds() async throws {
        let w = MediaWriter(); let r = WriterFixtures.request(root:root(),offset:100)
        let started = expectation(description:"started"), done = expectation(description:"300 boundary")
        done.assertForOverFulfill = true
        var output: Result<RecordingResult,Error>?
        w.arm(r,onStarted:{ _ in started.fulfill() },onFinished:{ result in output=result; done.fulfill() })
        w.appendAudio(try WriterFixtures.audio(pts:100)); w.appendVideo(try WriterFixtures.video(pts:100))
        await fulfillment(of:[started],timeout:4)
        try await Task.sleep(nanoseconds:100_000_000)
        // Sparse video exercises an exact 300s container end without waiting five minutes.
        // Missing audio is an explicit interruption, after the last video frame is accepted.
        w.appendVideo(try WriterFixtures.video(pts:399.99))
        try await Task.sleep(nanoseconds:30_000_000)
        w.appendAudio(try WriterFixtures.audio(pts:399.89,frames:1024))
        try await Task.sleep(nanoseconds:100_000_000)
        w.appendVideo(try WriterFixtures.video(pts:400))
        w.appendAudio(try WriterFixtures.audio(pts:400))
        w.stop(id:r.id,reason:nil)
        await fulfillment(of:[done],timeout:20)
        let value = try XCTUnwrap(output).get()
        XCTAssertLessThanOrEqual(value.duration,300.034)
        XCTAssertGreaterThan(value.duration,299.9)
        XCTAssertTrue(value.interruptedReason?.contains("音声PTSに不連続") == true)
        let asset = AVURLAsset(url:value.partialURL)
        for track in try await asset.load(.tracks) {
            let range = try await track.load(.timeRange)
            XCTAssertLessThanOrEqual(CMTimeRangeGetEnd(range).seconds,300.034)
            if track.mediaType == .video { XCTAssertGreaterThan(CMTimeRangeGetEnd(range).seconds,299.99) }
        }
        print("SPARSE 300s HARDWARE BOUNDARY: \(value.partialURL.path) duration=\(value.duration)")
    }
}
