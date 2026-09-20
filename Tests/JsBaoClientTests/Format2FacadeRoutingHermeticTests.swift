import XCTest
@testable import JsBaoClient
import YSwift

/// The doors onto a large document that the facade has to route, and the ones
/// that decide what a write means (#3436).
///
/// Every case here is a path an app reaches through the GENERATED model — a
/// `save(in:)`, a paginated query, an include, a unique lookup, a stringset
/// assignment — rather than through the per-document `DynamicModel` the rest
/// of this child's suites drive. That distinction is the point: a path that
/// was never routed reads or writes the format-1 nested maps a large document
/// does not have, and it does so silently.
final class Format2FacadeRoutingHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Fixture

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
            "slug": FieldDescriptor(type: .string, unique: true),
            "views": FieldDescriptor(type: .number),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-routing-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private struct Fixture {
        let host: any Format2SqlHost
        let coordinator: Format2Coordinator
        let shared: MultiDocModel
        /// The large document, its binding and its Y.Doc.
        let large: (documentId: String, binding: Format2DocumentBinding, doc: YDocument)
    }

    private func makeFixture(
        host: (any Format2SqlHost)? = nil
    ) async throws -> Fixture {
        let sqlHost: any Format2SqlHost
        if let host { sqlHost = host } else { sqlHost = try await makeProvider() }
        let coordinator = Format2Coordinator(
            host: sqlHost, clientId: "me", logger: Logger(level: .none)
        )
        let shared = MultiDocModel(schema: Self.schema)
        let large = try connectLarge(coordinator: coordinator, shared: shared)
        return Fixture(host: sqlHost, coordinator: coordinator, shared: shared, large: large)
    }

    @discardableResult
    private func connectLarge(
        coordinator: Format2Coordinator, shared: MultiDocModel, suffix: String = "a"
    ) throws -> (documentId: String, binding: Format2DocumentBinding, doc: YDocument) {
        let documentId = "big-\(suffix)-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let member = shared.connect(docId: documentId, doc: doc)
        member.bindFormat2(binding)
        return (documentId, binding, doc)
    }

    /// An ordinary document connected to the same shared model.
    @discardableResult
    private func connectOrdinary(_ shared: MultiDocModel) -> (String, YDocument) {
        let documentId = "ordinary-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        shared.connect(docId: documentId, doc: doc)
        return (documentId, doc)
    }

    private func overlayKeys(_ binding: Format2DocumentBinding) -> [String] {
        binding.overlay.entries(model: "Note").map(\.0).sorted()
    }

    /// The write a generated model makes: `Model.save(in:)` resolves the
    /// document's member and calls `DynamicModel.save`, which is the one that
    /// has to decide insert-vs-update from the merged view rather than from a
    /// nested record map (`JsBaoClient.save(_:id:values:in:)` →
    /// `requireMember(schema, in: docId).save(...)`).
    @discardableResult
    private func saved(
        _ fixture: Fixture, id: String,
        values: [String: PrimitiveValue], in documentId: String
    ) throws -> PrimitiveRecord {
        let member = try XCTUnwrap(
            fixture.shared.member(docId: documentId),
            "no member is connected for \(documentId)"
        )
        return try member.save(id: id, values: values)
    }

    // MARK: - The generated save

    /// `Model.save(in:)` is the write every generated model makes, and it took
    /// its own route to the nested-map path: the insert-vs-update decision was
    /// read from a record Y.Map a large document does not have, and the write
    /// went into that map. So a save reported success and left nothing behind
    /// — no merged row, no pending op, no overlay key, nothing for the server.
    func testTheGeneratedSaveCommitsThroughTheRecordStore() async throws {
        let fixture = try await makeFixture()
        let documentId = fixture.large.documentId

        _ = try self.saved(fixture, id: "n1", values: ["title": .string("through save"), "slug": .string("s1")], in: documentId)

        let row = try XCTUnwrap(
            fixture.large.binding.store.read(model: "Note", recordId: "n1"),
            "a save through the shared model left no merged row"
        )
        XCTAssertEqual(row["title"]?.stringValue, "through save")

        let pending = try fixture.large.binding.store.pendingOps()
        XCTAssertEqual(pending.count, 1, "a save owes the server exactly one pending op")
        XCTAssertEqual(pending.first?.recordId, "n1")

        XCTAssertTrue(
            overlayKeys(fixture.large.binding).contains { $0.hasPrefix("n1/") },
            "and it published the overlay keys that send it: "
            + "\(overlayKeys(fixture.large.binding))"
        )
    }

    /// The second half of the same claim: a save on an id the document already
    /// holds is an UPDATE, decided from the merged view, so it leaves the
    /// fields it did not name alone rather than replacing the record.
    func testASaveOnAnExistingIdUpdatesRatherThanReplaces() async throws {
        let fixture = try await makeFixture()
        let documentId = fixture.large.documentId

        _ = try self.saved(fixture, id: "n1", values: ["title": .string("first"), "views": .number(7)], in: documentId)
        _ = try self.saved(fixture, id: "n1", values: ["title": .string("second")], in: documentId)

        let row = try XCTUnwrap(
            fixture.large.binding.store.read(model: "Note", recordId: "n1")
        )
        XCTAssertEqual(row["title"]?.stringValue, "second")
        XCTAssertEqual(
            row["views"]?.numberValue, 7,
            "the save was taken for a create and replaced the record"
        )
    }

    // MARK: - Stringsets on a replacement

    /// A create REPLACES the record, and the fold drops every member the base
    /// row held before applying the mutation's entries. So a create that names
    /// its stringset as a DIFF against what is already there emits only the
    /// members that are new — and the ones it meant to keep are deleted by the
    /// replace and never written back.
    func testACreateOverAnExistingRecordKeepsTheMembersItNames() async throws {
        let fixture = try await makeFixture()
        let documentId = fixture.large.documentId
        let member = try XCTUnwrap(fixture.shared.member(docId: documentId))

        try member.create(id: "n1", values: [
            "title": .string("first"), "tags": .stringset(["a", "b"]),
        ])
        XCTAssertEqual(
            try fixture.large.binding.store
                .members(model: "Note", recordId: "n1", field: "tags").sorted(),
            ["a", "b"]
        )

        // Re-created with the same members plus one.
        try member.create(id: "n1", values: [
            "title": .string("again"), "tags": .stringset(["a", "b", "c"]),
        ])
        XCTAssertEqual(
            try fixture.large.binding.store
                .members(model: "Note", recordId: "n1", field: "tags").sorted(),
            ["a", "b", "c"],
            "the replacement kept only the members that were new to it"
        )

        // And re-created with exactly what it already had, which a diff makes
        // an empty delta of — the case that loses the whole set.
        try member.create(id: "n1", values: [
            "title": .string("third"), "tags": .stringset(["a", "b", "c"]),
        ])
        XCTAssertEqual(
            try fixture.large.binding.store
                .members(model: "Note", recordId: "n1", field: "tags").sorted(),
            ["a", "b", "c"],
            "an unchanged set emitted no entries, so the replace emptied it"
        )
    }

    /// The control, and the property the diff exists for: on a PATCH a member
    /// another device added concurrently is not dropped because this caller
    /// did not name it.
    func testAnUpdateStillDiffsTheSetAgainstTheMergedView() async throws {
        let fixture = try await makeFixture()
        let documentId = fixture.large.documentId
        let member = try XCTUnwrap(fixture.shared.member(docId: documentId))

        try member.create(id: "n1", values: [
            "title": .string("first"), "tags": .stringset(["a", "b"]),
        ])
        try member.update(id: "n1", values: ["tags": .stringset(["b", "c"])])
        XCTAssertEqual(
            try fixture.large.binding.store
                .members(model: "Note", recordId: "n1", field: "tags").sorted(),
            ["b", "c"],
            "an update names the whole set, so `a` is removed and `c` added"
        )
    }

    // MARK: - Unique lookups

    /// `findByUnique` and the upsert's existing-record search both read the
    /// `_uniqueIdx_*` Y.Maps, which a large document never writes: its
    /// uniqueness lives in the merged view, which is also what its write path
    /// checks against. So a lookup missed every record the format-2 path ever
    /// wrote, and an upsert on a value that IS taken tried to insert and was
    /// then refused by the write path's own check.
    func testFindByUniqueAnswersFromTheMergedView() async throws {
        let fixture = try await makeFixture()
        let member = try XCTUnwrap(fixture.shared.member(docId: fixture.large.documentId))

        try member.create(id: "n1", values: [
            "title": .string("first"), "slug": .string("the-slug"),
        ])

        let found = try member.findByUnique(constraint: "Note_slug_unique", value: .string("the-slug"))
        XCTAssertEqual(found?.id, "n1", "the unique lookup missed a record the document holds")
        XCTAssertNil(
            try member.findByUnique(constraint: "Note_slug_unique", value: .string("absent")),
            "and still answers nothing for a value nobody holds"
        )
    }

    func testAnUpsertOnATakenUniqueValueMergesInsteadOfInserting() async throws {
        let fixture = try await makeFixture()
        let member = try XCTUnwrap(fixture.shared.member(docId: fixture.large.documentId))

        try member.create(id: "n1", values: [
            "title": .string("first"), "slug": .string("the-slug"), "views": .number(1),
        ])

        let result = try member.upsertByUnique(
            constraint: "Note_slug_unique",
            data: ["slug": .string("the-slug"), "title": .string("merged")],
            id: "n1"
        )
        XCTAssertFalse(result.wasCreated, "the upsert did not find the record it should merge into")
        XCTAssertEqual(result.record.id, "n1")

        let row = try XCTUnwrap(
            fixture.large.binding.store.read(model: "Note", recordId: "n1")
        )
        XCTAssertEqual(row["title"]?.stringValue, "merged")
        XCTAssertEqual(row["views"]?.numberValue, 1, "a merge leaves what it did not name")
        XCTAssertEqual(
            try fixture.large.binding.store.recordIds(model: "Note"), ["n1"],
            "and there is one record, not two"
        )
    }

    /// The cross-document door onto the same question.
    func testTheSharedUpsertFindsALargeDocumentsRecord() async throws {
        let fixture = try await makeFixture()
        let documentId = fixture.large.documentId
        _ = try self.saved(fixture, id: "n1", values: ["title": .string("first"), "slug": .string("shared-slug")], in: documentId)

        let result = try fixture.shared.upsertByUnique(
            constraint: "Note_slug_unique",
            data: ["slug": .string("shared-slug"), "title": .string("merged")],
            id: "n1",
            targetDocId: documentId
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(
            try fixture.large.binding.store.recordIds(model: "Note"), ["n1"]
        )
    }

    // MARK: - Uniqueness and the commit, one operation

    /// The uniqueness check has to be inside the document's operation with the
    /// commit it decides for. Serializing only the commit lets two concurrent
    /// creates each find the same unique value free and then commit one after
    /// the other — and the derived query tables carry ordinary indexes, so
    /// nothing downstream rejects the second.
    func testConcurrentCreatesOfOneUniqueValueProduceOneRecord() async throws {
        let fixture = try await makeFixture()
        let member = try XCTUnwrap(fixture.shared.member(docId: fixture.large.documentId))

        final class Tally: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func note() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }
        let refused = Tally()

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try member.create(id: "n\(index)", values: [
                    "title": .string("racer \(index)"), "slug": .string("contested"),
                ])
            } catch {
                refused.note()
            }
        }

        XCTAssertEqual(
            refused.value, 1,
            "both creates of the same unique value were allowed to commit"
        )
        XCTAssertEqual(
            try fixture.large.binding.store.recordIds(model: "Note").count, 1,
            "the document holds two records with the same unique value"
        )
    }

    // MARK: - Query routing

    /// Every filtered read has to route, not just the plain `query`. A page
    /// answered from the in-memory mirror while a large document is connected
    /// is a page of the ordinary documents only, and its cursor walks them
    /// alone.
    func testPaginatedAndIncludeQueriesRouteToTheLargeDocumentsTables() async throws {
        let fixture = try await makeFixture()
        let documentId = fixture.large.documentId
        for index in 1...3 {
            _ = try self.saved(fixture, id: "n\(index)", values: ["title": .string("t\(index)"), "views": .number(Double(index))], in: documentId)
        }

        let page = try fixture.shared.queryPaged(nil, options: QueryOptions(limit: 2))
        XCTAssertEqual(
            page.data.count, 2,
            "the paginated read answered from an engine the rows are not in"
        )

        let withIncludes = try fixture.shared.query(nil, options: nil, include: [])
        XCTAssertEqual(
            withIncludes.count, 3,
            "the include variant's base query answered from the wrong engine"
        )

        let pagedWithIncludes = try fixture.shared.queryPaged(
            nil, options: QueryOptions(limit: 2), include: []
        )
        XCTAssertEqual(pagedWithIncludes.data.count, 2)
    }

    /// A read scoped to documents of ONE kind is answerable however many
    /// documents of the other kind happen to be open — which is exactly what
    /// the refusal's own message tells the caller to do.
    func testAScopedReadIsAnsweredRatherThanRefused() async throws {
        let fixture = try await makeFixture()
        let large = fixture.large.documentId
        let (ordinary, _) = connectOrdinary(fixture.shared)

        _ = try self.saved(fixture, id: "n1", values: ["title": .string("big")], in: large)
        _ = try self.saved(fixture, id: "n2", values: ["title": .string("small")], in: ordinary)

        // Unscoped: both kinds are in scope and one statement cannot span them.
        XCTAssertThrowsError(try fixture.shared.query()) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .format2QueryScope)
        }

        let fromLarge = try fixture.shared.query(
            nil, options: QueryOptions(documents: [large])
        )
        XCTAssertEqual(
            fromLarge.map { $0["id"]?.stringValue }, ["n1"],
            "a read scoped to the large document alone was refused or answered wrong"
        )

        let fromOrdinary = try fixture.shared.query(
            nil, options: QueryOptions(documents: [ordinary])
        )
        XCTAssertEqual(
            fromOrdinary.map { $0["id"]?.stringValue }, ["n2"],
            "a read scoped to the ordinary document alone was refused or answered wrong"
        )
    }

    /// And a scope that names ONE of several large documents answers from that
    /// one, not from every large document connected.
    func testAScopeNamingOneOfTwoLargeDocumentsAnswersFromThatOne() async throws {
        let fixture = try await makeFixture()
        let first = fixture.large.documentId
        let second = try connectLarge(
            coordinator: fixture.coordinator, shared: fixture.shared, suffix: "b"
        )

        _ = try self.saved(fixture, id: "n1", values: ["title": .string("in first")], in: first)
        _ = try self.saved(fixture, id: "n2", values: ["title": .string("in second")], in: second.documentId)

        XCTAssertEqual(
            try fixture.shared.query(nil, options: QueryOptions(documents: [first]))
                .map { $0["id"]?.stringValue },
            ["n1"],
            "the scope was replaced by every large document connected"
        )
        XCTAssertEqual(
            try fixture.shared.count(nil, options: QueryOptions(documents: [second.documentId])),
            1
        )
        XCTAssertEqual(
            try fixture.shared.query().count, 2,
            "and an unscoped read over two large documents still spans both"
        )
    }

    // MARK: - A model registered after the bind

    /// The bind folds the overlay of the models registered BY THEN. A model
    /// registered later has folded nothing, so without a catch-up of its own
    /// its records are missing from the merged view — and the projection that
    /// runs beside the registration then copies an empty model into the query
    /// tables and marks it done, which makes the emptiness durable.
    func testAModelRegisteredAfterTheBindFoldsWhatTheOverlayAlreadyHolds() async throws {
        let host = try await makeProvider()
        let coordinator = Format2Coordinator(
            host: host, clientId: "me", logger: Logger(level: .none)
        )
        let documentId = "late-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()

        // The document binds and syncs with NO model registered — the app has
        // not reached its schema yet.
        let binding = try coordinator.bind(
            documentId: documentId, models: [], document: doc
        )
        XCTAssertTrue(binding.observer.registeredModels().isEmpty, "precondition")

        // A peer's records arrive into the overlay.
        let peer = OverlayDocument(document: doc)
        _ = peer.applyRawEntries(
            [
                (OverlayKeys.fieldKey(recordId: "n1", field: "title"), .string("from the room")),
                (OverlayKeys.fieldKey(recordId: "n2", field: "title"), .string("also")),
            ],
            model: "Note"
        )

        // Now the model is registered.
        let shared = MultiDocModel(schema: Self.schema)
        let member = shared.connect(docId: documentId, doc: doc)
        member.bindFormat2(binding)

        XCTAssertEqual(
            try binding.store.recordIds(model: "Note"), ["n1", "n2"],
            "the model registered after the bind never folded the overlay it arrived to"
        )
        XCTAssertEqual(
            try shared.query().count, 2,
            "and its rows never reached the query tables"
        )
    }
}
