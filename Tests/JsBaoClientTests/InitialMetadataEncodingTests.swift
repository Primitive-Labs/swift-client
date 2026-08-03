import XCTest
@testable import JsBaoClient

/// Server-free encoding tests for the create-time `initialMetadata` parameter
/// (issue #1451, parity with #1420).
///
/// `initialMetadata` is a create-only payload keyed by category name → that
/// category's values. These tests lock in the wire shape: the key is emitted
/// only when the caller sets it, it carries the nested category → values
/// object, and it is reachable from every initializer overload (including the
/// deprecated `contextId:` / `metadata:` / `celContext:` ones).
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

    /// Behavior 2 + edge case: the deprecated `contextId:` overload also
    /// accepts `initialMetadata`, and both keys encode side by side.
    /// `@available(*, deprecated)` on the test suppresses the intended
    /// call-site deprecation warning we are deliberately exercising.
    @available(*, deprecated)
    func testCollectionParamsDeprecatedContextIdOverloadCarriesInitialMetadata() throws {
        let dict = try encodedObject(
            CreateCollectionParams(
                name: "Class 42",
                contextId: "class-42",
                initialMetadata: ["settings": ["visibility": .string("class-only")]]
            )
        )
        XCTAssertEqual(dict["contextId"] as? String, "class-42")
        let initial = try XCTUnwrap(dict["initialMetadata"] as? [String: Any])
        XCTAssertNotNil(initial["settings"])
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
        // Distinct from the deprecated CEL-context keys.
        XCTAssertNil(dict["metadata"])
        XCTAssertNil(dict["celContext"])
    }

    /// Behavior 5: omitting it leaves the key off the wire.
    func testDatabaseParamsOmitInitialMetadataWhenUnset() throws {
        let dict = try encodedObject(CreateDatabaseParams(title: "A", databaseType: "t"))
        XCTAssertNil(dict["initialMetadata"])
    }

    /// Behavior 3 + edge case: the deprecated `metadata:` overload keeps its own
    /// wire key and also carries `initialMetadata`.
    @available(*, deprecated)
    func testDatabaseParamsDeprecatedMetadataOverloadCarriesInitialMetadata() throws {
        let dict = try encodedObject(
            CreateDatabaseParams(
                title: "A",
                databaseType: "t",
                metadata: ["k": .string("v")],
                initialMetadata: ["settings": ["visibility": .string("class-only")]]
            )
        )
        let metadata = try XCTUnwrap(dict["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["k"] as? String, "v")
        let initial = try XCTUnwrap(dict["initialMetadata"] as? [String: Any])
        XCTAssertNotNil(initial["settings"])
    }

    /// Behavior 3 + edge case: the deprecated `celContext:` overload likewise.
    @available(*, deprecated)
    func testDatabaseParamsDeprecatedCelContextOverloadCarriesInitialMetadata() throws {
        let dict = try encodedObject(
            CreateDatabaseParams(
                title: "A",
                databaseType: "t",
                celContext: ["k": .string("v")],
                initialMetadata: ["settings": ["visibility": .string("class-only")]]
            )
        )
        let celContext = try XCTUnwrap(dict["celContext"] as? [String: Any])
        XCTAssertEqual(celContext["k"] as? String, "v")
        let initial = try XCTUnwrap(dict["initialMetadata"] as? [String: Any])
        XCTAssertNotNil(initial["settings"])
    }
}
