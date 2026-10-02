import XCTest
@testable import JsBaoClient

/// Server-free encoding tests for the create-time `initialMetadata` parameter
/// (issue #1451, parity with #1420).
///
/// `initialMetadata` is a create-only payload keyed by category name → that
/// category's values. These tests lock in the wire shape: the key is emitted
/// only when the caller sets it, and it carries the nested category → values
/// object.
final class InitialMetadataEncodingTests: XCTestCase {
    private func encodedObject<T: Encodable>(_ params: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(params)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    // MARK: CreateCollectionParams

    /// Behavior 1: the non-deprecated initializer accepts `initialMetadata` and
    /// encodes it under the `initialMetadata` wire key as category → values.
    func testCollectionParamsEncodeInitialMetadata() throws {
        let dict = try encodedObject(
            CreateCollectionParams(
                name: "Class 42",
                initialMetadata: ["settings": ["visibility": .string("class-only")]]
            )
        )
        XCTAssertEqual(dict["name"] as? String, "Class 42")
        let initial = try XCTUnwrap(dict["initialMetadata"] as? [String: Any])
        let settings = try XCTUnwrap(initial["settings"] as? [String: Any])
        XCTAssertEqual(settings["visibility"] as? String, "class-only")
    }

    /// Behavior 5: omitting it leaves the key off the wire — existing creates
    /// are byte-for-byte unchanged.
    func testCollectionParamsOmitInitialMetadataWhenUnset() throws {
        let dict = try encodedObject(CreateCollectionParams(name: "Plain"))
        XCTAssertNil(dict["initialMetadata"])
    }

    // MARK: CreateDatabaseParams

    /// Behavior 3 + 4: the plain initializer accepts `initialMetadata` and
    /// encodes it under the `initialMetadata` wire key.
    func testDatabaseParamsEncodeInitialMetadata() throws {
        let dict = try encodedObject(
            CreateDatabaseParams(
                title: "Class Roster",
                databaseType: "roster",
                initialMetadata: ["settings": ["visibility": .string("class-only")]]
            )
        )
        XCTAssertEqual(dict["title"] as? String, "Class Roster")
        XCTAssertEqual(dict["databaseType"] as? String, "roster")
        let initial = try XCTUnwrap(dict["initialMetadata"] as? [String: Any])
        let settings = try XCTUnwrap(initial["settings"] as? [String: Any])
        XCTAssertEqual(settings["visibility"] as? String, "class-only")
        // The retired CEL-context keys are never sent (#3991).
        XCTAssertNil(dict["metadata"])
        XCTAssertNil(dict["celContext"])
    }

    /// Behavior 5: omitting it leaves the key off the wire.
    func testDatabaseParamsOmitInitialMetadataWhenUnset() throws {
        let dict = try encodedObject(CreateDatabaseParams(title: "A", databaseType: "t"))
        XCTAssertNil(dict["initialMetadata"])
    }
}
