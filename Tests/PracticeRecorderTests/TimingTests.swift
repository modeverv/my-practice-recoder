import XCTest
import AVFoundation
@testable import PracticeRecorderMedia

final class TimingTests: XCTestCase {
    func testOffsetSignAndBeginningTrim() {
        let t = CMTime(seconds: 1234, preferredTimescale: 48_000)
        let late = MediaTimeline(start: t, audioOffsetMs: 100)
        let early = MediaTimeline(start: t, audioOffsetMs: -100)
        XCTAssertEqual((t + late.audioOffset - t).seconds, 0.1, accuracy: 0.000001)
        XCTAssertEqual((t + early.audioOffset - t).seconds, -0.1, accuracy: 0.000001)
        XCTAssertEqual(late.audioRange(pts: t, frames: 9600, sampleRate: 48_000), 0..<9600)
        XCTAssertEqual(early.audioRange(pts: t, frames: 9600, sampleRate: 48_000), 4800..<9600)
        XCTAssertEqual(early.audioRange(pts: t, frames: 1000, sampleRate: 48_000), 1000..<1000)
    }
    func testPositiveOffsetExcludesPreStartCaptureAudio() throws {
        for rate in [44_100, 48_000] {
            let start = CMTime(seconds:10,preferredTimescale:600_000)
            let timeline = MediaTimeline(start:start,audioOffsetMs:100)
            // CMTime(seconds:9.95) truncates one tick at these rates because the
            // Double is below the exact fraction. Construct the source PTS rationally.
            let inputPTS = CMTime(value:Int64(rate * 199 / 20),timescale:Int32(rate))
            let crossing = try MediaTimeline.retime(WriterFixtures.audio(pts:9.95,frames:rate / 5,rate:rate),
                pts:inputPTS,duration:CMTime(value:1,timescale:Int32(rate)))
            let trimmed = try XCTUnwrap(timeline.adjustedAudio(crossing))
            XCTAssertEqual(CMSampleBufferGetNumSamples(trimmed),rate * 3 / 20)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(trimmed).seconds,10.1,accuracy:1e-8)
            let before = try WriterFixtures.audio(pts:9.95,frames:rate / 25,rate:rate)
            XCTAssertNil(try timeline.adjustedAudio(before))
        }
    }
    func testOneTickEarlierInputRequiresOneMoreTrimmedFrame() throws {
        for rate in [44_100, 48_000] {
            let timeline = MediaTimeline(start:CMTime(value:10,timescale:1),audioOffsetMs:100)
            let oneTickEarly = CMTime(value:Int64(rate * 199 / 20 - 1),timescale:Int32(rate))
            let sample = try MediaTimeline.retime(WriterFixtures.audio(pts:9.95,frames:rate / 5,rate:rate),
                pts:oneTickEarly,duration:CMTime(value:1,timescale:Int32(rate)))
            let trimmed = try XCTUnwrap(timeline.adjustedAudio(sample))
            XCTAssertEqual(CMSampleBufferGetNumSamples(trimmed),rate * 3 / 20 - 1)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(trimmed).seconds,10.1,accuracy:1e-8)
        }
    }
    func testBoundaryTrimAtBothRatesAndOffset() {
        for rate in [44_100.0, 48_000.0] {
            let t = CMTime(seconds: 1000, preferredTimescale: 600_000)
            let timeline = MediaTimeline(start: t, audioOffsetMs: 100)
            let p = t + CMTime(seconds: 299.89, preferredTimescale: 600_000)
            let range = timeline.audioRange(pts: p, frames: Int(rate), sampleRate: rate)
            XCTAssertEqual(range, 0..<Int(rate / 100))
            XCTAssertEqual(timeline.audioRange(pts: timeline.end, frames: 1000, sampleRate: rate), 0..<0)
        }
    }
    func testNegativeOffsetExcludesPostLimitCaptureAudio() throws {
        for rate in [44_100, 48_000] {
            let start = CMTime(seconds:10,preferredTimescale:600_000)
            let timeline = MediaTimeline(start:start,audioOffsetMs:-100)
            let crossing = try WriterFixtures.audio(pts:309.95,frames:rate / 5,rate:rate)
            let trimmed = try XCTUnwrap(timeline.adjustedAudio(crossing))
            XCTAssertEqual(CMSampleBufferGetNumSamples(trimmed),rate / 20)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(trimmed).seconds,309.85,accuracy:1e-8)
            XCTAssertEqual((CMSampleBufferGetPresentationTimeStamp(trimmed) + CMSampleBufferGetDuration(trimmed)).seconds,309.9,accuracy:1e-8)
            let after = try WriterFixtures.audio(pts:310.01,frames:rate / 25,rate:rate)
            XCTAssertNil(try timeline.adjustedAudio(after))
        }
    }
    func testFrameDurationsAndExactLimit() {
        let start = CMTime(value: 777_000, timescale: 1000)
        let t = MediaTimeline(start: start, audioOffsetMs: 0)
        let actualNTSCFrame = CMTime(value: 1001, timescale: 30_000)
        let pts = t.end - CMTime(value: 1, timescale: 1000)
        XCTAssertEqual(t.videoDuration(pts: pts, duration: actualNTSCFrame)?.seconds ?? -1, 0.001, accuracy: 1e-8)
        XCTAssertNil(t.videoDuration(pts: t.end, duration: actualNTSCFrame))
        XCTAssertNil(t.videoDuration(pts: t.end + actualNTSCFrame, duration: actualNTSCFrame))
        XCTAssertNil(t.videoDuration(pts: start - actualNTSCFrame, duration: actualNTSCFrame))
        XCTAssertEqual(t.videoDuration(pts: start, duration: actualNTSCFrame), actualNTSCFrame)
    }
    func testActualPCMTrimmingPreservesSamplesAndShiftedPTS() throws {
        for rate in [44_100, 48_000] {
            let sample = try WriterFixtures.audio(pts: 10, frames: rate / 5, rate: rate)
            let timeline = MediaTimeline(start: CMTime(seconds:10, preferredTimescale:600_000), audioOffsetMs:-100)
            let trimmed = try XCTUnwrap(timeline.adjustedAudio(sample))
            XCTAssertEqual(CMSampleBufferGetNumSamples(trimmed), rate / 10)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(trimmed).seconds, 10, accuracy:1e-8)
            XCTAssertEqual(CMSampleBufferGetDuration(trimmed).seconds, 0.1, accuracy:1e-8)
            let late = MediaTimeline(start: CMTime(seconds:10, preferredTimescale:600_000), audioOffsetMs:100)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(try XCTUnwrap(late.adjustedAudio(sample))).seconds, 10.1, accuracy:1e-8)
        }
    }
}
