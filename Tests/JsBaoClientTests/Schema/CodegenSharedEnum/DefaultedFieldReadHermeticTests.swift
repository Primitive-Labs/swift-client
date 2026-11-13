import XCTest
@testable import JsBaoClient
import YSwift

/// #5896 phase 4 — a generated model reads a defaulted field as js-bao's
/// getter reads it on a db3 (record-log) document: a record that does not
/// hold the field reads the field's literal `default`; a record that holds it
/// as `null` (a field cleared in either client) reads `nil`; a stored value
/// reads as itself. The fill is a read only: nothing is marked changed, and a
/// later save does not write the default.
///
/// `EnumCardRecord` is the committed model swift-bao-codegen writes for the
/// board fixture's `cards` model. Each record is read through the real paths:
/// `init?(record:)` over the document's `PrimitiveRecord`, and `init?(row:)`
/// over the row `find` and a query answer.
final class DefaultedFieldReadHermeticTests: XCTestCase {

    private static let db3Id = "01JD5896DEFAVLTREADXXXXXXX"
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

    /// A client over its own SQLite store with no server, holding the db3
    /// `db3Id`, with the card model (`registering`) registered and configured
    /// as the default client.
    private func client(registering registered: PrimitiveSchema = uniqueNoteSchema) async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/defaulted-field-read-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "defaulted-field-read-5896",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([registered])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        JsBaoClient.configureDefault(client)
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Cards", "createdBy": "user-a", "createdAt": "2026-11-13T00:00:00.000Z",
         "modifiedAt": "2026-11-13T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": null, "tags": []}
        """
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 201, json: answer), client: client)
            .create(title: "Cards", custodian: "user:user-a")
        XCTAssertTrue(try XCTUnwrap(client.recordLogBinding(Self.db3Id)).isResident)
        return client
    }

    private static var schema: PrimitiveSchema { EnumCardRecord.primitiveSchema }

    /// The card model with `note` unique, so a card that holds a note is also
    /// read through `findByUnique`. The generated model reads the same fields.
    private static var uniqueNoteSchema: PrimitiveSchema {
        var schema = EnumCardRecord.primitiveSchema
        schema.fields["note"]?.unique = true
        return schema
    }

    /// Write card `id` holding exactly `fields`, as another client or a
    /// record written before the defaults were declared: a save through the
    /// model fills the defaults on create, so this commits the entry itself.
    private func storeWithout(_ client: JsBaoClient, id: String, _ fields: [String: JSONValue]) throws {
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        var values = fields
        values["id"] = .string(id)
        _ = try binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: Self.schema.name, id: id, kind: .create, fields: values),
        ])])
    }

    /// The document's handle on card `id`.
    private func record(_ client: JsBaoClient, id: String) throws -> PrimitiveRecord {
        try XCTUnwrap(client.sharedModel(for: Self.schema).member(docId: Self.db3Id)?.find(id: id))
    }

    /// Card `id` read through each real path, by the path's name: a card
    /// that holds a note is also looked up by it (`findByUnique`).
    private func reads(_ client: JsBaoClient, id: String) throws -> [(String, EnumCardRecord?)] {
        try rows(client, id: id).map { ($0.0, EnumCardRecord(row: $0.1)) }
            + [("record", EnumCardRecord(record: try record(client, id: id)))]
    }

    /// The rows each query path answers for card `id`, by the path's name.
    private func rows(_ client: JsBaoClient, id: String) throws -> [(String, [String: JSONValue])] {
        let found = try XCTUnwrap(client.codegen.find(Self.schema, id: id))
        let queried = try XCTUnwrap(
            try client.codegen.query(Self.schema, options: QueryOptions(db3: [Self.db3Id])).first { $0["id"]?.stringValue == id }
        )
        var rows = [("find", found), ("query", queried)]
        if let note = found["note"]?.stringValue {
            let unique = try XCTUnwrap(
                try client.codegen.findByUnique(Self.uniqueNoteSchema, constraint: "cards_note_unique", value: .string(note))
            )
            XCTAssertEqual(unique["id"]?.stringValue, id)
            rows.append(("findByUnique", unique))
        }
        return rows
    }

    /// The stored row of card `id`, as the document's view holds it.
    private func stored(_ client: JsBaoClient, id: String) throws -> [String: JSONValue] {
        try XCTUnwrap(client.codegen.find(Self.schema, id: id))
    }

    // MARK: - Behaviors 30, 31, 35, 36: a record that does not hold the field

    func testARecordThatDoesNotHoldADefaultedFieldReadsTheDefault() async throws {
        let client = try await client()
        try storeWithout(client, id: "c1", ["note": .string("n")])
        for (path, read) in try reads(client, id: "c1") {
            let card = try XCTUnwrap(read, "\(path): a required field with a default the record lacks decodes")
            XCTAssertEqual(card.title, "Untitled", path)
            XCTAssertEqual(card.points, 3, path)
            XCTAssertEqual(card.ratio, 0.5, path)
            XCTAssertEqual(card.done, false, path)
            XCTAssertEqual(card.rank, 1, path)
            XCTAssertEqual(card.phase, .open, "\(path): a ref'd field reads its default's case")
            XCTAssertEqual(card.phaseRaw, "open", path)
            XCTAssertEqual(card.note, "n", path)
            XCTAssertEqual(card._changedFields, [], "\(path): the fill is a read, not a change")
        }

        // A save that assigns another field does not write the defaults.
        var card = try XCTUnwrap(EnumCardRecord(record: try record(client, id: "c1")))
        card.note = "m"
        XCTAssertEqual(card._changedFields, ["note"])
        _ = try card.save(in: Self.db3Id)
        let row = try stored(client, id: "c1")
        XCTAssertEqual(row["note"], .string("m"))
        for field in ["title", "points", "ratio", "done", "phase", "rank"] {
            XCTAssertNil(row[field], "\(field) is not stored by a save that did not assign it")
        }
    }

    func testAStoredValueReadsAsItself() async throws {
        let client = try await client()
        try storeWithout(client, id: "c2", [
            "title": .string("T"), "points": .number(8), "ratio": .number(2), "done": .bool(true),
            "phase": .string("closed"), "rank": .number(5),
        ])
        for (path, read) in try reads(client, id: "c2") {
            let card = try XCTUnwrap(read, path)
            XCTAssertEqual(card.title, "T", path)
            XCTAssertEqual(card.points, 8, path)
            XCTAssertEqual(card.ratio, 2, path)
            XCTAssertEqual(card.done, true, path)
            XCTAssertEqual(card.phase, .closed, path)
            XCTAssertEqual(card.rank, 5, path)
            XCTAssertNil(card.note, path)
        }
    }

    // MARK: - Behaviors 35, 36 and the explicit-null edge case: a cleared field

    /// Clearing a field through the Swift client stores `null` on a db3
    /// document, and js-bao's getter returns a stored `null` as it is: the
    /// field reads `nil`, not its default.
    func testAFieldClearedThroughTheSwiftClientReadsNil() async throws {
        let client = try await client()
        _ = try client.codegen.save(Self.schema, id: "c3", values: [
            "title": .string("T"), "points": .number(8), "ratio": .number(2), "done": .boolean(true),
            "phase": .string("closed"), "rank": .number(5), "note": .string("c3"),
        ], in: Self.db3Id)
        let handle = try record(client, id: "c3")
        for field in ["title", "points", "ratio", "done", "phase"] { handle[field] = nil }
        let row = try stored(client, id: "c3")
        for field in ["title", "points", "ratio", "done", "phase"] {
            XCTAssertEqual(row[field], .null, "\(field) is stored as null")
        }
        XCTAssertEqual(try reads(client, id: "c3").map(\.0), ["find", "query", "findByUnique", "record"])
        for (path, read) in try reads(client, id: "c3") {
            let card = try XCTUnwrap(read, path)
            XCTAssertNil(card.title, path)
            XCTAssertNil(card.points, path)
            XCTAssertNil(card.ratio, path)
            XCTAssertNil(card.done, path)
            XCTAssertNil(card.phase, path)
            XCTAssertNil(card.phaseRaw, path)
            XCTAssertEqual(card.rank, 5, path)
            XCTAssertEqual(card._changedFields, [], path)
        }
    }

    /// A record that holds a required defaulted field as `null` fails the
    /// row, as a required field without a default does.
    func testARequiredDefaultedFieldHeldAsNullFailsTheRow() async throws {
        let client = try await client()
        try storeWithout(client, id: "c4", ["rank": .null, "note": .string("c4")])
        XCTAssertEqual(try stored(client, id: "c4")["rank"], .null)
        let reads = try reads(client, id: "c4")
        XCTAssertEqual(reads.map(\.0), ["find", "query", "findByUnique", "record"])
        for (path, read) in reads {
            XCTAssertNil(read, path)
        }
    }

    // MARK: - Clearing a field the record does not hold

    /// A field read as its default and then cleared is stored as `null`, so
    /// the next read is `nil` on every path, not the default again; js-bao
    /// writes a touched field with no value as `null` too. A defaulted field
    /// the save left alone is still not written.
    func testClearingAFieldReadAsItsDefaultStoresNull() async throws {
        let client = try await client()
        try storeWithout(client, id: "c6", ["note": .string("c6")])
        var card = try XCTUnwrap(EnumCardRecord(record: try record(client, id: "c6")))
        XCTAssertEqual(card.points, 3)
        XCTAssertEqual(card.phase, .open)
        card.points = nil
        card.phase = nil
        XCTAssertEqual(card._changedFields, ["points", "phase"])
        _ = try card.save(in: Self.db3Id)
        let row = try stored(client, id: "c6")
        XCTAssertEqual(row["points"], .null, "the clear is stored")
        XCTAssertEqual(row["phase"], .null, "the clear is stored")
        XCTAssertNil(row["title"], "a defaulted field the save did not assign is not written")
        for (path, read) in try reads(client, id: "c6") {
            let read = try XCTUnwrap(read, path)
            XCTAssertNil(read.points, path)
            XCTAssertNil(read.phase, path)
            XCTAssertNil(read.phaseRaw, path)
            XCTAssertEqual(read.title, "Untitled", path)
            XCTAssertEqual(read.rank, 1, path)
        }
    }

    // MARK: - A captured row

    /// A row read from a db3 is read the same way later, whichever client is
    /// the default then: after the default client is cleared, and with another
    /// client that holds no such document as the default.
    func testACapturedRowDecodesTheSameWhicheverClientIsTheDefault() async throws {
        let client = try await client()
        try storeWithout(client, id: "c7", ["note": .string("c7"), "points": .null])
        let captured = try rows(client, id: "c7")
        XCTAssertEqual(captured.map(\.0), ["find", "query", "findByUnique"])

        func check(_ when: String) throws {
            for (path, row) in captured {
                let card = try XCTUnwrap(EnumCardRecord(row: row), "\(when), \(path): a required defaulted field the row lacks decodes")
                XCTAssertEqual(card.title, "Untitled", "\(when), \(path)")
                XCTAssertEqual(card.rank, 1, "\(when), \(path)")
                XCTAssertEqual(card.phase, .open, "\(when), \(path)")
                XCTAssertNil(card.points, "\(when), \(path): a stored null is not filled")
            }
        }
        try check("with the reading client as the default")
        JsBaoClient.clearDefault()
        try check("with no default client")
        let directory = NSTemporaryDirectory() + "/defaulted-field-read-other-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let other = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "defaulted-field-read-5896-other",
            token: makeTestJwt(userId: "user-b"), logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(other)
        JsBaoClient.configureDefault(other)
        try check("with another client as the default")
        await client.destroy()
        clients.removeAll { $0 === client }
        try check("after the reading client is destroyed")
    }

    // MARK: - Edge case: a string set's default

    /// js-bao's getter reads a string set through the same fill as a scalar:
    /// a card that does not hold `tags` reads the default's members, and one
    /// that holds it as `null` reads none. The generated model reads it the
    /// same way on every path. The fill is a read only: the schema the model
    /// registers declares no default for `tags`, so a create writes none, as
    /// before.
    func testAStringSetReadsItsDefaultWhereTheRecordDoesNotHoldIt() async throws {
        let client = try await client()
        try storeWithout(client, id: "c5", ["note": .string("c5")])
        try storeWithout(client, id: "c8", ["note": .string("c8"), "tags": .null])
        for (path, read) in try reads(client, id: "c5") {
            let card = try XCTUnwrap(read, path)
            XCTAssertEqual(card.tags, ["a"], path)
            XCTAssertEqual(card._changedFields, [], path)
        }
        for (path, read) in try reads(client, id: "c8") {
            XCTAssertEqual(try XCTUnwrap(read, path).tags ?? [], [], path)
        }
        XCTAssertNil(Self.schema.fields["tags"]?.default)
    }

    /// A string set read as its default and then set to nil is cleared by
    /// the save, so the next read is empty on every path, not the default
    /// again: the schema declares no default for a set (a create writes
    /// none), and the save still writes the clear.
    func testClearingAStringSetReadAsItsDefaultIsSaved() async throws {
        let client = try await client()
        try storeWithout(client, id: "c9", ["note": .string("c9")])
        var card = try XCTUnwrap(EnumCardRecord(record: try record(client, id: "c9")))
        XCTAssertEqual(card.tags, ["a"])
        card.tags = nil
        XCTAssertEqual(card._changedFields, ["tags"])
        _ = try card.save(in: Self.db3Id)
        let row = try stored(client, id: "c9")
        XCTAssertNil(row["title"], "a defaulted field the save did not assign is not written")
        for (path, read) in try reads(client, id: "c9") {
            let read = try XCTUnwrap(read, path)
            XCTAssertEqual(read.tags ?? [], [], "\(path): the clear is kept, the default is not read again")
            XCTAssertEqual(read.title, "Untitled", path)
        }
    }

    /// CSO-5896-019 — a required string set the record does not hold reads
    /// its default, so it is present for the save's required check, as
    /// js-bao's validator reads it through the same getter. An unchanged save
    /// and one that assigns another field succeed and do not write the set; a
    /// clear still fails the required check. The schema is the card's with
    /// `tags` required, saved as the generated model saves.
    func testARequiredStringSetReadAsItsDefaultSaves() async throws {
        var schema = Self.uniqueNoteSchema
        schema.fields["tags"]?.required = true
        let client = try await client(registering: schema)
        XCTAssertNil(schema.fields["tags"]?.default, "a create still writes no default for a set")
        try storeWithout(client, id: "c10", ["note": .string("c10")])
        var card = try XCTUnwrap(EnumCardRecord(record: try record(client, id: "c10")))
        XCTAssertEqual(card.tags, ["a"])
        func save(_ card: EnumCardRecord) throws {
            _ = try client.codegen.save(schema, id: card.id, values: card.primitiveValues(), in: Self.db3Id, changedFields: card._changedFields)
        }

        try save(card)
        card.note = "m"
        try save(card)
        let row = try stored(client, id: "c10")
        XCTAssertEqual(row["note"], .string("m"))
        XCTAssertTrue(try record(client, id: "c10").holds("tags") == false, "the default is not written")

        card.tags = nil
        XCTAssertThrowsError(try save(card)) { error in
            guard case FieldValidationError.requiredFieldMissing(let field, _) = error else {
                return XCTFail("expected requiredFieldMissing, got \(error)")
            }
            XCTAssertEqual(field, "tags")
        }
    }

    // MARK: - Included records

    /// A record a query includes is the parent's db3's, so a model built
    /// from it reads its defaults as one read directly does: a field it does
    /// not hold reads the default (a required one too, so the included model
    /// is not dropped), and a field held as `null` reads `nil`. This holds for
    /// `refersTo` and `hasMany` legs and for a nested include.
    func testAnIncludedRecordReadsItsDefaultsAsADirectReadDoes() async throws {
        let client = try await client()
        try storeWithout(client, id: "c10", ["note": .string("c11")])
        try storeWithout(client, id: "c11", ["note": .string("c12")])
        try storeWithout(client, id: "c12", ["note": .string("c12x"), "points": .null, "phase": .null])
        try storeWithout(client, id: "c13", ["note": .string("c10")])
        let target = client.codegen.includeTarget(for: Self.uniqueNoteSchema)
        let rows = try client.codegen.query(
            Self.uniqueNoteSchema, filter: ["id": .string("c10")], options: QueryOptions(db3: [Self.db3Id]),
            include: [
                Include(type: .refersTo, target: target, sourceField: "note", resultKey: "linked", include: [
                    Include(type: .refersTo, target: target, sourceField: "note", resultKey: "next"),
                ]),
                Include(type: .hasMany, target: target, foreignKey: "note", resultKey: "children"),
            ]
        )
        let parent = try XCTUnwrap(EnumCardRecord(row: try XCTUnwrap(rows.first)))

        func checkFilled(_ card: EnumCardRecord?, _ what: String) throws {
            let card = try XCTUnwrap(card, "\(what): a required defaulted field the record lacks decodes")
            XCTAssertEqual(card.title, "Untitled", what)
            XCTAssertEqual(card.points, 3, what)
            XCTAssertEqual(card.rank, 1, what)
            XCTAssertEqual(card.phase, .open, what)
            XCTAssertEqual(card.tags, ["a"], what)
            XCTAssertEqual(card._changedFields, [], what)
        }
        let linked = parent.related.one("linked", as: EnumCardRecord.self)
        try checkFilled(linked, "refersTo")
        let children = parent.related.many("children", as: EnumCardRecord.self)
        XCTAssertEqual(children.map(\.id), ["c13"])
        try checkFilled(children.first, "hasMany")

        let next = try XCTUnwrap(linked?.related.one("next", as: EnumCardRecord.self), "nested")
        XCTAssertNil(next.points, "nested: a field held as null is not filled")
        XCTAssertNil(next.phase, "nested: a field held as null is not filled")
        XCTAssertEqual(next.title, "Untitled", "nested")
        XCTAssertEqual(next.rank, 1, "nested")
    }

    // MARK: - Behavior 33: the default-read fixture both clients read

    /// `tests/fixtures/default-read-parity-5896/cards.json`: records of this
    /// model stored with fields present, absent and `null`, on a db3 and on a
    /// Y.Map document, and what every client reads. js-bao's side is
    /// `cli/tests/unit/default-read-parity-5896.test.ts`.
    private struct ParityFixture: Decodable {
        struct Entry: Decodable {
            let id: String
            let stored: [String: JSONValue]
            let reads: [String: JSONValue]
        }
        let model: String
        let fields: [String: JSONValue]
        let db3: [Entry]
        let ymap: [Entry]
    }

    private func parityFixture() throws -> ParityFixture {
        var url = URL(fileURLWithPath: #filePath)
        // The file, CodegenSharedEnum, Schema, JsBaoClientTests, Tests, swift-client.
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("tests/fixtures/default-read-parity-5896/cards.json"))
        return try JSONDecoder().decode(ParityFixture.self, from: data)
    }

    /// A card's fields as the fixture writes a read: empty as `null`, `phase`
    /// as its stored string, `tags` as its sorted members.
    private func parityReads(_ card: EnumCardRecord) -> [String: JSONValue] {
        [
            "title": card.title.map(JSONValue.string) ?? .null,
            "points": card.points.map(JSONValue.number) ?? .null,
            "ratio": card.ratio.map(JSONValue.number) ?? .null,
            "done": card.done.map(JSONValue.bool) ?? .null,
            "phase": card.phaseRaw.map(JSONValue.string) ?? .null,
            "rank": .number(card.rank),
            "tags": .array((card.tags ?? []).sorted().map(JSONValue.string)),
            "note": card.note.map(JSONValue.string) ?? .null,
        ]
    }

    func testTheDefaultReadFixtureReadsAsRecordedOnADb3() async throws {
        let fixture = try parityFixture()
        XCTAssertEqual(fixture.model, Self.schema.name)
        XCTAssertEqual(Set(fixture.fields.keys), Set(Self.schema.fields.keys).subtracting(["id"]))
        let client = try await client()
        for entry in fixture.db3 { try storeWithout(client, id: entry.id, entry.stored) }
        for entry in fixture.db3 {
            let reads = try reads(client, id: entry.id)
            XCTAssertEqual(reads.map(\.0), ["find", "query", "findByUnique", "record"], entry.id)
            for (path, read) in reads {
                let card = try XCTUnwrap(read, "\(entry.id), \(path)")
                XCTAssertEqual(parityReads(card), entry.reads, "\(entry.id), \(path)")
                XCTAssertEqual(card._changedFields, [], "\(entry.id), \(path)")
            }
        }
    }

    func testTheDefaultReadFixtureReadsAsRecordedOnAYMapDocument() throws {
        let fixture = try parityFixture()
        SchemaSync.clearCache()
        let doc = YDocument()
        var plain = Self.schema
        plain.fields = plain.fields.mapValues { field in
            var copy = field
            copy.default = nil
            return copy
        }
        let writer = DynamicModel(doc: doc, schema: plain)
        for entry in fixture.ymap {
            var values: [String: PrimitiveValue] = [:]
            for (field, value) in entry.stored {
                switch value {
                case let .string(s): values[field] = .string(s)
                case let .number(n): values[field] = .number(n)
                case let .bool(b): values[field] = .boolean(b)
                default: XCTFail("\(entry.id).\(field): the Y.Map records store scalars only")
                }
            }
            _ = try writer.create(id: entry.id, values: values)
        }
        let model = DynamicModel(doc: doc, schema: Self.schema)
        let rows = try model.query(nil)
        for entry in fixture.ymap {
            let fromRecord = try XCTUnwrap(EnumCardRecord(record: try XCTUnwrap(model.find(id: entry.id))), entry.id)
            XCTAssertEqual(parityReads(fromRecord), entry.reads, "\(entry.id), record")
            let row = try XCTUnwrap(rows.first { $0["id"]?.stringValue == entry.id }, entry.id)
            let fromRow = try XCTUnwrap(EnumCardRecord(row: row), entry.id)
            XCTAssertEqual(parityReads(fromRow), entry.reads, "\(entry.id), query")
        }
    }

    // MARK: - Y.Map documents

    /// On a Y.Map (format 1) document js-bao's getter returns what the
    /// record's map holds, with no default for a field it lacks, and a
    /// cleared field is removed from the map, so a missing key may be one a
    /// client cleared. The generated model reads such a record as js-bao
    /// does: the stored value, or `nil`.
    func testAYMapRecordReadsWhatItsMapHolds() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        var plain = Self.schema
        plain.fields = plain.fields.mapValues { field in
            var copy = field
            copy.default = nil
            return copy
        }
        let writer = DynamicModel(doc: doc, schema: plain)
        _ = try writer.create(id: "y1", values: ["rank": .number(2)])
        _ = try writer.create(id: "y2", values: ["rank": .number(2), "points": .number(8)])
        let model = DynamicModel(doc: doc, schema: Self.schema)
        let lacking = try XCTUnwrap(EnumCardRecord(record: try XCTUnwrap(model.find(id: "y1"))))
        XCTAssertNil(lacking.points)
        XCTAssertNil(lacking.title)
        let holding = try XCTUnwrap(EnumCardRecord(record: try XCTUnwrap(model.find(id: "y2"))))
        XCTAssertEqual(holding.points, 8)
        let rows = try model.query(nil)
        XCTAssertNil(EnumCardRecord(row: try XCTUnwrap(rows.first { $0["id"]?.stringValue == "y1" }))?.points)
        XCTAssertEqual(EnumCardRecord(row: try XCTUnwrap(rows.first { $0["id"]?.stringValue == "y2" }))?.points, 8)
    }
}
