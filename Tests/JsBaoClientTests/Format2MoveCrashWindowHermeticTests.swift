import XCTest
@testable import JsBaoClient
import YSwift

/// The windows either side of an epoch move (#3437, edges E6 and E7).
///
/// E7 is the crash between persisting the fresh overlay and moving the epoch
/// mark. The order is deliberate (finding 3437-R05): the restart then holds
/// the OLD mark and the FRESH overlay, which the next handshake's catch-up
/// repairs idempotently — the sealed archive is re-applied over a merged view
/// it already agrees with, and the owed writes are carried off the fresh
/// overlay a second time. The reverse order would restart with the SEALED
/// overlay under the NEW mark and resend it whole into the new epoch, which is
/// exactly what re-seeding rotation exists to prevent.
///
/// E6 is two `JsBaoClient` instances in one process over one database file.
/// One process per database file is the rule — Node's — and it is documented
/// rather than prevented: the second instance adopts the first's pending ops,
/// because every foreign client id reads as a session that has ended.
final class Format2MoveCrashWindowHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
        ]
    )

    private func newPath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-crash-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    // MARK: - Edge E7 — the crash between the persist and the mark

    /// Stopped between the two steps, then restarted over the same file: the
    /// mark is the OLD epoch and the overlay is the FRESH one.
    func testARestartBetweenThePersistAndTheMarkHoldsTheOldMark() async throws {
        let path = newPath()
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "test")

        let documentId = "crash-window"
        let coordinator = Format2Coordinator(
            host: provider, clientId: "first", logger: Logger(level: .none)
        )
        let doc = YDocument()
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: documentId, doc: doc)
        model.bindFormat2(binding)
        _ = try coordinator.handleEpochInfo(
            ["documentId": documentId, "epoch": 1, "sealedEpochs": []],
            now: Int(Date().timeIntervalSince1970 * 1000)
        )
        _ = try model.create(id: "owed", values: ["title": .string("still owed")])

        // The move runs whole, and then the epoch mark is rolled BACK — which
        // is exactly the durable state a crash between the two steps leaves:
        // the fresh overlay persisted, the transaction that moves the mark
        // never committed. Modelled this way rather than by injecting a
        // failure, because what the edge is about is the STATE a restart
        // finds, not the mechanism that produced it.
        coordinator.replaceDocument = { _, _ in }
        let outcome = try await coordinator.runEpochMove(
            documentId: documentId, next: 2,
            now: Int(Date().timeIntervalSince1970 * 1000)
        )
        XCTAssertEqual(outcome, .moved(epoch: 2))
        try binding.store.setEpoch(1)

        // The restart: a second coordinator over the same file, and the fresh
        // overlay is what local persistence would hand it.
        let restarted = Format2Coordinator(
            host: provider, clientId: "second", logger: Logger(level: .none)
        )
        let restartedDoc = YDocument()
        let restartedBinding = try restarted.bind(
            documentId: documentId, models: ["Note"], document: restartedDoc
        )
        try restartedBinding.overlay.applyUpdate(binding.overlay.encodeStateAsUpdate())

        XCTAssertEqual(
            try restartedBinding.store.epoch(), 1,
            "the old mark: the next handshake sees a client one epoch behind "
            + "and repairs it with the chain, which is idempotent"
        )
        XCTAssertEqual(
            restartedBinding.overlay.value(model: "Note", key: "owed/title"),
            .string("still owed"),
            "and the owed write is on the FRESH overlay, so the carry finds it "
            + "again rather than a sealed overlay it would resend whole"
        )
        // The write is still owed and still adoptable, which is what makes the
        // repair possible at all.
        let adopted = try restartedBinding.store.adoptOrphanedPendingOps()
        XCTAssertEqual(adopted.count, 1)
        XCTAssertEqual(adopted.first?.recordId, "owed")
    }

    // MARK: - Edge E6 — two instances over one file

    func testASecondInstanceOverOneFileAdoptsTheFirstsPendingOps() async throws {
        let path = newPath()
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "test")

        let first = Format2RecordStore(
            host: provider, documentId: "shared", clientId: "instance-a"
        )
        try first.initialize()
        try first.commitLocalWrite(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            pending: PendingOpInput(
                model: "Note", recordId: "r1", op: .create, fields: ["title"],
                baseEpoch: 1, ts: 0
            )
        )

        let second = Format2RecordStore(
            host: provider, documentId: "shared", clientId: "instance-b"
        )
        try second.initialize()
        XCTAssertEqual(
            try second.pendingOps().count, 0,
            "another instance's writes are invisible until they are adopted"
        )

        // Documented, not prevented: one process per database file is the
        // rule, and under it a row under another client id is a session that
        // has ended. The cost of being wrong is a write delivered twice, which
        // the server's replay is idempotent against; the cost of the other
        // choice is a write delivered never.
        XCTAssertEqual(try second.adoptOrphanedPendingOps().count, 1)
        XCTAssertEqual(try second.pendingOps().map(\.recordId), ["r1"])
        XCTAssertEqual(
            try first.pendingOps().count, 0,
            "and they are no longer the first instance's to claim"
        )
    }
}
