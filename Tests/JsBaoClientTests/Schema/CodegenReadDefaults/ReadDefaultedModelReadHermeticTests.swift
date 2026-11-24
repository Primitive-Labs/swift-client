import Foundation
import XCTest
@testable import JsBaoClient
import YSwift

/// #6304 phase 2 — a generated model reads a read-defaulted field (a scalar
/// field whose `default` is a literal of its type) as its default wherever
/// the stored record has no value of the field's kind, and types it
/// non-optional. The fill is the model's own: it is never a pending change,
/// so saving over an existing record does not write it.
///
/// `MarkRecord` and `MarkBareRecord` are the committed models swift-bao-codegen
/// writes for `db3-types/marks.toml` (`ReadDefaultedModelHermeticTests` holds
/// them to the tool). Records are read through the real paths: `init?(record:)`
/// over the document's `PrimitiveRecord`, `init?(row:)` over the rows `find` and
/// a query answer, and `init(from:)` over JSON.
final class ReadDefaultedModelReadHermeticTests: XCTestCase {

    private static let db3Id = "01JD6304READDEFAVLTEDXXXXX"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private static var schema: PrimitiveSchema { MarkRecord.primitiveSchema }

    /// The fields `marks.toml` declares on `marks`, as the db3's type holds them.
    private static let declared: [String: [String: String]] = ["marks": [
        "title": "string", "label": "string", "score": "number", "on": "boolean", "off": "boolean",
        "due": "date", "rank": "number", "made": "date", "count": "number", "tags": "stringset",
    ], "marksKeyed": ["title": "string", "slug": "string"]]

    /// A client over its own SQLite store with no server, holding the db3
    /// `db3Id` of the `marks` type, with `MarkRecord` registered and the
    /// client configured as the default.
    private func client(marks: PrimitiveSchema = MarkRecord.primitiveSchema) async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/read-defaulted-model-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "read-defaulted-model-6304",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([marks, MarkKeyRecord.primitiveSchema])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        JsBaoClient.configureDefault(client)
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Marks", "createdBy": "user-a", "createdAt": "2026-11-21T00:00:00.000Z",
         "modifiedAt": "2026-11-21T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": null, "tags": []}
        """
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 201, json: answer), client: client)
            .create(title: "Marks", custodian: "user:user-a")
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        XCTAssertTrue(binding.isResident)
        try binding.setState(type: .typed(name: "marks", hash: "h1", models: Self.declared))
        return client
    }

    private func binding(_ client: JsBaoClient) throws -> RecordLogDocumentBinding {
        try XCTUnwrap(client.recordLogBinding(Self.db3Id))
    }

    /// Write record `id` holding exactly `fields`, as another client, a
    /// workflow or a record written before the defaults were declared could
    /// have stored it.
    private func store(_ client: JsBaoClient, _ id: String, _ fields: [String: JSONValue], model: String = MarkRecord.modelName) throws {
        var values = fields
        values["id"] = .string(id)
        _ = try binding(client).commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: model, id: id, kind: .create, fields: values),
        ])])
    }

    private func record(_ client: JsBaoClient, _ id: String) throws -> PrimitiveRecord {
        try XCTUnwrap(client.sharedModel(for: Self.schema).member(docId: Self.db3Id)?.find(id: id), id)
    }

    /// The rows `find` and a query answer for record `id`, by the path's name.
    private func rows(_ client: JsBaoClient, _ id: String) throws -> [(String, [String: JSONValue])] {
        let found = try XCTUnwrap(client.codegen.find(Self.schema, id: id), id)
        let queried = try XCTUnwrap(
            try client.codegen.query(Self.schema, options: QueryOptions(db3: [Self.db3Id])).first { $0["id"]?.stringValue == id }, id
        )
        return [("find", found), ("query", queried)]
    }

    /// Record `id` built by `MarkRecord` through each real path, by the path's name.
    private func reads(_ client: JsBaoClient, _ id: String) throws -> [(String, MarkRecord?)] {
        try rows(client, id).map { ($0.0, MarkRecord(row: $0.1)) } + [("record", MarkRecord(record: try record(client, id)))]
    }

    /// The stored row of record `id`, as the document's view holds it.
    private func stored(_ client: JsBaoClient, _ id: String) throws -> [String: JSONValue] {
        try XCTUnwrap(try binding(client).store.read(model: Self.schema.name, id: id), id)
    }

    private static let defaults: (label: String, score: Double, on: Bool, off: Bool, due: String, rank: Double) =
        ("none", 7, true, false, "2026-01-01T00:00:00.000Z", 1)

    private func assertDefaults(_ mark: MarkRecord?, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let mark = try XCTUnwrap(mark, "\(what): the record is built", file: file, line: line)
        XCTAssertEqual(mark.label, Self.defaults.label, what, file: file, line: line)
        XCTAssertEqual(mark.score, Self.defaults.score, what, file: file, line: line)
        XCTAssertEqual(mark.on, Self.defaults.on, what, file: file, line: line)
        XCTAssertEqual(mark.off, Self.defaults.off, what, file: file, line: line)
        XCTAssertEqual(mark.due, Self.defaults.due, what, file: file, line: line)
        XCTAssertEqual(mark._changedFields, [], "\(what): the fill is a read, not a change", file: file, line: line)
        XCTAssertTrue(mark._suppliedDefaults.isSuperset(of: ["label", "score", "on", "off", "due"]), "\(what): \(mark._suppliedDefaults)", file: file, line: line)
        for field in ["label", "score", "on", "off", "due"] {
            XCTAssertNil(mark.primitiveValues()[field], "\(what): no write sends a supplied default", file: file, line: line)
        }
    }

    // MARK: - Behaviors 22 and 32: the types

    func testAReadDefaultedFieldIsNonOptionalAndOthersKeepTheirTypes() {
        XCTAssertTrue(type(of: \MarkRecord.label) == WritableKeyPath<MarkRecord, String>.self)
        XCTAssertTrue(type(of: \MarkRecord.score) == WritableKeyPath<MarkRecord, Double>.self)
        XCTAssertTrue(type(of: \MarkRecord.on) == WritableKeyPath<MarkRecord, Bool>.self)
        XCTAssertTrue(type(of: \MarkRecord.off) == WritableKeyPath<MarkRecord, Bool>.self)
        XCTAssertTrue(type(of: \MarkRecord.due) == WritableKeyPath<MarkRecord, String>.self)
        XCTAssertTrue(type(of: \MarkRecord.rank) == WritableKeyPath<MarkRecord, Double>.self)
        // No default, a generator default and a string set default keep their optional types.
        XCTAssertTrue(type(of: \MarkRecord.title) == WritableKeyPath<MarkRecord, String?>.self)
        XCTAssertTrue(type(of: \MarkRecord.count) == WritableKeyPath<MarkRecord, Double?>.self)
        XCTAssertTrue(type(of: \MarkRecord.made) == WritableKeyPath<MarkRecord, String?>.self)
        XCTAssertTrue(type(of: \MarkRecord.tags) == WritableKeyPath<MarkRecord, Set<String>?>.self)
        XCTAssertTrue(type(of: \MarkBareRecord.score) == WritableKeyPath<MarkBareRecord, Double?>.self)
        // The committed acceptance model's defaulted fields.
        XCTAssertTrue(type(of: \CrashTestRecord.score) == WritableKeyPath<CrashTestRecord, Double>.self)
        XCTAssertTrue(type(of: \CrashTestRecord.active) == WritableKeyPath<CrashTestRecord, Bool>.self)
        XCTAssertTrue(type(of: \CrashTestRecord.`default`) == WritableKeyPath<CrashTestRecord, String>.self)
    }

    /// Behavior 32: a read of a defaulted field binds to its plain type
    /// with no cast or unwrap, on the committed acceptance model too.
    func testAReadOfADefaultedFieldNeedsNoUnwrap() {
        let crash = CrashTestRecord(id: "c1", requiredTags: ["a"])
        let active: Bool = crash.active
        let score: Double = crash.score
        let fallback: String = crash.`default`
        XCTAssertEqual(active, true)
        XCTAssertEqual(score, 100)
        XCTAssertEqual(fallback, "fallback")
        let mark = MarkRecord(rank: 2)
        let on: Bool = mark.on
        let due: String = mark.due
        XCTAssertEqual(on, true)
        XCTAssertEqual(due, "2026-01-01T00:00:00.000Z")
    }

    // MARK: - Behavior 64: the stored kind decides, on a db3

    func testOnADb3ABooleanIsJudgedOnItsStoredKind() async throws {
        let client = try await client()
        try store(client, "z", ["rank": 2, "on": 0, "off": 1])
        try store(client, "t", ["rank": 2, "on": true, "off": true])
        try store(client, "f", ["rank": 2, "on": false, "off": false])
        try store(client, "d", ["rank": 2, "due": "soon"])
        for (path, read) in try reads(client, "z") {
            let mark = try XCTUnwrap(read, path)
            XCTAssertEqual(mark.on, true, "\(path): a stored 0 is no boolean on a db3, so `on` reads its default")
            XCTAssertEqual(mark.off, false, "\(path): a stored 1 is no boolean on a db3, so `off` reads its default")
        }
        for (path, read) in try reads(client, "t") {
            XCTAssertEqual(try XCTUnwrap(read, path).on, true, path)
            XCTAssertEqual(try XCTUnwrap(read, path).off, true, "\(path): a stored true reads true")
        }
        for (path, read) in try reads(client, "f") {
            XCTAssertEqual(try XCTUnwrap(read, path).on, false, "\(path): a stored false reads false")
        }
        for (path, read) in try reads(client, "d") {
            XCTAssertEqual(try XCTUnwrap(read, path).due, Self.defaults.due, "\(path): a non-ISO date reads the default")
        }
    }

    /// `findByUnique` builds its row from the record rather than from a
    /// query (6304-IMPL-013). On a db3 the row still carries a stored `0` or
    /// `1` in a boolean field as a number, so the model reads it as its
    /// default, as `find`, a query, the web getter and the room read it. A
    /// stored boolean reads as itself.
    func testOnADb3FindByUniqueJudgesABooleanOnItsStoredKind() async throws {
        var keyed = Self.schema
        keyed.fields["title"]?.unique = true
        let client = try await client(marks: keyed)
        try store(client, "z", ["title": "z", "rank": 2, "on": 0, "off": 1])
        try store(client, "t", ["title": "t", "rank": 2, "on": true, "off": true])
        try store(client, "f", ["title": "f", "rank": 2, "on": false, "off": false])
        func unique(_ title: String) throws -> MarkRecord {
            let row = try XCTUnwrap(
                try client.codegen.findByUnique(keyed, constraint: "marks_title_unique", value: .string(title)), title
            )
            return try XCTUnwrap(MarkRecord(row: row), title)
        }
        let z = try unique("z")
        XCTAssertEqual(z.on, true, "a stored 0 is no boolean on a db3, so `on` reads its default")
        XCTAssertEqual(z.off, false, "a stored 1 is no boolean on a db3, so `off` reads its default")
        XCTAssertTrue(z._suppliedDefaults.isSuperset(of: ["on", "off"]), "\(z._suppliedDefaults)")
        let t = try unique("t")
        XCTAssertEqual(t.on, true)
        XCTAssertEqual(t.off, true, "a stored true reads true")
        let f = try unique("f")
        XCTAssertEqual(f.on, false, "a stored false reads false")
        XCTAssertEqual(f.off, false)
        XCTAssertFalse(f._suppliedDefaults.contains("on"), "a stored boolean is no supplied default")
    }

    // MARK: - Behaviors 23, 24 and E4: missing, null and wrongly typed

    func testAMissingNullOrWronglyTypedValueReadsTheDefault() async throws {
        let client = try await client()
        try store(client, "m", [:])
        try store(client, "n", ["label": .null, "score": .null, "on": .null, "off": .null, "due": .null, "rank": .null])
        try store(client, "w", ["label": 5, "score": "5", "on": "true", "off": 1, "due": "2026-02-30", "rank": "2"])
        try store(client, "w2", ["label": .object(["a": 1]), "score": true, "due": "2026-01-01 1:00 PM"])
        for id in ["m", "n", "w", "w2"] {
            for (path, read) in try reads(client, id) {
                try assertDefaults(read, "\(id), \(path)")
                XCTAssertEqual(read?.rank, Self.defaults.rank, "\(id), \(path): a required defaulted field reads its default too")
            }
        }
        XCTAssertEqual(try stored(client, "n")["score"], .null, "a read stores nothing")
        XCTAssertEqual(try stored(client, "w")["score"], .string("5"), "a read stores nothing")
        XCTAssertNil(try stored(client, "m")["score"], "a read stores nothing")
    }

    func testAStoredValueOfTheFieldsKindReadsAsItself() async throws {
        let client = try await client()
        try store(client, "v", [
            "label": "", "score": 0, "on": false, "off": true, "due": "2026-05-06T07:08:09.000Z", "rank": 0,
            "title": "T", "count": 4, "made": "2026-01-02T00:00:00.000Z",
        ])
        try store(client, "e", ["rank": 3, "due": 86_400_000])
        for (path, read) in try reads(client, "v") {
            let mark = try XCTUnwrap(read, path)
            XCTAssertEqual(mark.label, "", "\(path): an empty string is a value")
            XCTAssertEqual(mark.score, 0, "\(path): a zero is a value")
            XCTAssertEqual(mark.on, false, path)
            XCTAssertEqual(mark.off, true, path)
            XCTAssertEqual(mark.due, "2026-05-06T07:08:09.000Z", path)
            XCTAssertEqual(mark.rank, 0, path)
            XCTAssertEqual(mark.title, "T", path)
            XCTAssertEqual(mark.count, 4, path)
            XCTAssertEqual(mark.made, "2026-01-02T00:00:00.000Z", path)
        }
        for (path, read) in try reads(client, "e") {
            XCTAssertEqual(try XCTUnwrap(read, path).due, "1970-01-02T00:00:00.000Z", "\(path): an epoch number is a date")
        }
    }

    /// A field with no default, a generator default and a string set default
    /// read as before: empty where the record has no value.
    func testAFieldThatIsNotReadDefaultedReadsAsBefore() async throws {
        let client = try await client()
        try store(client, "x", ["rank": 2, "title": .null])
        for (path, read) in try reads(client, "x") {
            let mark = try XCTUnwrap(read, path)
            XCTAssertNil(mark.title, path)
            XCTAssertNil(mark.count, path)
            XCTAssertNil(mark.made, "\(path): a generator default is not filled")
            XCTAssertEqual(mark.tags, ["a"], "\(path): a string set the record lacks reads its default members, as before")
        }
    }

    // MARK: - Behavior 25: a read's fill is never written

    func testSavingAnotherFieldOfARecordReadWithDefaultsWritesNoneOfThem() async throws {
        let client = try await client()
        try store(client, "s", ["rank": 2, "score": .null, "label": 5])
        var mark = try XCTUnwrap(MarkRecord(record: try record(client, "s")))
        XCTAssertEqual(mark.score, 7)
        XCTAssertEqual(mark.label, "none")
        mark.title = "changed"
        XCTAssertEqual(mark._changedFields, ["title"])
        _ = try mark.save(in: Self.db3Id)
        let row = try stored(client, "s")
        XCTAssertEqual(row["title"], .string("changed"))
        XCTAssertEqual(row["score"], .null, "the stored null is kept")
        XCTAssertEqual(row["label"], .number(5), "the stored value is kept")
        for field in ["on", "off", "due"] { XCTAssertNil(row[field], "\(field) is not written") }
    }

    // MARK: - Behaviors 26 and 67: the initializers

    func testAnInitializerStoresTheDefaultOfAnOmittedFieldWithoutMarkingIt() async throws {
        let client = try await client()
        let fresh = MarkRecord(title: "t", rank: 2)
        try assertBuilt(fresh, changed: ["title", "rank"])
        // `made`'s generator default is no read default; this create gives it a value.
        let pinned = MarkRecord(id: "p1", title: "t", label: nil, score: nil, rank: 2, made: "2026-01-01T00:00:00.000Z")
        try assertBuilt(pinned, changed: ["title", "rank", "made"])

        // A create writes every field it carries, the defaults included.
        _ = try pinned.save(in: Self.db3Id)
        let created = try stored(client, "p1")
        XCTAssertEqual(created["label"], .string("none"))
        XCTAssertEqual(created["score"], .number(7))
        XCTAssertEqual(created["on"], .bool(true))
        XCTAssertEqual(created["off"], .bool(false))
        XCTAssertEqual(created["due"], .string("2026-01-01T00:00:00.000Z"))

        // Over an existing record, an omitted default is not written.
        try store(client, "e1", ["rank": 2, "score": 42, "label": "kept", "on": false])
        _ = try MarkRecord(id: "e1", title: "new", rank: 2).save(in: Self.db3Id)
        let kept = try stored(client, "e1")
        XCTAssertEqual(kept["title"], .string("new"))
        XCTAssertEqual(kept["score"], .number(42))
        XCTAssertEqual(kept["label"], .string("kept"))
        XCTAssertEqual(kept["on"], .bool(false))

        // A value passed, one equal to the default included, is the caller's.
        let passed = MarkRecord(id: "e1", score: 7, on: true, rank: 2)
        XCTAssertEqual(passed._changedFields, ["score", "on", "rank"])
        _ = try passed.save(in: Self.db3Id)
        XCTAssertEqual(try stored(client, "e1")["score"], .number(7))
        XCTAssertEqual(try stored(client, "e1")["on"], .bool(true))
    }

    private func assertBuilt(_ mark: MarkRecord, changed: Set<String>, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(mark.label, Self.defaults.label, file: file, line: line)
        XCTAssertEqual(mark.score, Self.defaults.score, file: file, line: line)
        XCTAssertEqual(mark.on, Self.defaults.on, file: file, line: line)
        XCTAssertEqual(mark.off, Self.defaults.off, file: file, line: line)
        XCTAssertEqual(mark.due, Self.defaults.due, file: file, line: line)
        XCTAssertEqual(mark._changedFields, changed, "a default the model supplied is not a change", file: file, line: line)
    }

    // MARK: - Behaviors 27, 65 and 66: init(from:)

    private func decode(_ json: String) throws -> MarkRecord {
        try JSONDecoder().decode(MarkRecord.self, from: Data(json.utf8))
    }

    func testDecodingAMissingNullOrWronglyTypedValueReadsTheDefaultAndDoesNotThrow() throws {
        for json in [
            #"{"id":"j1","rank":2}"#,
            #"{"id":"j2","rank":2,"label":null,"score":null,"on":null,"off":null,"due":null}"#,
            #"{"id":"j3","rank":2,"label":5,"score":"5","on":1,"off":"false","due":"soon"}"#,
        ] {
            let mark = try decode(json)
            XCTAssertEqual(mark.label, Self.defaults.label, json)
            XCTAssertEqual(mark.score, Self.defaults.score, json)
            XCTAssertEqual(mark.on, Self.defaults.on, json)
            XCTAssertEqual(mark.off, Self.defaults.off, json)
            XCTAssertEqual(mark.due, Self.defaults.due, json)
            XCTAssertEqual(mark._changedFields, ["rank"], "\(json): a default the model supplied is not a change")
        }
        XCTAssertEqual(try decode(#"{"id":"j4"}"#).rank, 1, "a required defaulted field decodes its default")
        XCTAssertEqual(try decode(#"{"id":"j5","rank":"2"}"#).rank, 1)
        XCTAssertEqual(try decode(#"{"id":"j4"}"#)._changedFields, [])
        let carried = try decode(#"{"id":"j6","rank":2,"score":3,"on":false,"due":"2026-02-03T00:00:00.000Z"}"#)
        XCTAssertEqual(carried.score, 3)
        XCTAssertEqual(carried.on, false)
        XCTAssertEqual(carried._changedFields, ["rank", "score", "on", "due"])
    }

    /// A field that is not read-defaulted still throws on a value of another kind.
    func testDecodingAWronglyTypedValueOfAFieldWithNoDefaultThrows() {
        XCTAssertThrowsError(try decode(#"{"id":"j7","rank":2,"count":"x"}"#))
        XCTAssertThrowsError(try decode(#"{"id":"j8","rank":2,"title":5}"#))
    }

    func testSavingADecodedValueOverAnExistingRecordWritesNoDefaultItSupplied() async throws {
        let client = try await client()
        try store(client, "e3", ["rank": 2, "score": 42, "label": "kept"])
        _ = try decode(#"{"id":"e3","rank":2}"#).save(in: Self.db3Id)
        XCTAssertEqual(try stored(client, "e3")["score"], .number(42), "nothing else assigned")
        XCTAssertEqual(try stored(client, "e3")["label"], .string("kept"))
        var other = try decode(#"{"id":"e3","rank":2}"#)
        other.title = "t"
        _ = try other.save(in: Self.db3Id)
        XCTAssertEqual(try stored(client, "e3")["score"], .number(42), "another field assigned")
        XCTAssertEqual(try stored(client, "e3")["title"], .string("t"))
        _ = try decode(#"{"id":"e3","rank":2,"score":3}"#).save(in: Self.db3Id)
        XCTAssertEqual(try stored(client, "e3")["score"], .number(3), "a value the JSON carried is written")
    }

    // MARK: - A default the model supplied never keys an upsert

    /// `MarkKeyRecord.slug` is required, unique and defaulted. A value whose
    /// `slug` the model supplied (read from a record that lacks it or holds
    /// `null`, or decoded from JSON without one) sends no `slug`, so an
    /// upsert on it is refused as a missing key and never picks the record
    /// that holds the default.
    func testAnUpsertOnARequiredDefaultedKeyTheModelSuppliedIsRefused() async throws {
        let client = try await client()
        let keyed = MarkKeyRecord.modelName
        try store(client, "main1", ["slug": "main", "title": "kept"], model: keyed)
        try store(client, "bare", ["title": "no slug"], model: keyed)
        try store(client, "nulled", ["slug": .null, "title": "null slug"], model: keyed)
        func keyedRecord(_ id: String) throws -> PrimitiveRecord {
            try XCTUnwrap(client.sharedModel(for: MarkKeyRecord.primitiveSchema).member(docId: Self.db3Id)?.find(id: id), id)
        }
        func storedKeyed(_ id: String) throws -> [String: JSONValue] {
            try XCTUnwrap(try binding(client).store.read(model: keyed, id: id), id)
        }

        var tries: [(String, MarkKeyRecord)] = []
        for id in ["bare", "nulled"] {
            var read = try XCTUnwrap(MarkKeyRecord(record: try keyedRecord(id)), id)
            XCTAssertEqual(read.slug, "main", "\(id): the read fills the default")
            XCTAssertNil(read.primitiveValues()["slug"], "\(id): no write sends a supplied required default")
            read.title = "overwrite"
            tries.append(("\(id), record", read))
        }
        for json in [#"{"id":"j1","title":"overwrite"}"#, #"{"id":"j2","slug":null,"title":"overwrite"}"#] {
            let decoded = try JSONDecoder().decode(MarkKeyRecord.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.slug, "main", json)
            XCTAssertNil(decoded.primitiveValues()["slug"], json)
            tries.append((json, decoded))
        }
        for (what, value) in tries {
            XCTAssertThrowsError(try value.save(in: Self.db3Id, upsertOn: "slug"), "\(what): the key is missing")
        }
        XCTAssertEqual(try storedKeyed("main1")["title"], .string("kept"), "the record holding the default is not overwritten")
        XCTAssertEqual(try storedKeyed("main1")["slug"], .string("main"))
        XCTAssertEqual(try storedKeyed("bare")["title"], .string("no slug"))
        XCTAssertNil(try storedKeyed("bare")["slug"], "a read stores nothing")

        // A key the caller gives upserts as before, one equal to the default included.
        _ = try MarkKeyRecord(title: "merged", slug: "main").save(in: Self.db3Id, upsertOn: "slug")
        XCTAssertEqual(try storedKeyed("main1")["title"], .string("merged"))
    }

    // MARK: - Behavior 30: a db3 that holds a clear of the field

    func testAModelGeneratedWithADefaultDoesNotBuildARecordWhoseDb3ClearsTheField() async throws {
        let client = try await client()
        try store(client, "r1", ["rank": 2, "score": 42])
        try store(client, "r2", ["rank": 2])
        let binding = try binding(client)
        // The push that removed `score`'s default: the type declares the same fields.
        try binding.setState(type: .typed(name: "marks", hash: "h2", models: Self.declared))
        for id in ["r1", "r2"] { for (path, read) in try reads(client, id) { XCTAssertNotNil(read, "\(id), \(path)") } }

        // The next push clears `score`.
        var cleared = Self.declared
        cleared["marks"]?["score"] = nil
        try binding.setState(type: .typed(name: "marks", hash: "h3", models: cleared, cleared: ["marks": ["score"]]))
        for id in ["r1", "r2"] {
            for (path, read) in try reads(client, id) {
                XCTAssertNil(read, "\(id), \(path): a non-optional field the db3 clears cannot read as unset")
            }
            // The model regenerated from the push that removed the default builds them, reading `score` unset.
            for (path, row) in try rows(client, id) {
                let bare = try XCTUnwrap(MarkBareRecord(row: row), "\(id), \(path)")
                XCTAssertNil(bare.score, "\(id), \(path)")
            }
            let bare = try XCTUnwrap(MarkBareRecord(record: try record(client, id)), "\(id), record")
            XCTAssertNil(bare.score, "\(id), record")
        }

        // Un-cleared, the first model builds them again.
        try binding.setState(type: .typed(name: "marks", hash: "h4", models: Self.declared, cleared: nil))
        for (path, read) in try reads(client, "r1") { XCTAssertEqual(try XCTUnwrap(read, path).score, 42, path) }
        for (path, read) in try reads(client, "r2") { XCTAssertEqual(try XCTUnwrap(read, path).score, 7, path) }
    }

    // MARK: - Behavior 31 and 64: a Y.Map document

    func testAYMapRecordThatLacksAReadDefaultedFieldReadsTheDefault() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        var plain = Self.schema
        plain.fields = plain.fields.mapValues { field in
            var copy = field
            copy.default = nil
            return copy
        }
        plain.fields["off"] = FieldDescriptor(type: .number)
        plain.fields["due"] = FieldDescriptor(type: .number)
        let writer = DynamicModel(doc: doc, schema: plain)
        _ = try writer.create(id: "y1", values: ["rank": .number(2)])
        _ = try writer.create(id: "y2", values: ["rank": .number(2), "off": .number(1)])
        _ = try writer.create(id: "y3", values: ["rank": .number(2), "off": .number(5), "due": .number(86_400_000)])
        let model = DynamicModel(doc: doc, schema: Self.schema)
        let rows = try model.query(nil)
        func row(_ id: String) throws -> [String: JSONValue] { try XCTUnwrap(rows.first { $0["id"]?.stringValue == id }, id) }
        try assertDefaults(MarkRecord(record: try XCTUnwrap(model.find(id: "y1"))), "y1, record")
        try assertDefaults(MarkRecord(row: try row("y1")), "y1, query")
        // A stored 1 in a boolean field of a Y.Map document reads true, as before.
        XCTAssertEqual(MarkRecord(record: try XCTUnwrap(model.find(id: "y2")))?.off, true)
        XCTAssertEqual(MarkRecord(row: try row("y2"))?.off, true)
        // Any other number is no boolean, and an epoch number is a date,
        // through the record and the query row alike.
        for (path, read) in [("record", MarkRecord(record: try XCTUnwrap(model.find(id: "y3")))), ("query", MarkRecord(row: try row("y3")))] {
            let mark = try XCTUnwrap(read, path)
            XCTAssertEqual(mark.off, Self.defaults.off, "\(path): a stored 5 reads the default")
            XCTAssertEqual(mark.due, "1970-01-02T00:00:00.000Z", "\(path): an epoch number reads as its ISO string")
        }
    }

    /// A projection does not change what a selected field reads: a projected
    /// Y.Map query row keeps the stored values its columns convert, for the
    /// fields it answers and no others (6304-IMPL-011).
    func testAProjectedYMapRowReadsASelectedFieldAsItsRecordDoes() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        var plain = Self.schema
        plain.fields = plain.fields.mapValues { field in
            var copy = field
            copy.default = nil
            return copy
        }
        plain.fields["off"] = FieldDescriptor(type: .number)
        plain.fields["due"] = FieldDescriptor(type: .number)
        _ = try DynamicModel(doc: doc, schema: plain)
            .create(id: "y3", values: ["rank": .number(2), "off": .number(5), "due": .number(86_400_000)])
        let model = DynamicModel(doc: doc, schema: Self.schema)
        func row(_ projection: [String: Int]) throws -> [String: JSONValue] {
            try XCTUnwrap(try model.query(nil, options: QueryOptions(projection: projection)).first, "\(projection)")
        }
        let projections: [(String, [String: Int])] = [
            ("exclusion", ["label": 0]),
            ("inclusion", ["off": 1, "due": 1, "rank": 1]),
        ]
        for (what, projection) in projections {
            let mark = try XCTUnwrap(MarkRecord(row: try row(projection)), what)
            XCTAssertEqual(mark.off, Self.defaults.off, "\(what): a stored 5 reads the default, as the record does")
            XCTAssertEqual(mark.due, "1970-01-02T00:00:00.000Z", "\(what): an epoch number reads as its ISO string")
        }
        // A field the projection leaves out lists no stored value.
        XCTAssertEqual(try row(["due": 1])[PrimitiveRecord.storedKindsKey], .object(["due": .number(86_400_000)]))
        XCTAssertEqual(try row(["off": 0])[PrimitiveRecord.storedKindsKey], .object(["due": .number(86_400_000)]))
        XCTAssertNil(try row(["off": 0, "due": 0])[PrimitiveRecord.storedKindsKey])
        XCTAssertNil(try row(["title": 1])[PrimitiveRecord.storedKindsKey])
    }
}
