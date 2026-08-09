import XCTest
@testable import JsBaoClient
import YSwift

/// Tests the one-model facade (#918): the codegen'd type is the single
/// app-facing API. Reads (`query`/`count`/`findAll`/`find`/`subscribe`) span
/// every open document by default; instance writes (`save(in:)` —
/// create-or-update, like JS — and `delete(in:)`) target one document and
/// throw if it isn't open. All delegate to the configured default
/// `JsBaoClient`'s shared store.
///
/// `CrossDocNote` + its facade extension below are hand-written to match what
/// `SwiftEmitter.crossDocumentFacade(schema:)` emits, so this exercises the
/// real generated contract without invoking codegen.
///
/// They cover the READ/WRITE DELEGATION only. The hand-written models here
/// deliberately leave out the emitter's change tracking (`_changedFields`,
/// the per-field `didSet`, `discardChanges()` / `markAllChanged()`), so their
/// writes take the untyped `changedFields: nil` path — which is what these
/// tests want to assert against. The emitted shape is pinned elsewhere:
/// `SwiftEmitterTests.testEmitsChangeTrackingMembers` and the committed
/// goldens under `CodegenAcceptance/Generated/`. Don't read these structs as
/// a current picture of generated code.
final class CrossDocumentStaticQueryTests: XCTestCase {

    struct CrossDocNote: PrimitiveModel, Equatable {
        static let modelName = "crossdoc_notes"
        static let primitiveSchema = PrimitiveSchema(
            name: "crossdoc_notes",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string, required: true),
                "done":  FieldDescriptor(type: .boolean, required: true),
            ]
        )

        var id: String
        var title: String
        var done: Bool

        init(id: String, title: String, done: Bool) {
            self.id = id; self.title = title; self.done = done
        }

        init?(record: PrimitiveRecord) {
            guard let title = record["title"]?.asString,
                  let done = record["done"]?.asBoolean
            else { return nil }
            self.id = record.id; self.title = title; self.done = done
        }

        init?(row: [String: Any]) {
            guard let id = row["id"] as? String,
                  let title = row["title"] as? String,
                  let done = (row["done"] as? Bool) ?? (row["done"] as? Int).map({ $0 != 0 })
            else { return nil }
            self.id = id; self.title = title; self.done = done
        }

        func primitiveValues() -> [String: PrimitiveValue] {
            ["title": .string(title), "done": .boolean(done)]
        }
    }

    override func setUp() {
        super.setUp()
        SchemaSync.clearCache()
        JsBaoClient.clearDefault()
    }

    override func tearDown() {
        JsBaoClient.clearDefault()
        super.tearDown()
    }

    // MARK: - Default client lifecycle

    func testDefaultClientConfigureAndClear() {
        XCTAssertNil(JsBaoClient.default)
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        XCTAssertIdentical(JsBaoClient.default, client)
        XCTAssertIdentical(JsBaoClient.requireDefault(), client)
        JsBaoClient.clearDefault()
        XCTAssertNil(JsBaoClient.default)
    }

    // MARK: - Reads span every open doc; writes target one doc

    func testQuerySpansAllOpenDocumentsAndDropsOnClose() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])

        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        let (docB, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        // Writes go through the ONE model, naming the target doc.
        try CrossDocNote(id: "a1", title: "alpha", done: false).save(in: docA)
        try CrossDocNote(id: "a2", title: "beta",  done: true).save(in: docA)
        try CrossDocNote(id: "b1", title: "gamma", done: false).save(in: docB)

        // Reads span every open doc by default.
        XCTAssertEqual(try CrossDocNote.count(), 3)
        let all = try CrossDocNote.findAll()
        XCTAssertEqual(Set(all.map(\.id)), ["a1", "a2", "b1"])
        let b1 = try CrossDocNote.find("b1")
        XCTAssertEqual(b1?.title, "gamma")

        // Filters apply across the union.
        XCTAssertEqual(Set(try CrossDocNote.query(["done": false]).map(\.id)), ["a1", "b1"])

        // Single-doc opt-in via options.documents (matches js-bao).
        let onlyA = try CrossDocNote.query(nil, options: QueryOptions(documents: [docA]))
        XCTAssertEqual(Set(onlyA.map(\.id)), ["a1", "a2"])

        // Closing a document drops its rows from later cross-doc reads.
        await client.closeDocument(docB)
        XCTAssertEqual(try CrossDocNote.count(), 2)
        let remaining = try CrossDocNote.findAll()
        XCTAssertEqual(Set(remaining.map(\.id)), ["a1", "a2"])
    }

    // MARK: - Writing to a doc that isn't open throws

    func testWriteToUnopenedDocumentThrows() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])

        XCTAssertThrowsError(
            try CrossDocNote(id: "x", title: "nope", done: false)
                .save(in: "01ZZZZZZZZZZZZZZZZZZZZZZZZ")
        )
    }

    // MARK: - save() is create-or-update (matches JS save())

    func testSaveInsertsThenUpdatesInPlace() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])

        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        // First save inserts.
        try CrossDocNote(id: "n1", title: "draft", done: false).save(in: docA)
        XCTAssertEqual(try CrossDocNote.count(), 1)
        let inserted = try CrossDocNote.find("n1")
        XCTAssertEqual(inserted?.title, "draft")
        XCTAssertEqual(inserted?.done, false)

        // Second save with the same id updates in place — no duplicate row.
        try CrossDocNote(id: "n1", title: "final", done: true).save(in: docA)
        XCTAssertEqual(try CrossDocNote.count(), 1)
        let updated = try CrossDocNote.find("n1")
        XCTAssertEqual(updated?.title, "final")
        XCTAssertEqual(updated?.done, true)
    }

    // MARK: - A document opened AFTER registration is auto-connected

    func testDocumentOpenedAfterRegistrationIsConnected() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])
        XCTAssertEqual(try CrossDocNote.count(), 0)

        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        try CrossDocNote(id: "a1", title: "alpha", done: false).save(in: docA)

        XCTAssertEqual(try CrossDocNote.count(), 1)
        let firstNote = try CrossDocNote.findAll().first
        XCTAssertEqual(firstNote?.title, "alpha")
    }

    // MARK: - Lazy registration: write/read before registerModels still works

    func testLazyRegistrationConnectsAlreadyOpenDocuments() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)

        // Open a doc BEFORE the model is ever registered/queried.
        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        XCTAssertEqual(try CrossDocNote.count(), 0)   // lazily registers here
        // The first write also lazily connects the already-open doc.
        try CrossDocNote(id: "a1", title: "alpha", done: false).save(in: docA)
        XCTAssertEqual(try CrossDocNote.count(), 1)
    }

    // MARK: - subscribe fires across documents

    func testSubscribeFiresOnWritesInAnyDocument() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])

        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        let (docB, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        let counter = LockedBox(0)
        let unsubscribe = CrossDocNote.subscribe { counter.add(1) }
        defer { unsubscribe() }

        try CrossDocNote(id: "a1", title: "alpha", done: false).save(in: docA)
        try CrossDocNote(id: "b1", title: "gamma", done: true).save(in: docB)

        try await eventually(description: "subscribe fired for writes in both docs") {
            counter.value >= 2
        }
    }

    // MARK: - queryOne returns the first match (or nil)

    func testQueryOneReturnsFirstMatchOrNil() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])

        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        try CrossDocNote(id: "a1", title: "alpha", done: false).save(in: docA)
        try CrossDocNote(id: "a2", title: "beta", done: true).save(in: docA)

        // A filter that matches exactly one row returns it.
        XCTAssertEqual(try CrossDocNote.queryOne(["title": "beta"])?.id, "a2")
        // A filter that matches nothing returns nil.
        XCTAssertNil(try CrossDocNote.queryOne(["title": "nope"]))
        // queryOne(nil) returns *some* record when any exist.
        XCTAssertNotNil(try CrossDocNote.queryOne())
    }

    // MARK: - queryOne with query-time includes (#1216)
    //
    // Closes the typed parity hole #1194 left: query/queryPaged took an
    // `include:` overload but queryOne did not, so a typed Swift app could
    // not load related data for a single record without dropping to the
    // untyped DynamicModel path. The overload returns the first match with
    // its `_related` bag populated, reachable through the typed accessor —
    // equivalent to `query(filter, include:).first`.

    func testQueryOneWithIncludeReturnsFirstMatchWithRelated() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([IncAuthor.self, IncPost.self])

        let (authorsDoc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        let (postsDoc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        try IncAuthor(id: "au1", name: "Alice").save(in: authorsDoc)
        try IncAuthor(id: "au2", name: "Bob").save(in: authorsDoc)
        // Two posts by Alice so the filter matches more than one row — proves
        // queryOne returns the FIRST and still resolves its include.
        try IncPost(id: "p1", authorId: "au1", title: "alpha").save(in: postsDoc)
        try IncPost(id: "p2", authorId: "au1", title: "beta").save(in: postsDoc)
        try IncPost(id: "p3", authorId: "au2", title: "gamma").save(in: postsDoc)

        // First match (by id sort) for Alice's posts, with the author included.
        let post = try IncPost.queryOne(
            ["authorId": "au1"],
            options: QueryOptions(sort: ["id": 1]),
            include: [IncPost.includeAuthor()]
        )
        XCTAssertEqual(post?.id, "p1", "queryOne returns the first matching row")
        XCTAssertEqual(post?.relatedAuthor?.id, "au1")
        XCTAssertEqual(post?.relatedAuthor?.name, "Alice",
                       "the author lives in a different doc — the include must still resolve")

        // Equivalent to `query(filter, include:).first`.
        let firstOfQuery = try IncPost.query(
            ["authorId": "au1"],
            options: QueryOptions(sort: ["id": 1]),
            include: [IncPost.includeAuthor()]
        ).first
        XCTAssertEqual(post?.id, firstOfQuery?.id)
        XCTAssertEqual(post?.relatedAuthor?.id, firstOfQuery?.relatedAuthor?.id)
    }

    func testQueryOneWithIncludeReturnsNilWhenNoMatch() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([IncAuthor.self, IncPost.self])

        let (authorsDoc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        let (postsDoc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        try IncAuthor(id: "au1", name: "Alice").save(in: authorsDoc)
        try IncPost(id: "p1", authorId: "au1", title: "alpha").save(in: postsDoc)

        // A filter that matches nothing returns nil — no related decode attempted.
        let none = try IncPost.queryOne(
            ["authorId": "nobody"],
            include: [IncPost.includeAuthor()]
        )
        XCTAssertNil(none)
    }

    // MARK: - findByUnique + save(in:upsertOn:) (unique-constraint facade)

    func testFindByUniqueAndUpsertOnAcrossDocs() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([UniqueNote.self])

        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        // Insert via upsertOn — no existing slug, so a new record lands
        // with the struct's id.
        let inserted = try UniqueNote(id: "u1", slug: "intro", body: "first")
            .save(in: docA, upsertOn: "slug")
        XCTAssertEqual(inserted.id, "u1", "no-match upsert inserts under the struct's id")
        XCTAssertEqual(try UniqueNote.count(), 1)

        // findByUnique resolves the record by its unique slug.
        let found = try UniqueNote.findByUnique("by_slug", .string("intro"))
        XCTAssertEqual(found?.id, "u1")
        XCTAssertEqual(found?.body, "first")

        // #1122: a DIFFERENT *explicit* id colliding on the slug is now a
        // hard conflict (js-bao `_constructorProvidedId` parity).
        XCTAssertThrowsError(
            try UniqueNote(id: "u2", slug: "intro", body: "rewritten")
                .save(in: docA, upsertOn: "slug")
        ) { error in
            XCTAssertEqual(error as? UpsertError,
                           .explicitIdConflict(supplied: "u2", existing: "u1"))
        }

        // upsertOn with the same slug and an AUTO id MERGES into the
        // existing record (keeps id u1), not a second row. The RETURNED
        // record carries the resolved (existing) id — JS parity with
        // `this.id = existingId` reassignment in save({ upsertOn }).
        let merged = try UniqueNote(slug: "intro", body: "rewritten")
            .save(in: docA, upsertOn: "slug")
        XCTAssertEqual(merged.id, "u1", "merge must resolve to the existing record's id")
        XCTAssertEqual(merged.body, "rewritten")
        XCTAssertEqual(try UniqueNote.count(), 1, "upsertOn should merge, not duplicate")
        XCTAssertEqual(try UniqueNote.findByUnique("by_slug", .string("intro"))?.body, "rewritten")
        XCTAssertEqual(try UniqueNote.findByUnique("by_slug", .string("intro"))?.id, "u1")

        // Double-upsert with identical content stays idempotent.
        let again = try UniqueNote(slug: "intro", body: "rewritten")
            .save(in: docA, upsertOn: "slug")
        XCTAssertEqual(again.id, "u1")
        XCTAssertEqual(try UniqueNote.count(), 1)
        XCTAssertNil(try UniqueNote.find("u2"))

        // A slug with no record returns nil.
        XCTAssertNil(try UniqueNote.findByUnique("by_slug", .string("missing")))
    }

    // MARK: - find/findAll decode-miss semantics (#992)
    //
    // JS `Model.find` resolves null ONLY for "not found" and `Model.findAll`
    // returns every stored row (there is no typed-decode step in JS). The
    // Swift facade therefore keeps `nil` strictly for "not found" and throws
    // `PrimitiveDecodeError` when a stored row exists but no longer decodes
    // as the typed model — instead of returning `nil` (find) or silently
    // dropping the row (findAll).

    /// Write a row for `CrossDocNote`'s model that VIOLATES the typed schema
    /// (missing the required `done` field) by going through a separate
    /// permissive `DynamicModel` bound to the same underlying `YDocument`.
    /// The shared store's per-doc member observes the Y change and mirrors
    /// the drifted row into the cross-document SQLite table.
    private func insertDriftedRow(id: String, into docId: String, client: JsBaoClient) throws {
        let entry = try XCTUnwrap(
            client.documentManager.openDocumentsSnapshot().first { $0.documentId == docId }
        )
        let permissiveSchema = PrimitiveSchema(
            name: CrossDocNote.modelName,
            fields: [
                "id":    FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string),
                // no `done` — the typed schema requires it
            ]
        )
        let raw = DynamicModel(doc: entry.doc, schema: permissiveSchema)
        _ = try raw.create(id: id, values: ["title": .string("ghost")])
    }

    func testFindReturnsNilOnlyForNotFound() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])
        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        try CrossDocNote(id: "ok", title: "fine", done: false).save(in: docA)

        // Not found → nil (no throw).
        let missing = try CrossDocNote.find("definitely-not-there")
        XCTAssertNil(missing)

        // Found and well-shaped → the record.
        let ok = try CrossDocNote.find("ok")
        XCTAssertEqual(ok?.title, "fine")
    }

    func testFindThrowsDecodeErrorForDriftedRow() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])
        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        try insertDriftedRow(id: "drifted", into: docA, client: client)

        // The row IS stored — the raw shared store can see it.
        XCTAssertNotNil(JsBaoClient.requireDefault()
            .codegen.find(CrossDocNote.primitiveSchema, id: "drifted"),
            "precondition: the drifted row must exist in the shared store")

        // …but the typed find must throw a decode error, NOT return nil.
        do {
            let result = try CrossDocNote.find("drifted")
            XCTFail("expected PrimitiveDecodeError, got \(String(describing: result))")
        } catch let error as PrimitiveDecodeError {
            XCTAssertEqual(error.modelName, CrossDocNote.modelName)
            XCTAssertEqual(error.recordId, "drifted")
            XCTAssertEqual(error.documentId, docA)
        }
    }

    func testFindAllThrowsInsteadOfDroppingDriftedRow() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])
        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        // One healthy row, one drifted row.
        try CrossDocNote(id: "ok", title: "fine", done: true).save(in: docA)
        try insertDriftedRow(id: "drifted", into: docA, client: client)
        XCTAssertEqual(try CrossDocNote.count(), 2,
                       "precondition: both rows must be stored")

        // findAll must surface the drift loudly — never a silently short list.
        do {
            let result = try CrossDocNote.findAll()
            XCTFail("expected PrimitiveDecodeError, got \(result.count) rows")
        } catch let error as PrimitiveDecodeError {
            XCTAssertEqual(error.modelName, CrossDocNote.modelName)
            XCTAssertEqual(error.recordId, "drifted")
        }

        // With the drifted row gone, findAll succeeds again.
        try JsBaoClient.requireDefault()
            .codegen.delete(CrossDocNote.primitiveSchema, id: "drifted", in: docA)
        let healthy = try CrossDocNote.findAll()
        XCTAssertEqual(healthy.map(\.id), ["ok"])
    }

    // MARK: - upsertByUnique (named-constraint facade)

    func testUpsertByUniqueFacade() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([UniqueNote.self])

        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        // .either with no match → insert under the struct's id.
        let inserted = try UniqueNote(id: "n1", slug: "guide", body: "v1")
            .upsertByUnique("by_slug", in: docA)
        XCTAssertEqual(inserted.id, "n1")
        XCTAssertEqual(try UniqueNote.count(), 1)

        // #1122: a DIFFERENT *explicit* id colliding on the slug throws.
        XCTAssertThrowsError(
            try UniqueNote(id: "n2", slug: "guide", body: "v2")
                .upsertByUnique("by_slug", in: docA)
        ) { error in
            XCTAssertEqual(error as? UpsertError,
                           .explicitIdConflict(supplied: "n2", existing: "n1"))
        }

        // .either with a match + AUTO id → merge; returned record resolves
        // to the existing id and reflects the merged fields.
        let merged = try UniqueNote(slug: "guide", body: "v2")
            .upsertByUnique("by_slug", in: docA)
        XCTAssertEqual(merged.id, "n1", "merge must keep the existing record's id")
        XCTAssertEqual(merged.body, "v2")
        XCTAssertEqual(try UniqueNote.count(), 1, "upsertByUnique should merge, not duplicate")
        XCTAssertNil(try UniqueNote.find("n2"))

        // .mustExist on a missing key → UpsertByUniqueError.recordNotFound
        // (JS `objectMustExist` → RecordNotFoundError).
        XCTAssertThrowsError(
            try UniqueNote(id: "n3", slug: "absent", body: "x")
                .upsertByUnique("by_slug", mode: .mustExist, in: docA)
        ) { error in
            XCTAssertEqual(error as? UpsertByUniqueError,
                           .recordNotFound(constraint: "by_slug"))
        }

        // .mustExist on an existing key + AUTO id → updates in place.
        let updated = try UniqueNote(slug: "guide", body: "v3")
            .upsertByUnique("by_slug", mode: .mustExist, in: docA)
        XCTAssertEqual(updated.id, "n1")
        XCTAssertEqual(updated.body, "v3")

        // .mustNotExist on an existing key → unique-constraint violation
        // (JS `objectMustNotExist` → UniqueConstraintViolationError).
        XCTAssertThrowsError(
            try UniqueNote(id: "n5", slug: "guide", body: "x")
                .upsertByUnique("by_slug", mode: .mustNotExist, in: docA)
        ) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError,
                          "expected UniqueConstraintViolationError, got \(error)")
        }

        // .mustNotExist on a fresh key → plain insert.
        let fresh = try UniqueNote(id: "n6", slug: "other", body: "y")
            .upsertByUnique("by_slug", mode: .mustNotExist, in: docA)
        XCTAssertEqual(fresh.id, "n6")
        XCTAssertEqual(try UniqueNote.count(), 2)

        // An undeclared constraint name throws (JS: "Unique constraint
        // named '…' not found for upsert.").
        XCTAssertThrowsError(
            try UniqueNote(id: "n7", slug: "z", body: "z")
                .upsertByUnique("no_such_constraint", in: docA)
        )
    }

    // MARK: - upsertByUnique searches every open doc (#1122)

    /// The facade's `upsertByUnique` must find a match in ANY open doc,
    /// not just the target doc — mirroring js-bao's cross-doc search.
    /// A slug stored in docB must be found even when the upsert names docA
    /// as the target; JS then saves the resolved record through
    /// `targetDocument`, so the resolved id is written into docA.
    func testUpsertByUniqueFacadeSearchesAcrossDocs() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([UniqueNote.self])

        let (docA, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        let (docB, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        // Seed the slug in docB only.
        let seeded = try UniqueNote(id: "b1", slug: "shared", body: "v1")
            .upsertByUnique("by_slug", in: docB)
        XCTAssertEqual(seeded.id, "b1")
        XCTAssertEqual(try UniqueNote.count(), 1)

        // Upsert the same slug targeting docA — the cross-doc search must
        // find docB's record, then save the resolved id through docA
        // (JS `existingRecord.save({ targetDocument })` parity). This is
        // intentionally a target-write, not a move: JS does not delete the
        // original docB row.
        let merged = try UniqueNote(slug: "shared", body: "v2")
            .upsertByUnique("by_slug", in: docA)
        XCTAssertEqual(merged.id, "b1", "must resolve docB's existing record id")
        XCTAssertEqual(merged.body, "v2")
        let scopedToDocA = try JsBaoClient.requireDefault()
            .codegen.query(UniqueNote.primitiveSchema, options: QueryOptions(documents: [docA]))
            .compactMap { UniqueNote(row: $0) }
        XCTAssertTrue(scopedToDocA.contains { $0.id == "b1" && $0.body == "v2" },
                      "targetDocument parity writes the resolved id into docA")
        let scopedToDocB = try JsBaoClient.requireDefault()
            .codegen.query(UniqueNote.primitiveSchema, options: QueryOptions(documents: [docB]))
            .compactMap { UniqueNote(row: $0) }
        XCTAssertTrue(scopedToDocB.contains { $0.id == "b1" && $0.body == "v1" },
                      "JS parity keeps the original matching row in its source doc")
        XCTAssertEqual(
            try UniqueNote.count(), 2,
            "targetDocument parity can leave the same resolved id in two open docs"
        )

        // A genuinely fresh slug inserts into the target doc (docA).
        let fresh = try UniqueNote(id: "a1", slug: "fresh", body: "y")
            .upsertByUnique("by_slug", in: docA)
        XCTAssertEqual(fresh.id, "a1")
        XCTAssertEqual(try UniqueNote.count(), 3)
    }

    // MARK: - hasManyThrough shared traversal (generated-accessor backend)

    private static let throughTagSchema = PrimitiveSchema(
        name: "through_tags",
        fields: [
            "id":   FieldDescriptor(type: .id),
            "name": FieldDescriptor(type: .string),
        ]
    )

    private static let throughLinkSchema = PrimitiveSchema(
        name: "through_post_tag_links",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "postId":   FieldDescriptor(type: .string, indexed: true),
            "tagId":    FieldDescriptor(type: .string, indexed: true),
            // Required (non-null) so it passes the D7 nullable-order-field
            // guard, but non-unique so pages can straddle a tie. Default 0
            // lets links that don't exercise ordering omit it.
            "position": FieldDescriptor(type: .number, required: true, default: .scalar(.number(0))),
            // Nullable — drives the D7 rejection test below.
            "weight":   FieldDescriptor(type: .number),
        ]
    )

    /// `client.codegen.hasManyThrough` returns targets in **target `id ASC`** —
    /// the declared join order picks which join rows, but the batched
    /// `id: { $in: [...] }` query re-sorts the output, matching js-bao.
    /// (#1201: previously it returned targets in join-row order.)
    func testHasManyThroughSharedReturnsTargetIdAscending() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([Self.throughTagSchema, Self.throughLinkSchema])

        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        try client.codegen.save(Self.throughTagSchema, id: "t1", values: ["name": .string("red")], in: doc)
        try client.codegen.save(Self.throughTagSchema, id: "t2", values: ["name": .string("blue")], in: doc)
        // Join rows inserted so join-row order ([t2, t1]) differs from
        // target id ASC; position ASC selects t1-then-t2.
        try client.codegen.save(Self.throughLinkSchema, id: "l1",
            values: ["postId": .string("p1"), "tagId": .string("t2"), "position": .number(1)], in: doc)
        try client.codegen.save(Self.throughLinkSchema, id: "l2",
            values: ["postId": .string("p1"), "tagId": .string("t1"), "position": .number(2)], in: doc)

        // Default (no declared join order) → target id ASC.
        let defaultRows = try client.codegen.hasManyThrough(
            target: Self.throughTagSchema, joinModel: Self.throughLinkSchema,
            sourceId: "p1", joinModelLocalField: "postId", joinModelRelatedField: "tagId"
        )
        XCTAssertEqual(defaultRows.compactMap { $0["id"] as? String }, ["t1", "t2"],
                       "no declared join order → defaults to target id ASC")

        // DESC join order still yields target id ASC (the $in re-sort wins).
        let descRows = try client.codegen.hasManyThrough(
            target: Self.throughTagSchema, joinModel: Self.throughLinkSchema,
            sourceId: "p1", joinModelLocalField: "postId", joinModelRelatedField: "tagId",
            joinModelOrderByField: "position", joinModelOrderDirection: "DESC"
        )
        XCTAssertEqual(descRows.compactMap { $0["id"] as? String }, ["t1", "t2"],
                       "DESC join leg selects t2-then-t1 but output stays target id ASC")
    }

    /// Paginated `client.codegen.hasManyThrough` (#1230, rerouted #1607) pages the
    /// join leg by `position` through the shared composite-cursor engine
    /// and `$in`-resolves each page. Seeds six tags/links so `limit: 2`
    /// produces three pages; walks forward via `nextCursor`, then steps
    /// back. Cursors are now OPAQUE `String` tokens copied verbatim from
    /// the join leg's paged envelope, so the test feeds them back rather
    /// than asserting their bytes.
    func testHasManyThroughSharedPaginatesJoinLeg() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([Self.throughTagSchema, Self.throughLinkSchema])

        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        // Position i points at tag t{i}, so position ASC and target id ASC
        // agree — each page's rows read as a clean id-ordered slice.
        for i in 1...6 {
            try client.codegen.save(Self.throughTagSchema, id: "t\(i)", values: ["name": .string("n\(i)")], in: doc)
            try client.codegen.save(Self.throughLinkSchema, id: "l\(i)",
                values: ["postId": .string("p1"), "tagId": .string("t\(i)"), "position": .number(Double(i))], in: doc)
        }

        func page(after: String? = nil, before: String? = nil,
                  direction: CursorDirection = .forward) throws -> PagedQueryResult<PrimitiveRow> {
            try client.codegen.hasManyThrough(
                target: Self.throughTagSchema, joinModel: Self.throughLinkSchema,
                sourceId: "p1", joinModelLocalField: "postId", joinModelRelatedField: "tagId",
                joinModelOrderByField: "position",
                limit: 2, afterCursor: after, beforeCursor: before, direction: direction
            )
        }
        func ids(_ p: PagedQueryResult<PrimitiveRow>) -> [String] { p.data.compactMap { $0["id"] as? String } }

        // Page 1 — first page: prevCursor nil, nextCursor present.
        let p1 = try page()
        XCTAssertEqual(ids(p1), ["t1", "t2"])
        XCTAssertNotNil(p1.nextCursor)
        XCTAssertNil(p1.prevCursor)
        XCTAssertTrue(p1.hasMore)

        // Page 2 — no overlap, no gap with page 1. Feeding the opaque
        // cursor back proves it round-trips through the shared decoder.
        let p2 = try page(after: p1.nextCursor)
        XCTAssertEqual(ids(p2), ["t3", "t4"])
        XCTAssertNotNil(p2.nextCursor)
        XCTAssertNotNil(p2.prevCursor)
        XCTAssertTrue(p2.hasMore)

        // Page 3 — last page: nextCursor nil, hasMore false.
        let p3 = try page(after: p2.nextCursor)
        XCTAssertEqual(ids(p3), ["t5", "t6"])
        XCTAssertNil(p3.nextCursor)
        XCTAssertFalse(p3.hasMore)

        // Backward from page 3's prevCursor lands back on page 2's rows,
        // returned in declared order. `hasMore` tracks the backward
        // direction (earlier rows remain), the over-fetch signal.
        let back = try page(before: p3.prevCursor, direction: .backward)
        XCTAssertEqual(ids(back), ["t3", "t4"])
        XCTAssertTrue(back.hasMore,
                      "backward hasMore should track earlier rows remaining, not nextCursor")

        // limit larger than the set → whole set, no next page.
        let all = try client.codegen.hasManyThrough(
            target: Self.throughTagSchema, joinModel: Self.throughLinkSchema,
            sourceId: "p1", joinModelLocalField: "postId", joinModelRelatedField: "tagId",
            joinModelOrderByField: "position", limit: 50
        )
        XCTAssertEqual(ids(all), ["t1", "t2", "t3", "t4", "t5", "t6"])
        XCTAssertNil(all.nextCursor)
        XCTAssertFalse(all.hasMore)

        // Empty join set → empty page. Cursors copy the (empty) join
        // leg's envelope: no rows means no cursors either.
        let empty = try client.codegen.hasManyThrough(
            target: Self.throughTagSchema, joinModel: Self.throughLinkSchema,
            sourceId: "no-such-post", joinModelLocalField: "postId", joinModelRelatedField: "tagId",
            joinModelOrderByField: "position", limit: 2
        )
        XCTAssertTrue(empty.data.isEmpty)
        XCTAssertNil(empty.nextCursor)
        XCTAssertNil(empty.prevCursor)
        XCTAssertFalse(empty.hasMore)
    }

    /// Straddling-tie regression (#1607, Swift analog of JS scenario8 /
    /// scenario50) for the cross-document shared path. A join set whose
    /// `position` value repeats ACROSS a page boundary must page with no
    /// skips and no duplicates — the composite `(position, id)` cursor
    /// handles the tie the old raw-scalar cursor mis-cut.
    func testHasManyThroughSharedStraddlingTiePagesCleanly() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([Self.throughTagSchema, Self.throughLinkSchema])

        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        // positions 1,2,2,3,3,4 — ties straddle both limit-2 boundaries.
        let positions = [1, 2, 2, 3, 3, 4]
        for i in 1...6 {
            try client.codegen.save(Self.throughTagSchema, id: "t\(i)", values: ["name": .string("n\(i)")], in: doc)
            try client.codegen.save(Self.throughLinkSchema, id: "l\(i)",
                values: ["postId": .string("p1"), "tagId": .string("t\(i)"),
                         "position": .number(Double(positions[i - 1]))], in: doc)
        }

        var seen: [String] = []
        var cursor: String? = nil
        var guardCount = 0
        repeat {
            let p = try client.codegen.hasManyThrough(
                target: Self.throughTagSchema, joinModel: Self.throughLinkSchema,
                sourceId: "p1", joinModelLocalField: "postId", joinModelRelatedField: "tagId",
                joinModelOrderByField: "position",
                limit: 2, afterCursor: cursor
            )
            seen.append(contentsOf: p.data.compactMap { $0["id"] as? String })
            cursor = p.hasMore ? p.nextCursor : nil
            guardCount += 1
            XCTAssertLessThan(guardCount, 10, "pagination should terminate")
        } while cursor != nil

        XCTAssertEqual(seen.sorted(), ["t1", "t2", "t3", "t4", "t5", "t6"],
                       "every row visited exactly once despite ties on the boundary")
        XCTAssertEqual(seen.count, Set(seen).count, "no duplicate rows across pages")
    }

    /// D7 / Fork B (#1607, relaxed): ordering the shared paginated join leg
    /// by a NULLABLE field is now ACCEPTED (it warns rather than throwing).
    /// The composite `(field, id)` cursor's `id` tiebreaker keeps a
    /// not-`required` order field deterministic, so paging must succeed and
    /// return the linked tag. See `warnIfOrderFieldNullable`.
    func testHasManyThroughSharedNullableOrderFieldIsAccepted() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([Self.throughTagSchema, Self.throughLinkSchema])

        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))
        try client.codegen.save(Self.throughTagSchema, id: "t1", values: ["name": .string("n1")], in: doc)
        try client.codegen.save(Self.throughLinkSchema, id: "l1",
            values: ["postId": .string("p1"), "tagId": .string("t1"),
                     "position": .number(1), "weight": .number(1)], in: doc)

        let page = try client.codegen.hasManyThrough(
            target: Self.throughTagSchema, joinModel: Self.throughLinkSchema,
            sourceId: "p1", joinModelLocalField: "postId", joinModelRelatedField: "tagId",
            joinModelOrderByField: "weight", limit: 2
        )
        XCTAssertEqual(
            page.data.compactMap { $0["id"] as? String }, ["t1"],
            "paging the shared join leg by a nullable order field should succeed"
        )
    }
}

// Mirrors `SwiftEmitter.crossDocumentFacade(schema:)` output — keep in sync
// with the emitter if its template changes.
extension CrossDocumentStaticQueryTests.CrossDocNote {
    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> [CrossDocumentStaticQueryTests.CrossDocNote] {
        try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: filter, options: options)
            .compactMap { CrossDocumentStaticQueryTests.CrossDocNote(row: $0) }
    }

    static func count(_ filter: DocumentFilter? = nil) throws -> Int {
        try JsBaoClient.requireDefault().codegen.count(primitiveSchema, filter: filter)
    }

    static func findAll() throws -> [CrossDocumentStaticQueryTests.CrossDocNote] {
        try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: nil, options: nil)
            .map { row in
                guard let decoded = CrossDocumentStaticQueryTests.CrossDocNote(row: row) else {
                    throw PrimitiveDecodeError(modelName: modelName, row: row)
                }
                return decoded
            }
    }

    static func find(_ id: String) throws -> CrossDocumentStaticQueryTests.CrossDocNote? {
        guard let row = JsBaoClient.requireDefault().codegen.find(primitiveSchema, id: id) else {
            return nil
        }
        guard let decoded = CrossDocumentStaticQueryTests.CrossDocNote(row: row) else {
            throw PrimitiveDecodeError(modelName: modelName, row: row)
        }
        return decoded
    }

    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> CrossDocumentStaticQueryTests.CrossDocNote? {
        try JsBaoClient.requireDefault()
            .codegen.queryOne(primitiveSchema, filter: filter, options: options)
            .flatMap { CrossDocumentStaticQueryTests.CrossDocNote(row: $0) }
    }

    @discardableResult
    static func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        JsBaoClient.requireDefault().codegen.subscribe(primitiveSchema, callback)
    }

    @discardableResult
    func save(in documentId: String) throws -> CrossDocumentStaticQueryTests.CrossDocNote {
        try JsBaoClient.requireDefault().codegen.save(Self.primitiveSchema, id: id, values: primitiveValues(), in: documentId)
        return self
    }

    func delete(in documentId: String) throws {
        try JsBaoClient.requireDefault().codegen.delete(Self.primitiveSchema, id: id, in: documentId)
    }
}

// MARK: - UniqueNote: a model WITH a single-field unique constraint
//
// Exercises the unique-constraint facade methods (`findByUnique` /
// `save(in:upsertOn:)`) the emitter generates. Hand-written to mirror
// `SwiftEmitter.crossDocumentFacade(schema:)`'s `findByUnique` + the
// `save(in:upsertOn:)` upsert write, against a schema that declares a
// `by_slug` unique constraint on `slug`.
extension CrossDocumentStaticQueryTests {
    struct UniqueNote: PrimitiveModel, Equatable {
        static let modelName = "unique_notes"
        static let primitiveSchema = PrimitiveSchema(
            name: "unique_notes",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "slug": FieldDescriptor(type: .string, unique: true, required: true),
                "body": FieldDescriptor(type: .string, required: true),
            ],
            constraints: [
                "by_slug": ConstraintDescriptor(name: "by_slug", fields: ["slug"]),
            ]
        )

        var id: String
        var slug: String
        var body: String
        // Mirrors the emitter's #1122 explicit-id provenance flag.
        private(set) var _explicitId: Bool = true

        init(id: String, slug: String, body: String) {
            self.id = id; self.slug = slug; self.body = body
        }

        /// Auto-id convenience init (mirrors the emitter): marks the id
        /// non-explicit so a colliding upsert silently merges.
        init(slug: String, body: String) {
            self.id = PrimitiveSchemaRegistry.newId()
            self.slug = slug; self.body = body
            self._explicitId = false
        }

        init?(record: PrimitiveRecord) {
            guard let slug = record["slug"]?.asString,
                  let body = record["body"]?.asString
            else { return nil }
            self.id = record.id; self.slug = slug; self.body = body
        }

        init?(row: [String: Any]) {
            guard let id = row["id"] as? String,
                  let slug = row["slug"] as? String,
                  let body = row["body"] as? String
            else { return nil }
            self.id = id; self.slug = slug; self.body = body
        }

        func primitiveValues() -> [String: PrimitiveValue] {
            ["slug": .string(slug), "body": .string(body)]
        }
    }
}

extension CrossDocumentStaticQueryTests.UniqueNote {
    static func count(_ filter: DocumentFilter? = nil) throws -> Int {
        try JsBaoClient.requireDefault().codegen.count(primitiveSchema, filter: filter)
    }

    // Mirrors the emitter's sync-throws `find(_:)` (#1156); previously this
    // mirror diverged as a non-throwing accessor.
    static func find(_ id: String) throws -> CrossDocumentStaticQueryTests.UniqueNote? {
        JsBaoClient.requireDefault().codegen.find(primitiveSchema, id: id)
            .flatMap { CrossDocumentStaticQueryTests.UniqueNote(row: $0) }
    }

    static func findByUnique(_ constraint: String, _ value: PrimitiveValue) throws -> CrossDocumentStaticQueryTests.UniqueNote? {
        try JsBaoClient.requireDefault()
            .codegen.findByUnique(primitiveSchema, constraint: constraint, value: value)
            .flatMap { CrossDocumentStaticQueryTests.UniqueNote(row: $0) }
    }

    @discardableResult
    func save(in documentId: String, upsertOn: String) throws -> CrossDocumentStaticQueryTests.UniqueNote {
        let result = try JsBaoClient.requireDefault().codegen.upsert(Self.primitiveSchema, id: id, values: primitiveValues(), on: upsertOn, in: documentId, explicitId: _explicitId)
        if let resolved = CrossDocumentStaticQueryTests.UniqueNote(record: result.record) { return resolved }
        var copy = self
        copy.id = result.record.id
        return copy
    }

    @discardableResult
    func upsertByUnique(_ constraint: String, mode: UpsertMode = .either, in documentId: String) throws -> CrossDocumentStaticQueryTests.UniqueNote {
        let result = try JsBaoClient.requireDefault().codegen.upsertByUnique(Self.primitiveSchema, id: id, values: primitiveValues(), constraint: constraint, mode: mode, in: documentId, explicitId: _explicitId)
        if let resolved = CrossDocumentStaticQueryTests.UniqueNote(record: result.record) { return resolved }
        var copy = self
        copy.id = result.record.id
        return copy
    }
}

// MARK: - IncAuthor / IncPost: a model PAIR with a refersTo relationship
//
// Exercises the typed query-time include facade (#1216 `queryOne(_:options:include:)`).
// Hand-written to mirror `SwiftEmitter.crossDocumentFacade(schema:)`'s
// `query(...,include:)` / `queryOne(...,include:)` overloads, the per-relationship
// `relatedAuthor` accessor over `RelatedRecords`, and the `includeAuthor()` builder.
extension CrossDocumentStaticQueryTests {
    struct IncAuthor: PrimitiveModel, PrimitiveRowDecodable, Equatable {
        static let modelName = "inc_authors"
        static let primitiveSchema = PrimitiveSchema(
            name: "inc_authors",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string, required: true),
            ]
        )

        var id: String
        var name: String

        init(id: String, name: String) { self.id = id; self.name = name }

        init?(record: PrimitiveRecord) {
            guard let name = record["name"]?.asString else { return nil }
            self.id = record.id; self.name = name
        }

        init?(row: [String: Any]) {
            guard let id = row["id"] as? String, let name = row["name"] as? String
            else { return nil }
            self.id = id; self.name = name
        }

        func primitiveValues() -> [String: PrimitiveValue] { ["name": .string(name)] }
    }

    struct IncPost: PrimitiveModel, PrimitiveRowDecodable, Equatable {
        static let modelName = "inc_posts"
        static let primitiveSchema = PrimitiveSchema(
            name: "inc_posts",
            fields: [
                "id":       FieldDescriptor(type: .id),
                "authorId": FieldDescriptor(type: .string, indexed: true),
                "title":    FieldDescriptor(type: .string, required: true),
            ],
            relationships: [
                "author": RelationshipDescriptor(properties: [
                    "type": "refersTo", "model": "inc_authors", "relatedIdField": "authorId",
                ]),
            ]
        )

        var id: String
        var authorId: String
        var title: String
        // Mirrors the emitter's `var related: RelatedRecords = .empty`, populated
        // from `row["_related"]` in `init?(row:)`.
        var related: RelatedRecords = .empty

        init(id: String, authorId: String, title: String) {
            self.id = id; self.authorId = authorId; self.title = title
        }

        init?(record: PrimitiveRecord) {
            guard let authorId = record["authorId"]?.asString,
                  let title = record["title"]?.asString
            else { return nil }
            self.id = record.id; self.authorId = authorId; self.title = title
            self.related = .empty
        }

        init?(row: [String: Any]) {
            guard let id = row["id"] as? String,
                  let authorId = row["authorId"] as? String,
                  let title = row["title"] as? String
            else { return nil }
            self.id = id; self.authorId = authorId; self.title = title
            self.related = RelatedRecords(raw: row["_related"] as? [String: Any] ?? [:])
        }

        func primitiveValues() -> [String: PrimitiveValue] {
            ["authorId": .string(authorId), "title": .string(title)]
        }

        // `related` is a query-result attachment — exclude it from equality so
        // it never affects record identity (mirrors the emitter).
        static func == (lhs: IncPost, rhs: IncPost) -> Bool {
            lhs.id == rhs.id && lhs.authorId == rhs.authorId && lhs.title == rhs.title
        }
    }
}

extension CrossDocumentStaticQueryTests.IncAuthor {
    @discardableResult
    func save(in documentId: String) throws -> CrossDocumentStaticQueryTests.IncAuthor {
        try JsBaoClient.requireDefault().codegen.save(Self.primitiveSchema, id: id, values: primitiveValues(), in: documentId)
        return self
    }
}

extension CrossDocumentStaticQueryTests.IncPost {
    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil, include: [Include]) throws -> [CrossDocumentStaticQueryTests.IncPost] {
        try JsBaoClient.requireDefault()
            .codegen.query(primitiveSchema, filter: filter, options: options, include: include)
            .compactMap { CrossDocumentStaticQueryTests.IncPost(row: $0) }
    }

    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil, include: [Include]) throws -> CrossDocumentStaticQueryTests.IncPost? {
        try JsBaoClient.requireDefault()
            .codegen.queryOne(primitiveSchema, filter: filter, options: options, include: include)
            .flatMap { CrossDocumentStaticQueryTests.IncPost(row: $0) }
    }

    /// Typed query-time include payload for `author`, when present in `related`.
    var relatedAuthor: CrossDocumentStaticQueryTests.IncAuthor? {
        related.one("author", as: CrossDocumentStaticQueryTests.IncAuthor.self)
            ?? related.one(CrossDocumentStaticQueryTests.IncAuthor.modelName, as: CrossDocumentStaticQueryTests.IncAuthor.self)
    }

    /// Build a query-time include for `author`.
    static func includeAuthor(resultKey: String? = "author") -> Include {
        Include(
            type: .refersTo,
            target: JsBaoClient.requireDefault().codegen.includeTarget(for: CrossDocumentStaticQueryTests.IncAuthor.primitiveSchema),
            sourceField: "authorId",
            resultKey: resultKey
        )
    }

    @discardableResult
    func save(in documentId: String) throws -> CrossDocumentStaticQueryTests.IncPost {
        try JsBaoClient.requireDefault().codegen.save(Self.primitiveSchema, id: id, values: primitiveValues(), in: documentId)
        return self
    }
}
