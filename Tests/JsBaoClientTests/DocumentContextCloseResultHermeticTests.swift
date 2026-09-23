import XCTest
@testable import JsBaoClient

/// `DocumentContext.close` must report what `client.closeDocument` decided
/// (#3589).
///
/// The eviction guard from #961/#2668 lives in `client.closeDocument`: an
/// `evictLocal` close keeps the local data and reports `evicted: false` while
/// the server is still missing this client's writes. `client.closeDocument`
/// returns that verdict and `DocumentsAPI.close` forwards it; the per-document
/// handle dropped it on the floor, so a caller holding a handle could not tell
/// a skipped eviction from one that went through.
///
/// Server-free: the skipped close runs offline against an unreachable socket,
/// and the confirmed close runs against an in-process loopback WebSocket
/// server whose `stateVectorCheck` answer is fed back through the client's own
/// message router.
final class DocumentContextCloseResultHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    /// A fresh database file path. `.sqlite(directory:)` takes the FILE path;
    /// the enclosing directory is what gets cleaned up.
    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "ctx-close-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeClient(
        storage: StorageConfig,
        wsUrl: String = "ws://127.0.0.1:1",
        offline: Bool = true
    ) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: wsUrl,
            appId: "document-context-close-test-app",
            token: "test-token",
            offline: offline,
            logLevel: .none,
            storageConfig: storage,
            autoNetwork: false
        ))
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    // MARK: - Behavior 1: the handle reports the verdict

    /// The socket is down, so the server cannot have confirmed anything: the
    /// close keeps the local data and the handle must say so.
    func testCloseThroughTheHandleReportsEvictedFalseWhenTheServerHasNotConfirmed() async throws {
        let client = makeClient(storage: .memory)
        defer { Task { await client.destroy() } }

        let documentId = "ctx-unconfirmed-\(UUID().uuidString.prefix(8))"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "unconfirmed", localOnly: true
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        let result = await client.document(documentId).close(
            options: CloseDocumentOptions(evictLocal: true)
        )

        XCTAssertFalse(
            result.evicted,
            "DocumentContext.close must report evicted:false when the server has not "
            + "confirmed the writes — the skipped eviction is otherwise invisible here (#3589)"
        )
        XCTAssertNotNil(
            client.documentManager.getMetadataIndex()[documentId],
            "precondition: nothing was evicted, so the metadata row is still there"
        )
    }

    /// The other half of the same claim: when the server confirms the writes
    /// the eviction goes through, and the handle reports `evicted: true`.
    func testCloseThroughTheHandleReportsEvictedTrueWhenTheEvictionGoesThrough() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient(
            storage: .sqlite(directory: newDatabasePath()),
            wsUrl: wsBase(url),
            offline: false
        )
        defer { Task { await client.destroy() } }
        _ = await client.waitForStorageReady()
        try await client.connect()

        let documentId = "ctx-confirmed-\(UUID().uuidString.prefix(8))"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "confirmed", localOnly: true
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        let provider = await client.documentManager.offlineStore?.getStorageProvider()
        let storage = try XCTUnwrap(provider, "storage provider never became available")
        let persistence = YjsSQLitePersistence(storageProvider: storage, documentId: documentId)
        try await persistence.saveDocument(data: Data([4, 5, 6]))

        // Answer the close's `stateVectorCheck` the way a server that holds
        // every write does. The waiter is parked before the frame goes out, so
        // a frame on the wire means the response has somewhere to land.
        let responder = Task {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let asked = server.receivedFrames.contains {
                    $0.contains("\"stateVectorCheck\"") && $0.contains(documentId)
                }
                if asked {
                    await client.handleWebSocketMessage("""
                    {"type":"stateVectorCheckResponse","documentId":"\(documentId)",\
                    "includesWrites":true,"inSync":true}
                    """)
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        defer { responder.cancel() }

        let result = await client.document(documentId).close(
            options: CloseDocumentOptions(evictLocal: true)
        )

        XCTAssertTrue(
            server.receivedFrames.contains {
                $0.contains("\"stateVectorCheck\"") && $0.contains(documentId)
            },
            "precondition: the close asked the server for its verdict, so the eviction "
            + "below went through the guard rather than around it"
        )
        XCTAssertTrue(
            result.evicted,
            "DocumentContext.close must report evicted:true when the confirmed eviction "
            + "went through (#3589)"
        )
        let record: StorageRecord<Data>? = try await storage.get(
            store: YjsSQLitePersistence.store, key: documentId
        )
        XCTAssertNil(
            record,
            "precondition: the reported eviction really deleted the local CRDT bytes"
        )
    }

    // MARK: - Edge case: the handle outlives its client

    /// `DocumentContext` holds its client weakly. With the client gone there is
    /// nothing to close and nothing was evicted — the same verdict
    /// `DocumentsAPI.close` reports for its own nil client.
    func testCloseReportsNotEvictedWhenTheHandleOutlivesItsClient() async throws {
        weak var released: JsBaoClient?
        var handle: DocumentContext?
        do {
            let client = makeClient(storage: .memory)
            released = client
            handle = client.document("ctx-orphan-\(UUID().uuidString.prefix(8))")
            await client.destroy()
        }
        let context = try XCTUnwrap(handle)
        handle = nil
        try await waitFor("the client to be released") { released == nil }

        let result = await context.close(options: CloseDocumentOptions(evictLocal: true))

        XCTAssertFalse(
            result.evicted,
            "a handle whose client is gone evicted nothing, so it must report evicted:false"
        )
    }

    // MARK: - Behavior 2: existing call sites keep compiling

    /// `@discardableResult`, so `await ctx.close()` — the shape every existing
    /// caller uses — keeps compiling without a `result of call … is unused
    /// [#no-usage]` warning. The attribute has no runtime trace, so the claim
    /// is read off the declaration, as the suite's other compiler-adjacent
    /// invariants are.
    func testCloseIsMarkedDiscardableResult() throws {
        let source = try ClientSourceText.clientSource("JsBaoClient.swift")
        // `public func close(` appears once in this file: the handle's own
        // close. `closeDocument(` does not match it — the paren is part of the
        // needle.
        let attributes = ClientSourceText.attributes(before: "public func close(", in: source)
        XCTAssertTrue(
            attributes.contains("@discardableResult"),
            """
            DocumentContext.close returns a CloseDocumentResult, so without \
            @discardableResult every existing `await ctx.close()` call site \
            takes a new [#no-usage] warning (#3589). Found: \(attributes)
            """
        )
    }

    /// And the call site itself: this statement drops the result, which is
    /// exactly what the attribute exists to allow.
    func testAnExistingStyleCallSiteStillCompilesWithTheResultDiscarded() async throws {
        let client = makeClient(storage: .memory)
        defer { Task { await client.destroy() } }

        let documentId = "ctx-discard-\(UUID().uuidString.prefix(8))"
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "discard", localOnly: true
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        await client.document(documentId).close()

        XCTAssertNil(
            client.getDoc(documentId),
            "the discarded close still closed the document"
        )
    }

    /// The same claim one level down, where it is currently false: the
    /// `@discardableResult` written for `client.closeDocument` was orphaned
    /// onto `discardQueuedOutboundUpdates` when that `Void` helper was inserted
    /// between the attribute and the declaration it belongs to. The attribute
    /// binds to the next declaration, so `closeDocument` lost it — 34 call
    /// sites across this suite take a `result of call … is unused [#no-usage]`
    /// warning and the published trees no longer build warning-free, which is
    /// what `pnpm swift:check:warnings` fails on.
    func testClientCloseDocumentCarriesItsDiscardableResultAttribute() throws {
        let source = try ClientSourceText.clientSource("JsBaoClient.swift")
        XCTAssertTrue(
            ClientSourceText.attributes(before: "public func closeDocument(", in: source)
                .contains("@discardableResult"),
            """
            `client.closeDocument` returns a CloseDocumentResult that most \
            callers ignore, so it must carry @discardableResult — otherwise \
            every plain `await client.closeDocument(id)` warns [#no-usage].
            """
        )
        XCTAssertFalse(
            ClientSourceText.attributes(before: "func discardQueuedOutboundUpdates(", in: source)
                .contains("@discardableResult"),
            """
            `discardQueuedOutboundUpdates` returns Void, so an @discardableResult \
            on it is both meaningless ("declared on a function returning 'Void' \
            is unnecessary") and a sign the attribute was taken from the \
            declaration below it.
            """
        )
    }
}
