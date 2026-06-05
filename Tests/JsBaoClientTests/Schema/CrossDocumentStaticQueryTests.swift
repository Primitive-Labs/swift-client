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

        let (docA, _) = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))
        let (docB, _) = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))

        // Writes go through the ONE model, naming the target doc.
        try CrossDocNote(id: "a1", title: "alpha", done: false).save(in: docA)
        try CrossDocNote(id: "a2", title: "beta",  done: true).save(in: docA)
        try CrossDocNote(id: "b1", title: "gamma", done: false).save(in: docB)

        // Reads span every open doc by default.
        XCTAssertEqual(CrossDocNote.count(), 3)
        XCTAssertEqual(Set(CrossDocNote.findAll().map(\.id)), ["a1", "a2", "b1"])
        XCTAssertEqual(CrossDocNote.find("b1")?.title, "gamma")

        // Filters apply across the union.
        XCTAssertEqual(Set(CrossDocNote.query(["done": false]).map(\.id)), ["a1", "b1"])

        // Single-doc opt-in via options.documents (matches js-bao).
        let onlyA = CrossDocNote.query(nil, options: QueryOptions(documents: [docA]))
        XCTAssertEqual(Set(onlyA.map(\.id)), ["a1", "a2"])

        // Closing a document drops its rows from later cross-doc reads.
        await client.closeDocument(docB)
        XCTAssertEqual(CrossDocNote.count(), 2)
        XCTAssertEqual(Set(CrossDocNote.findAll().map(\.id)), ["a1", "a2"])
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

        let (docA, _) = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))

        // First save inserts.
        try CrossDocNote(id: "n1", title: "draft", done: false).save(in: docA)
        XCTAssertEqual(CrossDocNote.count(), 1)
        XCTAssertEqual(CrossDocNote.find("n1")?.title, "draft")
        XCTAssertEqual(CrossDocNote.find("n1")?.done, false)

        // Second save with the same id updates in place — no duplicate row.
        try CrossDocNote(id: "n1", title: "final", done: true).save(in: docA)
        XCTAssertEqual(CrossDocNote.count(), 1)
        XCTAssertEqual(CrossDocNote.find("n1")?.title, "final")
        XCTAssertEqual(CrossDocNote.find("n1")?.done, true)
    }

    // MARK: - A document opened AFTER registration is auto-connected

    func testDocumentOpenedAfterRegistrationIsConnected() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])
        XCTAssertEqual(CrossDocNote.count(), 0)

        let (docA, _) = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))
        try CrossDocNote(id: "a1", title: "alpha", done: false).save(in: docA)

        XCTAssertEqual(CrossDocNote.count(), 1)
        XCTAssertEqual(CrossDocNote.findAll().first?.title, "alpha")
    }

    // MARK: - Lazy registration: write/read before registerModels still works

    func testLazyRegistrationConnectsAlreadyOpenDocuments() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)

        // Open a doc BEFORE the model is ever registered/queried.
        let (docA, _) = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))

        XCTAssertEqual(CrossDocNote.count(), 0)   // lazily registers here
        // The first write also lazily connects the already-open doc.
        try CrossDocNote(id: "a1", title: "alpha", done: false).save(in: docA)
        XCTAssertEqual(CrossDocNote.count(), 1)
    }

    // MARK: - subscribe fires across documents

    func testSubscribeFiresOnWritesInAnyDocument() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([CrossDocNote.self])

        let (docA, _) = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))
        let (docB, _) = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))

        let counter = FireCounter()
        let unsubscribe = CrossDocNote.subscribe { counter.bump() }
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

        let (docA, _) = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))
        try CrossDocNote(id: "a1", title: "alpha", done: false).save(in: docA)
        try CrossDocNote(id: "a2", title: "beta", done: true).save(in: docA)

        // A filter that matches exactly one row returns it.
        XCTAssertEqual(CrossDocNote.queryOne(["title": "beta"])?.id, "a2")
        // A filter that matches nothing returns nil.
        XCTAssertNil(CrossDocNote.queryOne(["title": "nope"]))
        // queryOne(nil) returns *some* record when any exist.
        XCTAssertNotNil(CrossDocNote.queryOne())
    }

    // MARK: - findByUnique + save(in:upsertOn:) (unique-constraint facade)

    func testFindByUniqueAndUpsertOnAcrossDocs() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        client.registerModels([UniqueNote.self])

        let (docA, _) = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))

        // Insert via upsertOn — no existing slug, so a new record lands.
        try UniqueNote(id: "u1", slug: "intro", body: "first").save(in: docA, upsertOn: "slug")
        XCTAssertEqual(UniqueNote.count(), 1)

        // findByUnique resolves the record by its unique slug.
        let found = try UniqueNote.findByUnique("by_slug", .string("intro"))
        XCTAssertEqual(found?.id, "u1")
        XCTAssertEqual(found?.body, "first")

        // upsertOn again with the same slug MERGES into the existing record
        // (keeps id u1), not a second row.
        try UniqueNote(id: "u2", slug: "intro", body: "rewritten").save(in: docA, upsertOn: "slug")
        XCTAssertEqual(UniqueNote.count(), 1, "upsertOn should merge, not duplicate")
        XCTAssertEqual(try UniqueNote.findByUnique("by_slug", .string("intro"))?.body, "rewritten")
        XCTAssertEqual(try UniqueNote.findByUnique("by_slug", .string("intro"))?.id, "u1")

        // A slug with no record returns nil.
        XCTAssertNil(try UniqueNote.findByUnique("by_slug", .string("missing")))
    }
}

// Mirrors `SwiftEmitter.crossDocumentFacade(schema:)` output — keep in sync
// with the emitter if its template changes.
extension CrossDocumentStaticQueryTests.CrossDocNote {
    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) -> [CrossDocumentStaticQueryTests.CrossDocNote] {
        JsBaoClient.requireDefault()
            .queryShared(primitiveSchema, filter: filter, options: options)
            .compactMap { CrossDocumentStaticQueryTests.CrossDocNote(row: $0) }
    }

    static func count(_ filter: DocumentFilter? = nil) -> Int {
        JsBaoClient.requireDefault().countShared(primitiveSchema, filter: filter)
    }

    static func findAll() -> [CrossDocumentStaticQueryTests.CrossDocNote] {
        query(nil, options: nil)
    }

    static func find(_ id: String) -> CrossDocumentStaticQueryTests.CrossDocNote? {
        JsBaoClient.requireDefault().findShared(primitiveSchema, id: id)
            .flatMap { CrossDocumentStaticQueryTests.CrossDocNote(row: $0) }
    }

    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) -> CrossDocumentStaticQueryTests.CrossDocNote? {
        JsBaoClient.requireDefault()
            .queryOneShared(primitiveSchema, filter: filter, options: options)
            .flatMap { CrossDocumentStaticQueryTests.CrossDocNote(row: $0) }
    }

    @discardableResult
    static func subscribe(_ callback: @escaping () -> Void) -> () -> Void {
        JsBaoClient.requireDefault().subscribeShared(primitiveSchema, callback)
    }

    @discardableResult
    func save(in documentId: String) throws -> CrossDocumentStaticQueryTests.CrossDocNote {
        try JsBaoClient.requireDefault().saveShared(Self.primitiveSchema, id: id, values: primitiveValues(), in: documentId)
        return self
    }

    func delete(in documentId: String) throws {
        try JsBaoClient.requireDefault().deleteShared(Self.primitiveSchema, id: id, in: documentId)
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

        init(id: String, slug: String, body: String) {
            self.id = id; self.slug = slug; self.body = body
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
    static func count(_ filter: DocumentFilter? = nil) -> Int {
        JsBaoClient.requireDefault().countShared(primitiveSchema, filter: filter)
    }

    static func findByUnique(_ constraint: String, _ value: PrimitiveValue) throws -> CrossDocumentStaticQueryTests.UniqueNote? {
        try JsBaoClient.requireDefault()
            .findByUniqueShared(primitiveSchema, constraint: constraint, value: value)
            .flatMap { CrossDocumentStaticQueryTests.UniqueNote(row: $0) }
    }

    @discardableResult
    func save(in documentId: String, upsertOn: String) throws -> CrossDocumentStaticQueryTests.UniqueNote {
        try JsBaoClient.requireDefault().upsertShared(Self.primitiveSchema, id: id, values: primitiveValues(), on: upsertOn, in: documentId)
        return self
    }
}

/// Thread-safe fire counter with only synchronous locked methods, safe to
/// read from an async polling closure (Swift 6 forbids lock()/unlock() there).
private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
