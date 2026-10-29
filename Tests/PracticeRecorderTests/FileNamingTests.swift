import XCTest
import CoreMedia
@testable import PracticeRecorderCore

final class FileNamingTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testEveryInstrumentAndRoundedActualDuration() {
        for instrument in Instrument.allCases {
            XCTAssertEqual(FileNaming.filename(instrument: instrument, startedAt: date("2026-10-29T14:15:30Z"),
                                               duration: 136.5, id: "7F3A9C2D", timeZone: utc),
                           "\(instrument.rawValue)-2026-10-29-141530-02m17s-7f3a9c2d.mp4")
        }
    }

    func testRoundingAndLimitAreFixed() {
        let values: [(Double, Int)] = [(0, 0), (0.49, 0), (0.5, 1), (59.49, 59), (59.5, 60),
                                      (299.49, 299), (299.5, 300), (300.04, 300),
                                      (Double.greatestFiniteMagnitude, 300), (-1, 0), (.nan, 0), (.infinity, 0)]
        for (duration, seconds) in values { XCTAssertEqual(FileNaming.roundedSeconds(duration), seconds) }
    }

    func testStartDateOwnsFolderAcrossMonthAndYearBoundary() {
        let root = URL(fileURLWithPath: "/tmp/PracticeRecorder")
        let started = date("2026-12-31T23:59:59Z")
        XCTAssertEqual(FileNaming.directory(root: root, instrument: .piano, startedAt: started, timeZone: utc).path,
                       "/tmp/PracticeRecorder/piano/2026/12")
        XCTAssertEqual(FileNaming.filename(instrument: .piano, startedAt: started, duration: 300,
                                           id: "12345678", timeZone: utc),
                       "piano-2026-12-31-235959-05m00s-12345678.mp4")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(FileNaming.directory(root: root, instrument: .bass, startedAt: started, timeZone: tokyo).path,
                       "/tmp/PracticeRecorder/bass/2027/01")
    }

    func testIDsCannotInjectPathComponentsAndInterruptedIsExplicit() {
        let name = FileNaming.filename(instrument: .other, startedAt: date("2026-10-29T00:00:00Z"),
                                       duration: 3, id: "../../A1B2-C3D4", interrupted: true, timeZone: utc)
        XCTAssertEqual(name, "other-2026-10-29-000000-00m03s-a1b2c3d4-interrupted.mp4")
    }

    func testCollisionRetriesWithoutOverwritingExistingFile() throws {
        let (root, context, partial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = partial.deletingLastPathComponent().appendingPathComponent(
            FileNaming.filename(instrument: .guitar, startedAt: context.startedAt, duration: 4.7, id: "11111111"))
        try Data("existing take".utf8).write(to: existing)
        try Data("new take".utf8).write(to: partial)
        var ids = ["11111111", "22222222"]
        let final = try FileStore.publish(partialURL: partial, context: context, duration: 4.7,
                                          interrupted: false, idGenerator: { ids.removeFirst() })
        XCTAssertTrue(final.lastPathComponent.hasSuffix("-00m05s-22222222.mp4"))
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing take".utf8))
        XCTAssertEqual(try Data(contentsOf: final), Data("new take".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testInterruptedPublishNeverUsesNormalName() throws {
        let (root, context, partial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("interrupted".utf8).write(to: partial)
        let final = try FileStore.publish(partialURL: partial, context: context, duration: 5,
                                          interrupted: true, idGenerator: { "33333333" })
        XCTAssertTrue(final.lastPathComponent.hasSuffix("-interrupted.mp4"))
    }

    func testFailedRenamePreservesPartialAndExistingFile() throws {
        let (root, context, partial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("partial".utf8).write(to: partial)
        let destination = partial.deletingLastPathComponent().appendingPathComponent(
            FileNaming.filename(instrument: .guitar, startedAt: context.startedAt, duration: 5, id: "44444444"))
        try Data("existing".utf8).write(to: destination)
        XCTAssertThrowsError(try FileStore.publish(partialURL: partial, context: context, duration: 5,
                                                  interrupted: false, idGenerator: { "44444444" }))
        XCTAssertEqual(try Data(contentsOf: partial), Data("partial".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
    }

    func testInvalidMediaRemainsPartialWithNoFinalName() async throws {
        let (root, context, partial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not an MP4".utf8).write(to: partial)
        do {
            _ = try await FileStore.finalize(.init(context: context, partialURL: partial, duration: 5, interruptedReason: nil))
            XCTFail("Invalid media must not receive a final filename")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(partial.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: partial.deletingLastPathComponent().path),
                       [partial.lastPathComponent])
    }

    func testFinalizationTimeoutReturnsBeforeLateValidationAndDoesNotRename() async throws {
        let (root, context, partial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("finished writer output".utf8).write(to: partial)
        let validationReturned = expectation(description: "late validator returned")
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await FileStore.finalize(.init(context: context, partialURL: partial,
                                                   duration: 5, interruptedReason: nil), timeout: 0.01) { _ in
                // This deliberately ignores cancellation, like a stuck AVAsset load may do.
                try? await Task.sleep(nanoseconds: 500_000_000)
                validationReturned.fulfill()
                return 5
            }
            XCTFail("A finalization timeout must not report saved")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("完了しませんでした"))
            XCTAssertTrue(error.localizedDescription.contains(partial.path))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.4)
        await fulfillment(of: [validationReturned], timeout: 1)
        // Let the detached task consume the returned result and try its publication claim.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: partial.deletingLastPathComponent().path),
                       [partial.lastPathComponent])
    }

    func testFinalizationSuccessBeforeTimeoutPublishesExactlyOnce() async throws {
        let (root, context, partial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("finished writer output".utf8).write(to: partial)
        let final = try await FileStore.finalize(.init(context: context, partialURL: partial,
                                                      duration: 4.7, interruptedReason: nil), timeout: 0.1) { _ in 4.7 }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: final), Data("finished writer output".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: final.deletingLastPathComponent().path),
                       [final.lastPathComponent])
    }

    func testPublicationUsesCapturedStartTimeZone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = date("2026-12-31T23:59:59Z")
        let selection = CaptureSelection(cameraID: "camera", audioDeviceID: "audio", leftChannel: 10,
                                          rightChannel: 11, video: QualityProfile.p720_30.video)
        let request = RecordingRequest(instrument: .piano, selection: selection,
                                        settings: .init(root: root, quality: .p720_30, audioOffsetMs: 0))
        let context = RecordingContext(request: request, startedAt: start, startPTS: .zero,
                                        monotonicStart: 0, timeZoneIdentifier: "Etc/GMT")
        let folder = FileNaming.directory(root: root, instrument: .piano, startedAt: start, timeZone: utc)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".recording-\(request.id).partial.mp4")
        try Data("take".utf8).write(to: partial)
        let final = try FileStore.publish(partialURL: partial, context: context, duration: 5,
                                          interrupted: false, idGenerator: { "12345678" })
        XCTAssertEqual(final.path, folder.appendingPathComponent("piano-2026-12-31-235959-00m05s-12345678.mp4").path)
    }

    func testSixtyFPSAllowsOneAACFrameButRejectsLargerAssetOrTrackOverrun() throws {
        let tolerance = FileStore.mediaDurationTolerance(video: QualityProfile.p1080_60.video)
        // At 60fps the 44.1kHz AAC frame is longer than a video frame. A valid AAC
        // rounding tail must be accepted, but the former 50ms allowance must not be.
        let accepted = 300.0232
        let validRanges = [timeRange(end: accepted), timeRange(end: accepted)]
        XCTAssertNoThrow(try FileStore.validateTiming(duration: accepted, trackRanges: validRanges,
                                                      tolerance: tolerance))
        XCTAssertThrowsError(try FileStore.validateTiming(duration: 300.024, trackRanges: validRanges,
                                                          tolerance: tolerance))
        XCTAssertThrowsError(try FileStore.validateTiming(duration: 300,
                                                          trackRanges: [timeRange(end: 300.024), timeRange(end: 300)],
                                                          tolerance: tolerance))
        XCTAssertThrowsError(try FileStore.validateTiming(duration: 300,
                                                          trackRanges: [timeRange(end: 300), timeRange(end: 300.024)],
                                                          tolerance: tolerance))
    }

    func testThirtyAndFractionalFPSUseTheirActualVideoFrameBoundary() throws {
        let thirty = FileStore.mediaDurationTolerance(video: QualityProfile.p1080_30.video)
        XCTAssertNoThrow(try FileStore.validateTiming(duration: 300.03333,
                                                      trackRanges: [timeRange(end: 300.03333), timeRange(end: 300)],
                                                      tolerance: thirty))
        XCTAssertThrowsError(try FileStore.validateTiming(duration: 300.03334,
                                                          trackRanges: [timeRange(end: 300), timeRange(end: 300)],
                                                          tolerance: thirty))
        let fractional = VideoConfiguration(width: 1920, height: 1080,
                                             frameDuration: CMTime(value: 1001, timescale: 30_000), bitrate: 3_000_000)
        let ntsc = FileStore.mediaDurationTolerance(video: fractional)
        XCTAssertNoThrow(try FileStore.validateTiming(duration: 300.03336,
                                                      trackRanges: [timeRange(end: 300.03336), timeRange(end: 300)],
                                                      tolerance: ntsc))
        XCTAssertThrowsError(try FileStore.validateTiming(duration: 300.03337,
                                                          trackRanges: [timeRange(end: 300), timeRange(end: 300)],
                                                          tolerance: ntsc))
        for allowance in [thirty, ntsc] {
            XCTAssertThrowsError(try FileStore.validateTiming(duration: 300.05,
                                                              trackRanges: [timeRange(end: 300), timeRange(end: 300)],
                                                              tolerance: allowance))
        }
    }

    func testAssetTimingValidationRejectsMissingTracksAndInvalidPresentationRanges() throws {
        let tolerance = FileStore.mediaDurationTolerance(video: QualityProfile.p720_30.video)
        let valid = timeRange(end: 10)
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertThrowsError(try FileStore.validateTiming(duration: duration, trackRanges: [valid, valid],
                                                              tolerance: tolerance))
        }
        XCTAssertThrowsError(try FileStore.validateTiming(duration: 10, trackRanges: [valid], tolerance: tolerance))
        let invalidRanges = [CMTimeRange(start: CMTime(value: -1, timescale: 1), duration: CMTime(value: 10, timescale: 1)),
                             CMTimeRange(start: .zero, duration: .zero),
                             CMTimeRange(start: .zero, duration: .invalid),
                             CMTimeRange(start: .zero, duration: .positiveInfinity)]
        for range in invalidRanges {
            XCTAssertThrowsError(try FileStore.validateTiming(duration: 10, trackRanges: [valid, range],
                                                              tolerance: tolerance))
        }
    }

    func testPreflightRejectsFileAsDirectoryWithoutDeletingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("user file".utf8).write(to: root)
        XCTAssertThrowsError(try FileStore.preflight(root: root))
        XCTAssertEqual(try Data(contentsOf: root), Data("user file".utf8))
    }

    func testPreflightLeavesNoProbeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileStore.preflight(root: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func fixture() throws -> (URL, RecordingContext, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selection = CaptureSelection(cameraID: "camera", audioDeviceID: "audio", leftChannel: 10,
                                          rightChannel: 11, video: QualityProfile.p720_30.video)
        let request = RecordingRequest(instrument: .guitar, selection: selection,
                                        settings: .init(root: root, quality: .p720_30, audioOffsetMs: 0))
        let startedAt = date("2026-10-29T14:15:30Z")
        let context = RecordingContext(request: request, startedAt: startedAt, startPTS: .zero, monotonicStart: 0)
        let folder = FileNaming.directory(root: root, instrument: .guitar, startedAt: startedAt)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, context, folder.appendingPathComponent(".recording-\(request.id).partial.mp4"))
    }

    private func timeRange(end: Double) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: end, preferredTimescale: 1_000_000))
    }
}
