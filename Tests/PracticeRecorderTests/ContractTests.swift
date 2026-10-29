import XCTest
@testable import PracticeRecorderCore
final class ContractTests: XCTestCase { func testFixedLimit() { XCTAssertEqual(RecordingSettings(root:URL(fileURLWithPath:"/tmp"),quality:.p1080_30,audioOffsetMs:0).limitSeconds,300) } }
