import XCTest
@testable import JsBaoClient

/// Server-free encoding tests for `CreateGroupParams.initialMetadata`
/// (issue #3983, parity with `CreateCollectionParams.initialMetadata`).
///
/// The live half — the server stamps the categories and an invalid entry fails
/// the whole create — is in `InitialMetadataCreateTests`.
///
/// `CreateGroupParams` is deprecated with `groups.create` (a session cannot
/// create a group, #4737), so these pins are deprecated test methods.
final class GroupsCreateInitialMetadataHermeticTests: XCTestCase {
    private func encodedObject<T: Encodable>(_ params: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(params)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    /// The initializer accepts `initialMetadata` and encodes it under the
    /// `initialMetadata` wire key as category → values.
    @available(*, deprecated)
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
    /// unchanged. No `groupId` goes on the wire either: the server mints it
    /// (#4917).
    @available(*, deprecated)
    func testGroupParamsOmitInitialMetadataWhenUnset() throws {
        let dict = try encodedObject(
            CreateGroupParams(groupType: "team", name: "Engineering")
        )
        XCTAssertNil(dict["initialMetadata"])
        XCTAssertNil(dict["groupId"])
    }

    /// The params carry no `groupId` at all, so a caller cannot name the new
    /// group's id: the server mints it and answers it on `GroupInfo` (#4917).
    @available(*, deprecated)
    func testGroupParamsDeclareNoGroupId() {
        let labels = Mirror(reflecting: CreateGroupParams(groupType: "team", name: "Engineering"))
            .children.compactMap(\.label)
        XCTAssertEqual(labels.sorted(), ["description", "groupType", "initialMetadata", "name"])
    }
}
