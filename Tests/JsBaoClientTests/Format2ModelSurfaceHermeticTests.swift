import XCTest
@testable import JsBaoClient
import YSwift

/// The rest of the model surface, on a large document (#3436).
///
/// `Format2ModelFacadeHermeticTests` covers the reads, the writes and the
/// record handles. These are the public entry points BESIDE those — a model
/// transaction, an upsert on a unique field, a single stringset member, a
/// subscriber, and the model declaration a write publishes — each of which
/// reached a nested Y.Map a large document does not have, and so did something
/// other than what it does on an ordinary document: threw, crashed, went
/// silent, or quietly published nothing.
///
/// Server-free, in the same shape `connectToSharedModels` wires: a
/// `MultiDocModel` member pointed at a coordinator's binding over one Y.Doc.
final class Format2ModelSurfaceHermeticTests: XCTestCase {

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
            "tags": FieldDescriptor(type: .stringset, maxCount: 3),
        ]
    )

    private struct Fixture {
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let model: DynamicModel
        let doc: YDocument
        let documentId: String
    }

    private func makeFixture() async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "/f2-surface-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let documentId = "surface-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let model = MultiDocModel(schema: Self.schema).connect(docId: documentId, doc: doc)
        model.bindFormat2(binding)
        return Fixture(
            coordinator: coordinator, binding: binding,
            model: model, doc: doc, documentId: documentId
        )
    }

    /// Deliver a peer's overlay writes to the document under test, and wait for
    /// the fold they schedule.
    private func deliver(_ peer: OverlayDocument, to fixture: Fixture) throws {
        try fixture.binding.overlay.applyUpdate(peer.encodeStateAsUpdate())
        fixture.binding.settleFolds()
    }

    // MARK: - A model transaction (finding 3436-REV-05)

    /// `model.transact { … }` opens a yrs transaction on the model's document.
    /// The format-2 write path reads the overlay and publishes into it through
    /// `transactSync`, which `dispatchPrecondition`s against being called on
    /// its own transaction queue — so a transaction around a large document's
    /// write did not throw or misbehave, it killed the process.
    func testAModelTransactionAroundLargeDocumentWritesCompletes() async throws {
        let fixture = try await makeFixture()

        try fixture.model.transact {
            _ = try fixture.model.create(id: "n1", values: ["title": .string("one")])
            _ = try fixture.model.create(id: "n2", values: ["title": .string("two")])
            try fixture.model.update(id: "n1", values: ["title": .string("one!")])
            fixture.model.delete(id: "n2")
        }

        XCTAssertEqual(
            fixture.model.find(id: "n1")?["title"], .string("one!"),
            "every write in the batch has to have landed"
        )
        XCTAssertNil(fixture.model.find(id: "n2"), "including the delete")
        XCTAssertEqual(
            try fixture.binding.store.pendingOps().count, 4,
            "and each is its own serialized operation with its own pending op — a large "
            + "document has no batch commit to fold them into"
        )
    }

    // MARK: - The declaration a write publishes (finding 3436-REV-04)

    /// `_meta_<model>` is how the server learns a model exists: the projector
    /// records it from the update's diff into `_format2_schema`, which is the
    /// only durable declaration a later epoch — and a snapshot build — reads.
    /// A model first authored by this client and never declared has no
    /// stringset fields on the server, so a base cut from it cannot restore
    /// them on a cold load.
    func testAWriteDeclaresItsModelInTheOverlay() async throws {
        let fixture = try await makeFixture()

        XCTAssertTrue(
            metaKeys(fixture, model: "Note").isEmpty,
            "precondition: nothing has declared the model yet"
        )

        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("one"),
            "tags": .stringset(["a"]),
        ])

        let declared = metaKeys(fixture, model: "Note")
        XCTAssertTrue(
            declared.contains("tags"),
            "the stringset field has to be declared — it is what a cold load needs to "
            + "read the members back out of a chunk; declared: \(declared)"
        )
        XCTAssertTrue(declared.contains("title"), "declared: \(declared)")
        XCTAssertTrue(declared.contains("slug"), "declared: \(declared)")
    }

    /// The declaration is published AFTER the durable commit, so a write that
    /// could not commit publishes nothing at all — not the record, and not the
    /// model either.
    func testAWriteThatCannotCommitDeclaresNothing() async throws {
        let fixture = try await makeFixture()

        XCTAssertThrowsError(
            try fixture.model.create(id: "", values: ["title": .string("one")]),
            "precondition: this write is refused"
        )
        XCTAssertTrue(
            metaKeys(fixture, model: "Note").isEmpty,
            "a refused write leaves the overlay exactly as it found it"
        )
    }

    private func metaKeys(_ fixture: Fixture, model: String) -> [String] {
        fixture.doc.transactSync { transaction in
            guard let meta = transaction.transactionGetMap(name: "_meta_\(model)")
            else { return [] }
            let collector = DynamicModel.KeyCollector()
            meta.keys(tx: transaction, delegate: collector)
            return collector.keys.sorted()
        }
    }

    // MARK: - Upsert on a unique field (finding 3436-REV-07)

    /// A large document keeps no `_uniqueIdx_*` map — uniqueness is answered
    /// from the merged view, because an index map cannot hold a document of
    /// this size. Reading one here found it empty for every value, took the
    /// insert path, and was then refused by that same merged-view check: an
    /// upsert of an existing value threw a uniqueness violation instead of
    /// updating the record it names.
    func testUpsertOnAnExistingUniqueValueUpdatesThatRecord() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("first"), "slug": .string("hello"),
        ])

        let result = try fixture.model.upsert(
            ["title": .string("second"), "slug": .string("hello")], on: "slug"
        )

        XCTAssertFalse(result.wasCreated, "the existing record's id wins")
        XCTAssertEqual(result.record.id, "n1")
        XCTAssertEqual(fixture.model.find(id: "n1")?["title"], .string("second"))
        XCTAssertEqual(
            try fixture.binding.store.recordIds(model: "Note"), ["n1"],
            "and no second record was minted"
        )
    }

    func testUpsertOnAnUnseenUniqueValueCreates() async throws {
        let fixture = try await makeFixture()

        let result = try fixture.model.upsert(
            ["title": .string("first"), "slug": .string("fresh")], on: "slug"
        )

        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(
            fixture.model.find(id: result.record.id)?["slug"], .string("fresh")
        )
    }

    // MARK: - One stringset member (finding 3436-REV-08)

    /// Both methods required the record's nested member map, which a large
    /// document does not have — so they reported `notFound` for a record the
    /// document holds and can read.
    func testAddingAndRemovingOneMemberLeavesTheRestOfTheSetAlone() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("one"), "tags": .stringset(["a", "b"]),
        ])

        try fixture.model.addStringsetMember(id: "n1", fieldName: "tags", member: "c")
        XCTAssertEqual(
            Set(try fixture.binding.store.members(
                model: "Note", recordId: "n1", field: "tags"
            )),
            ["a", "b", "c"],
            "one member added, the others untouched"
        )

        try fixture.model.removeStringsetMember(id: "n1", fieldName: "tags", member: "a")
        XCTAssertEqual(
            Set(try fixture.binding.store.members(
                model: "Note", recordId: "n1", field: "tags"
            )),
            ["b", "c"]
        )

        let mutated = try fixture.binding.store.pendingOps()
            .filter { $0.fields == ["tags"] }
        XCTAssertEqual(
            mutated.count, 2,
            "each is a durable local write of its own, or the server never hears it"
        )
    }

    func testAMemberRemoveTheRecordDoesNotHoldWritesNothing() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("one"), "tags": .stringset(["a"]),
        ])
        let before = try fixture.binding.store.pendingOps().count

        try fixture.model.removeStringsetMember(id: "n1", fieldName: "tags", member: "z")

        XCTAssertEqual(
            try fixture.binding.store.pendingOps().count, before,
            "a no-op on the nested-map path is a no-op here: no pending op, no frame"
        )
    }

    func testAMemberWriteAgainstAnAbsentRecordIsRefused() async throws {
        let fixture = try await makeFixture()
        XCTAssertThrowsError(
            try fixture.model.addStringsetMember(id: "ghost", fieldName: "tags", member: "a")
        ) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .notFound)
        }
    }

    func testAMemberAddOverTheMaxCountIsRefusedAndWritesNothing() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("one"), "tags": .stringset(["a", "b", "c"]),
        ])
        let before = try fixture.binding.store.pendingOps().count

        XCTAssertThrowsError(
            try fixture.model.addStringsetMember(id: "n1", fieldName: "tags", member: "d"),
            "maxCount is 3"
        )
        XCTAssertEqual(try fixture.binding.store.pendingOps().count, before)
        XCTAssertEqual(
            Set(try fixture.binding.store.members(
                model: "Note", recordId: "n1", field: "tags"
            )),
            ["a", "b", "c"]
        )
    }

    // MARK: - Subscribers (finding 3436-REV-06)

    /// A large document's records are flat overlay keys, so the root-map and
    /// per-record observers that carry a peer's edit to `subscribe` on an
    /// ordinary document see nothing here — they ignore flat scalar keys by
    /// design. Without the fold telling them, a subscriber fired for its own
    /// writes and never for anybody else's: the query stays current while the
    /// view watching it goes stale.
    func testASubscriberHearsAPeersCreateUpdateAndDelete() async throws {
        let fixture = try await makeFixture()
        let notifications = LockedBox<Int>(0)
        let unsubscribe = fixture.model.subscribe {
            notifications.withValue { $0 += 1 }
        }
        defer { unsubscribe() }

        let peerOverlay = OverlayDocument()

        peerOverlay.apply(
            OverlayMutation(id: "p1", kind: .create, fields: ["title": .string("theirs")]),
            model: "Note"
        )
        try deliver(peerOverlay, to: fixture)
        XCTAssertEqual(
            fixture.model.find(id: "p1")?["title"], .string("theirs"),
            "precondition: the fold landed"
        )
        XCTAssertGreaterThanOrEqual(
            notifications.value, 1, "the peer's create has to reach the subscriber"
        )

        let afterCreate = notifications.value
        peerOverlay.apply(
            OverlayMutation(id: "p1", kind: .patch, fields: ["title": .string("edited")]),
            model: "Note"
        )
        try deliver(peerOverlay, to: fixture)
        XCTAssertGreaterThan(notifications.value, afterCreate, "and so does the edit")

        let afterUpdate = notifications.value
        peerOverlay.apply(OverlayMutation(id: "p1", kind: .delete), model: "Note")
        try deliver(peerOverlay, to: fixture)
        XCTAssertGreaterThan(notifications.value, afterUpdate, "and the delete")
    }

    func testASubscriberIsNotToldAboutAFoldThatTouchedNothing() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("one")])
        // The observer folds a local write a second time, idempotently — yswift
        // carries no transaction origin — and that fold is a real change to
        // announce. Settle it before the subscriber exists, so what is measured
        // below is the EMPTY drain and nothing else.
        fixture.binding.settleFolds()
        let notifications = LockedBox<Int>(0)
        let unsubscribe = fixture.model.subscribe {
            notifications.withValue { $0 += 1 }
        }
        defer { unsubscribe() }

        // Nothing captured: an empty drain folds nothing and says so.
        XCTAssertEqual(try fixture.binding.writePath.foldPendingUnderOperation(), [])
        XCTAssertEqual(
            notifications.value, 0,
            "a fold with nothing in it is not a change and must not wake a view"
        )
    }
}
