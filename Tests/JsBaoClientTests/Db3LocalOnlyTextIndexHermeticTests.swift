import XCTest
@testable import JsBaoClient

/// #5223 behavior 16 and edge case E10 — a local-only db3 takes a text index
/// by js-bao's `parseLocalRegistration` and `registerTextIndex` rules: the
/// shape first (`unique` or `name` on a text index, or `text` options beside
/// another kind, `DB3_INDEX_INVALID`, whatever `on` says), then `on`
/// (`DB3_LOCAL_ONLY`), then the kind's placement (`vector`
/// `DB3_INDEX_PLACEMENT_UNSUPPORTED`); one text index per model, named
/// `idx_text_<model>`, listed on the device with its options filled in,
/// adding no constraint. Pure functions: no store.
final class Db3LocalOnlyTextIndexRulesHermeticTests: XCTestCase {

    private static let fields: [String: FieldDescriptor] = [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "body": FieldDescriptor(type: .string),
        "slug": FieldDescriptor(type: .string, unique: true),
    ]
    private let schemas = [PrimitiveSchema(name: "Note", fields: fields)]

    private func refusal(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> JsBaoError? {
        do {
            try body()
            XCTFail("the registration was not refused", file: file, line: line)
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("threw \(error)", file: file, line: line)
        }
        return nil
    }

    private func text(_ fields: [String], on: Db3IndexPlacement? = nil, options: Db3TextIndexOptions? = nil, model: String = "Note") -> Db3IndexRegistration {
        fields.count == 1
            ? Db3IndexRegistration(model: model, field: fields[0], kind: .text, on: on, text: options)
            : Db3IndexRegistration(model: model, fields: fields, kind: .text, on: on, text: options)
    }

    func testParsesATextRegistrationWithFieldOrFields() throws {
        let one = try RecordLogLocalOnly.parse(text(["title"]))
        XCTAssertEqual(one.kind, .text)
        XCTAssertEqual(one.fields, ["title"])
        XCTAssertEqual(one.text, RecordLogTextIndexOptions(tokenizer: .unicode61, prefix: [], weights: ["title": 1]))
        let two = try RecordLogLocalOnly.parse(text(["title", "body"], on: .device, options: Db3TextIndexOptions(tokenizer: .porter, prefix: [2], weights: ["title": 3])))
        XCTAssertEqual(two.fields, ["title", "body"])
        XCTAssertEqual(two.text, RecordLogTextIndexOptions(tokenizer: .porter, prefix: [2], weights: ["title": 3, "body": 1]))
        XCTAssertFalse(two.unique)
    }

    /// The shape before the placement (E10), as js-bao's parser and this one judge it.
    func testRefusesTheShapeBeforeThePlacementAndThePlacementBeforeTheKind() {
        let shaped = "unique and name apply to a scalar index only: a text index takes neither"
        for body in [
            Db3IndexRegistration(model: "Note", field: "title", fields: nil, unique: true, name: nil, members: nil, kind: .text, on: .both),
            Db3IndexRegistration(model: "Note", field: "title", fields: nil, unique: nil, name: "t", members: nil, kind: .text, on: .server),
            Db3IndexRegistration(model: "Note", field: "title", fields: nil, unique: false, name: nil, members: nil, kind: .text),
        ] {
            let refused = refusal { _ = try RecordLogLocalOnly.parse(body) }
            XCTAssertEqual(refused?.code, .db3IndexInvalid)
            XCTAssertEqual(refused?.message, shaped)
        }
        let besideAnother = refusal {
            _ = try RecordLogLocalOnly.parse(Db3IndexRegistration(
                model: "Note", field: "title", fields: nil, unique: nil, name: nil, members: nil, kind: .scalar, text: Db3TextIndexOptions()
            ))
        }
        XCTAssertEqual(besideAnother?.code, .db3IndexInvalid)
        XCTAssertEqual(besideAnother?.message, "text options apply to kind: \"text\" only")
        let badPrefix = refusal { _ = try RecordLogLocalOnly.parse(self.text(["title"], options: Db3TextIndexOptions(prefix: [40]))) }
        XCTAssertEqual(badPrefix?.code, .db3IndexInvalid)
        XCTAssertEqual(badPrefix?.message, "text.prefix must be at most 8 integers from 1 to 32")
        let badWeight = refusal { _ = try RecordLogLocalOnly.parse(self.text(["title"], options: Db3TextIndexOptions(weights: ["body": 2]))) }
        XCTAssertEqual(badWeight?.message, "text.weights.body names a field the index does not cover: title")
        let zero = refusal { _ = try RecordLogLocalOnly.parse(self.text(["title"], options: Db3TextIndexOptions(weights: ["title": 0]))) }
        XCTAssertEqual(zero?.message, "text.weights.title must be a positive number")
        for on in [Db3IndexPlacement.server, .both] {
            let placed = refusal { _ = try RecordLogLocalOnly.parse(self.text(["title"], on: on)) }
            XCTAssertEqual(placed?.code, .db3LocalOnly)
            XCTAssertEqual(placed?.details?["on"], .string(on.rawValue))
        }
        // A vector index is admitted on the device since #5230; its field is judged when it is registered.
        XCTAssertEqual(try RecordLogLocalOnly.parse(Db3IndexRegistration(model: "Note", field: "embedding", kind: .vector, vector: nil)).kind, .vector)
    }

    func testRegistersOneTextIndexPerModelListedOnTheDeviceAddingNoConstraint() throws {
        let both = schemas + [PrimitiveSchema(name: "note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)])]
        let planned = try RecordLogLocalOnly.register(both, [], text(["title", "body"], options: Db3TextIndexOptions(weights: ["title": 3])))
        XCTAssertEqual(planned.index, Db3Index(
            name: "idx_text_note", model: "Note", fields: ["title", "body"], unique: false, members: false,
            origins: [Db3IndexOrigin(kind: .named, unique: false)], kind: .text, on: .device,
            text: Db3TextIndex(tokenizer: .unicode61, prefix: [], weights: ["title": 3, "body": 1])
        ))
        XCTAssertTrue(RecordLogLocalOnly.indexList(both, planned.registrations).contains(planned.index))
        XCTAssertEqual(RecordLogLocalOnly.constraints(both, planned.registrations), RecordLogLocalOnly.constraints(both, []))
        // A model differing in case takes `_2`.
        let lower = try RecordLogLocalOnly.register(both, planned.registrations, text(["title"], model: "note"))
        XCTAssertEqual(lower.index.name, "idx_text_note_2")
        // The same fields again answer the index as it is; other fields are refused.
        let again = try RecordLogLocalOnly.register(both, planned.registrations, text(["title", "body"]))
        XCTAssertEqual(again.registrations, planned.registrations)
        XCTAssertEqual(again.index, planned.index)
        let other = refusal { _ = try RecordLogLocalOnly.register(both, planned.registrations, self.text(["title"])) }
        XCTAssertEqual(other?.code, .db3IndexExists)
        XCTAssertEqual(other?.details?["index"], "idx_text_note")
        // A scalar index over the same field coexists, and dropping either leaves the other.
        let scalar = try RecordLogLocalOnly.register(both, planned.registrations, Db3IndexRegistration(model: "Note", field: "title"))
        let list = RecordLogLocalOnly.indexList(both, scalar.registrations)
        XCTAssertEqual(list.filter { $0.model == "Note" && $0.fields.first == "title" }.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.scalar, .text])
        XCTAssertEqual(RecordLogLocalOnly.entries(list).filter { $0.kind == .text }.map(\.name), ["idx_text_note"])
        XCTAssertEqual(RecordLogLocalOnly.entries(list).first { $0.kind == .text }?.text, ["tokenizer": "unicode61", "prefix": [], "weights": ["title": 3, "body": 1]])
        let dropped = try RecordLogLocalOnly.drop(both, scalar.registrations, name: "idx_text_note")
        XCTAssertFalse(RecordLogLocalOnly.indexList(both, dropped).contains { $0.kind == .text })
        XCTAssertTrue(RecordLogLocalOnly.indexList(both, dropped).contains { $0.name == "idx_records_note_title" })
    }

    func testARegistrationRoundTripsItsKindAndTextThroughItsJSON() throws {
        let planned = try RecordLogLocalOnly.register(schemas, [], text(["title"], options: Db3TextIndexOptions(tokenizer: .porter, prefix: [3])))
        let stored = try XCTUnwrap(planned.registrations.first)
        XCTAssertEqual(stored.kind, .text)
        XCTAssertEqual(stored.json["kind"], "text")
        XCTAssertEqual(stored.json["text"], ["tokenizer": "porter", "prefix": [3], "weights": ["title": 1]])
        XCTAssertEqual(RecordLogLocalIndex(json: stored.json), stored)
        // A scalar or member registration is stored as before, without `kind` or `text`.
        let scalar = RecordLogLocalIndex(name: "idx_records_note_title", model: "Note", fields: ["title"], unique: false)
        XCTAssertNil(scalar.json["kind"])
        XCTAssertNil(scalar.json["text"])
        XCTAssertEqual(RecordLogLocalIndex(json: scalar.json), scalar)
    }
}

/// #5223 behavior 16 (surface half) — a local-only db3's text index through
/// `client.db3.indexes`, with no server: registered, listed, built, searched
/// through the `Note` model with `_score`, kept across saves, and dropped,
/// with nothing sent.
final class Db3LocalOnlyTextIndexSurfaceHermeticTests: XCTestCase {

    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        await world.tearDown()
        try await super.tearDown()
    }

    private func rows(_ client: JsBaoClient, _ db3Id: String, _ sql: String) throws -> [Format2SqlRow] {
        let binding = try XCTUnwrap(client.recordLogBinding(db3Id))
        return try binding.store.readView { try $0.rows(sql) }
    }

    private func drift(_ client: JsBaoClient, _ db3Id: String) throws -> [String] {
        let binding = try XCTUnwrap(client.recordLogBinding(db3Id))
        return try binding.store.readView { try Db3DeviceIndexOracle.drift($0.connection) }
    }

    func testRegistersListsBuildsSearchesKeepsAndDropsATextIndexSendingNothing() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 500, json: "{}")
        let info = try await world.createLocalOnly(client, transport: transport)
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let notes = try world.notes(client, info.id)
        _ = try notes.save(id: "a", values: ["slug": .string("s-a"), "title": .string("Apple pie")])
        _ = try notes.save(id: "b", values: ["slug": .string("s-b"), "title": .string("Pear"), "status": .string("apple apple")])

        let index = try await db3.indexes.register(info.id, Db3IndexRegistration(
            model: "Note", fields: ["title", "status"], kind: .text, on: .device, text: Db3TextIndexOptions(weights: ["title": 3])
        ))
        XCTAssertEqual(index.name, "idx_text_note")
        XCTAssertEqual(index.kind, .text)
        XCTAssertEqual(index.on, .device)
        XCTAssertEqual(index.text, Db3TextIndex(tokenizer: .unicode61, prefix: [], weights: ["title": 3, "status": 1]))
        let listed = try await db3.indexes.list(info.id)
        XCTAssertTrue(listed.contains(index))
        let table = RecordLogIndexes.textTableName(documentId: info.id, model: "Note")
        XCTAssertEqual(try rows(client, info.id, "SELECT name FROM sqlite_master WHERE name = '\(table)'").count, 1)

        let found = try notes.query(["$search": "apple"])
        XCTAssertEqual(found.compactMap { $0["id"]?.stringValue }.sorted(), ["a", "b"])
        XCTAssertTrue(found.allSatisfy { $0["_score"]?.numberValue != nil })
        // Saves after the registration are kept in the table.
        _ = try notes.save(id: "c", values: ["slug": .string("s-c"), "title": .string("Apple crumble")])
        try notes.update(id: "a", values: ["title": .string("Plum")])
        XCTAssertEqual(try notes.query(["$search": "apple"]).compactMap { $0["id"]?.stringValue }.sorted(), ["b", "c"])
        XCTAssertEqual(try drift(client, info.id), [])

        try await db3.indexes.drop(info.id, name: index.name)
        XCTAssertEqual(try rows(client, info.id, "SELECT name FROM sqlite_master WHERE name = '\(table)'").count, 0)
        let remaining = try await db3.indexes.list(info.id)
        XCTAssertFalse(remaining.contains { $0.kind == .text })
        let refused = await db3LocalOnlyThrown { _ = try notes.query(["$search": "apple"]) }
        XCTAssertEqual(refused?.code, .queryIndexNotOnDevice)
        XCTAssertEqual(transport.calls.count, 0, "nothing is sent")
        XCTAssertEqual(world.remoteCreates, 0)
    }
}
