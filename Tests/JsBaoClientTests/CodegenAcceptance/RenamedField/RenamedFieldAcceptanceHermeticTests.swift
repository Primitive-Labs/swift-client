import Foundation
import XCTest
@testable import JsBaoClient

/// #6023 behavior 28 (the emitted file compiles) and E13 — the struct
/// `swift-bao-codegen` emits for `Fixtures/stored-as-6023/renamed-6023.toml`
/// (`dueAt` stored as `due`), committed here so the test target compiles it.
///
/// The property is `dueAt`; every key the struct hands the runtime, and its
/// `Codable` JSON, is `due`.
final class RenamedFieldAcceptanceHermeticTests: XCTestCase {

    func testTheSchemaDeclaresTheStoredNameAndCarriesTheMap() {
        let schema = RenamedTask6023.primitiveSchema
        XCTAssertNotNil(schema.fields["due"])
        XCTAssertNil(schema.fields["dueAt"])
        XCTAssertEqual(schema.fieldNames, ["dueAt": "due"])
        XCTAssertEqual(schema.fieldNameTypes, ["tasks6023"])
        XCTAssertEqual(schema.resolvedUniqueConstraints.map(\.name), ["renamed_tasks_due_unique"])
    }

    func testValuesAndRowsUseTheStoredName() throws {
        let task = RenamedTask6023(id: "t1", title: "Plan", dueAt: 5)
        XCTAssertEqual(task.primitiveValues()["due"], .number(5))
        XCTAssertNil(task.primitiveValues()["dueAt"])
        let row: [String: JSONValue] = ["id": .string("t2"), "title": .string("Row"), "due": .number(7)]
        XCTAssertEqual(RenamedTask6023(row: row)?.dueAt, 7)
    }

    /// E13: encoding writes `due`; decoding JSON with `due` fills `dueAt`.
    func testCodableUsesTheStoredName() throws {
        let encoded = try JSONEncoder().encode(RenamedTask6023(id: "t3", title: "C", dueAt: 9))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["due"] as? Double, 9)
        XCTAssertNil(object["dueAt"])
        let decoded = try JSONDecoder().decode(RenamedTask6023.self, from: Data(#"{"id":"t4","title":"D","due":11}"#.utf8))
        XCTAssertEqual(decoded.dueAt, 11)
        XCTAssertTrue(decoded.primitiveValues().keys.contains("due"))
    }
}
