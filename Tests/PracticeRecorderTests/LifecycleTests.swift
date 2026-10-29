import XCTest
@testable import PracticeRecorderCore
final class LifecycleTests: XCTestCase {
 func testRapidStartArmingStopAndSavingRestart() {
  var s=TakeLifecycle(); let id=UUID()
  XCTAssertTrue(s.begin(id:id)); XCTAssertFalse(s.begin(id:UUID()))
  XCTAssertTrue(s.stop(id:id)); XCTAssertFalse(s.started(id:id)); XCTAssertFalse(s.begin(id:UUID()))
  XCTAssertTrue(s.complete(id:id,failed:true)); XCTAssertEqual(s.phase,.error)
 }
 func testStopRacesAndStaleTake() {
  for _ in 0..<100 {
   var s=TakeLifecycle(); let id=UUID(); XCTAssertTrue(s.begin(id:id)); XCTAssertTrue(s.started(id:id))
   XCTAssertTrue(s.stop(id:id)); XCTAssertFalse(s.stop(id:id)); XCTAssertFalse(s.stop(id:id))
   XCTAssertTrue(s.complete(id:id,failed:false)); XCTAssertFalse(s.complete(id:id,failed:false))
   let next=UUID(); XCTAssertTrue(s.begin(id:next)); XCTAssertFalse(s.stop(id:id)); XCTAssertFalse(s.complete(id:id,failed:false)); XCTAssertEqual(s.phase,.arming)
  }
 }
 func testFakeMonotonicTimeAndStaleTimer() {
  let id=UUID(); let d=RecordingDeadline(id:id,start:1000)
  XCTAssertFalse(d.expired(id:id,now:1299.9)); XCTAssertTrue(d.expired(id:id,now:1300)); XCTAssertTrue(d.expired(id:id,now:1300.1))
  XCTAssertEqual(d.elapsed(now:1300.1),300); XCTAssertFalse(d.expired(id:UUID(),now:1500))
  // No Date/run-loop dependency: wall clock and frozen UI cannot affect the deadline.
  XCTAssertEqual(d.elapsed(now:1137),137)
 }
}
