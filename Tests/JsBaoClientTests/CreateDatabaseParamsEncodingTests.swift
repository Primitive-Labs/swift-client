import XCTest
@testable import JsBaoClient

/// Server-free encoding tests for `CreateDatabaseParams` (issue #1820).
///
/// The fix deprecated the legacy `metadata:` alias initializer path so both the
/// `metadata:` and `celContext:` spellings surface the migration warning. The
/// deprecation is compile-time only — it must NOT change how the struct encodes.
/// These tests lock in that invariant: each spelling still encodes to its own
/// wire key (the server treats both as the same legacy CEL-context field), and
/// the plain initializer emits neither key.
final class CreateDatabaseParamsEncodingTests: XCTestCase {
    private func encodedObject(_ params: CreateDatabaseParams) throws -> [String: Any] {
        let data = try JSONEncoder().encode(params)
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any])
    }

    /// The plain, non-deprecated initializer encodes neither CEL-context key.
    func testPlainInitEncodesNoCelContextKeys() throws {
        let dict = try encodedObject(CreateDatabaseParams(title: "A", databaseType: "t"))
        XCTAssertEqual(dict["title"] as? String, "A")
        XCTAssertEqual(dict["databaseType"] as? String, "t")
        XCTAssertNil(dict["metadata"])
        XCTAssertNil(dict["celContext"])
    }

    /// The legacy `metadata:` alias still encodes under the `metadata` wire key.
    /// `@available(*, deprecated)` on the test suppresses the intended
    /// call-site deprecation warning we are deliberately exercising.
    @available(*, deprecated)
    func testMetadataAliasStillEncodesUnderMetadataKey() throws {
        let dict = try encodedObject(
            CreateDatabaseParams(title: "A", databaseType: "t", metadata: ["k": .string("v")])
        )
        let metadata = try XCTUnwrap(dict["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["k"] as? String, "v")
        XCTAssertNil(dict["celContext"])
    }

    /// `celContext:` still encodes under the `celContext` wire key.
    @available(*, deprecated)
    func testCelContextStillEncodesUnderCelContextKey() throws {
        let dict = try encodedObject(
            CreateDatabaseParams(title: "A", databaseType: "t", celContext: ["k": .string("v")])
        )
        let celContext = try XCTUnwrap(dict["celContext"] as? [String: Any])
        XCTAssertEqual(celContext["k"] as? String, "v")
        XCTAssertNil(dict["metadata"])
    }
}
