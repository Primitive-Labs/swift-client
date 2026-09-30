import XCTest
@testable import JsBaoClient
import YSwift

/// A model connected for a large document reads and writes the document's
/// record store, not nested Y.Maps (#3436, behaviors 8, 34 and 36).
///
/// This is the seam an app actually touches: `Note.create(...)`,
/// `Note.find(id)`, `record["title"]`. A large document's Y.Doc holds only the
/// current epoch's overlay, so every one of those would otherwise read an
/// empty nested map and answer nothing — a `find` that succeeds and then
/// reports no fields is worse than one that fails.
///
/// Server-free and client-free: a `MultiDocModel` member is pointed at a
/// coordinator's binding over the same Y.Doc, which is exactly what
/// `connectToSharedModels` does.
final class Format2ModelFacadeHermeticTests: XCTestCase {

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

    private struct Fixture {
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let shared: MultiDocModel
        let model: DynamicModel
        let doc: YDocument
        let documentId: String
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-facade-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeFixture(host: (any Format2SqlHost)? = nil) async throws -> Fixture {
        let sqlHost: any Format2SqlHost
        if let host { sqlHost = host } else { sqlHost = try await makeProvider() }
        let documentId = "facade-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        let coordinator = Format2Coordinator(
            host: sqlHost, clientId: "me", logger: Logger(level: .none)
        )
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: documentId, doc: doc)
        model.bindFormat2(binding)
        return Fixture(
            coordinator: coordinator, binding: binding, shared: shared,
            model: model, doc: doc, documentId: documentId
        )
    }

    /// The flat overlay keys the document's Y.Doc holds for `Note`.
    private func overlayKeys(_ fixture: Fixture) -> [String] {
        fixture.binding.overlay.entries(model: "Note").map(\.0).sorted()
    }

    // MARK: - Behavior 8 — the write path

    func testCreateCommitsTheRowAndThePendingOpAndThenPublishesTheOverlay() async throws {
        let fixture = try await makeFixture()

        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("first"), "views": .number(3),
        ])

        let row = try XCTUnwrap(try fixture.binding.store.read(model: "Note", recordId: "n1"))
        XCTAssertEqual(row["title"], .string("first"))
        XCTAssertEqual(row["views"], .number(3))
        XCTAssertEqual(row["id"], .string("n1"), "the row carries its own id")

        let ops = try fixture.binding.store.pendingOps()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.seq, 1)
        XCTAssertEqual(ops.first?.op, .create)
        XCTAssertNotNil(
            ops.first?.mutation,
            "a pending op carries the mutation it wrote, so the write can be reproduced "
            + "from the durable log alone"
        )
        XCTAssertEqual(
            ops.first?.priorOverlay, [:],
            "nothing was in the overlay for this record before the write"
        )

        XCTAssertTrue(
            overlayKeys(fixture).contains("n1/title"),
            "the write publishes flat overlay keys, which is what sends it; keys: "
            + "\(overlayKeys(fixture))"
        )
        XCTAssertFalse(
            overlayKeys(fixture).contains("n1"),
            "a large document has no nested record map — that layout is format 1's, and "
            + "the overlay is keyed by `{id}/{field}`; keys: \(overlayKeys(fixture))"
        )
    }

    func testUpdateAndDeleteAppendTheirOwnSequences() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("first")])
        try fixture.model.update(id: "n1", values: ["title": .string("second")])
        fixture.model.delete(id: "n1")

        XCTAssertEqual(
            try fixture.binding.store.pendingOps().map(\.seq), [1, 2, 3],
            "each local write claims the next sequence in this client's space"
        )
        XCTAssertNil(
            try fixture.binding.store.read(model: "Note", recordId: "n1"),
            "the delete reached the merged view"
        )
    }

    func testASqliteFailureAtTheCommitPublishesNothingAndThrows() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)

        failing.failStatementsContaining = "INSERT INTO records_f2_"
        XCTAssertThrowsError(
            try fixture.model.create(id: "n1", values: ["title": .string("first")]),
            "a write whose commit fails has to be reported, not swallowed"
        )
        failing.failStatementsContaining = nil

        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "n1"))
        XCTAssertEqual(try fixture.binding.store.pendingOps().count, 0)
        XCTAssertEqual(
            overlayKeys(fixture), [],
            "nothing may be published for a write that did not commit — a Yjs mutation "
            + "cannot be rolled back, so it would be on its way to every peer with no "
            + "durable record that it happened"
        )
    }

    func testAUniqueConstraintIsEnforcedAgainstTheMergedView() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("first"), "slug": .string("shared"),
        ])

        XCTAssertThrowsError(
            try fixture.model.create(id: "n2", values: [
                "title": .string("second"), "slug": .string("shared"),
            ])
        ) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError, "got \(error)")
        }
        XCTAssertEqual(
            try fixture.binding.store.pendingOps().count, 1,
            "the refused write left no pending op behind"
        )
    }

    // MARK: - Behavior 34 — the record handles

    func testARecordHandleAnswersFromTheMergedRowAndTheMemberIndex() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("first"),
            "views": .number(7),
            "tags": .stringset(["b", "a"]),
        ])

        let record = try XCTUnwrap(fixture.model.find(id: "n1"))
        XCTAssertEqual(record["title"], .string("first"))
        XCTAssertEqual(record["views"], .number(7))
        XCTAssertEqual(
            record["tags"]?.asStringSet, ["a", "b"],
            "a stringset reads as its members, which is what keeps a large set readable "
            + "without rewriting the row for every add"
        )
        XCTAssertEqual(record.rawValue(for: "title"), "\"first\"")
        XCTAssertTrue(record.fieldNames().isSuperset(of: ["title", "views", "tags"]))

        let snapshot = record.snapshot()
        XCTAssertEqual(snapshot["title"], .string("first"))
        XCTAssertEqual(snapshot["tags"]?.asStringSet, ["a", "b"])
    }

    func testFindAndFindAllAnswerFromTheStore() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("a")])
        _ = try fixture.model.create(id: "n2", values: ["title": .string("b")])

        XCTAssertNotNil(fixture.model.find(id: "n1"))
        XCTAssertNil(fixture.model.find(id: "nope"))
        XCTAssertEqual(fixture.model.findAll().map(\.id).sorted(), ["n1", "n2"])
    }

    func testAssigningNilCommitsAnExplicitUnsetThroughTheWritePath() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("first"), "views": .number(7),
        ])
        let record = try XCTUnwrap(fixture.model.find(id: "n1"))

        record["views"] = nil

        XCTAssertNil(record["views"], "the field is gone from the merged row")
        let row = try XCTUnwrap(try fixture.binding.store.read(model: "Note", recordId: "n1"))
        XCTAssertNil(
            row["views"],
            "an unset REMOVES the key rather than storing a null; row: \(row)"
        )
        XCTAssertEqual(row["title"], .string("first"), "and touches nothing else")
        XCTAssertEqual(
            try fixture.binding.store.pendingOps().map(\.seq), [1, 2],
            "the clear is a write the server has to be told about, not a local edit"
        )
        XCTAssertTrue(
            overlayKeys(fixture).contains("n1/views"),
            "the overlay carries the explicit null; keys: \(overlayKeys(fixture))"
        )
    }

    // MARK: - Behavior 36 — the sticky fold-broken refusal

    func testAFoldThatFailedRefusesEveryReadAndWriteOnTheFacade() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)
        _ = try fixture.model.create(id: "n1", values: ["title": .string("first")])
        let record = try XCTUnwrap(fixture.model.find(id: "n1"))

        // A peer's update the fold cannot apply: from here the merged view is
        // known wrong, and nothing may read or write against it.
        let peer = OverlayDocument()
        try peer.applyUpdate(fixture.binding.overlay.encodeStateAsUpdate())
        peer.apply(
            OverlayMutation(id: "n2", kind: .create, fields: ["title": .string("peer")]),
            model: "Note"
        )
        // Armed BEFORE the update lands: a bound document folds an arriving
        // update on its own fold queue, so this is the shape a real failing
        // fold has — nobody was waiting for it, and the binding is left
        // holding the state.
        failing.failStatementsContaining = "INSERT INTO records_f2_"
        try fixture.binding.overlay.applyUpdate(peer.encodeStateAsUpdate())
        fixture.binding.settleFolds()
        failing.failStatementsContaining = nil
        XCTAssertTrue(fixture.binding.observer.isFoldBroken, "precondition")

        XCTAssertNil(
            fixture.model.find(id: "n1"),
            "a find against a merged view known to be wrong must not hand back a handle"
        )
        XCTAssertNil(
            record["title"],
            "and a handle taken before the break answers nothing either"
        )
        XCTAssertThrowsError(
            try fixture.model.create(id: "n3", values: ["title": .string("after")])
        ) { error in
            XCTAssertEqual(
                (error as? JsBaoError)?.code, .format2FoldBroken,
                "got \(error)"
            )
        }
        XCTAssertEqual(
            try fixture.binding.store.pendingOps().count, 1,
            "the refused write left no pending op — the create before the break is the only one"
        )
    }

    /// The state is sticky, and a rebind's whole-overlay catch-up is what
    /// clears it.
    func testARebindsCatchUpRepairsTheDocument() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)

        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "n2", kind: .create, fields: ["title": .string("peer")]),
            model: "Note"
        )
        failing.failStatementsContaining = "INSERT INTO records_f2_"
        try fixture.binding.overlay.applyUpdate(peer.encodeStateAsUpdate())
        fixture.binding.settleFolds()
        failing.failStatementsContaining = nil
        XCTAssertTrue(fixture.binding.observer.isFoldBroken, "precondition")

        try fixture.binding.observer.catchUp()

        XCTAssertFalse(fixture.binding.observer.isFoldBroken)
        let record = try XCTUnwrap(fixture.model.find(id: "n2"))
        XCTAssertEqual(record["title"], .string("peer"))
    }

    // MARK: - The cross-document facade

    /// `Model.query()`, `Model.count()` and `Model.aggregate()` answer from
    /// the large document's rows, which the connect projected into the
    /// file-backed query tables (behavior 13). Answering from the in-memory
    /// engine alone would silently leave out every record of the document.
    ///
    /// The projection itself — its transaction, its mark, its failure
    /// behavior and the routing rules — is
    /// `Format2QueryProjectionHermeticTests`; what this asserts is that the
    /// facade an app touches gets the answer.
    func testAFilteredReadAnswersFromTheLargeDocumentsProjectedRows() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("first")])
        _ = try fixture.model.create(id: "n2", values: ["title": .string("second")])

        XCTAssertEqual(try fixture.shared.count(nil), 2)
        XCTAssertEqual(
            try fixture.shared.query(["title": .string("second")], options: nil)
                .compactMap { $0["id"]?.stringValue },
            ["n2"]
        )
        XCTAssertEqual(
            try fixture.shared.aggregate(
                AggregateOptions(operations: [AggregateOperation(type: .count)])
            ).first?["count"]?.numberValue,
            2
        )
        // The per-document facade answers the same question, scoped to its
        // own document.
        XCTAssertEqual(try fixture.model.count(nil), 2)
    }

    /// The unfiltered reads have no filter to push down, so they answer
    /// completely rather than refusing: `findAll` reads the large document's
    /// own store, and `find` looks there when the engine has no such row.
    func testTheUnfilteredCrossDocumentReadsSeeTheLargeDocument() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("first"), "tags": .stringset(["a"]),
        ])
        _ = try fixture.model.create(id: "n2", values: ["title": .string("second")])

        let rows = fixture.shared.findAll()
        XCTAssertEqual(
            rows.compactMap { $0["id"]?.stringValue }.sorted(), ["n1", "n2"],
            "a cross-document findAll that omitted the large document would be a silent "
            + "wrong answer; rows: \(rows)"
        )
        XCTAssertEqual(
            rows.first { $0["id"]?.stringValue == "n1" }?["_meta_doc_id"]?.stringValue,
            fixture.documentId,
            "and each row says which document it came from"
        )
        XCTAssertEqual(
            rows.first { $0["id"]?.stringValue == "n1" }?["tags"],
            .array([.string("a")]),
            "a stringset reads in the same shape the engine's rows use"
        )

        let located = try XCTUnwrap(fixture.shared.find(id: "n2"))
        XCTAssertEqual(located.docId, fixture.documentId)
        XCTAssertEqual(located.row["title"]?.stringValue, "second")
    }
}
