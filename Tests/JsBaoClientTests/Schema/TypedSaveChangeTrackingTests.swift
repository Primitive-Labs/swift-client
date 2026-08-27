import XCTest
@testable import JsBaoClient
import YSwift

/// The typed facade half of #2459: the codegen'd struct tracks which fields
/// the caller assigned, and `save(in:)` hands that set to the runtime so an
/// update writes only those fields.
///
/// Runs against the committed `TaskRecord` golden
/// (`CodegenAcceptance/Generated/TaskRecord.swift`) so it exercises the real
/// emitted code, and against an offline in-memory client so `save(in:)` takes
/// its real path through `JsBaoClient.codegen.save`.
final class TypedSaveChangeTrackingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SchemaSync.clearCache()
        JsBaoClient.clearDefault()
    }

    override func tearDown() {
        JsBaoClient.clearDefault()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Encode the full state of `source` and apply it to `target`.
    private func sync(from source: YDocument, to target: YDocument) {
        let svTxn = target.document.transact(origin: nil)
        let sv = svTxn.transactionStateVector()
        svTxn.free()

        let diffTxn = source.document.transact(origin: nil)
        let update = (try? diffTxn.transactionEncodeStateAsUpdateFromSv(stateVector: sv)) ?? []
        diffTxn.free()

        if !update.isEmpty {
            let applyTxn = target.document.transact(origin: nil)
            try? applyTxn.transactionApplyUpdate(update: update)
            applyTxn.free()
        }
    }

    // MARK: - Change-set bookkeeping

    func testConstructedRecordMarksEveryFieldItCarries() {
        let made = TaskRecord(id: "t1", title: "hello", priority: 3)
        XCTAssertEqual(made._changedFields, ["title", "priority"],
                       "a constructed record is new data — every field it carries is a change")

        let auto = TaskRecord(title: "auto")
        XCTAssertEqual(auto._changedFields, ["title"],
                       "nil optionals aren't written, so they aren't changes either")
    }

    func testRecordReadFromStoreStartsCleanAndTracksAssignments() throws {
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: TaskRecord.primitiveSchema)
        _ = try model.create(id: "t1", values: TaskRecord(
            id: "t1", title: "stored", priority: 1
        ).primitiveValues())

        var loaded = try XCTUnwrap(TaskRecord(record: XCTUnwrap(model.find(id: "t1"))))
        XCTAssertTrue(loaded._changedFields.isEmpty,
                      "a record read back from the store has nothing pending")

        loaded.title = "edited"
        XCTAssertEqual(loaded._changedFields, ["title"])

        loaded.discardChanges()
        XCTAssertTrue(loaded._changedFields.isEmpty)
    }

    func testRowInitStartsClean() throws {
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: TaskRecord.primitiveSchema)
        _ = try model.create(id: "t1", values: TaskRecord(
            id: "t1", title: "stored", priority: 1
        ).primitiveValues())

        let row = try XCTUnwrap(try model.query(["id": "t1"]).first)
        let decoded = try XCTUnwrap(TaskRecord(row: row))
        XCTAssertTrue(decoded._changedFields.isEmpty)
    }

    func testDecodedRecordMarksEveryDecodedField() throws {
        let original = TaskRecord(id: "t1", title: "json", priority: 4, tags: ["a"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: data)
        XCTAssertEqual(
            decoded._changedFields, ["title", "priority", "tags"],
            "decoding is a construction, not a store read — a decoded record must still save its fields"
        )
    }

    // MARK: - End-to-end through the generated facade

    func testTypedSaveDoesNotClobberAnotherDevicesFieldEdit() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([TaskRecord.self])

        let (docId, maybeDoc) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        let docA = try XCTUnwrap(maybeDoc)

        try TaskRecord(id: "t1", title: "original", priority: 5).save(in: docId)

        // A second device: a bare doc carrying the same model, synced from A.
        let docB = YDocument()
        let modelB = DynamicModel(doc: docB, schema: TaskRecord.primitiveSchema)
        sync(from: docA, to: docB)

        // The app reads the record BEFORE the other device's edit arrives, so
        // its snapshot of `priority` is about to go stale.
        var task = try XCTUnwrap(try TaskRecord.find("t1"))
        XCTAssertEqual(task.priority, 5)

        // Device B changes `priority`; the change reaches this client.
        try modelB.update(id: "t1", values: ["priority": .number(9)])
        sync(from: docB, to: docA)
        XCTAssertEqual(try TaskRecord.find("t1")?.priority, 9,
                       "precondition: the remote field edit landed")

        // The app edits a DIFFERENT field on its stale snapshot and saves.
        task.title = "A's new title"
        let saved = try task.save(in: docId)

        let read = try XCTUnwrap(try TaskRecord.find("t1"))
        XCTAssertEqual(read.title, "A's new title")
        XCTAssertEqual(
            read.priority, 9,
            "save(in:) re-wrote `priority` from the stale snapshot — the other device's edit was lost"
        )
        XCTAssertTrue(saved._changedFields.isEmpty,
                      "the returned record is the saved state — nothing pending")
    }

    func testTypedSaveOfAConstructedRecordStillWritesEveryField() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([TaskRecord.self])

        let (docId, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )

        try TaskRecord(
            id: "t1", title: "full", priority: 7, tags: ["x", "y"],
            createdAt: "2026-08-05T00:00:00Z"
        ).save(in: docId)

        let read = try XCTUnwrap(try TaskRecord.find("t1"))
        XCTAssertEqual(read.title, "full")
        XCTAssertEqual(read.priority, 7)
        XCTAssertEqual(read.tags, ["x", "y"])
        XCTAssertEqual(read.createdAt, "2026-08-05T00:00:00Z")
    }

    /// A record loaded from one document has an empty change set. Saving it
    /// into a document that doesn't have it yet is an INSERT, and an insert
    /// must still write every field.
    func testSavingALoadedRecordIntoAnotherDocumentWritesEveryField() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([TaskRecord.self])

        let (docA, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        let (docB, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )

        try TaskRecord(id: "t1", title: "copy me", priority: 2, tags: ["z"]).save(in: docA)

        let loaded = try XCTUnwrap(try TaskRecord.find("t1"))
        XCTAssertTrue(loaded._changedFields.isEmpty)
        try loaded.save(in: docB)

        let inB = try XCTUnwrap(
            try TaskRecord.query(nil, options: QueryOptions(documents: [docB])).first
        )
        XCTAssertEqual(inB.title, "copy me")
        XCTAssertEqual(inB.priority, 2)
        XCTAssertEqual(inB.tags, ["z"])
    }

    /// The other half of the cross-document case: when the target document
    /// ALREADY holds the record, the save is an update, and a record read
    /// out of the store has an empty change set — so nothing is written.
    ///
    /// This matches js-bao (`BaseModel.save` bails on an empty
    /// `_diffWithYjsData` when the target doc already has the record), and
    /// it is the sharp edge of field-level saves: "copy this record over
    /// the one in that doc" is not what an unmodified loaded record means.
    /// `markAllChanged()` is the supported way to ask for the full copy.
    func testSavingALoadedRecordOverAnExistingOneNeedsMarkAllChanged() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([TaskRecord.self])

        let (docA, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        let (docB, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )

        try TaskRecord(id: "t1", title: "from A", priority: 2, tags: ["z"]).save(in: docA)
        try TaskRecord(id: "t1", title: "already in B", priority: 100).save(in: docB)

        let loaded = try XCTUnwrap(
            try TaskRecord.query(["id": "t1"], options: QueryOptions(documents: [docA])).first
        )
        XCTAssertTrue(loaded._changedFields.isEmpty)

        // Unmodified: the update writes nothing, so B keeps its own values.
        try loaded.save(in: docB)
        let untouched = try XCTUnwrap(
            try TaskRecord.query(nil, options: QueryOptions(documents: [docB])).first
        )
        XCTAssertEqual(untouched.title, "already in B",
                       "an unmodified loaded record must not overwrite the target doc's copy")
        XCTAssertEqual(untouched.priority, 100)

        // Re-armed: every field it carries is written.
        var copy = loaded
        copy.markAllChanged()
        try copy.save(in: docB)
        let overwritten = try XCTUnwrap(
            try TaskRecord.query(nil, options: QueryOptions(documents: [docB])).first
        )
        XCTAssertEqual(overwritten.title, "from A")
        XCTAssertEqual(overwritten.priority, 2)
        XCTAssertEqual(overwritten.tags, ["z"])
    }

    /// A decoded record is treated as constructed, so saving it over an
    /// existing record updates every decoded field.
    func testSavingADecodedRecordUpdatesEveryField() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([TaskRecord.self])

        let (docId, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        try TaskRecord(id: "t1", title: "old", priority: 1).save(in: docId)

        let payload = try JSONEncoder().encode(
            TaskRecord(id: "t1", title: "new", priority: 42)
        )
        let decoded = try JSONDecoder().decode(TaskRecord.self, from: payload)
        try decoded.save(in: docId)

        let read = try XCTUnwrap(try TaskRecord.find("t1"))
        XCTAssertEqual(read.title, "new")
        XCTAssertEqual(read.priority, 42)
    }

    // MARK: - What `save(in:)` hands back

    /// The return value must be the record AS SAVED, not a copy of the
    /// caller's own (now partly stale) value. Narrowing the write means the
    /// fields this save didn't touch may hold another device's newer value —
    /// the exact case #2459 is about — so returning `self` would hand back a
    /// record the document does not contain, while the emitted doc comment
    /// and the docs both tell callers to write `task = try task.save(...)`.
    func testSaveReturnsTheRecordAsSavedNotTheStaleSelf() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([TaskRecord.self])

        let (docId, maybeDoc) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )
        let docA = try XCTUnwrap(maybeDoc)

        try TaskRecord(id: "t1", title: "original", priority: 5).save(in: docId)

        let docB = YDocument()
        let modelB = DynamicModel(doc: docB, schema: TaskRecord.primitiveSchema)
        sync(from: docA, to: docB)

        // Read before the other device's edit arrives — `priority` goes stale.
        var task = try XCTUnwrap(try TaskRecord.find("t1"))
        XCTAssertEqual(task.priority, 5)

        try modelB.update(id: "t1", values: ["priority": .number(9)])
        sync(from: docB, to: docA)

        task.title = "A's new title"
        let saved = try task.save(in: docId)

        XCTAssertEqual(saved.title, "A's new title")
        XCTAssertEqual(
            saved.priority, 9,
            "save(in:) returned a stale copy of `self` — `priority` is the other device's value in the document"
        )
        XCTAssertTrue(saved._changedFields.isEmpty,
                      "the returned record is the saved state — nothing pending")

        // `self` is untouched: the caller's own value still reads as it did.
        XCTAssertEqual(task.priority, 5)
    }

    /// The insert path fills schema defaults into the document. Those are
    /// part of the saved record, so the returned value must carry them —
    /// a caller that reassigns is otherwise left holding `nil` for every
    /// defaulted field it didn't set.
    func testSaveReturnsSchemaDefaultsFilledOnInsert() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrashTestRecord.self])

        let (docId, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )

        let made = CrashTestRecord(id: "c1", requiredTags: ["a"])
        XCTAssertNil(made.`default`, "precondition: the caller never set the defaulted fields")
        XCTAssertNil(made.score)
        XCTAssertNil(made.active)

        let saved = try made.save(in: docId)
        XCTAssertEqual(saved.`default`, "fallback")
        XCTAssertEqual(saved.score, 100)
        XCTAssertEqual(saved.active, true)
        XCTAssertEqual(saved.requiredTags, ["a"])
        XCTAssertTrue(saved._changedFields.isEmpty)
    }

    /// Rebuilding from the stored record can't recover state the store
    /// doesn't hold, so `save(in:)` carries it over from `self`: query-time
    /// relationship includes (`related`) and the caller-pinned-id flag
    /// (`_explicitId`, which drives the upsert conflict check).
    func testSaveReturnValueKeepsIncludesAndExplicitIdProvenance() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([RelTestRecord.self, TaskRecord.self, UserProfileRecord.self])

        let (docId, _) = try await client.createDocumentForTest(
            options: CreateDocumentOptions(localOnly: true)
        )

        try TaskRecord(id: "task1", title: "Included task").save(in: docId)
        try RelTestRecord(id: "r1", taskId: "task1").save(in: docId)

        var withIncludes = try XCTUnwrap(
            try RelTestRecord.query(["id": "r1"], include: [RelTestRecord.includeTask()]).first
        )
        XCTAssertEqual(withIncludes.relatedTask?.id, "task1", "precondition: the include resolved")

        withIncludes.profileId = "p1"
        let saved = try withIncludes.save(in: docId)
        XCTAssertEqual(saved.profileId, "p1")
        XCTAssertEqual(saved.relatedTask?.id, "task1",
                       "the resolved include must survive the save — the store doesn't hold it")
        XCTAssertEqual(saved.related.one("task", as: TaskRecord.self)?.title, "Included task")

        // An auto-generated id is not caller-pinned; that provenance drives
        // `save(in:upsertOn:)`'s explicit-id conflict check, so it has to
        // survive a plain save too.
        let autoId = TaskRecord(title: "auto")
        XCTAssertFalse(autoId._explicitId)
        XCTAssertFalse(try autoId.save(in: docId)._explicitId)

        let pinned = TaskRecord(id: "pinned1", title: "pinned")
        XCTAssertTrue(pinned._explicitId)
        XCTAssertTrue(try pinned.save(in: docId)._explicitId)
    }
}
