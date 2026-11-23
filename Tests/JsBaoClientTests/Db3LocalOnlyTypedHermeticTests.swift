import XCTest
@testable import JsBaoClient

/// #6025 behaviors 54 to 57 — a typed local-only db3 through the Swift
/// client, with no server.
///
/// - 54: `create(title:type:localOnly: true)` for a type the build carries
///   local-only declarations for answers the typed db3 with nothing sent; a
///   type the build has none for is refused `.localOnlyUnsupportedOption`, and
///   in a `knownTypesOnly` build a type it does not know, or archived in it,
///   `.invalidArgument` `unknown-type`, before an id is minted.
/// - 55: its writes are judged by its installed declarations (a model it does
///   not declare, a value of the wrong kind, a value outside an enforced
///   enum, a shared unique key) through generated models, transactions and
///   the model-free `DocumentRecords`, inside the store transaction that
///   commits them.
/// - 56: its constraints and index list come from the installed declarations,
///   named as an untyped local-only db3 with the same models names them.
/// - 57: one store reopened under another registered build: a superset
///   installs; a refused install is reported in the state and keeps the
///   installed declarations; an older build keeps them (an enforced enum
///   still refuses); a diverged build's writes are refused; unreadable type
///   state refuses writes until a declaring build recovers it.
final class Db3LocalOnlyTypedHermeticTests: XCTestCase {

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

    /// The type's base declarations, in install shape: a unique `slug`, an
    /// enforced `status`, an unenforced `mood`, an indexed `label`, a string
    /// set `tags` and a compound unique `(title, weight)`.
    private static let baseFields: [String: String] = [
        "title": #"{"type":"string"}"#,
        "slug": #"{"type":"string","unique":true}"#,
        "status": #"{"type":"string","enum":["open","done"],"enforceEnum":true}"#,
        "mood": #"{"type":"string","enum":["x","y"]}"#,
        "weight": #"{"type":"number"}"#,
        "label": #"{"type":"string","indexed":true}"#,
        "tags": #"{"type":"stringset"}"#,
    ]

    /// Declarations of `Entry` with `edit` applied to its fields (`nil` drops one), and `more` models.
    private static func build(
        _ hash: String, _ edit: [String: String?] = [:], more: [String: String] = [:]
    ) -> PrimitiveDb3Types.LocalOnlyDeclarations {
        var fields = baseFields
        for (field, options) in edit { fields[field] = options }
        let entry = "{\"constraints\":{\"title_weight\":{\"fields\":[\"title\",\"weight\"],\"type\":\"unique\"}},\"fields\":{"
            + fields.keys.sorted().map { "\"\($0)\":\(fields[$0]!)" }.joined(separator: ",") + "}}"
        let models = ["Entry": entry].merging(more) { a, _ in a }
        return PrimitiveDb3Types.LocalOnlyDeclarations(
            hash: hash, modelsJSON: "{" + models.keys.sorted().map { "\"\($0)\":\(models[$0]!)" }.joined(separator: ",") + "}"
        )
    }

    private static let v1 = build("h-v1")
    /// A superset: a new indexed field, a new enum value, a new model.
    private static let v2 = build(
        "h-v2", ["notes": #"{"type":"string","indexed":true}"#, "status": #"{"type":"string","enum":["open","done","doing"],"enforceEnum":true}"#],
        more: ["Tag": #"{"fields":{"name":{"type":"string"}}}"#]
    )
    /// A superset that makes `label` unique.
    private static let v2Unique = build("h-v2u", ["label": #"{"type":"string","indexed":true,"unique":true}"#])
    /// A superset that enforces `mood`'s enum.
    private static let v2Enforced = build("h-v2e", ["mood": #"{"type":"string","enum":["x","y"],"enforceEnum":true}"#])
    /// Two builds each with a field the other lacks, and one holding both.
    private static let withA = build("h-a", ["a": #"{"type":"string"}"#])
    private static let withB = build("h-b", ["b": #"{"type":"string"}"#])
    private static let withBoth = build("h-ab", ["a": #"{"type":"string"}"#, "b": #"{"type":"string"}"#])

    /// The client models: `Entry` as the type declares it plus an indexed
    /// `extra` the type does not declare, and a `Stray` model the type does not declare.
    private static let entry = PrimitiveSchema(
        name: "Entry",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, unique: true), "status": FieldDescriptor(type: .string),
            "mood": FieldDescriptor(type: .string), "weight": FieldDescriptor(type: .number),
            "label": FieldDescriptor(type: .string, indexed: true), "tags": FieldDescriptor(type: .stringset),
            "notes": FieldDescriptor(type: .string), "a": FieldDescriptor(type: .string), "b": FieldDescriptor(type: .string),
            "extra": FieldDescriptor(type: .string, indexed: true),
        ]
    )
    private static let stray = PrimitiveSchema(name: "Stray", fields: ["id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string)])
    private static let tag = PrimitiveSchema(name: "Tag", fields: ["id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string)])

    /// `Entry` exactly as the base declarations hold it, for an untyped copy's list.
    private static let declaredEntry = PrimitiveSchema(
        name: "Entry",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, unique: true), "status": FieldDescriptor(type: .string),
            "mood": FieldDescriptor(type: .string), "weight": FieldDescriptor(type: .number),
            "label": FieldDescriptor(type: .string, indexed: true), "tags": FieldDescriptor(type: .stringset),
        ],
        constraints: ["title_weight": ConstraintDescriptor(name: "title_weight", fields: ["title", "weight"])]
    )

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _created: [String] = []
        private var _refused: [Db3WriteRefusedEvent] = []
        func created(_ id: String) { lock.withLock { _created.append(id) } }
        func refused(_ event: Db3WriteRefusedEvent) { lock.withLock { _refused.append(event) } }
        var createdIds: [String] { lock.withLock { _created } }
        var refusals: [Db3WriteRefusedEvent] { lock.withLock { _refused } }
    }

    private func directory() -> String {
        let made = NSTemporaryDirectory() + "/db3-local-only-typed-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        directories.append(made)
        return made
    }

    /// A client over `directory`'s store, signed in, networking stopped, its
    /// build declaring `types` (registered before anything binds) and its models.
    private func client(
        directory: String, types: PrimitiveDb3Types?, models: [PrimitiveSchema] = [entry, stray, tag]
    ) async throws -> (JsBaoClient, Heard, [EventSubscription]) {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-local-only-typed-6025",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        if let types { client.registerDb3Types(types) }
        _ = await client.waitForStorageReady()
        await client.goOffline()
        client.registerModels(models)
        client.documentManager.createRemoteDocument = { _ in throw JsBaoError(code: .unavailable, message: "nothing is sent") }
        client.documentManager.createRemoteDb3 = { _ in throw JsBaoError(code: .unavailable, message: "nothing is sent") }
        let heard = Heard()
        let subscriptions = [
            client.eventEmitter.subscribe(Db3CreatedEvent.self) { heard.created($0.id) },
            client.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { heard.refused($0) },
        ]
        return (client, heard, subscriptions)
    }

    private static func journal(_ declarations: PrimitiveDb3Types.LocalOnlyDeclarations, knownTypesOnly: Bool = false) -> PrimitiveDb3Types {
        PrimitiveDb3Types(knownTypesOnly: knownTypesOnly, types: [PrimitiveDb3Types.DeclaredType(name: "journal", localOnly: declarations)])
    }

    private func destroy(_ client: JsBaoClient) async {
        await client.destroy()
        clients.removeAll { $0 === client }
    }

    private func db3(_ client: JsBaoClient, _ transport: RecordingTransport) -> Db3API {
        Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
    }

    private func entries(_ client: JsBaoClient, _ db3Id: String) throws -> DynamicModel {
        try XCTUnwrap(client.sharedModel("Entry")?.member(docId: db3Id))
    }

    /// A typed local-only db3 created on a client building `declarations`, with `seed` saved, then that client destroyed.
    private func seeded(
        _ directory: String, _ declarations: PrimitiveDb3Types.LocalOnlyDeclarations, _ seed: [(String, [String: PrimitiveValue])]
    ) async throws -> String {
        let (first, _, subs) = try await client(directory: directory, types: Self.journal(declarations))
        let info = try await db3(first, RecordingTransport(status: 500, json: "{}")).create(title: "Journal", type: "journal", localOnly: true)
        let entries = try entries(first, info.id)
        for (id, values) in seed { _ = try entries.save(id: id, values: values) }
        subs.forEach { $0.cancel() }
        await destroy(first)
        return info.id
    }

    /// A client over `directory` building `declarations`, once the stored db3 bound.
    private func reopened(
        _ directory: String, _ db3Id: String, _ types: PrimitiveDb3Types?
    ) async throws -> (JsBaoClient, Heard, [EventSubscription]) {
        let opened = try await client(directory: directory, types: types)
        try await db3LocalOnlyEventually("the stored db3 bound at start-up") {
            guard opened.0.recordLogBinding(db3Id) != nil else { return false }
            return try await opened.0.db3.state(db3Id).resident
        }
        return opened
    }

    private func installedHash(_ client: JsBaoClient, _ db3Id: String) throws -> String? {
        try XCTUnwrap(client.recordLogBinding(db3Id)).store.marks().db3Type?.hash
    }

    // MARK: - Behavior 54

    func testATypedCreateAnswersTheTypedDb3WithNothingSent() async throws {
        let (client, heard, subs) = try await client(directory: directory(), types: Self.journal(Self.v1))
        defer { subs.forEach { $0.cancel() } }
        let transport = RecordingTransport(status: 500, json: "{}")
        let info = try await db3(client, transport).create(title: "Journal", type: "journal", localOnly: true)
        XCTAssertEqual(info.type, "journal")
        XCTAssertTrue(info.localOnly)
        XCTAssertFalse(info.sync)
        try await db3LocalOnlyEventually("Db3CreatedEvent") { heard.createdIds == [info.id] }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(heard.createdIds, [info.id], "Db3CreatedEvent fires once")
        XCTAssertEqual(transport.calls.count, 0, "nothing is sent")
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored.map(\.id), [info.id])
        XCTAssertEqual(stored.first?.type, "journal")
        XCTAssertEqual(stored.first?.localOnly, true)
        let state = try await client.db3.state(info.id)
        XCTAssertTrue(state.localOnly)
        XCTAssertNil(state.error)
        XCTAssertEqual(client.documentManager.getLocalMetadata(info.id)?.db3Type, "journal")
        XCTAssertEqual(try installedHash(client, info.id), "h-v1", "the build's declarations are installed with the create")
    }

    func testTheCreateRefusalsComeBeforeAnIdIsMinted() async throws {
        let types = PrimitiveDb3Types(knownTypesOnly: true, types: [
            PrimitiveDb3Types.DeclaredType(name: "journal", localOnly: Self.v1),
            PrimitiveDb3Types.DeclaredType(name: "catalog"),
            PrimitiveDb3Types.DeclaredType(name: "ledger", archived: true, localOnly: Self.v1),
        ])
        let (known, heard, subs) = try await client(directory: directory(), types: types)
        defer { subs.forEach { $0.cancel() } }
        let transport = RecordingTransport(status: 500, json: "{}")
        let api = db3(known, transport)
        let rows = known.documentManager.getMetadataIndex().count

        let unknown = await db3LocalOnlyThrown { _ = try await api.create(title: "T", type: "nope", localOnly: true) }
        XCTAssertEqual(unknown?.code, .invalidArgument)
        XCTAssertEqual(unknown?.details?["reason"], "unknown-type")
        let archived = await db3LocalOnlyThrown { _ = try await api.create(title: "T", type: "ledger", localOnly: true) }
        XCTAssertEqual(archived?.code, .invalidArgument)
        XCTAssertEqual(archived?.details?["reason"], "unknown-type")
        XCTAssertEqual(archived?.details?["archived"], .bool(true))
        for attempt in [
            { try await api.create(title: "T", type: "catalog", localOnly: true) },
            { try await api.create(title: "T", type: "journal", sync: false, localOnly: true) },
            { try await api.create(title: "T", type: "journal", custodian: "app", localOnly: true) },
        ] as [() async throws -> Db3Info] {
            let error = await db3LocalOnlyThrown { _ = try await attempt() }
            XCTAssertEqual(error?.code, .localOnlyUnsupportedOption)
        }

        // A build without the setting: a type it has no declarations for, as before.
        let (plain, _, plainSubs) = try await client(directory: directory(), types: Self.journal(Self.v1))
        defer { plainSubs.forEach { $0.cancel() } }
        let orders = await db3LocalOnlyThrown { _ = try await db3(plain, transport).create(title: "T", type: "orders", localOnly: true) }
        XCTAssertEqual(orders?.code, .localOnlyUnsupportedOption)

        XCTAssertEqual(known.documentManager.getMetadataIndex().count, rows, "no metadata row")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(heard.createdIds, [], "no event")
        XCTAssertEqual(transport.calls.count, 0)
    }

    // MARK: - Behavior 55

    func testWritesAreJudgedByTheInstalledDeclarationsThroughEveryDoor() async throws {
        let (client, heard, subs) = try await client(directory: directory(), types: Self.journal(Self.v1))
        defer { subs.forEach { $0.cancel() } }
        let info = try await db3(client, RecordingTransport(status: 500, json: "{}")).create(title: "J", type: "journal", localOnly: true)
        let entries = try entries(client, info.id)
        let strays = try XCTUnwrap(client.sharedModel("Stray")?.member(docId: info.id))
        let records = client.db3.records(info.id)
        _ = try entries.save(id: "e1", values: ["slug": .string("a"), "status": .string("open"), "weight": .number(1)])

        let cases: [(String, JsBaoErrorCode, () async throws -> Void)] = [
            ("a model it does not declare", .db3ModelNotDeclared, { _ = try strays.save(id: "s1", values: ["name": .string("x")]) }),
            ("a value of the wrong kind", .documentEntryInvalid, { _ = try entries.save(id: "e2", values: ["weight": .string("heavy")]) }),
            ("a value outside an enforced enum", .db3ValueNotInEnum, { _ = try entries.save(id: "e3", values: ["status": .string("lost")]) }),
            ("a shared unique key", .documentConstraintViolated, { _ = try entries.save(id: "e4", values: ["slug": .string("a")]) }),
            ("a transaction naming an undeclared model", .db3ModelNotDeclared, {
                try entries.transact {
                    _ = try entries.save(id: "e5", values: ["slug": .string("e5")])
                    _ = try strays.save(id: "s2", values: ["name": .string("y")])
                }
            }),
            ("a model-free write of an undeclared model", .db3ModelNotDeclared, { _ = try records.put("Stray", ["id": "s3", "name": "z"]) }),
            ("a model-free write of the wrong kind", .documentEntryInvalid, { _ = try records.put("Entry", ["id": "e6", "weight": "heavy"]) }),
            ("a model-free write outside an enforced enum", .db3ValueNotInEnum, { _ = try records.put("Entry", ["id": "e7", "status": "lost"]) }),
            ("a model-free write sharing a unique key", .documentConstraintViolated, { _ = try records.put("Entry", ["id": "e8", "slug": "a"]) }),
        ]
        for (what, code, attempt) in cases {
            let error = await db3LocalOnlyThrown { try await attempt() }
            XCTAssertEqual(error?.code, code, what)
            XCTAssertEqual(error?.details?["scope"], "local", what)
        }
        try await db3LocalOnlyEventually("one refusal event per refused write") { heard.refusals.count == cases.count }
        XCTAssertEqual(try entries.query().compactMap { $0["id"]?.stringValue }, ["e1"], "nothing refused landed")
        XCTAssertNil(strays.find(id: "s1"))

        // What the declarations take commits through each door.
        _ = try records.put("Entry", ["id": "e9", "slug": "b", "status": "done", "mood": "anything"])
        _ = try await entries.increment(id: "e1", fields: ["weight": 2], options: Db3WriteOptions())
        entries.delete(id: "e9")
        XCTAssertEqual(entries.find(id: "e1")?["weight"], .number(3))
    }

    func testAWriteIsJudgedByTheDeclarationsInstalledWhenItCommits() async throws {
        let (client, _, subs) = try await client(directory: directory(), types: Self.journal(Self.v1))
        defer { subs.forEach { $0.cancel() } }
        let info = try await db3(client, RecordingTransport(status: 500, json: "{}")).create(title: "J", type: "journal", localOnly: true)
        let binding = try XCTUnwrap(client.recordLogBinding(info.id))
        // Another client of the store installs declarations that add a string `notes`; this binding's marks are not re-read.
        let installed = try binding.store.installLocalType(try XCTUnwrap(RecordLogLocalType(name: "journal", declarations: Self.v2)))
        guard case .installed = installed else { return XCTFail("installed: \(installed)") }
        // The model-free door judges no field kind before its commit: only the store's judge, in the commit, refuses this.
        let error = await db3LocalOnlyThrown { _ = try client.db3.records(info.id).put("Entry", ["id": "e1", "notes": 1]) }
        XCTAssertEqual(error?.code, .documentEntryInvalid, "judged by the declarations the store holds at the commit")
        XCTAssertEqual(error?.details?["scope"], "local")
        _ = try client.db3.records(info.id).put("Entry", ["id": "e2", "notes": "n"])
        _ = try client.db3.records(info.id).put("Tag", ["id": "t1", "name": "x"])
    }

    // MARK: - Behavior 56

    func testIndexesAndConstraintsComeFromTheInstalledDeclarations() async throws {
        let transport = RecordingTransport(status: 500, json: "{}")
        let (typed, _, subs) = try await client(directory: directory(), types: Self.journal(Self.v1))
        defer { subs.forEach { $0.cancel() } }
        let info = try await db3(typed, transport).create(title: "J", type: "journal", localOnly: true)
        let list = try await db3(typed, transport).indexes.list(info.id)
        XCTAssertFalse(list.contains { $0.fields == ["extra"] }, "a registered model's own index adds nothing: \(list.map(\.name))")

        // An untyped local-only db3 whose models declare exactly what the type does lists the same indexes.
        let (untyped, _, untypedSubs) = try await client(directory: directory(), types: nil, models: [Self.declaredEntry])
        defer { untypedSubs.forEach { $0.cancel() } }
        let plain = try await db3(untyped, transport).create(title: "P", localOnly: true)
        let expected = try await db3(untyped, transport).indexes.list(plain.id)
        XCTAssertEqual(list.map(\.name), expected.map(\.name))
        XCTAssertEqual(list.map(\.fields), expected.map(\.fields))
        XCTAssertEqual(list.map(\.unique), expected.map(\.unique))
        XCTAssertTrue(list.contains { $0.fields == ["label"] && !$0.unique })
        XCTAssertTrue(list.contains { $0.fields == ["slug"] && $0.unique })
        XCTAssertTrue(list.contains { $0.fields == ["title", "weight"] && $0.unique })
        let constraints = try XCTUnwrap(typed.recordLogBinding(info.id)).store.marks().constraints.map(\.name).sorted()
        XCTAssertEqual(constraints, ["Entry_slug_unique", "title_weight"])
        XCTAssertEqual(transport.calls.count, 0)
    }

    // MARK: - Behavior 57

    func testANewerBuildsSupersetInstallsOnOpen() async throws {
        let directory = directory()
        let id = try await seeded(directory, Self.v1, [("e1", ["slug": .string("a"), "status": .string("open")])])
        let (client, _, subs) = try await reopened(directory, id, Self.journal(Self.v2))
        defer { subs.forEach { $0.cancel() } }
        try await db3LocalOnlyEventually("the superset installed") { try installedHash(client, id) == "h-v2" }
        let state = try await client.db3.state(id)
        XCTAssertNil(state.error)
        let list = try await db3(client, RecordingTransport(status: 500, json: "{}")).indexes.list(id)
        XCTAssertTrue(list.contains { $0.fields == ["notes"] }, "the new index is listed")
        let entries = try entries(client, id)
        _ = try entries.save(id: "e2", values: ["slug": .string("b"), "status": .string("doing"), "notes": .string("n")])
        let tags = try XCTUnwrap(client.sharedModel("Tag")?.member(docId: id))
        _ = try tags.save(id: "t1", values: ["name": .string("x")])
        let wrong = await db3LocalOnlyThrown { _ = try entries.save(id: "e3", values: ["notes": .number(1)]) }
        XCTAssertEqual(wrong?.code, .documentEntryInvalid, "a write of the new field is judged")
    }

    func testARefusedInstallIsReportedAndKeepsTheInstalledDeclarations() async throws {
        let directory = directory()
        let id = try await seeded(directory, Self.v1, [("e1", ["slug": .string("a"), "label": .string("same")]), ("e2", ["slug": .string("b"), "label": .string("same")])])
        let (client, _, subs) = try await reopened(directory, id, Self.journal(Self.v2Unique))
        try await db3LocalOnlyEventually("the refusal reported") { try await client.db3.state(id).error != nil }
        let error = try await XCTUnwrapAsync(try await client.db3.state(id).error)
        XCTAssertEqual(error.code, "DB3_TYPE_REFUSED")
        let reason = try XCTUnwrap(error.reasons?.first)
        XCTAssertEqual(reason.path, "models.Entry.constraints.Entry_label_unique")
        XCTAssertEqual(reason.duplicates, 1)
        XCTAssertEqual(reason.samples, [["same"]])
        XCTAssertEqual(try installedHash(client, id), "h-v1", "nothing installed")
        // Readable and writable under the installed declarations.
        let entries = try entries(client, id)
        _ = try entries.save(id: "e3", values: ["slug": .string("c"), "label": .string("same")])
        XCTAssertEqual(try entries.query().count, 3)
        entries.delete(id: "e3")
        _ = try entries.save(id: "e2", values: ["slug": .string("b"), "label": .string("other")])
        subs.forEach { $0.cancel() }
        await destroy(client)

        // With the duplicate resolved, the next bind installs and the error clears.
        let (again, _, againSubs) = try await reopened(directory, id, Self.journal(Self.v2Unique))
        defer { againSubs.forEach { $0.cancel() } }
        try await db3LocalOnlyEventually("the install") { try installedHash(again, id) == "h-v2u" }
        let cleared = try await again.db3.state(id)
        XCTAssertNil(cleared.error)
    }

    func testAnOlderBuildKeepsTheInstalledDeclarations() async throws {
        let directory = directory()
        let id = try await seeded(directory, Self.v1, [("e1", ["slug": .string("a"), "mood": .string("x")])])
        let (newer, _, newerSubs) = try await reopened(directory, id, Self.journal(Self.v2Enforced))
        try await db3LocalOnlyEventually("the newer build installed") { try installedHash(newer, id) == "h-v2e" }
        newerSubs.forEach { $0.cancel() }
        await destroy(newer)

        let (older, _, subs) = try await reopened(directory, id, Self.journal(Self.v1))
        defer { subs.forEach { $0.cancel() } }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try installedHash(older, id), "h-v2e", "kept")
        let state = try await older.db3.state(id)
        XCTAssertNil(state.error, "nothing is reported")
        let entries = try entries(older, id)
        _ = try entries.save(id: "e2", values: ["slug": .string("b"), "mood": .string("y")])
        let refused = await db3LocalOnlyThrown { _ = try entries.save(id: "e3", values: ["slug": .string("c"), "mood": .string("z")]) }
        XCTAssertEqual(refused?.code, .db3ValueNotInEnum, "the newer build's enforcement holds on the older build's writes")
    }

    func testADivergedBuildsWritesAreRefusedUntilASupersetBuildOpens() async throws {
        let directory = directory()
        let id = try await seeded(directory, Self.withA, [("e1", ["slug": .string("a")])])
        let (diverged, heard, subs) = try await reopened(directory, id, Self.journal(Self.withB))
        try await db3LocalOnlyEventually("the divergence reported") { try await diverged.db3.state(id).error != nil }
        let divergedState = try await diverged.db3.state(id)
        XCTAssertEqual(divergedState.error?.code, "DB3_TYPE_REFUSED")
        XCTAssertEqual(try installedHash(diverged, id), "h-a")
        let entries = try entries(diverged, id)
        XCTAssertEqual(entries.find(id: "e1")?.id, "e1", "reads work")
        let attempts: [() async throws -> Void] = [
            { _ = try entries.save(id: "e2", values: ["slug": .string("b")]) },
            { try entries.transact { _ = try entries.save(id: "e3", values: ["slug": .string("c")]) } },
            { _ = try diverged.db3.records(id).put("Entry", ["id": "e4", "slug": "d"]) },
        ]
        for attempt in attempts {
            let error = await db3LocalOnlyThrown { try await attempt() }
            XCTAssertEqual(error?.code, .db3TypeRefused)
            XCTAssertEqual(error?.details?["diverged"], .bool(true))
            XCTAssertEqual(error?.details?["scope"], "local")
        }
        try await db3LocalOnlyEventually("one event per refused write") { heard.refusals.count == attempts.count }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(heard.refusals.count, attempts.count)
        subs.forEach { $0.cancel() }
        await destroy(diverged)

        let (both, _, bothSubs) = try await reopened(directory, id, Self.journal(Self.withBoth))
        defer { bothSubs.forEach { $0.cancel() } }
        try await db3LocalOnlyEventually("the superset of both installed") { try installedHash(both, id) == "h-ab" }
        _ = try self.entries(both, id).save(id: "e5", values: ["slug": .string("e"), "a": .string("1"), "b": .string("2")])
    }

    func testUnreadableTypeStateRefusesWritesUntilADeclaringBuildRecoversIt() async throws {
        let directory = directory()
        let id = try await seeded(directory, Self.v1, [("e1", ["slug": .string("a"), "status": .string("open")])])
        do {
            let (first, _, subs) = try await reopened(directory, id, Self.journal(Self.v1))
            let store = try XCTUnwrap(first.recordLogBinding(id)).store
            try store.save { sql in
                try sql.exec("UPDATE record_log_meta SET value = '{not json' WHERE key = ?", [.text("db3_type:\(id)")])
            }
            subs.forEach { $0.cancel() }
            await destroy(first)
        }

        // A build with no declarations for the type: reads work, writes stay refused.
        let (none, _, noneSubs) = try await reopened(directory, id, nil)
        let entries = try entries(none, id)
        XCTAssertEqual(entries.find(id: "e1")?.id, "e1")
        let refused = await db3LocalOnlyThrown { _ = try entries.save(id: "e2", values: ["slug": .string("b")]) }
        XCTAssertEqual(refused?.code, .db3TypeRefused)
        XCTAssertEqual(refused?.details?["unreadable"], .bool(true))
        let modelFree = await db3LocalOnlyThrown { _ = try none.db3.records(id).put("Entry", ["id": "e3", "slug": "c"]) }
        XCTAssertEqual(modelFree?.code, .db3TypeRefused)
        try await db3LocalOnlyEventually("the state says so") { try await none.db3.state(id).error?.code == "DB3_TYPE_REFUSED" }
        noneSubs.forEach { $0.cancel() }
        await destroy(none)

        // A build declaring the type (named by the db3's metadata) checks the records and installs.
        let (declaring, _, subs) = try await reopened(directory, id, Self.journal(Self.v1))
        defer { subs.forEach { $0.cancel() } }
        try await db3LocalOnlyEventually("recovered") { try installedHash(declaring, id) == "h-v1" }
        let state = try await declaring.db3.state(id)
        XCTAssertNil(state.error)
        let recovered = try self.entries(declaring, id)
        _ = try recovered.save(id: "e4", values: ["slug": .string("d"), "status": .string("done")])
        let judged = await db3LocalOnlyThrown { _ = try recovered.save(id: "e5", values: ["slug": .string("e"), "status": .string("lost")]) }
        XCTAssertEqual(judged?.code, .db3ValueNotInEnum)
    }
}

/// `try XCTUnwrap` over an async expression.
private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
