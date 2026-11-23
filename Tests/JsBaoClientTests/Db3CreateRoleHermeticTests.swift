import XCTest
@testable import JsBaoClient

/// #5998 behavior 44 (hermetic) — `DB3_CREATE_ROLE_REQUIRED`, the refusal of
/// a create, alias create or type attach the caller's role may not make, is a
/// case of `JsBaoErrorCode`.
final class Db3CreateRoleHermeticTests: XCTestCase {
    func testTheCreateRoleCodeIsAnErrorCode() {
        XCTAssertEqual(JsBaoErrorCode(rawValue: "DB3_CREATE_ROLE_REQUIRED"), .db3CreateRoleRequired)
        XCTAssertEqual(JsBaoErrorCode.db3CreateRoleRequired.rawValue, "DB3_CREATE_ROLE_REQUIRED")
    }
}
