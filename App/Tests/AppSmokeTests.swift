import XCTest
@testable import MaiChartStudio
import MaiCore

final class AppSmokeTests: XCTestCase {
    func testCoreLinked() {
        XCTAssertFalse(MaiCore.version.isEmpty)
    }
}
