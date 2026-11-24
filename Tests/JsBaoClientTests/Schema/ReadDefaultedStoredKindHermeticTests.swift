import Foundation
import XCTest
@testable import JsBaoClient
import YSwift

/// #6304 phase 2, behavior 64's pin: what a generated model is built from.
/// A db3 record's raw value and a db3 query row carry each value as it is
/// stored (`true`, `1`, `"5"`, `"soon"`), so a read-defaulted field can be
/// judged on the stored kind when the model is built. On a Y.Map document the
/// query row holds a stored boolean as SQLite's integer, as it holds a stored
/// `1`. `ReadDefaultedRuntimeHermeticTests` reads the same stores.
final class ReadDefaultedStoredKindHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private static let schema = PrimitiveSchema(name: "marks", fields: [
        "id": FieldDescriptor(type: .id, autoAssign: true),
        "label": FieldDescriptor(type: .string, default: .scalar(.string("none"))),
        "ident": FieldDescriptor(type: .id),
        "score": FieldDescriptor(type: .number, default: .scalar(.number(7))),
        "on": FieldDescriptor(type: .boolean, default: .scalar(.boolean(true))),
        "due": FieldDescriptor(type: .date, default: .scalar(.string("2026-01-01T00:00:00.000Z"))),
    ])

    private static let declared: [String: [String: String]] = [
        "marks": ["label": "string", "ident": "id", "score": "number", "on": "boolean", "due": "date"],
    ]

    /// A db3 binding of a typed type over its own store, with the marks model bound to it.
    private func db3() async throws -> (binding: RecordLogDocumentBinding, model: DynamicModel) {
        let directory = NSTemporaryDirectory() + "/read-defaulted-runtime-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let documentId = "rl-read-defaulted-\(UUID().uuidString.prefix(8))"
        RecordLogDocumentIds.note(documentId)
        let binding = try RecordLogDocumentBinding(host: provider, documentId: documentId, clientId: "client-1", logger: Logger(level: .none))
        try binding.setState(type: .typed(name: "marks", hash: "h1", models: Self.declared))
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: Self.schema)
        try model.bindRecordLog(binding)
        return (binding, model)
    }

    /// Write record `id` holding exactly `fields`, as another client or a
    /// workflow could have stored it.
    private func store(_ binding: RecordLogDocumentBinding, _ id: String, _ fields: [String: JSONValue]) throws {
        var values = fields
        values["id"] = .string(id)
        _ = try binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: Self.schema.name, id: id, kind: .create, fields: values),
        ])])
    }

    private func row(_ model: DynamicModel, _ id: String) throws -> [String: JSONValue] {
        try XCTUnwrap(try model.query(nil).first { $0["id"]?.stringValue == id }, id)
    }

    // MARK: - Behavior 64's pin: what a model is built from

    func testADb3RecordAndRowCarryEachValueAsStored() async throws {
        let (binding, model) = try await db3()
        try store(binding, "t", ["on": true, "score": "5", "due": "soon"])
        try store(binding, "n", ["on": 1, "score": 5, "due": 0])
        let t = try XCTUnwrap(model.find(id: "t"))
        let n = try XCTUnwrap(model.find(id: "n"))
        XCTAssertEqual(t.rawValue(for: "on"), "true")
        XCTAssertEqual(n.rawValue(for: "on"), "1")
        XCTAssertEqual(t.rawValue(for: "score"), "\"5\"")
        XCTAssertEqual(t.rawValue(for: "due"), "\"soon\"")
        XCTAssertEqual(n.rawValue(for: "due"), "0")
        let tRow = try row(model, "t")
        let nRow = try row(model, "n")
        XCTAssertEqual(tRow["on"], .bool(true), "a db3 row holds a stored boolean as a boolean")
        XCTAssertEqual(nRow["on"], .number(1), "and a stored number as a number")
        XCTAssertEqual(tRow["score"], .string("5"))
        XCTAssertEqual(tRow["due"], .string("soon"))
        XCTAssertEqual(nRow["due"], .number(0))
        let found = try XCTUnwrap(model.find(id: "t")).id
        XCTAssertEqual(found, "t")
    }

    func testAYMapRowHoldsAStoredBooleanAsAnInteger() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        var numeric = Self.schema
        numeric.fields["on"] = FieldDescriptor(type: .number)
        _ = try DynamicModel(doc: doc, schema: numeric).create(id: "one", values: ["on": .number(1)])
        _ = try DynamicModel(doc: doc, schema: Self.schema).create(id: "yes", values: ["on": .boolean(true)])
        let model = DynamicModel(doc: doc, schema: Self.schema)
        XCTAssertEqual(try XCTUnwrap(model.find(id: "one")).rawValue(for: "on"), "1")
        XCTAssertEqual(try XCTUnwrap(model.find(id: "yes")).rawValue(for: "on"), "true")
        let rows = try model.query(nil)
        XCTAssertEqual(rows.first { $0["id"]?.stringValue == "yes" }?["on"], .number(1), "SQLite holds a boolean as INTEGER")
        XCTAssertEqual(rows.first { $0["id"]?.stringValue == "one" }?["on"], .number(1))
    }
}
