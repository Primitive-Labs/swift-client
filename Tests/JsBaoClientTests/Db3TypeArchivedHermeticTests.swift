import XCTest
@testable import JsBaoClient

/// #6020 behavior 20 (hermetic) — `DB3_TYPE_ARCHIVED`, the refusal of a
/// create, alias create or type attach of a db3 type the app archived, is a
/// case of `JsBaoErrorCode`.
final class Db3TypeArchivedHermeticTests: XCTestCase {
    func testTheArchivedCodeIsAnErrorCode() {
        XCTAssertEqual(JsBaoErrorCode(rawValue: "DB3_TYPE_ARCHIVED"), .db3TypeArchived)
        XCTAssertEqual(JsBaoErrorCode.db3TypeArchived.rawValue, "DB3_TYPE_ARCHIVED")
    }
}
