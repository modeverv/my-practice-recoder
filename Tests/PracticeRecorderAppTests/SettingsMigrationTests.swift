import XCTest
@testable import PracticeRecorderApp
import PracticeRecorderCore

final class SettingsMigrationTests: XCTestCase {
 func testLegacySettingsKeepCameraRMEChannelsAndManualValue() throws {
  let data=try JSONSerialization.data(withJSONObject:["rootPath":"/tmp/user-recordings","cameraID":"user-camera","audioDeviceID":"user-rme","leftChannel":10,"rightChannel":11,"quality":"p1080_30","audioOffsetMs":170,"instrument":"bass"])
  let settings=try JSONDecoder().decode(AppSettings.self,from:data)
  XCTAssertEqual(settings.cameraID,"user-camera"); XCTAssertEqual(settings.audioDeviceID,"user-rme")
  XCTAssertEqual(settings.leftChannel,10); XCTAssertEqual(settings.rightChannel,11)
  XCTAssertEqual(settings.rootPath,"/tmp/user-recordings"); XCTAssertEqual(settings.instrument,.bass)
  XCTAssertEqual(settings.audioOffsetMs,170)
  XCTAssertEqual(settings.effectiveSynchronizationMode,.automaticPTS)
  XCTAssertEqual(AVSynchronizationPlan(mode:settings.effectiveSynchronizationMode,manualOffsetMs:settings.audioOffsetMs).effectiveAudioOffsetMs,0)
 }
 func testNewModePersistsWithoutDestroyingManualCorrection() throws {
  var settings=AppSettings(); settings.audioOffsetMs = -120
  settings.synchronizationMode = .manual
  var restored=try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings))
  XCTAssertEqual(restored.effectiveSynchronizationMode,.manual)
  XCTAssertEqual(AVSynchronizationPlan(mode:restored.effectiveSynchronizationMode,manualOffsetMs:restored.audioOffsetMs).effectiveAudioOffsetMs,-120)
  restored.synchronizationMode = .automaticPTS
  restored=try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(restored))
  XCTAssertEqual(restored.audioOffsetMs,-120)
  XCTAssertEqual(AVSynchronizationPlan(mode:restored.effectiveSynchronizationMode,manualOffsetMs:restored.audioOffsetMs).effectiveAudioOffsetMs,0)
 }
}
