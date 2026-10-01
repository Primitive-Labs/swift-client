import XCTest
@testable import JsBaoClient

/// Server-free encoding tests for `CreateGroupParams.initialMetadata`
/// (issue #3983, parity with `CreateCollectionParams.initialMetadata`).
///
/// The live half — the server stamps the categories and an invalid entry fails
/// the whole create — is in `InitialMetadataCreateTests`.
final class GroupsCreateInitialMetadataHermeticTests: XCTestCase {
    private func encodedObject<T: Encodable>(_ params: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(params)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    /// The initializer accepts `initialMetadata` and encodes it under the
    /// `initialMetadata` wire key as category → values.
    func testGroupParamsEncodeInitialMetadata() throws {
        let dict = try encodedObject(
            CreateGroupParams(
                groupType: "class-reading-group",
                name: "Reading group",
                initialMetadata: ["classLink": ["classId": .string("class-A")]]
            )
        )
        XCTAssertEqual(dict["groupType"] as? String, "class-reading-group")
        XCTAssertEqual(dict["name"] as? String, "Reading group")
        let initial = try XCTUnwrap(dict["initialMetadata"] as? [String: Any])
        let classLink = try XCTUnwrap(initial["classLink"] as? [String: Any])
        XCTAssertEqual(classLink["classId"] as? String, "class-A")
    }

    /// Omitting it leaves the key off the wire, so existing creates are
    /// unchanged.
    func testGroupParamsOmitInitialMetadataWhenUnset() throws {
        let dict = try encodedObject(
            CreateGroupParams(groupType: "team", groupId: "eng", name: "Engineering")
        )
        XCTAssertNil(dict["initialMetadata"])
        XCTAssertEqual(dict["groupId"] as? String, "eng")
    }
}
