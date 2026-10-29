import XCTest
import AVFoundation
@testable import PracticeRecorderMedia

final class AudioExtractionTests: XCTestCase {
    private func fixture(rate: Double = 48_000, channels: Int = 20, frames: Int = 8, bits: Int = 32, floating: Bool = true, planar: Bool = false, bigEndian: Bool = false, silence: Bool = false, negative: Bool = false) throws -> CMSampleBuffer {
        let width = bits / 8
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked | (floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
        if planar { flags |= kAudioFormatFlagIsNonInterleaved }; if bigEndian { flags |= kAudioFormatFlagIsBigEndian }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: UInt32(width * (planar ? 1 : channels)), mFramesPerPacket: 1, mBytesPerFrame: UInt32(width * (planar ? 1 : channels)), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bits), mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: CMTime(value: 1234567, timescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description!, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let nBuffers = planar ? channels : 1
        let listBytes = MemoryLayout<AudioBufferList>.size + (nBuffers - 1) * MemoryLayout<AudioBuffer>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: listBytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self); list.pointee.mNumberBuffers = UInt32(nBuffers)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var allocations: [UnsafeMutableRawPointer] = []
        defer { allocations.forEach { $0.deallocate() } }
        for b in 0..<nBuffers {
            let bufferChannels = planar ? 1 : channels
            let bytes = frames * bufferChannels * width
            let data = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8); allocations.append(data)
            let ptr = data.assumingMemoryBound(to: UInt8.self)
            for frame in 0..<frames { for c in 0..<bufferChannels {
                let channel = planar ? b : c
                let value = silence ? 0.0 : Double(channel + 1) / 32.0 * (negative ? -1 : 1)
                let raw: UInt64
                if floating { raw = bits == 32 ? UInt64(Float(value).bitPattern) : value.bitPattern }
                else { raw = UInt64(bitPattern: Int64(value * Double(Int64(1) << (bits - 1)))) }
                for byte in 0..<width { ptr[(frame*bufferChannels+c)*width+byte] = UInt8(truncatingIfNeeded: raw >> ((bigEndian ? width - 1 - byte : byte)*8)) }
            } }
            buffers[b] = AudioBuffer(mNumberChannels: UInt32(bufferChannels), mDataByteSize: UInt32(bytes), mData: data)
        }
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: list), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(sample!), noErr)
        return sample!
    }
    private func values(_ buffer: CMSampleBuffer) throws -> [Float] {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(buffer))
        let bytes = CMBlockBufferGetDataLength(block)
        var result = [Float](repeating: 0, count: bytes/4)
        let status = result.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
        XCTAssertEqual(status, noErr); return result
    }
    func testTwentyChannelsArbitraryPairAndSwapAcrossLayoutsAndRates() throws {
        for rate in [44_100.0,48_000] { for planar in [false,true] {
            let input = try fixture(rate: rate, planar: planar)
            let output = try PCMExtractor.extract(input, left: 10, right: 18)
            let data = try values(output.sampleBuffer)
            XCTAssertEqual(CMSampleBufferGetNumSamples(output.sampleBuffer), 8)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(output.sampleBuffer), CMSampleBufferGetPresentationTimeStamp(input))
            for f in 0..<8 { XCTAssertEqual(data[f*2],11/32.0); XCTAssertEqual(data[f*2+1],19/32.0) }
            XCTAssertEqual(output.meter.left,11/32.0); XCTAssertEqual(output.meter.right,19/32.0)
            let swapped = try values(PCMExtractor.extract(input,left:18,right:10).sampleBuffer)
            XCTAssertEqual(swapped[0],19/32.0); XCTAssertEqual(swapped[1],11/32.0)
            let desc = try XCTUnwrap(CMSampleBufferGetFormatDescription(output.sampleBuffer))
            XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee.mSampleRate,rate)
        } }
    }
    func testPackedIntegerAndFloatFormatsBothEndian() throws {
        for (floating,bits) in [(true,32),(true,64),(false,16),(false,24),(false,32)] { for planar in [false,true] { for big in [false,true] {
            let input = try fixture(bits:bits,floating:floating,planar:planar,bigEndian:big)
            let output = try values(PCMExtractor.extract(input,left:4,right:15).sampleBuffer)
            XCTAssertEqual(output[0],5/32.0,accuracy:0.0001); XCTAssertEqual(output[1],16/32.0,accuracy:0.0001)
        } } }
    }
    func testNativePackingTransitionIsEquivalentButSignalChangesAreNot() throws {
        let interleaved = try fixture()
        let planar = try fixture(planar:true)
        let i = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(interleaved)!)!.pointee
        let p = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(planar)!)!.pointee
        XCTAssertTrue(PCMExtractor.hasSameSignalFormat(i,p))
        XCTAssertTrue(PCMExtractor.hasSameSignalFormat(p,i))
        XCTAssertTrue(PCMExtractor.hasSameSignalFormat(i,i))
        var changed = p; changed.mSampleRate = 44100
        XCTAssertFalse(PCMExtractor.hasSameSignalFormat(i,changed))
        changed = p; changed.mChannelsPerFrame = 2
        XCTAssertFalse(PCMExtractor.hasSameSignalFormat(i,changed))
        changed = p; changed.mBitsPerChannel = 16
        XCTAssertFalse(PCMExtractor.hasSameSignalFormat(i,changed))
        changed = p; changed.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        XCTAssertFalse(PCMExtractor.hasSameSignalFormat(i,changed))
        changed = p; changed.mFormatID = kAudioFormatMPEG4AAC
        XCTAssertFalse(PCMExtractor.hasSameSignalFormat(i,changed))
        changed = p; changed.mBytesPerFrame = 8
        XCTAssertFalse(PCMExtractor.hasSameSignalFormat(i,changed))
        // Both representations normalize to identical selected samples without mixing.
        XCTAssertEqual(try values(PCMExtractor.extract(interleaved,left:10,right:11).sampleBuffer),
                       try values(PCMExtractor.extract(planar,left:10,right:11).sampleBuffer))
    }
    func testSignedNegativePCMAndUnsupportedEightBit() throws {
        for bits in [16,24,32] { for big in [false,true] {
            let output = try values(PCMExtractor.extract(fixture(bits:bits,floating:false,bigEndian:big,negative:true),left:10,right:11).sampleBuffer)
            XCTAssertEqual(output[0],-11/32.0,accuracy:0.0001); XCTAssertEqual(output[1],-12/32.0,accuracy:0.0001)
        } }
        XCTAssertThrowsError(try PCMExtractor.extract(fixture(bits:8,floating:false),left:10,right:11))
    }
    func testInvalidIndicesUnsupportedRateAndSilence() throws {
        let input = try fixture()
        for bad in [-1,20,100] { XCTAssertThrowsError(try PCMExtractor.extract(input,left:bad,right:0)); XCTAssertThrowsError(try PCMExtractor.extract(input,left:0,right:bad)) }
        XCTAssertThrowsError(try PCMExtractor.extract(fixture(rate:96_000),left:0,right:1))
        let silence = try PCMExtractor.extract(fixture(silence:true),left:10,right:11)
        XCTAssertEqual(silence.meter.left,0); XCTAssertEqual(silence.meter.right,0)
        XCTAssertEqual(try values(silence.sampleBuffer),[Float](repeating:0,count:16))
    }
    func testOwnedOutputSurvivesInputReleaseAndStereoUtility() throws {
        var input: CMSampleBuffer? = try fixture(planar:true)
        let output = try PCMExtractor.extract(input!,left:10,right:11)
        input = nil
        XCTAssertEqual(try values(output.sampleBuffer).prefix(2),[11/32.0,12/32.0])
        let samples:[Float] = [-0.9,0.8,0.1,-0.2]
        let stereo = try PCMExtractor.makeStereo(samples:samples,sampleRate:44_100,pts:CMTime(value:5,timescale:1))
        XCTAssertEqual(try values(stereo),samples)
        XCTAssertThrowsError(try PCMExtractor.makeStereo(samples:[],sampleRate:48_000,pts:.zero))
    }
}
