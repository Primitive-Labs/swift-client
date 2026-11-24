import JsBaoSQLite
import XCTest
@testable import JsBaoClient

/// #6025 second-opinion findings 6025-C016 to C022 — a typed local-only db3
/// on the Swift client, where another client of the same store (here, the
/// store itself, called past the binding) installs declarations while this
/// binding holds older marks.
///
/// - C016: an index change planned under older installed declarations is
///   not written; it is planned again under the store's.
/// - C017: a write the newly installed declarations take commits from an
///   already-bound handle: no copy of the older ones held here refuses it.
/// - C018: a `knownTypesOnly` build refuses a typed local-only copy of a type
///   it does not know `DB3_TYPE_UNKNOWN_TO_CLIENT`, and `allowUnknownType`
///   on subscribe opens it.
/// - C019: a field the newly installed declarations clear reads as unset on
///   an already-bound handle, through records, models, filters and sorts.
/// - C020: a write condition reads a cleared field as unset, and a refusal's
///   current record leaves it out.
/// - C021: two declarations that differ by a canonically equivalent but
///   different enum value or default are diverged, as js-bao classifies them.
/// - C022: an untyped local-only copy's commit and marks read the type entry
///   in no statement of their own, and a same-hash or untyped reconcile
///   reads nothing.
/// - C025: the index list is written under the installed declarations it
///   follows: an install writes the list its declarations give, an index
///   change caches its list in its own transaction, and the follow-up that
///   builds and drops makes the indexes what the store's list wants, so it
///   never puts back an index a later install took out.
/// - C027: no index of any kind is registered over a field the installed
///   declarations clear, as the room refuses it: `DB3_INDEX_INVALID`, and
///   the index list is unchanged.
final class Db3LocalOnlyTypedSiblingHermeticTests: XCTestCase {

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    // MARK: - Builds

    private static let baseFields: [String: String] = [
        "title": #"{"type":"string"}"#,
        "slug": #"{"type":"string","unique":true}"#,
        "status": #"{"type":"string","enum":["open","done"],"enforceEnum":true}"#,
        "mood": #"{"type":"string","enum":["x","y"]}"#,
        "weight": #"{"type":"number"}"#,
        "label": #"{"type":"string","indexed":true}"#,
    ]

    /// Declarations of `Entry` with `edit` applied to its fields (`nil` drops
    /// one), hiding `cleared`, and `more` models.
    private static func build(
        _ hash: String, _ edit: [String: String?] = [:], cleared: [String] = [], more: [String: String] = [:]
    ) -> PrimitiveDb3Types.LocalOnlyDeclarations {
        var fields = baseFields
        for (field, options) in edit { fields[field] = options }
        let hidden = cleared.isEmpty ? "" : ",\"cleared\":[" + cleared.sorted().map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let entry = "{\"constraints\":{\"title_weight\":{\"fields\":[\"title\",\"weight\"],\"type\":\"unique\"}}" + hidden + ",\"fields\":{"
            + fields.keys.sorted().map { "\"\($0)\":\(fields[$0]!)" }.joined(separator: ",") + "}}"
        let models = ["Entry": entry].merging(more) { a, _ in a }
        return PrimitiveDb3Types.LocalOnlyDeclarations(
            hash: hash, modelsJSON: "{" + models.keys.sorted().map { "\"\($0)\":\(models[$0]!)" }.joined(separator: ",") + "}"
        )
    }

    private static let v1 = build("h-v1")
    /// A superset: a new enum value and a new model.
    private static let v2 = build(
        "h-v2", ["status": #"{"type":"string","enum":["open","done","doing"],"enforceEnum":true}"#],
        more: ["Tag": #"{"fields":{"name":{"type":"string"}}}"#]
    )
    /// A superset that makes `label` unique.
    private static let v2Unique = build("h-v2u", ["label": #"{"type":"string","indexed":true,"unique":true}"#])
    /// A superset that clears `mood`.
    private static let v2Cleared = build("h-v2c", ["mood": nil], cleared: ["mood"])
    /// A superset that clears `label`, which v1 declares `indexed`.
    private static let v2ClearedLabel = build("h-v2l", ["label": nil], cleared: ["label"])

    private static let entry = PrimitiveSchema(
        name: "Entry",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, unique: true), "status": FieldDescriptor(type: .string),
            "mood": FieldDescriptor(type: .string), "weight": FieldDescriptor(type: .number),
            "label": FieldDescriptor(type: .string, indexed: true),
        ]
    )
    private static let tag = PrimitiveSchema(name: "Tag", fields: ["id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string)])

    private func directory() -> String {
        let made = NSTemporaryDirectory() + "/db3-local-only-sibling-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        directories.append(made)
        return made
    }

    private func client(directory: String, types: PrimitiveDb3Types?) async throws -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-local-only-sibling-6025",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        if let types { client.registerDb3Types(types) }
        _ = await client.waitForStorageReady()
        await client.goOffline()
        client.registerModels([Self.entry, Self.tag])
        client.documentManager.createRemoteDocument = { _ in throw JsBaoError(code: .unavailable, message: "nothing is sent") }
        client.documentManager.createRemoteDb3 = { _ in throw JsBaoError(code: .unavailable, message: "nothing is sent") }
        return client
    }

    private static func journal(_ declarations: PrimitiveDb3Types.LocalOnlyDeclarations) -> PrimitiveDb3Types {
        PrimitiveDb3Types(knownTypesOnly: false, types: [PrimitiveDb3Types.DeclaredType(name: "journal", localOnly: declarations)])
    }

    private func create(_ client: JsBaoClient) async throws -> String {
        let api = Db3API(lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 500, json: "{}"), client: client)
        return try await api.create(title: "Journal", type: "journal", localOnly: true).id
    }

    private func entries(_ client: JsBaoClient, _ db3Id: String) throws -> DynamicModel {
        try XCTUnwrap(client.sharedModel("Entry")?.member(docId: db3Id))
    }

    /// What another client of the store does: install `declarations` past this client's binding, whose marks stay as they were.
    ///
    /// The create's own follow-up (its event, the state reads that re-read
    /// the marks) is let settle first, so nothing this client does on its
    /// own reads the marks again before the test's next read or write.
    private func installBehind(_ client: JsBaoClient, _ db3Id: String, _ declarations: PrimitiveDb3Types.LocalOnlyDeclarations) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        let binding = try XCTUnwrap(client.recordLogBinding(db3Id))
        let installed = try binding.store.installLocalType(try XCTUnwrap(RecordLogLocalType(name: "journal", declarations: declarations)))
        guard case .installed = installed else { return XCTFail("installed: \(installed)") }
        XCTAssertEqual(binding.marks.db3Type?.hash, "h-v1", "this binding's marks were not read again")
    }

    // MARK: - C016

    func testAnIndexChangePlannedUnderOlderDeclarationsIsNotWritten() async throws {
        let client = try await client(directory: directory(), types: Self.journal(Self.v1))
        let id = try await create(client)
        let binding = try XCTUnwrap(client.recordLogBinding(id))
        let planned = try binding.store.marks()
        XCTAssertEqual(planned.db3Type?.hash, "h-v1")
        let olderConstraints = planned.constraints

        try await installBehind(client, id, Self.v2Unique)
        // The change planned under h-v1 would put back h-v1's constraints, dropping label's.
        let change = try binding.store.changeLocalIndexes(
            from: planned.localIndexes, to: planned.localIndexes, constraints: olderConstraints, typeHash: .some("h-v1")
        )
        guard case .moved(let marks) = change else { return XCTFail("written under older declarations: \(change)") }
        XCTAssertTrue(marks.constraints.contains { $0.name == "Entry_label_unique" }, "\(marks.constraints.map(\.name))")

        // Planned again through the binding, the newer constraint stands and judges.
        try binding.applyLocalDeclarations()
        XCTAssertTrue(try binding.store.marks().constraints.contains { $0.name == "Entry_label_unique" })
        let entries = try entries(client, id)
        _ = try entries.save(id: "e1", values: ["slug": .string("a"), "label": .string("same")])
        let shared = await db3LocalOnlyThrown { _ = try entries.save(id: "e2", values: ["slug": .string("b"), "label": .string("same")]) }
        XCTAssertEqual(shared?.code, .documentConstraintViolated)
    }

    // MARK: - C017

    func testAnAlreadyBoundHandleWritesWhatNewlyInstalledDeclarationsTake() async throws {
        let client = try await client(directory: directory(), types: Self.journal(Self.v1))
        let id = try await create(client)
        let entries = try entries(client, id)
        let tags = try XCTUnwrap(client.sharedModel("Tag")?.member(docId: id))
        try await installBehind(client, id, Self.v2)
        _ = try entries.save(id: "e1", values: ["slug": .string("a"), "status": .string("doing")])
        try entries.transact { _ = try entries.save(id: "e2", values: ["slug": .string("b"), "status": .string("doing")]) }
        _ = try tags.save(id: "t1", values: ["name": .string("x")])
        _ = try client.db3.records(id).put("Entry", ["id": "e3", "slug": "c", "status": "doing"])
        XCTAssertEqual(Set(try entries.query().compactMap { $0["id"]?.stringValue }), ["e1", "e2", "e3"])

        // What the installed declarations refuse is still refused, by the store.
        let lost = await db3LocalOnlyThrown { _ = try entries.save(id: "e4", values: ["slug": .string("d"), "status": .string("lost")]) }
        XCTAssertEqual(lost?.code, .db3ValueNotInEnum)
        XCTAssertEqual(lost?.details?["scope"], "local")
    }

    // MARK: - C018

    func testAKnownTypesOnlyBuildRefusesATypedLocalOnlyCopyOfATypeItDoesNotKnow() async throws {
        let directory = directory()
        let id: String
        do {
            let first = try await client(directory: directory, types: Self.journal(Self.v1))
            id = try await create(first)
            _ = try entries(first, id).save(id: "e1", values: ["slug": .string("a")])
            await first.destroy()
            clients.removeAll { $0 === first }
        }

        let second = try await client(
            directory: directory, types: PrimitiveDb3Types(knownTypesOnly: true, types: [PrimitiveDb3Types.DeclaredType(name: "catalog")])
        )
        let subscription = try second.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: 2))
        let refused = await db3LocalOnlyThrown { try await subscription.ready() }
        XCTAssertEqual(refused?.code, .db3TypeUnknownToClient)
        XCTAssertEqual(refused?.details?["type"], "journal")
        let state = try await second.db3.state(id)
        XCTAssertEqual(state.error?.code, "DB3_TYPE_UNKNOWN_TO_CLIENT")
        XCTAssertFalse(state.resident)
        XCTAssertNil(second.recordLogBinding(id), "not bound")

        // The subscribe option opens it under its installed declarations.
        let escaped = try second.db3.subscribe(id, options: {
            var options = Db3SubscribeOptions(readyTimeout: 2)
            options.allowUnknownType = true
            return options
        }())
        try await escaped.ready()
        let opened = try await second.db3.state(id)
        XCTAssertNil(opened.error)
        XCTAssertTrue(opened.resident)
        XCTAssertEqual(try XCTUnwrap(second.recordLogBinding(id)).store.marks().db3Type?.hash, "h-v1")
        let lost = await db3LocalOnlyThrown { _ = try entries(second, id).save(id: "e2", values: ["slug": .string("b"), "status": .string("lost")]) }
        XCTAssertEqual(lost?.code, .db3ValueNotInEnum, "judged by the installed declarations")
        escaped.dispose()
    }

    // MARK: - C019

    func testAFieldAnotherHandleClearedReadsAsUnsetHere() async throws {
        let client = try await client(directory: directory(), types: Self.journal(Self.v1))
        let id = try await create(client)
        let entries = try entries(client, id)
        _ = try entries.save(id: "e1", values: ["slug": .string("a"), "mood": .string("x")])
        _ = try entries.save(id: "e2", values: ["slug": .string("b"), "mood": .string("y")])
        let records = client.db3.records(id)
        XCTAssertEqual(entries.find(id: "e1")?["mood"], .string("x"), "read before the install")

        try await installBehind(client, id, Self.v2Cleared)

        XCTAssertNil(entries.find(id: "e1")?["mood"], "a model read")
        XCTAssertEqual(try entries.query(["mood": "x"]).count, 0, "a model filter")
        XCTAssertNil(try records.get("Entry", id: "e1")?["mood"], "a model-free read")
        XCTAssertEqual(try records.query("Entry", ["mood": "x"]).data.count, 0, "a model-free filter")
        XCTAssertEqual(try records.count("Entry", ["mood": "y"]), 0, "a model-free count")
        let sorted = try records.query("Entry", nil, options: QueryOptions(sort: ["mood": 1]))
        XCTAssertEqual(sorted.data.compactMap { $0["id"]?.stringValue }, ["e1", "e2"], "a sort on the cleared field orders by id")
        XCTAssertTrue(sorted.data.allSatisfy { $0["mood"] == nil })
    }

    // MARK: - C020

    func testAWriteConditionReadsAClearedFieldAsUnset() async throws {
        let client = try await client(directory: directory(), types: Self.journal(Self.v1))
        let id = try await create(client)
        let entries = try entries(client, id)
        _ = try entries.save(id: "e1", values: ["slug": .string("a"), "mood": .string("x")])
        try await installBehind(client, id, Self.v2Cleared)

        let matched = await db3LocalOnlyThrown {
            _ = try await entries.save(id: "e1", values: ["title": .string("t")], options: Db3WriteOptions(condition: ["mood": "x"]))
        }
        XCTAssertEqual(matched?.code, .db3ConditionNotMet, "the cleared value does not meet a condition")
        let current = matched?.details?["current"]?.objectValue?["row"]?.objectValue
        XCTAssertNotNil(current, "\(String(describing: matched?.details))")
        XCTAssertNil(current?["mood"], "the refusal's current record leaves the cleared field out")

        _ = try await entries.save(id: "e1", values: ["title": .string("u")], options: Db3WriteOptions(condition: ["mood": .null]))
        XCTAssertEqual(entries.find(id: "e1")?["title"], .string("u"), "a condition expecting it unset is met")
    }

    // MARK: - C021

    func testCanonicallyEquivalentButDifferentValuesAreDiverged() {
        func models(_ options: [String: JSONValue]) -> [String: JSONValue] {
            ["Entry": .object(["fields": .object(["s": .object(options)])])]
        }
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed, "Swift's String equality takes them as one")

        let installed = models(["type": "string", "enum": .array([.string(composed)])])
        let swapped = RecordLogLocalType(name: "t", hash: "h2", models: models(["type": "string", "enum": .array([.string(decomposed), "x"])]))
        XCTAssertEqual(recordLogClassifyDeclarations(installed: ("h1", installed), build: swapped), .diverged, "an enum value removed and another added")
        XCTAssertEqual(
            recordLogDeclarationChanges(installed, swapped.models).map(\.change), ["enum-value-removed"]
        )

        let withDefault = models(["type": "string", "default": .string(composed)])
        let otherDefault = RecordLogLocalType(name: "t", hash: "h2", models: models(["type": "string", "default": .string(decomposed)]))
        XCTAssertEqual(recordLogClassifyDeclarations(installed: ("h1", withDefault), build: otherDefault), .diverged)

        let added = RecordLogLocalType(name: "t", hash: "h2", models: models(["type": "string", "enum": .array([.string(composed), "x"])]))
        XCTAssertEqual(recordLogClassifyDeclarations(installed: ("h1", installed), build: added), .superset, "the same value kept, one added")
    }

    // MARK: - C022

    /// Every statement the provider's connection runs, with its bound values.
    private final class Trace: @unchecked Sendable {
        let lock = NSLock()
        var statements: [String] = []
        func take() -> [String] {
            lock.withLock {
                defer { statements = [] }
                return statements
            }
        }
    }

    /// Trace `provider`'s connection while `body` runs, answering its statements.
    private func traced(_ provider: SQLiteStorageProvider, _ body: () throws -> Void) throws -> [String] {
        let trace = Trace()
        let context = Unmanaged.passRetained(trace).toOpaque()
        defer { Unmanaged<Trace>.fromOpaque(context).release() }
        _ = try provider.withRecordLogConnection { connection in
            sqlite3_trace_v2(connection.rawHandle, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
                guard let context, let statement, let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else { return 0 }
                defer { sqlite3_free(expanded) }
                let trace = Unmanaged<Trace>.fromOpaque(context).takeUnretainedValue()
                let text = String(cString: expanded)
                trace.lock.withLock { trace.statements.append(text) }
                return 0
            }, context)
        }
        defer { _ = try? provider.withRecordLogConnection { sqlite3_trace_v2($0.rawHandle, 0, nil, nil) } }
        try body()
        return trace.take()
    }

    /// A statement that reads the type entry and nothing else.
    private static func readsTypeEntryAlone(_ statement: String) -> Bool {
        statement.hasPrefix("SELECT value FROM record_log_meta WHERE key = 'db3_type:")
    }

    func testAnUntypedLocalOnlyCommitAndMarksReadTheTypeEntryInNoStatementOfTheirOwn() async throws {
        let made = directory()
        let provider = SQLiteStorageProvider(path: made + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let store = RecordLogStore(host: provider, documentId: "db3-untyped", clientId: "client-1")
        try store.initialize()
        let writer = try store.mintWriter()
        try store.setState(writer: writer, localOnly: true)

        let commit = try traced(provider) {
            _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [
                RecordLogMutation(model: "Entry", id: "e1", kind: .create, fields: ["slug": "a"]),
            ])])
            try store.flush()
        }
        XCTAssertFalse(commit.isEmpty, "the trace saw the commit")
        XCTAssertFalse(commit.contains(where: Self.readsTypeEntryAlone), "\(commit)")
        XCTAssertEqual(commit.filter { $0.contains("FROM record_log_state") && $0.contains("local_only") }.count, 1, "\(commit)")

        let marks = try traced(provider) { _ = try store.marks() }
        XCTAssertEqual(marks.filter { $0.contains("db3_type:") }.count, 1, "the marks read the type entry once: \(marks)")
    }

    func testAnUntypedOrSameHashReconcileReadsNothing() async throws {
        let client = try await client(directory: directory(), types: Self.journal(Self.v1))
        let typed = try await create(client)
        let untyped = try await Db3API(
            lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 500, json: "{}"), client: client
        ).create(title: "Plain", localOnly: true).id
        let build = try XCTUnwrap(RecordLogLocalType(name: "journal", declarations: Self.v1))
        for id in [typed, untyped] {
            let binding = try XCTUnwrap(client.recordLogBinding(id))
            let provider = try XCTUnwrap(binding.store.host as? SQLiteStorageProvider)
            let statements = try traced(provider) {
                try binding.reconcileLocalType({ $0 == "journal" ? build : nil }, knownType: id == typed ? "journal" : nil)
            }
            XCTAssertEqual(statements, [], "\(id == typed ? "same hash" : "untyped"): \(statements)")
            XCTAssertNil(binding.localTypeStanding)
        }
    }

    // MARK: - C025

    /// Whether the store has a view index, and a cached list entry, over `Entry.<field>` alone.
    private static func indexed(_ store: RecordLogStore, _ field: String) throws -> (physical: Bool, listed: Bool) {
        (
            try store.indexTuples().contains { $0.model == "Entry" && $0.fields == [field] },
            try store.localIndexes().contains { $0.model == "Entry" && $0.fields == [field] }
        )
    }

    func testAnInstallWritesTheIndexListItsDeclarationsGive() async throws {
        let client = try await client(directory: directory(), types: Self.journal(Self.v1))
        let id = try await create(client)
        let binding = try XCTUnwrap(client.recordLogBinding(id))
        let before = try Self.indexed(binding.store, "label")
        XCTAssertTrue(before.physical, "v1 indexes label")
        XCTAssertTrue(before.listed, "v1 lists label's index")

        try await installBehind(client, id, Self.v2ClearedLabel)
        XCTAssertFalse(try Self.indexed(binding.store, "label").listed, "the install alone took label's index out of the list")
        // What follows any change (this binding's planned under v1 included) makes the indexes the list's.
        try binding.store.syncIndexes(nil)
        let after = try Self.indexed(binding.store, "label")
        XCTAssertFalse(after.physical, "label's index is dropped")
        XCTAssertFalse(after.listed)
        XCTAssertTrue(try Self.indexed(binding.store, "slug").physical, "a field still declared keeps its index")
    }

    func testAnIndexChangeCachesTheListItCarriesInItsOwnTransaction() async throws {
        let client = try await client(directory: directory(), types: Self.journal(Self.v1))
        let id = try await create(client)
        let binding = try XCTUnwrap(client.recordLogBinding(id))
        let marks = try binding.store.marks()
        let local = try XCTUnwrap(marks.localDeclarations)
        let v1List = RecordLogLocalOnly.entries(RecordLogLocalOnly.indexList(recordLogLocalSchemas(local), marks.localIndexes))
        XCTAssertTrue(v1List.contains { $0.fields == ["label"] })
        // A change carrying a list without label's index: the list is the store's once the change is written, before any build or drop.
        let change = try binding.store.changeLocalIndexes(
            from: marks.localIndexes, to: marks.localIndexes, constraints: marks.constraints, typeHash: .some("h-v1"),
            indexes: v1List.filter { $0.fields != ["label"] }
        )
        guard case .changed = change else { return XCTFail("not written: \(change)") }
        XCTAssertFalse(try Self.indexed(binding.store, "label").listed, "cached with the change")
        XCTAssertTrue(try Self.indexed(binding.store, "label").physical, "nothing dropped yet")
        // A change planned under declarations no longer installed caches nothing.
        let stale = try binding.store.changeLocalIndexes(
            from: marks.localIndexes, to: marks.localIndexes, constraints: marks.constraints, typeHash: .some("h-other"), indexes: v1List
        )
        guard case .moved = stale else { return XCTFail("written under other declarations: \(stale)") }
        XCTAssertFalse(try Self.indexed(binding.store, "label").listed, "the moved change cached nothing")
        // The follow-up names no list: the indexes become what the store's list wants.
        try binding.store.syncIndexes(nil)
        XCTAssertFalse(try Self.indexed(binding.store, "label").physical)
        XCTAssertTrue(try Self.indexed(binding.store, "slug").physical)
    }

    // MARK: - C027

    func testAnIndexOverAFieldTheInstalledDeclarationsClearIsRefused() async throws {
        let client = try await client(directory: directory(), types: Self.journal(Self.v1))
        let id = try await create(client)
        try await installBehind(client, id, Self.v2Cleared)
        let before = try await client.db3.indexes.list(id)
        let bodies = [
            Db3IndexRegistration(model: "Entry", field: "mood"),
            Db3IndexRegistration(model: "Entry", fields: ["title", "mood"], unique: true, name: "pair"),
            Db3IndexRegistration(model: "Entry", field: "mood", kind: .members, on: .device),
            Db3IndexRegistration(model: "Entry", field: "mood", kind: .text, on: .device),
        ]
        for body in bodies {
            let refused = await db3LocalOnlyThrown { _ = try await client.db3.indexes.register(id, body) }
            XCTAssertEqual(refused?.code, .db3IndexInvalid, "\(body)")
            XCTAssertTrue(refused?.message.contains("Entry.mood is cleared by the db3's type") == true, "\(String(describing: refused?.message))")
        }
        let after = try await client.db3.indexes.list(id)
        XCTAssertEqual(after, before, "the index list is unchanged")
        // A field the type still declares takes one.
        let title = try await client.db3.indexes.register(id, Db3IndexRegistration(model: "Entry", field: "title"))
        XCTAssertEqual(title.fields, ["title"])
    }
}
