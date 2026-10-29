import XCTest
@testable import PracticeRecorderCore

final class AVSynchronizationTests: XCTestCase {
    func testAutomaticModeIgnoresExistingManualCorrection() {
        for oldCorrection in [Int.min, -500, -120, 0, 120, 500, Int.max] {
            let automatic = AVSynchronizationPlan(mode: .automaticPTS, manualOffsetMs: oldCorrection)
            XCTAssertEqual(automatic.mode, .automaticPTS)
            XCTAssertEqual(automatic.effectiveAudioOffsetMs, 0)
        }
    }

    func testSwitchingModesKeepsManualCorrectionAvailable() {
        let storedCorrection = -130
        let firstManual = AVSynchronizationPlan(mode: .manual, manualOffsetMs: storedCorrection)
        let automatic = AVSynchronizationPlan(mode: .automaticPTS, manualOffsetMs: storedCorrection)
        let restoredManual = AVSynchronizationPlan(mode: .manual, manualOffsetMs: storedCorrection)
        XCTAssertEqual(firstManual.effectiveAudioOffsetMs, -130)
        XCTAssertEqual(automatic.effectiveAudioOffsetMs, 0)
        XCTAssertEqual(restoredManual, firstManual)
    }

    func testManualCorrectionRetainsSignAndUsesTenMillisecondSteps() {
        for (requested, expected) in [(-25, -30), (-24, -20), (-15, -20), (-14, -10), (-5, -10), (-4, 0), (0, 0), (4, 0), (5, 10), (14, 10), (15, 20), (24, 20), (25, 30)] {
            XCTAssertEqual(AVSynchronizationPlan(mode: .manual, manualOffsetMs: requested).effectiveAudioOffsetMs, expected)
        }
    }

    func testManualCorrectionClampsBeforeQuantizingEvenExtremeIntegers() {
        for (requested, expected) in [(Int.min, -500), (-501, -500), (-500, -500), (500, 500), (501, 500), (Int.max, 500)] {
            XCTAssertEqual(AVSynchronizationPlan(mode: .manual, manualOffsetMs: requested).effectiveAudioOffsetMs, expected)
        }
    }

    func testModeSurvivesSettingsSerialization() throws {
        for mode in AVSynchronizationMode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(AVSynchronizationMode.self, from: data), mode)
        }
    }
}
