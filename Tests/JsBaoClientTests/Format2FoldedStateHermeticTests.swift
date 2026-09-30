import XCTest
@testable import JsBaoClient
import YSwift

/// The folded-state mark on the Swift client (#3782, behaviors 18 and 19).
///
/// A bind used to catch up by folding every registered model's whole overlay,
/// on every open — for a document that never rotated, the document. The store
/// now keeps `_epoch.folded_state`: the overlay's state vector at the last
/// fold, and the models that fold covered, as the SAME canonical JSON the JS
/// client writes. Every fold stamps it inside its own transaction, merged per
/// client by max under the guard both clients share; a bind whose overlay has
/// the stored vector folds nothing.
///
/// What SQLite stored and what the vector decodes to are held against the real
/// js-bao code through the node harness, never a transcription.
final class Format2FoldedStateHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-folded-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(
        _ provider: (any Format2SqlHost)? = nil, documentId: String = "doc1"
    ) async throws -> Format2RecordStore {
        let host: any Format2SqlHost
        if let provider { host = provider } else { host = try await makeProvider() }
        let store = Format2RecordStore(host: host, documentId: documentId, clientId: "me")
        try store.initialize()
        return store
    }

    private func epochColumns(_ host: any Format2SqlHost) throws -> [String] {
        try host.withConnection { connection in
            try connection.query("PRAGMA table_info(_epoch)", []).compactMap {
                $0["name"].stringValue
            }
        }
    }

    private func storedText(_ host: any Format2SqlHost, _ documentId: String = "doc1") throws -> String? {
        try host.withConnection { connection in
            try connection.query(
                "SELECT folded_state FROM _epoch WHERE doc_id = ?", [.text(documentId)]
            ).first?["folded_state"].stringValue
        }
    }

    /// What js-bao writes into the column for the same state.
    private func javaScriptText(_ vector: [String: Int], _ models: [String]) throws -> String {
        let response = try Format2Harness.run([
            "command": "encode-folded-state",
            "state": ["vector": vector, "models": models],
        ])
        return try XCTUnwrap(response["text"] as? String)
    }

    private func stampWhole(
        _ store: Format2RecordStore, _ vector: [String: Int], _ models: [String] = ["Note"]
    ) throws -> Bool {
        try store.noteFoldedState(
            FoldedState(vector: vector, models: models), docState: vector, whole: true
        )
    }

    // MARK: - Behavior 18 — the column, the merge, the guard

    func testTheEpochRowCarriesFoldedStateRightAfterHydratedModels() async throws {
        let provider = try await makeProvider()
        let store = try await makeStore(provider)
        let columns = try epochColumns(provider)
        let hydrated = try XCTUnwrap(columns.firstIndex(of: "hydrated_models"))
        XCTAssertEqual(columns.firstIndex(of: "folded_state"), hydrated + 1)
        XCTAssertNil(try store.foldedState(), "a fresh store knows nothing")
    }

    func testTheStoredTextIsTheJavaScriptClientsCanonicalJson() async throws {
        let provider = try await makeProvider()
        let store = try await makeStore(provider)
        XCTAssertTrue(try stampWhole(store, ["12": 1, "5": 3], ["b", "a"]))
        let text = try XCTUnwrap(try storedText(provider))
        XCTAssertEqual(text, #"{"vector":{"5":3,"12":1},"models":["a","b"]}"#)
        XCTAssertEqual(text, try javaScriptText(["12": 1, "5": 3], ["b", "a"]))
        XCTAssertEqual(
            try store.foldedState(),
            FoldedState(vector: ["5": 3, "12": 1], models: ["a", "b"])
        )
    }

    func testAPassingGuardMergesPerClientByMaxAndUnionsTheModels() async throws {
        let provider = try await makeProvider()
        let store = try await makeStore(provider)
        _ = try stampWhole(store, ["5": 3, "12": 1], ["a", "b"])
        XCTAssertTrue(try store.noteFoldedState(
            FoldedState(vector: ["5": 2, "7": 4], models: ["c"]),
            docState: ["5": 3, "7": 4, "12": 1],
            whole: false
        ))
        XCTAssertEqual(
            try storedText(provider),
            #"{"vector":{"5":3,"7":4,"12":1},"models":["a","b","c"]}"#
        )
    }

    func testADocumentBehindTheStoreOnAnyClientWritesNothing() async throws {
        let provider = try await makeProvider()
        let store = try await makeStore(provider)
        _ = try stampWhole(store, ["5": 3, "7": 4, "12": 1], ["a"])
        let before = try storedText(provider)
        XCTAssertFalse(try store.noteFoldedState(
            FoldedState(vector: ["5": 9, "7": 3], models: ["a", "z"]),
            docState: ["5": 9, "7": 3],
            whole: false
        ))
        XCTAssertEqual(try storedText(provider), before)
    }

    func testAnIncrementalFoldCannotBeTheFirstThingToVouchForTheStore() async throws {
        let provider = try await makeProvider()
        let store = try await makeStore(provider)
        XCTAssertFalse(try store.noteFoldedState(
            FoldedState(vector: ["5": 3], models: ["a"]), docState: ["5": 3], whole: false
        ))
        XCTAssertNil(try storedText(provider))
    }

    func testClearedWhereverTheRowsComeFromAnotherSource() async throws {
        let store = try await makeStore()

        _ = try stampWhole(store, ["5": 3])
        try store.setEpoch(0)
        XCTAssertNotNil(try store.foldedState(), "the same epoch keeps it")
        try store.setEpoch(1)
        XCTAssertNil(try store.foldedState(), "another epoch is another Y.Doc")

        _ = try stampWhole(store, ["5": 3])
        try store.applyChunk(
            model: "Note", entries: [OverlayRecordEntry(id: "r1", fields: ["title": .string("a")])],
            buildId: "b", ordinal: 0
        )
        XCTAssertNil(try store.foldedState(), "base rows replace what the fold wrote")

        _ = try stampWhole(store, ["5": 3])
        try store.discardMergedView()
        XCTAssertNil(try store.foldedState(), "nothing is folded any more")

        _ = try stampWhole(store, ["5": 3])
        try store.setHydrationScope(nil)
        XCTAssertNotNil(try store.foldedState(), "the same scope keeps it")
        try store.setHydrationScope(["Note"])
        XCTAssertNil(try store.foldedState(), "a changed scope changes what a fold writes")
    }

    /// A Swift database written before the column existed — records,
    /// projection marks, unacknowledged writes and a deferred-replay note in
    /// it — gains the column on its first initialize and keeps every row.
    func testInitializeMigratesAPopulatedFileWrittenBeforeTheColumn() async throws {
        let provider = try await makeProvider()
        let first = try await makeStore(provider)
        try first.transaction {
            try first.applyRemote(
                model: "Note",
                entry: OverlayRecordEntry(id: "r1", fields: ["title": .string("kept")])
            )
        }
        try first.commitLocalWrite(
            model: "Note",
            mutation: OverlayMutation(id: "r2", kind: .create, fields: ["title": .string("owed")]),
            pending: PendingOpInput(
                model: "Note", recordId: "r2", op: .create, fields: ["title"],
                baseEpoch: 0, ts: 1
            )
        )
        try first.noteDeferredReplay(throughSeq: 1, fromEpoch: 0, toEpoch: 1, kind: .ordinary)
        try provider.withConnection { connection in
            try connection.execute(
                "INSERT INTO _query_projection (doc_id, model) VALUES (?, ?)",
                [.text("doc1"), .text("Note")]
            )
            // The file as every build before this one left it.
            try connection.executeScript("ALTER TABLE _epoch DROP COLUMN folded_state")
        }
        XCTAssertFalse(try epochColumns(provider).contains("folded_state"))

        let upgraded = try await makeStore(provider)
        XCTAssertTrue(try epochColumns(provider).contains("folded_state"))
        XCTAssertNil(try upgraded.foldedState(), "nothing is known about an older build's folds")
        XCTAssertEqual(try upgraded.read(model: "Note", recordId: "r1")?["title"], .string("kept"))
        XCTAssertEqual(try upgraded.pendingOps().map(\.recordId), ["r2"])
        XCTAssertEqual(try upgraded.deferredReplay()?.throughSeq, 1)
        let marks = try provider.withConnection { connection in
            try connection.query("SELECT model FROM _query_projection WHERE doc_id = ?", [.text("doc1")])
                .compactMap { $0["model"].stringValue }
        }
        XCTAssertEqual(marks, ["Note"])
        // And a second initialize does not try to add it again.
        XCTAssertNoThrow(try upgraded.initialize())
    }

    /// The vector the overlay holds, decoded from yrs' lib0 encoding exactly
    /// as the JS client decodes the same update.
    func testTheStateVectorDecodesAsTheJavaScriptClientDecodesIt() async throws {
        let overlay = OverlayDocument()
        overlay.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            model: "Note"
        )
        let peer = OverlayDocument()
        try peer.applyUpdate(overlay.encodeStateAsUpdate())
        for index in 0..<3 {
            peer.apply(
                OverlayMutation(id: "p\(index)", kind: .create, fields: ["title": .string("p")]),
                model: "Note"
            )
        }
        try overlay.applyUpdate(peer.encodeStateAsUpdate())

        let mine = overlay.stateVector()
        XCTAssertEqual(mine.count, 2, "two writers, two clients")
        let response = try Format2Harness.run([
            "command": "state-vector",
            "update": Data(overlay.encodeStateAsUpdate()).base64EncodedString(),
        ])
        let theirs = try XCTUnwrap(response["vector"] as? [String: Int])
        XCTAssertEqual(mine, theirs)
    }

    // MARK: - Behavior 19 — every fold stamps, inside its own transaction

    private struct Fixture {
        let store: Format2RecordStore
        let overlay: OverlayDocument
        let observer: Format2Observer
    }

    private func makeFixture(
        host: (any Format2SqlHost)? = nil, models: [String] = ["Note", "Tag"]
    ) async throws -> Fixture {
        let store = try await makeStore(host)
        let overlay = OverlayDocument()
        let observer = Format2Observer(store: store, overlay: overlay)
        for model in models { observer.register(model: model) }
        return Fixture(store: store, overlay: overlay, observer: observer)
    }

    private func peerWrite(_ fixture: Fixture, model: String, id: String) throws {
        let peer = OverlayDocument()
        try peer.applyUpdate(fixture.overlay.encodeStateAsUpdate())
        peer.apply(
            OverlayMutation(id: id, kind: .create, fields: ["title": .string(id)]),
            model: model
        )
        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())
    }

    func testACatchUpStampsTheOverlaysVectorAndTheModelsItFolded() async throws {
        let fixture = try await makeFixture()
        try peerWrite(fixture, model: "Note", id: "r1")
        try fixture.observer.catchUp()
        XCTAssertEqual(
            try fixture.store.foldedState(),
            FoldedState(vector: fixture.overlay.stateVector(), models: ["Note", "Tag"])
        )
    }

    func testADrainStampsWhatItFolded() async throws {
        let fixture = try await makeFixture()
        try fixture.observer.catchUp()
        try peerWrite(fixture, model: "Note", id: "r2")
        try fixture.observer.drain()
        XCTAssertEqual(try fixture.store.foldedState()?.vector, fixture.overlay.stateVector())
        XCTAssertEqual(try fixture.store.read(model: "Note", recordId: "r2")?["title"], .string("r2"))
    }

    func testAFailedFoldStampsNothing() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)
        try fixture.observer.catchUp()
        let stamped = try fixture.store.foldedState()

        try peerWrite(fixture, model: "Note", id: "r3")
        failing.failStatementsContaining = "INSERT INTO records_f2_"
        XCTAssertThrowsError(try fixture.observer.drain())
        failing.failStatementsContaining = nil
        XCTAssertEqual(try fixture.store.foldedState(), stamped, "a failed fold vouches for nothing")

        // Broken, the observer refuses to drain at all — and so stamps nothing.
        try peerWrite(fixture, model: "Note", id: "r4")
        XCTAssertThrowsError(try fixture.observer.drain())
        XCTAssertEqual(try fixture.store.foldedState(), stamped)
    }

    // MARK: - What a stamp may keep covering (#3782, second opinion)

    private func peerPatch(_ overlay: OverlayDocument, model: String, id: String, title: String) throws {
        let peer = OverlayDocument()
        try peer.applyUpdate(overlay.encodeStateAsUpdate())
        peer.apply(
            OverlayMutation(id: id, kind: .patch, fields: ["title": .string(title)]),
            model: model
        )
        try overlay.applyUpdate(peer.encodeStateAsUpdate())
    }

    /// Finding 3782-C04. A session that observes fewer models than the last
    /// stamp covered must not carry the others forward to a newer vector:
    /// their changes since were never captured.
    func testADrainDoesNotCarryAModelItNeverObservedToANewerVector() async throws {
        let provider = try await makeProvider()
        let first = try await makeFixture(host: provider, models: ["Note", "Task"])
        try peerWrite(first, model: "Note", id: "n1")
        try peerWrite(first, model: "Task", id: "t1")
        try first.observer.catchUp()
        XCTAssertEqual(try first.store.foldedState()?.models, ["Note", "Task"])

        // Reopened with only Note registered: the bind finds the vector equal
        // and folds nothing, so Note is caught up by the stamp.
        let store = try await makeStore(provider)
        let observer = Format2Observer(store: store, overlay: first.overlay)
        observer.register(model: "Note")
        XCTAssertEqual(try store.foldedState()?.vector, first.overlay.stateVector())
        observer.markCaughtUp(["Note"])

        try peerPatch(first.overlay, model: "Task", id: "t1", title: "changed")
        try peerPatch(first.overlay, model: "Note", id: "n1", title: "changed")
        try observer.drain()

        let stamped = try XCTUnwrap(try store.foldedState())
        XCTAssertEqual(stamped.vector, first.overlay.stateVector())
        XCTAssertEqual(
            stamped.models, ["Note"],
            "Task's change was never captured; the stamp must not vouch for it"
        )
        XCTAssertEqual(try store.read(model: "Task", recordId: "t1")?["title"], .string("t1"))
    }

    /// Finding 3782-C04. A catch-up of one model stamps a newer vector while
    /// another model's captured keys are still waiting for the next drain.
    func testAPartialCatchUpDoesNotVouchForAnotherModelsPendingKeys() async throws {
        let fixture = try await makeFixture()
        try fixture.observer.catchUp()
        XCTAssertEqual(try fixture.store.foldedState()?.models, ["Note", "Tag"])

        try peerWrite(fixture, model: "Note", id: "pending")
        try peerWrite(fixture, model: "Tag", id: "g1")
        try fixture.observer.catchUp(models: ["Tag"])

        let partial = try XCTUnwrap(try fixture.store.foldedState())
        XCTAssertEqual(partial.vector, fixture.overlay.stateVector())
        XCTAssertEqual(partial.models, ["Tag"], "Note's keys are captured and not folded")
        XCTAssertNil(try fixture.store.read(model: "Note", recordId: "pending"))

        // The drain that folds them certifies both again.
        try fixture.observer.drain()
        XCTAssertEqual(
            try fixture.store.foldedState(),
            FoldedState(vector: fixture.overlay.stateVector(), models: ["Note", "Tag"])
        )
    }

    /// Finding 3782-C05. A catch-up from an overlay behind the stamp rewrites
    /// rows with older values; it must not leave the newer stamp standing.
    func testACatchUpFromAnOverlayBehindTheStoreClearsTheStamp() async throws {
        let provider = try await makeProvider()
        let ahead = try await makeFixture(host: provider, models: ["Note"])
        try peerWrite(ahead, model: "Note", id: "r1")
        let lagging = OverlayDocument()
        try lagging.applyUpdate(ahead.overlay.encodeStateAsUpdate())
        try peerPatch(ahead.overlay, model: "Note", id: "r1", title: "newer")
        try ahead.observer.catchUp()
        XCTAssertNotNil(try ahead.store.foldedState())

        // Reopened over an overlay whose persist lagged the fold.
        let store = try await makeStore(provider)
        let observer = Format2Observer(store: store, overlay: lagging)
        observer.register(model: "Note")
        try observer.catchUp()

        XCTAssertEqual(try store.read(model: "Note", recordId: "r1")?["title"], .string("r1"))
        XCTAssertNil(
            try store.foldedState(),
            "the rows are older than the stamp says; nothing may vouch for them"
        )
    }
}
