import XCTest
@testable import MaiCore

final class SmokeTests: XCTestCase {
    func testVersion() { XCTAssertFalse(MaiCore.version.isEmpty) }
}
