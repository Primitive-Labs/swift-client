import XCTest
@testable import JsBaoClient

/// A background `syncMetadata` still in flight at logout must never write the
/// signed-out user's documents into the cache the next user reads (#4150).
///
/// Swift mirror of `tests/client/js-bao-client-logout-background-refresh-4150.test.ts`.
/// JS is the reference: a sync reads the signed-in session when it starts and
/// drops its answer when a logout or a user switch has happened since.
///
/// Server-free (`*HermeticTests`): a `LoopbackAPIServer` answers the client's
/// real HTTP requests and holds the sync's answer until the test releases it,
/// so the order — request sent as A, logout, answer — is fixed rather than a
/// timing guess.
final class SyncMetadataLogoutFenceHermeticTests: XCTestCase {
    private static let userA = "user-a"
    private static let userB = "user-b"
    private static let docA = "doc-a-owned"
    private static let docB = "doc-b-owned"

    private var clients: [JsBaoClient] = []
    private var servers: [LoopbackAPIServer] = []
    private var heldAnswers: [HeldAnswer] = []

    override func tearDown() async throws {
        for held in heldAnswers { held.release() }
        heldAnswers = []
        for client in clients { await client.destroy() }
        clients = []
        for server in servers { server.stop() }
        servers = []
    }

    // MARK: - Fixture

    /// The answer to one request, sent only once `release()` is called.
    private final class HeldAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var send: (@Sendable () -> Void)?
        private var issued = false
        private var released = false

        func hold(_ send: @escaping @Sendable () -> Void) {
            let sendNow = lock.withLock { () -> Bool in
                issued = true
                if released { return true }
                self.send = send
                return false
            }
            if sendNow { send() }
        }

        var isIssued: Bool { lock.withLock { issued } }

        func release() {
            let pending = lock.withLock { () -> (@Sendable () -> Void)? in
                released = true
                defer { send = nil }
                return send
            }
            pending?()
        }
    }

    /// Lets only the first matching request through to the hold.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func take() -> Bool {
            lock.withLock {
                if fired { return false }
                fired = true
                return true
            }
        }
    }

    /// A client signed in as A whose first `GET <heldPath>` is answered with
    /// `heldAnswer` only on `held.release()`. Otherwise both document lists
    /// are empty; everything else is a 404.
    private func makeClient(
        appId: String,
        heldPath: String,
        heldAnswer: LoopbackAPIServer.Response
    ) async throws -> (JsBaoClient, HeldAnswer) {
        let held = HeldAnswer()
        heldAnswers.append(held)
        let once = Once()
        let server = try LoopbackAPIServer(deferredResponder: { request, respond in
            let path = request.apiPathOnly
            if request.method == "GET", path == heldPath, once.take() {
                held.hold { respond(heldAnswer) }
                return
            }
            if path == "/me/owned-documents" || path == "/me/shared-documents" {
                respond(.json(Self.page("")))
                return
            }
            respond(.status(404, "unscripted path \(path)"))
        })
        let baseUrl = try server.start()
        servers.append(server)

        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: baseUrl,
            // Nothing in these tests needs a socket.
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            token: makeTestJwt(userId: Self.userA),
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        clients.append(client)
        let storageReady = await client.waitForStorageReady()
        XCTAssertTrue(storageReady)
        XCTAssertEqual(client.documentManager.userId, Self.userA)
        return (client, held)
    }

    /// One page of the `{ items, hasMore }` envelope the document lists answer.
    private static func page(_ rows: String) -> String {
        #"{"items":[\#(rows)],"hasMore":false}"#
    }

    private static func ownedRow(_ id: String, _ title: String) -> String {
        #"{"documentId":"\#(id)","title":"\#(title)","permission":"owner"}"#
    }

    /// B signs in on the same client without a relaunch, and has one document
    /// of their own cached.
    private func signInAsB(_ client: JsBaoClient) async {
        client.updateToken(makeTestJwt(userId: Self.userB))
        await client.rebindUserScopedStorage()
        XCTAssertEqual(client.documentManager.userId, Self.userB)
        await client.documentManager.handleServerDocuments([
            ["documentId": Self.docB, "title": "B's document", "permission": "owner"]
        ])
    }

    private func waitUntilIssued(_ held: HeldAnswer) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !held.isIssued {
            guard Date() < deadline else {
                XCTFail("the sync's request never reached the server")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The released answer reaches the client over loopback; give the
    /// background sync time to write it, as the JS test does.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// What B can see: the cached row, and the local-first owned list.
    private func assertBSeesNoneOfA(
        _ client: JsBaoClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertNil(
            client.documentManager.getLocalMetadata(Self.docA),
            "the signed-out user's document reached the next user's cache",
            file: file, line: line
        )
        let owned = try await client.me.ownedDocuments(
            options: MeOwnedDocumentsOptions(refreshFromServer: false, waitForLoad: .local)
        )
        XCTAssertFalse(
            owned.map(\.documentId).contains(Self.docA),
            "the next user's local-first owned list holds the previous user's document",
            file: file, line: line
        )
        XCTAssertNotNil(
            client.documentManager.getLocalMetadata(Self.docB),
            "the next user's own document must survive the previous user's answer",
            file: file, line: line
        )
    }

    // MARK: - The listing path

    func test_listingAnsweredAfterSignOut_neverReachesTheNextUser() async throws {
        let (client, held) = try await makeClient(
            appId: "sync-fence-listing-signout",
            heldPath: "/me/owned-documents",
            heldAnswer: .json(Self.page(Self.ownedRow(Self.docA, "A's document")))
        )

        try await client.syncMetadata(options: SyncMetadataOptions(background: true))
        try await waitUntilIssued(held)

        try await client.logout()
        held.release()
        try await settle()

        await signInAsB(client)
        try await assertBSeesNoneOfA(client)
    }

    func test_listingAnsweredAfterNextSignIn_neverReachesTheNextUser() async throws {
        let (client, held) = try await makeClient(
            appId: "sync-fence-listing-signin",
            heldPath: "/me/owned-documents",
            heldAnswer: .json(Self.page(Self.ownedRow(Self.docA, "A's document")))
        )

        try await client.syncMetadata(options: SyncMetadataOptions(background: true))
        try await waitUntilIssued(held)

        try await client.logout()
        await signInAsB(client)
        held.release()
        try await settle()

        try await assertBSeesNoneOfA(client)
    }

    /// An ids listing defers its evictions to a per-document check. A's
    /// listing not mentioning B's document says nothing about it, so the
    /// check must not run against B's cache at all.
    func test_idsListingAnsweredAfterNextSignIn_neverEvictsTheNextUsersDocuments() async throws {
        let (client, held) = try await makeClient(
            appId: "sync-fence-ids-signin",
            heldPath: "/me/owned-documents",
            heldAnswer: .json(Self.page(#"{"documentId":"\#(Self.docA)"}"#))
        )

        try await client.syncMetadata(
            options: SyncMetadataOptions(payloadType: "ids", background: true)
        )
        try await waitUntilIssued(held)

        try await client.logout()
        await signInAsB(client)
        held.release()
        try await settle()

        try await assertBSeesNoneOfA(client)
        XCTAssertFalse(
            servers[0].paths.contains { $0.hasPrefix("/documents/\(Self.docB)") },
            "A's listing sent B's document to the eviction check"
        )
    }

    /// The fence must hold inside the merge, not only in front of it: A's
    /// listing passed the check while A was signed in, and its merge suspends
    /// on each row's persist. Logout and B's sign-in land in that suspension;
    /// the rows still to come and the authoritative eviction pass that follows
    /// them belong to A and must not touch B's cache or B's storage.
    func test_listingMergeSuspendedAcrossNextSignIn_neverReachesTheNextUser() async throws {
        let docA2 = "doc-a-owned-2"
        let (client, held) = try await makeClient(
            appId: "sync-fence-listing-mid-merge",
            heldPath: "/me/owned-documents",
            heldAnswer: .json(
                Self.page("\(Self.ownedRow(Self.docA, "A's document")),\(Self.ownedRow(docA2, "A's other document"))")
            )
        )
        held.release()

        let persistHeld = HeldAnswer()
        heldAnswers.append(persistHeld)
        let firstRow = Once()
        client.documentManager.onServerDocumentPersistedForTest = { documentId in
            guard documentId == Self.docA, firstRow.take() else { return }
            await withCheckedContinuation { continuation in
                persistHeld.hold { continuation.resume() }
            }
        }

        try await client.syncMetadata(options: SyncMetadataOptions(background: true))
        try await waitUntilIssued(persistHeld)

        try await client.logout()
        await signInAsB(client)
        persistHeld.release()
        try await settle()

        XCTAssertNil(
            client.documentManager.getLocalMetadata(docA2),
            "a row merged after the user switch reached the next user's cache"
        )
        try await assertBSeesNoneOfA(client)
        let storedForB = try await client.documentManager.offlineStore?.loadAllMetadata(
            appId: "sync-fence-listing-mid-merge", userId: Self.userB
        ) ?? []
        XCTAssertEqual(
            storedForB.map(\.documentId).sorted(), [Self.docB],
            "the previous user's rows were persisted under the next user"
        )
    }

    // MARK: - The single-document path

    /// A's single-document answer says A lost the document. B, who has it
    /// cached, has not.
    func test_singleDocumentDenialAnsweredAfterNextSignIn_neverEvictsTheNextUsersRow() async throws {
        let (client, held) = try await makeClient(
            appId: "sync-fence-single-denial",
            heldPath: "/documents/\(Self.docB)",
            heldAnswer: .status(403, "Forbidden")
        )

        try await client.syncMetadata(
            options: SyncMetadataOptions(documentId: Self.docB, background: true)
        )
        try await waitUntilIssued(held)

        try await client.logout()
        await signInAsB(client)
        held.release()
        try await settle()

        try await assertBSeesNoneOfA(client)
    }

    func test_singleDocumentAnsweredAfterSignOut_neverReachesTheNextUser() async throws {
        let (client, held) = try await makeClient(
            appId: "sync-fence-single-signout",
            heldPath: "/documents/\(Self.docA)",
            heldAnswer: .json(Self.ownedRow(Self.docA, "A's document"))
        )

        try await client.syncMetadata(
            options: SyncMetadataOptions(documentId: Self.docA, background: true)
        )
        try await waitUntilIssued(held)

        try await client.logout()
        held.release()
        try await settle()

        await signInAsB(client)
        try await assertBSeesNoneOfA(client)
    }

    func test_singleDocumentAnsweredAfterNextSignIn_neverReachesTheNextUser() async throws {
        let (client, held) = try await makeClient(
            appId: "sync-fence-single-signin",
            heldPath: "/documents/\(Self.docA)",
            heldAnswer: .json(Self.ownedRow(Self.docA, "A's document"))
        )

        try await client.syncMetadata(
            options: SyncMetadataOptions(documentId: Self.docA, background: true)
        )
        try await waitUntilIssued(held)

        try await client.logout()
        await signInAsB(client)
        held.release()
        try await settle()

        try await assertBSeesNoneOfA(client)
    }
}
