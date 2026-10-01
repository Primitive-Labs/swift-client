import XCTest
@testable import JsBaoClient

/// `AnalyticsEventInput` no longer carries `user_created_at_epoch_s` (#4003).
///
/// The field was client-supplied, so an app could put any number in it. The
/// server records when the user joined the app and ignores the key, so the
/// Swift input stopped exposing it and its encoded row stopped sending it.
///
/// Server-free: these build an input and read its two bridges.
final class AnalyticsSignupFieldRemovedHermeticTests: XCTestCase {

    private static let removedKey = "user_created_at_epoch_s"

    private func fullyPopulated() -> AnalyticsEventInput {
        AnalyticsEventInput(
            action: "a", feature: "b", route: "c", plan: "d", tenant_id: "e",
            user_ulid: "f", device_type: "g", os_name: "h", os_version: "i",
            browser_name: "j", browser_version: "k", app_version: "l",
            context_json: .object(["m": .string("n")])
        )
    }

    func testInputHasNoSignupField() {
        let labels = Mirror(reflecting: AnalyticsEventInput(action: "a"))
            .children.compactMap(\.label)
        XCTAssertFalse(labels.contains(Self.removedKey),
                       "AnalyticsEventInput still declares \(Self.removedKey)")
    }

    func testBridgesEmitThirteenKeysWithoutTheSignupField() {
        let input = fullyPopulated()
        let json = input.asJSONObject()
        let dict = input.asDictionary()

        XCTAssertEqual(json.count, 13)
        XCTAssertEqual(dict.count, 13)
        XCTAssertNil(json[Self.removedKey])
        XCTAssertNil(dict[Self.removedKey])
        XCTAssertEqual(Set(json.keys), Set(dict.keys),
                       "the typed and untyped bridges must spell the same fields")
    }
}
