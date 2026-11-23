import Foundation
import XCTest
@testable import JsBaoClient
import YSwift

/// #6304 phase 2 — what the runtime answers a generated model that reads a
/// read-defaulted field (a scalar field whose `default` is a literal of its
/// type).
///
/// - Behavior 64's pin: a db3 record and a db3 query row carry each value as
///   it is stored (`true`, `1`, `"5"`, `"soon"`), so the kind can still be
///   judged when a model is built; on a Y.Map document the query row holds a
///   stored boolean as SQLite's integer.
/// - `fittingValue` answers a field's value only when it is of the kind the
///   field takes, judged on the stored kind as a typed db3 judges a write: a
///   string for `string`, a finite number for `number`, a boolean for
///   `boolean`, an ISO date on a real calendar day (or an epoch number) for
///   `date`. On a Y.Map document a stored `0` or `1` in a boolean field is a
///   boolean, as both clients read it there (#2825).
/// - Behavior 29: `isCleared` answers whether the db3's held revision clears
///   a field, for a record and for a query row; a Y.Map record or row that
///   merely lacks the field answers `false`. `holds` answers as before.
final class ReadDefaultedRuntimeHermeticTests: XCTestCase {

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

    // MARK: - fittingValue: the stored kind decides

    func testADb3ValueFitsOnlyWhenItIsOfTheFieldsKind() async throws {
        let (binding, model) = try await db3()
        try store(binding, "ok", [
            "label": "x", "ident": "i1", "score": 0, "on": false, "due": "2026-03-04T05:06:07.000Z",
        ])
        try store(binding, "epoch", ["due": 0, "on": true])
        try store(binding, "wrong", ["label": 5, "ident": ["a"], "score": "5", "on": 1, "due": "soon"])
        try store(binding, "wrong2", ["label": .object(["a": 1]), "score": true, "on": "true", "due": "2026-02-30"])
        try store(binding, "wrong3", ["label": true, "on": 0, "due": "2026-01-01 1:00 PM"])
        try store(binding, "empty", ["label": .null, "score": .null, "on": .null, "due": .null])
        try store(binding, "missing", [:])

        func both(_ id: String, _ field: String, _ type: PrimitiveFieldType) throws -> [PrimitiveValue?] {
            [try XCTUnwrap(model.find(id: id)).fittingValue(field, as: type),
             PrimitiveRecord.fittingValue(field, as: type, in: try row(model, id))]
        }
        XCTAssertEqual(try both("ok", "label", .string), [.string("x"), .string("x")])
        XCTAssertEqual(try both("ok", "ident", .id), [.id("i1"), .id("i1")])
        XCTAssertEqual(try both("ok", "score", .number), [.number(0), .number(0)], "a stored 0 is a number, not absent")
        XCTAssertEqual(try both("ok", "on", .boolean), [.boolean(false), .boolean(false)])
        XCTAssertEqual(try both("ok", "due", .date), [.date("2026-03-04T05:06:07.000Z"), .date("2026-03-04T05:06:07.000Z")])
        XCTAssertEqual(try both("epoch", "due", .date), [.date("1970-01-01T00:00:00.000Z"), .date("1970-01-01T00:00:00.000Z")],
                       "an epoch number is a date a typed db3 takes, read as its ISO string")
        XCTAssertEqual(try both("epoch", "on", .boolean), [.boolean(true), .boolean(true)])
        for (id, field, type) in [
            ("wrong", "label", PrimitiveFieldType.string), ("wrong", "ident", .id), ("wrong", "score", .number),
            ("wrong", "on", .boolean), ("wrong", "due", .date),
            ("wrong2", "label", .string), ("wrong2", "score", .number), ("wrong2", "on", .boolean), ("wrong2", "due", .date),
            ("wrong3", "label", .string), ("wrong3", "on", .boolean), ("wrong3", "due", .date),
            ("empty", "label", .string), ("empty", "score", .number), ("empty", "on", .boolean), ("empty", "due", .date),
            ("missing", "label", .string), ("missing", "score", .number), ("missing", "on", .boolean), ("missing", "due", .date),
        ] {
            XCTAssertEqual(try both(id, field, type), [nil, nil], "\(id).\(field)")
        }
    }

    func testOnAYMapDocumentANumericBooleanFits() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        var loose = Self.schema
        loose.fields["on"] = FieldDescriptor(type: .number)
        loose.fields["score"] = FieldDescriptor(type: .string)
        loose.fields["due"] = FieldDescriptor(type: .string)
        let writer = DynamicModel(doc: doc, schema: loose)
        _ = try writer.create(id: "one", values: ["on": .number(1)])
        _ = try writer.create(id: "zero", values: ["on": .number(0)])
        _ = try writer.create(id: "five", values: ["on": .number(5), "score": .string("5"), "due": .string("soon")])
        _ = try DynamicModel(doc: doc, schema: Self.schema).create(id: "yes", values: ["on": .boolean(true), "score": .number(2)])
        let model = DynamicModel(doc: doc, schema: Self.schema)
        let rows = try model.query(nil)
        func row(_ id: String) throws -> [String: JSONValue] { try XCTUnwrap(rows.first { $0["id"]?.stringValue == id }, id) }
        func record(_ id: String) throws -> PrimitiveRecord { try XCTUnwrap(model.find(id: id), id) }

        XCTAssertEqual(try record("one").fittingValue("on", as: .boolean), .boolean(true))
        XCTAssertEqual(try record("zero").fittingValue("on", as: .boolean), .boolean(false))
        XCTAssertEqual(try record("yes").fittingValue("on", as: .boolean), .boolean(true))
        XCTAssertNil(try record("five").fittingValue("on", as: .boolean), "only 0 and 1 are booleans")
        XCTAssertNil(try record("five").fittingValue("score", as: .number))
        XCTAssertNil(try record("five").fittingValue("due", as: .date))
        XCTAssertEqual(try record("yes").fittingValue("score", as: .number), .number(2))
        XCTAssertNil(try record("one").fittingValue("score", as: .number))
        XCTAssertEqual(PrimitiveRecord.fittingValue("on", as: .boolean, in: try row("one")), .boolean(true))
        XCTAssertEqual(PrimitiveRecord.fittingValue("on", as: .boolean, in: try row("zero")), .boolean(false))
        XCTAssertEqual(PrimitiveRecord.fittingValue("on", as: .boolean, in: try row("yes")), .boolean(true),
                       "a stored true the row holds as SQLite's 1 reads true")
        XCTAssertNil(PrimitiveRecord.fittingValue("score", as: .number, in: try row("one")))
        // The row the mirror holds a stored 5 in as `true` reads as its record does.
        XCTAssertNil(PrimitiveRecord.fittingValue("on", as: .boolean, in: try row("five")), "only 0 and 1 are booleans, on a row too")
        XCTAssertNil(PrimitiveRecord.fittingValue("score", as: .number, in: try row("five")))
        XCTAssertNil(PrimitiveRecord.fittingValue("due", as: .date, in: try row("five")))
    }

    /// A Y.Map query row lists a stored value its columns do not carry as
    /// stored, so it reads as the record does; filters still match the
    /// columns.
    func testAYMapRowReadsTheStoredKindItsColumnsConvert() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        var loose = Self.schema
        loose.fields["on"] = FieldDescriptor(type: .number)
        loose.fields["due"] = FieldDescriptor(type: .number)
        let writer = DynamicModel(doc: doc, schema: loose)
        _ = try writer.create(id: "five", values: ["on": .number(5), "due": .number(86_400_000)])
        _ = try writer.create(id: "minus", values: ["on": .number(-1)])
        _ = try writer.create(id: "one", values: ["on": .number(1)])
        let model = DynamicModel(doc: doc, schema: Self.schema)
        let rows = try model.query(nil)
        func row(_ id: String) throws -> [String: JSONValue] { try XCTUnwrap(rows.first { $0["id"]?.stringValue == id }, id) }
        func record(_ id: String) throws -> PrimitiveRecord { try XCTUnwrap(model.find(id: id), id) }

        for id in ["five", "minus"] {
            XCTAssertNil(try record(id).fittingValue("on", as: .boolean), id)
            XCTAssertNil(PrimitiveRecord.fittingValue("on", as: .boolean, in: try row(id)), "\(id): the row reads as the record")
        }
        XCTAssertEqual(try record("five").fittingValue("due", as: .date), .date("1970-01-02T00:00:00.000Z"))
        XCTAssertEqual(PrimitiveRecord.fittingValue("due", as: .date, in: try row("five")), .date("1970-01-02T00:00:00.000Z"),
                       "an epoch number the mirror leaves out is a date on the row too")
        XCTAssertEqual(PrimitiveRecord.fittingValue("on", as: .boolean, in: try row("one")), .boolean(true))
        XCTAssertNil(try row("one")["_meta_stored"], "a row whose columns carry every value as stored lists none")
        // The columns are as before, so a filter matches as before.
        XCTAssertEqual(Set(try model.query(["on": .bool(true)]).compactMap { $0["id"]?.stringValue }), ["five", "minus", "one"])
        // A projected row lists the stored values of the fields it answers, and no others.
        let projected = try model.query(nil, options: QueryOptions(projection: ["label": 0]))
        let five = try XCTUnwrap(projected.first { $0["id"]?.stringValue == "five" })
        XCTAssertNil(PrimitiveRecord.fittingValue("on", as: .boolean, in: five), "a projected row reads as the record")
        XCTAssertEqual(PrimitiveRecord.fittingValue("due", as: .date, in: five), .date("1970-01-02T00:00:00.000Z"))
        let onlyDue = try model.query(nil, options: QueryOptions(projection: ["due": 1]))
        XCTAssertEqual(try XCTUnwrap(onlyDue.first { $0["id"]?.stringValue == "five" })["_meta_stored"], .object(["due": .number(86_400_000)]))
    }

    // MARK: - Dates: the shared fixture

    private struct DatesFixture: Decodable {
        struct Stored: Decodable {
            let value: JSONValue
            let fits: Bool
        }
        let stored: [Stored]
    }

    /// `tests/fixtures/read-default-dates-6304/dates.json`'s stored dates
    /// fit as the shared grammar's `storedValueFits` answers them
    /// (`read-default-dates-6304.test.ts`), a `24:00` with zero seconds
    /// included.
    func testAStoredDateFitsAsTheSharedGrammarJudgesIt() throws {
        var url = URL(fileURLWithPath: #filePath)
        // The file, Schema, JsBaoClientTests, Tests, swift-client.
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("tests/fixtures/read-default-dates-6304/dates.json"))
        let stored = try JSONDecoder().decode(DatesFixture.self, from: data).stored
        XCTAssertFalse(stored.isEmpty)
        for entry in stored {
            XCTAssertEqual(PrimitiveRecord.fitting(entry.value, as: .date, numericBooleans: false) != nil, entry.fits, "\(entry.value)")
        }
    }

    func testTheClassifierTakesWhatATypedDb3TakesOnWrite() {
        func fits(_ value: JSONValue, _ type: PrimitiveFieldType, numericBooleans: Bool = false) -> PrimitiveValue? {
            PrimitiveRecord.fitting(value, as: type, numericBooleans: numericBooleans)
        }
        XCTAssertEqual(fits("2026-01-01", .date), .date("2026-01-01"))
        XCTAssertEqual(fits("2026-01-01 13:00", .date), .date("2026-01-01 13:00"))
        XCTAssertEqual(fits("2026-01-01T13:00:00+02:00", .date), .date("2026-01-01T13:00:00+02:00"))
        XCTAssertNil(fits("2026-02-30", .date), "no such calendar day")
        XCTAssertNil(fits("2026-13-01", .date))
        XCTAssertNil(fits("2026-01-01T25:00", .date))
        XCTAssertNil(fits("2026-01-01 1:00 PM", .date))
        XCTAssertNil(fits("soon", .date))
        XCTAssertNil(fits(.number(1e20), .date), "past what a Date represents")
        XCTAssertEqual(fits(.number(86_400_000), .date), .date("1970-01-02T00:00:00.000Z"))
        XCTAssertNil(fits(.bool(true), .date))
        XCTAssertNil(fits(.number(1), .boolean))
        XCTAssertEqual(fits(.number(1), .boolean, numericBooleans: true), .boolean(true))
        XCTAssertEqual(fits(.number(0), .boolean, numericBooleans: true), .boolean(false))
        XCTAssertNil(fits(.number(2), .boolean, numericBooleans: true))
        XCTAssertNil(fits("true", .boolean, numericBooleans: true))
        XCTAssertEqual(fits("", .string), .string(""), "an empty string is a string")
        XCTAssertNil(fits(.array([]), .id))
        XCTAssertNil(fits(.null, .number))
    }

    /// A decoded value is judged the same way, and a value of another kind
    /// is answered `nil` rather than thrown.
    func testADecoderAnswersOnlyAValueOfTheFieldsKind() throws {
        struct Probe: Decodable {
            enum CodingKeys: String, CodingKey { case label, score, on, due }
            let label: PrimitiveValue?, score: PrimitiveValue?, on: PrimitiveValue?, due: PrimitiveValue?
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                label = container.fittingValue(forKey: .label, as: .string)
                score = container.fittingValue(forKey: .score, as: .number)
                on = container.fittingValue(forKey: .on, as: .boolean)
                due = container.fittingValue(forKey: .due, as: .date)
            }
        }
        func decode(_ json: String) throws -> Probe { try JSONDecoder().decode(Probe.self, from: Data(json.utf8)) }
        let good = try decode(#"{"label":"x","score":2,"on":false,"due":"2026-01-01T00:00:00.000Z"}"#)
        XCTAssertEqual([good.label, good.score, good.on, good.due], [.string("x"), .number(2), .boolean(false), .date("2026-01-01T00:00:00.000Z")])
        let wrong = try decode(#"{"label":5,"score":"5","on":1,"due":"soon"}"#)
        XCTAssertEqual([wrong.label, wrong.score, wrong.on, wrong.due], [nil, nil, nil, nil])
        let empty = try decode(#"{"label":null}"#)
        XCTAssertEqual([empty.label, empty.score, empty.on, empty.due], [nil, nil, nil, nil])
    }

    // MARK: - Behavior 29: a held clear

    func testIsClearedAnswersTheDb3sHeldClearForARecordAndARow() async throws {
        let (binding, model) = try await db3()
        try store(binding, "r1", ["label": "a", "score": 42])
        try store(binding, "r2", ["label": "b"])
        for id in ["r1", "r2"] {
            XCTAssertFalse(try XCTUnwrap(model.find(id: id)).isCleared("score"), id)
            XCTAssertFalse(PrimitiveRecord.isCleared("score", in: try row(model, id)), id)
        }
        // `holds` answers as before.
        XCTAssertEqual(try XCTUnwrap(model.find(id: "r1")).holds("score"), true)
        XCTAssertEqual(try XCTUnwrap(model.find(id: "r2")).holds("score"), false)

        var cleared = Self.declared
        cleared["marks"]?["score"] = nil
        try binding.setState(type: .typed(name: "marks", hash: "h2", models: cleared, cleared: ["marks": ["score"]]))
        for id in ["r1", "r2"] {
            let record = try XCTUnwrap(model.find(id: id))
            XCTAssertTrue(record.isCleared("score"), id)
            XCTAssertFalse(record.isCleared("label"), id)
            XCTAssertNil(record.holds("score"), "\(id): holds answers a held clear as unset, as before")
            let row = try row(model, id)
            XCTAssertTrue(PrimitiveRecord.isCleared("score", in: row), id)
            XCTAssertFalse(PrimitiveRecord.isCleared("label", in: row), id)
            XCTAssertNil(PrimitiveRecord.holds("score", in: row), id)
        }

        try binding.setState(type: .typed(name: "marks", hash: "h3", models: Self.declared, cleared: nil))
        XCTAssertFalse(try XCTUnwrap(model.find(id: "r2")).isCleared("score"))
        XCTAssertFalse(PrimitiveRecord.isCleared("score", in: try row(model, "r2")))
    }

    func testAYMapRecordOrRowThatLacksAFieldIsNotCleared() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: Self.schema)
        _ = try model.create(id: "y1", values: ["label": .string("a")])
        let record = try XCTUnwrap(model.find(id: "y1"))
        XCTAssertFalse(record.isCleared("score"))
        XCTAssertNil(record.holds("score"), "holds answers a Y.Map record as before")
        let row = try XCTUnwrap(try model.query(nil).first)
        XCTAssertFalse(PrimitiveRecord.isCleared("score", in: row))
        XCTAssertNotEqual(PrimitiveRecord.holds("score", in: row), false, "holds never answers a Y.Map row as never written")
    }
}
