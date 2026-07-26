import XCTest

@testable import MIBKit

final class MIBKitTests: XCTestCase {
    func testVersionIsPopulated() {
        XCTAssertFalse(MIBKit.version.isEmpty)
    }
}
