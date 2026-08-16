import XCTest
@testable import JsBaoClient

/// #2667 (parity C19) — `openDocument` must bootstrap the document's
/// permission the way JS does (`documentManager._openCore`): seed
/// `read-write` immediately, then refresh from the server in the background
/// and cache what comes back.
///
/// Without it a reader opening a document on a fresh device has no permission
/// entry at all until some server frame happens to supply one, so `isReadOnly`
/// answers `false` for a document they cannot write.
///
/// Server-free (`*HermeticTests`): the `fetchDocumentInfo` hook is injected,
/// which is the same seam `JsBaoClient` wires to `documents.get`.
final class OpenPermissionBootstrapHermeticTests: XCTestCase {

    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
    }

    private func makeClient() -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "permission-bootstrap-hermetic-app",
            token: "test-token",
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        clients.append(client)
        return client
    }

    private func newDocId(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    /// `DocumentInfo` decodes from the server payload and has no memberwise
    /// initializer, so the stand-in document info is built the same way the
    /// real one arrives.
    private func documentInfo(
        documentId: String,
        permission: String
    ) throws -> DocumentInfo {
        let json = """
        {
          "documentId": "\(documentId)",
          "title": "bootstrap",
          "permission": "\(permission)"
        }
        """
        return try JSONDecoder().decode(DocumentInfo.self, from: Data(json.utf8))
    }

    /// A document opened locally, with no network wait to satisfy.
    private func openLocally(_ client: JsBaoClient, _ docId: String) async throws {
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local,
            enableNetworkSync: false
        ))
    }

    /// Behavior 6a — with nothing cached, the open seeds `read-write` so the
    /// caller is not left with "no permission at all" while the refresh is in
    /// flight. The hook here never returns, which is what a slow or
    /// unreachable server looks like.
    func testOpenSeedsReadWritePermissionWhenNothingIsCached() async throws {
        let client = makeClient()
        let docId = newDocId("seed")

        client.documentManager.fetchDocumentInfo = { _ in
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            throw JsBaoError(code: .unavailable)
        }

        try await openLocally(client, docId)

        XCTAssertEqual(
            client.documentManager.getPermission(docId), .readWrite,
            "open left the document with no permission entry"
        )
        XCTAssertFalse(client.isDocumentReadOnly(docId))
    }

    /// Behavior 6b — the background refresh runs, and the permission it
    /// returns both drives `isReadOnly` and is cached in local metadata with
    /// `permissionCachedAt`.
    func testBackgroundRefreshCachesTheFetchedPermission() async throws {
        let client = makeClient()
        let docId = newDocId("refresh")

        let info = try documentInfo(documentId: docId, permission: "reader")
        client.documentManager.fetchDocumentInfo = { _ in info }

        try await openLocally(client, docId)

        try await eventually(description: "permission refresh to land") {
            client.documentManager.getPermission(docId) == .reader
        }
        XCTAssertTrue(
            client.isDocumentReadOnly(docId),
            "a reader's document is still reported writable after the refresh"
        )

        let meta = client.documentManager.getLocalMetadata(docId)
        XCTAssertEqual(meta?.lastKnownPermission, "reader")
        XCTAssertNotNil(
            meta?.permissionCachedAt,
            "the cached permission has no age for callers to judge it by"
        )
    }

    /// Edge case — the seed must not overwrite a reader grant restored from
    /// local metadata. A reader reopening offline keeps the permission the
    /// last refresh cached, rather than being told they may write.
    func testSeedDoesNotClobberACachedReaderPermission() async throws {
        let client = makeClient()
        let docId = newDocId("cached-reader")

        let info = try documentInfo(documentId: docId, permission: "reader")
        client.documentManager.fetchDocumentInfo = { _ in info }
        try await openLocally(client, docId)
        try await eventually(description: "permission refresh to land") {
            client.documentManager.getPermission(docId) == .reader
        }
        await client.closeDocument(docId)
        // Drop the in-memory permission the way a fresh process would, so the
        // reopen has nothing but the persisted metadata to go on.
        client.documentManager.removeOpenDoc(docId)

        // Reopen with a refresh that never answers: the answer has to come
        // from what the first open cached.
        client.documentManager.fetchDocumentInfo = { _ in
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            throw JsBaoError(code: .unavailable)
        }
        try await openLocally(client, docId)

        XCTAssertEqual(
            client.documentManager.getPermission(docId), .reader,
            "the open-time read-write seed clobbered the cached reader permission"
        )
        XCTAssertTrue(client.isDocumentReadOnly(docId))
    }
}
