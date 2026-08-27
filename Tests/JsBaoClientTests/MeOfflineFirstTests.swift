import XCTest
@testable import JsBaoClient

/// Live integration coverage for the offline-first `me.ownedDocuments` /
/// `me.sharedDocuments` local/remote merge (#938 / #1058).
///
/// Contract under test (JS `_listImpl` is the source of truth):
///  - online: server rows win by documentId; locally-known docs the server
///    list didn't return are appended (e.g. localOnly / pendingCreate docs)
///  - offline / `localOnly` / `refreshFromServer: false`: local cache subset
///    only, no server call, no throw
///  - owned vs shared discriminated by the cached `permission`.
final class MeOfflineFirstTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-me-offline")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    /// Happy path: while ONLINE, a server-backed `ownedDocuments` returns the
    /// union of the server list (REST-created doc) and locally-known owned
    /// docs the server can't return (a `localOnly` doc that never syncs) —
    /// deduped by id.
    ///
    /// This asserts on `waitForLoad: .network` rather than the default.
    /// #2360 changed the default (`.localIfAvailableElseNetwork`) to js-bao's
    /// local-first meaning — a warm local cache answers immediately and the
    /// server refresh happens in the background — so the default no longer
    /// guarantees the server's rows are present at return time. `.network` is
    /// the mode that still means "wait for the server", which is what this
    /// merge assertion is about. The default's own contract is covered below
    /// and in `MeOwnedDocumentsLocalFirstTests`.
    func testOwnedDocumentsMergesServerAndLocalRows() async throws {
        let serverDocId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Server Owned Doc"
        )
        let (localDocId, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(
            title: "Local Only Owned Doc",
            localOnly: true
        ))

        try await client.connect()
        try await waitForConnection(client: client)

        let networkOptions = MeOwnedDocumentsOptions(waitForLoad: .network)
        let owned = try await client.me.ownedDocuments(options: networkOptions)
        let ids = owned.map { $0.documentId }
        XCTAssertTrue(ids.contains(serverDocId), "server-side doc missing from merged owned list")
        XCTAssertTrue(ids.contains(localDocId), "localOnly doc missing from merged owned list")
        XCTAssertEqual(
            ids.count, Set(ids).count,
            "merged owned list must be deduped by documentId"
        )

        // The page overload deliberately does NOT union the local-only rows
        // into the page (#2360): a page must not exceed `limit`, and a cursor
        // walk would otherwise see the same local-only rows repeated on every
        // page. js-bao returns its page before the equivalent merge
        // (`documentsApi.ts:1338-1340`). It carries the server's rows only.
        let page = try await client.me.ownedDocumentsPage(options: networkOptions)
        let pageIds = page.items.map { $0.documentId }
        XCTAssertTrue(pageIds.contains(serverDocId), "the paged form carries the server's rows")
        XCTAssertFalse(
            pageIds.contains(localDocId),
            "the paged form must not append unpaginated local-only rows"
        )
    }

    /// The default `waitForLoad` is local-first (#2360): with a warm local
    /// cache it answers from the cache — the locally-known doc is there — and
    /// refreshes in the background, so a later call also carries the server's
    /// rows.
    func testOwnedDocumentsDefaultIsLocalFirstThenRefreshes() async throws {
        let serverDocId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Server Doc For LocalFirst"
        )
        let (localDocId, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(
            title: "Warm Cache Doc",
            localOnly: true
        ))

        try await client.connect()
        try await waitForConnection(client: client)

        let first = try await client.me.ownedDocuments()
        XCTAssertTrue(
            first.map { $0.documentId }.contains(localDocId),
            "the warm local cache answers the default call"
        )

        // The background refresh writes the server rows into the local
        // metadata cache; a subsequent local-first call sees them.
        var sawServerDoc = false
        for _ in 0..<20 {
            let ids = try await client.me.ownedDocuments().map { $0.documentId }
            if ids.contains(serverDocId) {
                sawServerDoc = true
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(sawServerDoc, "background refresh never made the server row visible")
    }

    /// Edge: OFFLINE, `ownedDocuments` answers from the local cache only —
    /// no server call, no throw. The localOnly doc is present; the REST-created
    /// doc (never opened locally) is not.
    func testOwnedDocumentsOfflineServesLocalCacheOnly() async throws {
        let serverDocId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Server Doc Unseen Locally"
        )
        let (localDocId, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(
            title: "Offline Cached Doc",
            localOnly: true
        ))

        await client.goOffline()

        let owned = try await client.me.ownedDocuments()
        let ids = owned.map { $0.documentId }
        XCTAssertTrue(ids.contains(localDocId), "local cache row must surface offline")
        XCTAssertFalse(
            ids.contains(serverDocId),
            "a doc never seen locally cannot appear in the offline (cache-only) list"
        )
    }

    /// Edge: `localOnly: true` (and `refreshFromServer: false`) short-circuit
    /// to the local cache even while ONLINE — mirrors the JS `_listImpl`
    /// branches.
    func testOwnedDocumentsLocalOnlyOptionShortCircuits() async throws {
        let serverDocId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT, title: "Server Doc For ShortCircuit"
        )
        let (localDocId, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(
            title: "Local ShortCircuit Doc",
            localOnly: true
        ))

        try await client.connect()
        try await waitForConnection(client: client)

        var opts = MeOwnedDocumentsOptions()
        opts.localOnly = true
        let localOnlyList = try await client.me.ownedDocuments(options: opts)
        let localIds = localOnlyList.map { $0.documentId }
        XCTAssertTrue(localIds.contains(localDocId))
        XCTAssertFalse(
            localIds.contains(serverDocId),
            "options.localOnly must skip the server fetch entirely"
        )

        var noRefresh = MeOwnedDocumentsOptions()
        noRefresh.refreshFromServer = false
        let noRefreshIds = try await client.me.ownedDocuments(options: noRefresh).map { $0.documentId }
        XCTAssertTrue(noRefreshIds.contains(localDocId))
        XCTAssertFalse(noRefreshIds.contains(serverDocId))
    }

    /// `sharedDocuments` happy path: a doc another user shared with this user
    /// arrives from the server list (typed `{ items, cursor }` envelope) and
    /// is classified shared, not owned. Offline edge: the call answers from
    /// the cache without throwing and never contains owner rows.
    func testSharedDocumentsServerListAndOfflineSubset() async throws {
        // Second user creates a doc and shares it with the owner.
        let sharer = try await ctx.createTestUser(appId: testApp.appId, role: "member")
        let sharedDocId = try await ctx.createDocument(
            appId: testApp.appId, jwt: sharer.jwt, title: "Doc Shared With Owner"
        )
        try await ctx.grantPermission(
            appId: testApp.appId,
            documentId: sharedDocId,
            userId: testApp.ownerUserId,
            permission: "read-write",
            jwt: sharer.jwt
        )

        try await client.connect()
        try await waitForConnection(client: client)

        let shared = try await client.me.sharedDocuments()
        let sharedIds = shared.items.map { $0.document.documentId }
        XCTAssertTrue(sharedIds.contains(sharedDocId), "granted doc missing from sharedDocuments")

        // The shared doc must NOT be classified as owned. `.network` so the
        // assertion is about the server-backed list, not whatever the local
        // cache happens to hold (#2360 made the default local-first).
        let ownedIds = try await client.me.ownedDocuments(
            options: MeOwnedDocumentsOptions(waitForLoad: .network)
        ).map { $0.documentId }
        XCTAssertFalse(ownedIds.contains(sharedDocId), "shared doc leaked into ownedDocuments")

        // Offline: cache-only subset, no throw, no owner rows.
        let (myLocalDocId, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(
            title: "My Own Local Doc",
            localOnly: true
        ))
        await client.goOffline()
        let offlineShared = try await client.me.sharedDocuments()
        let offlineIds = offlineShared.items.map { $0.document.documentId }
        XCTAssertFalse(
            offlineIds.contains(myLocalDocId),
            "owned local doc must not appear in the offline shared list"
        )
        XCTAssertNil(offlineShared.cursor, "offline cache page carries no cursor")
    }
}
