import XCTest
@testable import JsBaoClient
import YSwift

/// `documents.create` is metadata-only, and a write to a document that has not
/// been opened throws — the JS contract (issue #3200, phase 1).
///
/// Before this fix `createDocument` built a `YDocument`, registered it in
/// `openDocs` and connected it to the shared model stores, but never registered
/// the per-document update observer. A write to a created-but-unopened document
/// was therefore accepted, readable through `Model.query`, and never sent: the
/// silent third state the issue reports. JS is the reference — its
/// `createDocument` writes local metadata only (`src/client/JsBaoClient.ts`),
/// and its write path throws for a document that is not open.
///
/// Server-free: the client is built with unreachable URLs and never connects.
/// Outbound frames are intercepted by replacing
/// `DocumentManager.sendWebSocketMessage`; a server `syncStep1` is driven
/// through the real message router (`handleWebSocketMessage`).
final class CreatedDocumentThrowsHermeticTests: XCTestCase {

    // MARK: - Fixtures

    /// Mirrors what `SwiftEmitter` emits for a registered model — the codegen
    /// write path (`Model.save(in:)`) funnels through `client.codegen.save`.
    private static let noteSchema = PrimitiveSchema(
        name: "created_doc_notes",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
        ]
    )

    /// Collects outbound frames from whichever thread the flush runs on.
    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [String] = []
        func append(_ frame: String) { lock.withLock { _frames.append(frame) } }
        var all: [String] { lock.withLock { _frames } }
        /// Frames that carry document content — an `update` or a `syncStep2`.
        /// A state-vector-only `syncStep1` is not one of them (#3200, review F5).
        var contentFrames: [String] {
            all.filter { $0.contains("\"update\"") || $0.contains("syncStep2") }
        }
    }

    /// Records every `markUnsyncedLocalChanges` call. `hasUnsyncedLocalChanges`
    /// cannot stand in for it: a drop and a hold both leave it false once the
    /// flag is cleared elsewhere, and only the call log shows a mark was made.
    private final class MarkSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _marks: [(String, Bool)] = []
        func append(_ documentId: String, _ value: Bool) {
            lock.withLock { _marks.append((documentId, value)) }
        }
        func markedUnsynced(_ documentId: String) -> Bool {
            lock.withLock { _marks.contains { $0.0 == documentId && $0.1 } }
        }
    }

    /// A client that never talks to a server, with zero outbound debounce so a
    /// queued update reaches the (intercepted) socket promptly.
    private func makeClient(_ appId: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
    }

    /// Same client, but with networking *allowed* — so an open that decides it
    /// needs the network really does take the availability path against an
    /// unreachable server, instead of being short-circuited by offline mode.
    private func makeOnlineClient(_ appId: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
    }

    /// Create a document through the public API and return its id.
    private func create(
        _ client: JsBaoClient,
        options: CreateDocumentOptions = CreateDocumentOptions()
    ) async throws -> String {
        // No server in these tests: the background commit must not be attempted.
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        let result = try await client.createDocument(options: options)
        return try XCTUnwrap(result.metadata?["documentId"]?.stringValue)
    }

    /// Give a zero-debounce flush time to reach the intercepted socket. Used
    /// only for the negative assertions, where there is no event to await.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func assertNotOpenError(
        _ error: Error,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let jsBaoError = error as? JsBaoError else {
            return XCTFail("expected a JsBaoError, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(jsBaoError.code, .notFound, file: file, line: line)
        XCTAssertTrue(
            jsBaoError.message.contains(fragment),
            "expected message containing `\(fragment)`, got `\(jsBaoError.message)`",
            file: file, line: line
        )
    }

    // MARK: - Behavior 1: the codegen write path throws

    func testCodegenSaveOnCreatedButUnopenedDocumentThrowsNotOpen() async throws {
        let client = makeClient("created-doc-codegen-save")
        defer { Task { await client.destroy() } }
        client.registerModels([Self.noteSchema])

        let documentId = try await create(client)

        XCTAssertThrowsError(
            try client.codegen.save(
                Self.noteSchema, id: "n1", values: ["title": .string("T")], in: documentId
            )
        ) { error in
            assertNotOpenError(error, containing: "is not open. Open it (client.openDocument)")
        }

        XCTAssertTrue(
            try client.codegen.query(Self.noteSchema).isEmpty,
            "a rejected write must apply nothing — the record must not be readable back"
        )
        XCTAssertNil(client.codegen.find(Self.noteSchema, id: "n1"))
    }

    // MARK: - Behavior 2: the transaction wrappers throw

    func testTransactAndSyncOnCreatedButUnopenedDocumentThrowsNotOpen() async throws {
        let client = makeClient("created-doc-transact")
        defer { Task { await client.destroy() } }

        let documentId = try await create(client)

        XCTAssertNil(
            client.getDoc(documentId),
            "a created document is not open, so there is no YDocument to hand out"
        )

        XCTAssertThrowsError(
            try client.transactAndSync(documentId) { _ in () }
        ) { error in
            assertNotOpenError(error, containing: "is not open")
        }

        do {
            _ = try await client.transactAndSyncAsync(documentId) { _ in () }
            XCTFail("transactAndSyncAsync must throw for a document that is not open")
        } catch {
            assertNotOpenError(error, containing: "is not open")
        }
    }

    // MARK: - Behavior 3: create is metadata-only

    func testCreateReturnsMetadataAndLeavesTheDocumentClosed() async throws {
        let client = makeClient("created-doc-metadata-only")
        defer { Task { await client.destroy() } }

        let documentId = try await create(
            client, options: CreateDocumentOptions(title: "T", tags: ["x"])
        )

        XCTAssertFalse(documentId.isEmpty)
        XCTAssertTrue(
            client.isPendingCreate(documentId),
            "a non-localOnly create still schedules its server commit"
        )
        XCTAssertEqual(client.documentManager.getLocalMetadata(documentId)?.title, "T")
        XCTAssertEqual(client.documentManager.getLocalMetadata(documentId)?.tags, ["x"])

        XCTAssertFalse(
            client.isDocumentOpen(documentId),
            "create leaves the document closed — opening is always an explicit step (JS parity)"
        )
        XCTAssertFalse(client.listOpenDocuments().contains(documentId))
        XCTAssertNil(client.getDoc(documentId))
    }

    // MARK: - Behavior 4: opening a created document is not degraded

    func testOpenOfPendingCreateDocumentWithDefaultOptionsResolvesPromptly() async throws {
        // The server cannot hold this document yet, so the open must count the
        // pending create as a local copy and resolve locally instead of
        // spending the availability budget (or fast-failing) on a document the
        // network could not answer for anyway.
        let client = makeOnlineClient("created-doc-open-prompt")
        defer { Task { await client.destroy() } }

        let documentId = try await create(client)

        let started = Date()
        _ = try await client.openDocument(documentId)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(client.isDocumentOpen(documentId))
        XCTAssertLessThan(
            elapsed, 5,
            "a default-options open of a pending-create document must resolve locally"
        )
    }

    // MARK: - Behavior 5: a post-commit write on an opened created document transmits

    func testPostCommitWriteOnCreatedThenOpenedDocumentTransmits() async throws {
        let client = makeClient("created-doc-post-commit-write")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = try await create(client)
        let doc = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        client.documentManager.handlePendingCreateCommitted(documentId)
        XCTAssertFalse(client.isPendingCreate(documentId))

        let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
        doc.transactSync { txn in
            notes.updateValue("reaches the server", forKey: "k", transaction: txn)
        }
        await settle()

        XCTAssertFalse(
            sink.contentFrames.isEmpty,
            "a write to an opened, committed document must reach the socket; sent: \(sink.all)"
        )
    }

    // MARK: - Behavior 6: the same through the codegen write path

    func testPostCommitCodegenSaveOnOpenedCreatedDocumentTransmits() async throws {
        let client = makeClient("created-doc-post-commit-codegen")
        defer { Task { await client.destroy() } }
        client.registerModels([Self.noteSchema])
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = try await create(client)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        client.documentManager.handlePendingCreateCommitted(documentId)

        try client.codegen.save(
            Self.noteSchema, id: "n1", values: ["title": .string("T")], in: documentId
        )
        await settle()

        XCTAssertEqual(
            try client.codegen.query(Self.noteSchema).count, 1,
            "the record is readable back through the shared store the open connected"
        )
        XCTAssertFalse(
            sink.contentFrames.isEmpty,
            "a codegen write to an opened, committed document must reach the socket; sent: \(sink.all)"
        )
    }

    // MARK: - Behavior 7: a pre-commit write is held, not dropped

    func testPreCommitWriteOnOpenedCreatedDocumentIsHeldAndMarkedUnsynced() async throws {
        let client = makeClient("created-doc-pre-commit-hold")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        let marks = MarkSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }
        client.documentManager.onMarkUnsyncedForTest = { marks.append($0, $1) }

        let documentId = try await create(client)
        let doc = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        XCTAssertTrue(client.isPendingCreate(documentId))

        let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
        doc.transactSync { txn in
            notes.updateValue("held", forKey: "k", transaction: txn)
        }
        await settle()

        XCTAssertTrue(
            sink.contentFrames.isEmpty,
            "the server has no row for a pending create, so the edit has nowhere to land; sent: \(sink.all)"
        )
        XCTAssertTrue(
            marks.markedUnsynced(documentId),
            "a held edit must be visible as unsynced local state, not silently dropped"
        )
    }

    // MARK: - Behavior 8: the held content is carried by the post-commit sync

    func testPreCommitContentIsCarriedByThePostCommitSync() async throws {
        let client = makeClient("created-doc-carry")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = try await create(client)
        let doc = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )

        let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
        doc.transactSync { txn in
            notes.updateValue("carried up", forKey: "k", transaction: txn)
        }
        await settle()
        XCTAssertTrue(sink.contentFrames.isEmpty, "precondition: nothing went out pre-commit")

        // The commit lands: the document now exists server-side.
        client.documentManager.handlePendingCreateCommitted(documentId)

        // A server that has never seen this document answers with an empty
        // state vector, so the diff the client owes carries everything.
        let emptyDocId = "carry-empty-source"
        _ = try await client.openDocument(
            emptyDocId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let emptyStateVector = try XCTUnwrap(
            client.documentManager.encodeStateVectorBase64(emptyDocId)
        )

        let response = try XCTUnwrap(
            client.documentManager.syncStep2ResponseForServerSyncStep1(
                documentId: documentId,
                serverDocHash: String(repeating: "0", count: 64),
                serverStateVectorBase64: emptyStateVector
            ),
            "the committed document owes the server the state written before the commit"
        )
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["type"] as? String, "syncStep2")
        let updateBase64 = try XCTUnwrap(decoded["update"] as? String)
        let update = try XCTUnwrap(Data(base64Encoded: updateBase64))

        // Apply the answer into a fresh document: the content written before
        // the commit has to be inside it.
        let replica = YDocument()
        let replicaNotes: YMap<String> = replica.getOrCreateMap(named: "notes")
        replica.transactSync { txn in
            try? txn.transactionApplyUpdate(update: Array(update))
        }
        let carried: String? = replica.transactSync { txn in
            replicaNotes.get(key: "k", transaction: txn)
        }
        XCTAssertEqual(
            carried, "carried up",
            "the pre-commit write must reach the server through the post-commit sync"
        )

        // And the round-trip clears the unsynced flag.
        await client.handleWebSocketMessage(
            #"{"type":"syncComplete","documentId":"\#(documentId)"}"#
        )
        XCTAssertTrue(client.documentManager.isSynced(documentId))
        XCTAssertFalse(
            client.documentManager.hasUnsyncedLocalChanges(documentId),
            "the carried content is on the server, so nothing local is left unsynced"
        )
    }

    // MARK: - Behavior 9: a localOnly document is written after an explicit open

    func testLocalOnlyCreatedDocumentIsWritableAfterOpenAndTransmitsNothing() async throws {
        let client = makeClient("created-doc-local-only")
        defer { Task { await client.destroy() } }
        client.registerModels([Self.noteSchema])
        let sink = FrameSink()
        let marks = MarkSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }
        client.documentManager.onMarkUnsyncedForTest = { marks.append($0, $1) }

        let documentId = try await create(
            client, options: CreateDocumentOptions(localOnly: true)
        )
        XCTAssertTrue(client.documentManager.isLocalOnly(documentId))

        // The shape the published local-only example uses.
        let doc = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
        doc.transactSync { txn in
            notes.updateValue("stays here", forKey: "secret", transaction: txn)
        }
        try client.codegen.save(
            Self.noteSchema, id: "n1", values: ["title": .string("local")], in: documentId
        )
        await settle()

        XCTAssertEqual(
            try client.codegen.query(Self.noteSchema).count, 1,
            "an opened local-only document is fully writable and queryable"
        )
        XCTAssertTrue(
            sink.all.isEmpty,
            "a local-only document must never put anything on the wire; sent: \(sink.all)"
        )
        XCTAssertFalse(
            marks.markedUnsynced(documentId),
            "nothing ever sends a local-only edit, so a mark here is one nothing could clear"
        )
    }

    // MARK: - Behavior 10: a localOnly document opened with default options

    func testLocalOnlyCreatedDocumentOpensPromptlyWithDefaultOptions() async throws {
        // `startNetworkSync` has no local-only guard (JS has none either), so
        // the contract is "no content on the wire", asserted by frame type —
        // in this vehicle the socket is never open, so nothing goes out at all.
        let client = makeOnlineClient("created-doc-local-only-default")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        let marks = MarkSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }
        client.documentManager.onMarkUnsyncedForTest = { marks.append($0, $1) }

        let documentId = try await create(
            client, options: CreateDocumentOptions(localOnly: true)
        )

        let started = Date()
        let doc = try await client.openDocument(documentId)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 5,
            "a local-only document is never on the server, so its open must resolve locally"
        )

        let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
        doc.transactSync { txn in
            notes.updateValue("stays here", forKey: "secret", transaction: txn)
        }
        await settle()

        XCTAssertTrue(
            sink.contentFrames.isEmpty,
            "no content or update frame may go out for a local-only document; sent: \(sink.all)"
        )
        XCTAssertFalse(marks.markedUnsynced(documentId))
    }

    // MARK: - Edge case: a commit that lands while the document was never opened

    func testCommitLandingWhileTheDocumentWasNeverOpenedIsSafe() async throws {
        let client = makeClient("created-doc-commit-unopened")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = try await create(client)

        client.documentManager.handlePendingCreateCommitted(documentId)
        await settle()

        XCTAssertFalse(client.isPendingCreate(documentId))
        XCTAssertTrue(
            sink.all.isEmpty,
            "there is no open document to sync, so the commit puts nothing on the wire; sent: \(sink.all)"
        )

        // …and the document still opens and writes normally afterwards.
        let doc = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
        doc.transactSync { txn in
            notes.updateValue("after the commit", forKey: "k", transaction: txn)
        }
        await settle()

        XCTAssertFalse(
            sink.contentFrames.isEmpty,
            "a document opened after its commit landed syncs like any other; sent: \(sink.all)"
        )
    }

    // MARK: - Edge case: an open of a created document that fails leaves nothing behind

    func testFailedFirstOpenOfACreatedDocumentLeavesNoHalfOpenEntry() async throws {
        // The first open of a created document now has origin `.created`, so
        // #2667's open-failure cleanup applies to it for the first time.
        let client = makeClient("created-doc-failed-open")
        defer { Task { await client.destroy() } }

        let documentId = try await create(client)

        do {
            _ = try await client.openDocument(
                documentId, options: OpenDocumentOptions(waitForLoad: .network)
            )
            XCTFail("a `.network` open against an unreachable server cannot be satisfied")
        } catch {
            let jsBaoError = try XCTUnwrap(error as? JsBaoError)
            XCTAssertTrue(
                [.documentUnavailableOffline, .connectionDisabled, .networkTimeout]
                    .contains(jsBaoError.code),
                "expected an availability fast-fail, got \(jsBaoError.code)"
            )
        }

        XCTAssertFalse(
            client.isDocumentOpen(documentId),
            "a failed open must not leave a half-open entry the next attempt would short-circuit to"
        )
        XCTAssertNil(client.getDoc(documentId))
        XCTAssertTrue(
            client.isPendingCreate(documentId),
            "the create's metadata survives the failed open, so a retry still has a document"
        )
    }

    // MARK: - Edge case: the permission bootstrap of a pending create is non-blocking

    func testFirstOpenOfAPendingCreateDoesNotAwaitThePermissionFetch() async throws {
        // The background `fetchDocumentInfo` 404s until the create commit
        // lands. The seeded permission has to stand, and the open must not
        // wait on the network for it.
        let client = makeClient("created-doc-permission-bootstrap")
        defer { Task { await client.destroy() } }

        let documentId = try await create(client)
        client.documentManager.fetchDocumentInfo = { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            throw JsBaoError(code: .notFound, message: "Document not found")
        }

        let started = Date()
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2,
            "the permission refresh runs in the background; the open must not await it"
        )
        XCTAssertFalse(
            client.documentManager.isReadOnly(documentId),
            "the seeded read-write permission stands while the fetch is outstanding"
        )
    }

    // MARK: - Edge case: a remote update on an opened created document is not echoed

    func testRemoteUpdateOnAnOpenedCreatedDocumentIsNotEchoedOutbound() async throws {
        let client = makeClient("created-doc-remote-echo")
        defer { Task { await client.destroy() } }
        let sink = FrameSink()
        client.documentManager.sendWebSocketMessage = { sink.append($0) }

        let documentId = try await create(client)
        let doc = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        client.documentManager.handlePendingCreateCommitted(documentId)

        // Encode a real update from a peer document.
        let peer = YDocument()
        let peerNotes: YMap<String> = peer.getOrCreateMap(named: "notes")
        peer.transactSync { txn in
            peerNotes.updateValue("from a peer", forKey: "k", transaction: txn)
        }
        let update: [UInt8] = peer.transactSync { txn in
            txn.transactionEncodeStateAsUpdate()
        }
        let base64 = Data(update).base64EncodedString()

        await client.handleWebSocketMessage(
            #"{"type":"update","documentId":"\#(documentId)","update":"\#(base64)"}"#
        )
        await settle()

        let notes: YMap<String> = doc.getOrCreateMap(named: "notes")
        let applied: String? = doc.transactSync { txn in
            notes.get(key: "k", transaction: txn)
        }
        XCTAssertEqual(applied, "from a peer", "precondition: the remote update was applied")
        XCTAssertTrue(
            sink.contentFrames.isEmpty,
            "a remote update must not be echoed back to the server; sent: \(sink.all)"
        )
    }
}
