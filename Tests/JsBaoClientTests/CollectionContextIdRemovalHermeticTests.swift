import XCTest
@testable import JsBaoClient

/// #3926 — collection `contextId` is removed from the platform.
///
/// The server no longer returns the key and refuses a create that sends it, so
/// the client types carry no such member: `CollectionInfo` decodes a response
/// that has none, and `CreateCollectionParams` has nothing that could put the
/// key on the wire. A collection is bound to an external entity through
/// `initialMetadata` (a resource metadata category) instead.
///
/// Server-free (`*HermeticTests`): the types are read with `Mirror`, and the
/// payloads are literals.
final class CollectionContextIdRemovalHermeticTests: XCTestCase {

    private func storedProperties(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap { $0.label }
    }

    func testCollectionInfoDeclaresNoContextId() throws {
        let json = """
        {
          "collectionId": "dc_1",
          "appId": "app_1",
          "name": "Class 42",
          "description": null,
          "collectionType": "class-posts",
          "documentCount": 0,
          "createdAt": "2026-09-29T00:00:00.000Z",
          "createdBy": "u_1",
          "modifiedAt": "2026-09-29T00:00:00.000Z"
        }
        """.data(using: .utf8)!
        let info = try JSONDecoder().decode(CollectionInfo.self, from: json)
        XCTAssertEqual(info.collectionType, "class-posts")
        let labels = storedProperties(of: info)
        XCTAssertTrue(labels.contains("collectionType"), "\(labels)")
        XCTAssertFalse(labels.contains("contextId"), "\(labels)")
    }

    func testCreateCollectionParamsDeclaresNoContextIdAndBindsWithInitialMetadata() throws {
        let params = CreateCollectionParams(
            name: "Class 42",
            collectionType: "class-posts",
            initialMetadata: ["classLink": ["classId": .string("class-42")]]
        )
        let labels = storedProperties(of: params)
        XCTAssertTrue(labels.contains("initialMetadata"), "\(labels)")
        XCTAssertFalse(labels.contains("contextId"), "\(labels)")

        let data = try JSONEncoder().encode(params)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(dict["contextId"])
        let initial = try XCTUnwrap(dict["initialMetadata"] as? [String: Any])
        let classLink = try XCTUnwrap(initial["classLink"] as? [String: Any])
        XCTAssertEqual(classLink["classId"] as? String, "class-42")
    }
}
