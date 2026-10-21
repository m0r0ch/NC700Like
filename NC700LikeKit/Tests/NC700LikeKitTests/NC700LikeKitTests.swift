import XCTest
@testable import NC700LikeKit

final class NC700LikeKitTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(NC700LikeKitInfo.version.isEmpty)
    }
}
