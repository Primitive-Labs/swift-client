import XCTest
@testable import JsBaoClient

/// `me.ownedDocuments` / `ownedDocumentsPage` local-first resolution (#2360).
///
/// `waitForLoad` and `serverTimeout` were declared on
/// `MeOwnedDocumentsOptions` and never read: every online call was a blocking
/// server fetch. These tests pin the resolution order the sponsor chose —
/// JS-parity local-first by default, with `.local` / `.network` as the
/// explicit escapes and a bounded, always-throwing `serverTimeout`.
final class MeOwnedDocumentsLocalFirstTests: XCTestCase {

    // MARK: - Fixtures

    /// A stand-in for `DocumentManager`'s metadata index: readable as the
    /// `localMetadata` snapshot and writable by the background refresh, so a
    /// "the next call is fresh" assertion is possible without a live client.
    final class MetadataStore: @unchecked Sendable {
        private let lock = NSLock()
        private var index: [String: LocalMetadataEntry] = [:]
        /// documentIds handed to `syncServerDocuments`, in call order.
        private(set) var synced: [[String]] = []

        init(_ entries: [LocalMetadataEntry] = []) {
            for entry in entries { index[entry.documentId] = entry }
        }

        func snapshot() -> [String: LocalMetadataEntry] {
            lock.withLock { index }
        }

        func merge(_ docs: [DocumentInfo]) {
            lock.withLock {
                synced.append(docs.map { $0.documentId })
                for doc in docs {
                    index[doc.documentId] = LocalMetadataEntry(
                        documentId: doc.documentId,
                        title: doc.title,
                        permission: doc.permission.rawValue
                    )
                }
            }
        }

        var syncCallCount: Int { lock.withLock { synced.count } }
    }

    private static func ownedEntry(_ id: String) -> LocalMetadataEntry {
        LocalMetadataEntry(documentId: id, title: "Local \(id)", permission: "owner")
    }

    /// The app root as it appears in the local metadata cache. Its real
    /// permission is `read-write` (never `owner`, #875), but a stale row can
    /// claim `owner` — hence the `permission` knob: the root is filtered by
    /// identity (id / `__ROOT_TAG__`), not by permission.
    private static func rootEntry(
        _ id: String = rootId,
        permission: String = "read-write"
    ) -> LocalMetadataEntry {
        LocalMetadataEntry(
            documentId: id,
            title: "Root",
            permission: permission,
            tags: ["__ROOT_TAG__"]
        )
    }

    private static let rootId = "root-doc"

    /// A transport whose response is held until the gate opens — a blocking
    /// fetch would never return, so a returned result proves the local path.
    private static func gatedTransport(_ gate: Gate, json: String) -> RecordingTransport {
        RecordingTransport(responder: { _ in
            await gate.wait()
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(json.utf8)
            )
        })
    }

    private static let serverPage = #"{"items":[{"documentId":"srv1","title":"Server Doc","permission":"owner"}]}"#

    /// A server page carrying a cursor — what a real paged fetch returns.
    private static let serverPageWithCursor = #"{"items":[{"documentId":"srv1","title":"Server Doc","permission":"owner"}],"cursor":"next-cursor"}"#

    /// A server page that also carries the app root (what
    /// `?includeRoot=true` returns — and what a stale server could return
    /// without it).
    private static let serverPageWithRoot = #"{"items":[{"documentId":"srv1","title":"Server Doc","permission":"owner"},{"documentId":"root-doc","title":"Root","permission":"read-write","tags":["__ROOT_TAG__"]}]}"#

    /// Wire a `MeAPI` over a recording transport plus a metadata store.
    private func makeAPI(
        store: MetadataStore,
        transport: RecordingTransport,
        isOnline: Bool = true,
        rootDocId: String? = nil
    ) -> MeAPI {
        MeAPI(
            transport: transport,
            localMetadata: { store.snapshot() },
            isOnline: { isOnline },
            syncServerDocuments: { docs in store.merge(docs) },
            rootDocId: { rootDocId }
        )
    }

    // MARK: - Behavior 4: local-first default with a warm cache

    func testDefaultReturnsLocalRowsAndRefreshesInBackground() async throws {
        let store = MetadataStore([Self.ownedEntry("local1")])
        let transport = RecordingTransport(json: Self.serverPage)
        let api = makeAPI(store: store, transport: transport)

        let first = try await api.ownedDocuments()
        XCTAssertEqual(
            first.map { $0.documentId }, ["local1"],
            "default waitForLoad with a warm cache answers from the local cache"
        )

        await api.awaitBackgroundRefresh()
        XCTAssertEqual(store.synced, [["srv1"]], "exactly one background refresh, merged into the cache")

        // The cache now carries the server row, so the next local-first call
        // reflects it.
        let second = try await api.ownedDocuments()
        XCTAssertEqual(Set(second.map { $0.documentId }), ["local1", "srv1"])
    }

    /// Edge: overlapping local-first calls share one refresh rather than
    /// spawning a second concurrent fetch.
    func testOverlappingCallsSpawnOneBackgroundRefresh() async throws {
        let store = MetadataStore([Self.ownedEntry("local1")])
        let gate = Gate()
        let transport = RecordingTransport(responder: { _ in
            await gate.wait()
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(Self.serverPage.utf8)
            )
        })
        let api = makeAPI(store: store, transport: transport)

        _ = try await api.ownedDocuments()
        _ = try await api.ownedDocuments()
        _ = try await api.ownedDocuments()
        await gate.open()
        await api.awaitBackgroundRefresh()

        XCTAssertEqual(transport.calls.count, 1, "one refresh in flight at a time")
    }

    // MARK: - Behavior 5: cold cache falls through to the server

    func testDefaultWithEmptyCacheFetchesFromServer() async throws {
        let store = MetadataStore()
        let transport = RecordingTransport(json: Self.serverPage)
        let api = makeAPI(store: store, transport: transport)

        let items = try await api.ownedDocuments()

        XCTAssertEqual(items.map { $0.documentId }, ["srv1"])
        XCTAssertEqual(transport.calls.count, 1, "a cold cache blocks on the server")
        XCTAssertEqual(transport.lastCall?.path, "/me/owned-documents")
    }

    // MARK: - Behavior 6: the cache-only options

    func testLocalPathsIssueNoRequest() async throws {
        for options in [
            MeOwnedDocumentsOptions(localOnly: true),
            MeOwnedDocumentsOptions(refreshFromServer: false),
            MeOwnedDocumentsOptions(waitForLoad: .local),
        ] {
            let store = MetadataStore([Self.ownedEntry("local1")])
            let transport = RecordingTransport(json: Self.serverPage)
            let api = makeAPI(store: store, transport: transport)

            let items = try await api.ownedDocuments(options: options)

            XCTAssertEqual(items.map { $0.documentId }, ["local1"])
            XCTAssertTrue(transport.calls.isEmpty, "\(options) must issue no request")
            await api.awaitBackgroundRefresh()
            XCTAssertEqual(store.syncCallCount, 0, "\(options) must not refresh in the background")
        }
    }

    /// Edge: `limit` / `cursor` are ignored on a local path (the cache isn't
    /// paginated) and the returned cursor is nil — no throw.
    func testLocalPathIgnoresPaginationOptions() async throws {
        let store = MetadataStore([Self.ownedEntry("local1"), Self.ownedEntry("local2")])
        let transport = RecordingTransport(json: Self.serverPage)
        let api = makeAPI(store: store, transport: transport)

        let page = try await api.ownedDocumentsPage(
            cursor: "c1",
            limit: 1,
            options: MeOwnedDocumentsOptions(localOnly: true)
        )

        XCTAssertEqual(page.items.count, 2)
        XCTAssertNil(page.cursor)
    }

    // MARK: - Behavior 7: offline

    func testOfflineDefaultServesCacheAndNetworkModeThrows() async throws {
        let store = MetadataStore([Self.ownedEntry("local1")])
        let transport = RecordingTransport(json: Self.serverPage)
        let api = makeAPI(store: store, transport: transport, isOnline: false)

        let items = try await api.ownedDocuments()
        XCTAssertEqual(items.map { $0.documentId }, ["local1"])
        XCTAssertTrue(transport.calls.isEmpty)
        await api.awaitBackgroundRefresh()
        XCTAssertEqual(store.syncCallCount, 0, "offline spawns no background refresh")

        do {
            _ = try await api.ownedDocuments(
                options: MeOwnedDocumentsOptions(waitForLoad: .network)
            )
            XCTFail("waitForLoad: .network must throw while offline")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .listUnavailableOffline)
        }
    }

    /// Edge: a `MeAPI` built in isolation (no metadata, no client) has an
    /// empty local set, so the default path degrades to the network fetch.
    func testIsolatedConstructionFallsBackToNetwork() async throws {
        let transport = RecordingTransport(json: Self.serverPage)
        let api = MeAPI(transport: transport)

        let items = try await api.ownedDocuments()

        XCTAssertEqual(items.map { $0.documentId }, ["srv1"])
    }

    // MARK: - Behavior 8: serverTimeout

    func testNetworkModeTimesOutWithTypedError() async throws {
        let store = MetadataStore([Self.ownedEntry("local1")])
        let transport = RecordingTransport(responder: { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return TransportResponse(status: 200, headers: [:], body: Data())
        })
        let api = makeAPI(store: store, transport: transport)

        let started = Date()
        do {
            _ = try await api.ownedDocuments(
                options: MeOwnedDocumentsOptions(serverTimeout: 0.1, waitForLoad: .network)
            )
            XCTFail("a stalled fetch must throw .listTimeout, not hang")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .listTimeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    /// `serverTimeout: 0` is unbounded — the in-Swift `KvCache` reading of
    /// the same option (`KvCache.swift`), documented on the field.
    func testZeroServerTimeoutIsUnbounded() async throws {
        let store = MetadataStore([Self.ownedEntry("local1")])
        let transport = RecordingTransport(responder: { _ in
            try await Task.sleep(nanoseconds: 250_000_000)
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(Self.serverPage.utf8)
            )
        })
        let api = makeAPI(store: store, transport: transport)

        let items = try await api.ownedDocuments(
            options: MeOwnedDocumentsOptions(serverTimeout: 0, waitForLoad: .network)
        )

        XCTAssertEqual(Set(items.map { $0.documentId }), ["local1", "srv1"])
    }

    // MARK: - Behavior 9: a failed background refresh is silent

    func testBackgroundRefreshFailureIsSilent() async throws {
        let store = MetadataStore([Self.ownedEntry("local1")])
        let transport = RecordingTransport(status: 500, json: #"{"error":"boom"}"#)
        let api = makeAPI(store: store, transport: transport)

        let items = try await api.ownedDocuments()
        XCTAssertEqual(items.map { $0.documentId }, ["local1"], "the caller's result stands")

        await api.awaitBackgroundRefresh()
        XCTAssertEqual(store.syncCallCount, 0, "a failed refresh writes nothing")

        // The API is still usable afterwards — the failure left no stuck state.
        let again = try await api.ownedDocuments()
        XCTAssertEqual(again.map { $0.documentId }, ["local1"])
    }

    // MARK: - Edge case 1: the root doc is filtered the same on every path

    /// The local-first default must apply the same root predicate the network
    /// path does (#848): a warm cache holding the app root does not surface it
    /// from `me.ownedDocuments()`.
    func testWarmCacheDefaultFiltersRootDocument() async throws {
        // The root row here claims `owner` — the shape a stale cache row can
        // take — so the assertion below can only pass on an identity-based
        // filter, not on the owner predicate.
        let store = MetadataStore([
            Self.ownedEntry("local1"),
            Self.rootEntry(permission: "owner"),
        ])
        // The gate holds the server response open, so a result that comes
        // back at all proves this answered from the cache rather than the
        // network — the branch `RootDocTests` can't reach with a cold cache.
        let gate = Gate()
        let transport = Self.gatedTransport(gate, json: Self.serverPage)
        let api = makeAPI(store: store, transport: transport, rootDocId: Self.rootId)

        let items = try await api.ownedDocuments()

        XCTAssertEqual(
            items.map { $0.documentId }, ["local1"],
            "the root doc must not leak through the warm-cache local path"
        )
        await gate.open()
        await api.awaitBackgroundRefresh()
    }

    /// Mirror direction: `includeRoot: true` on a warm cache that *has* the
    /// root returns it locally, even though its permission is `read-write`
    /// rather than `owner` (#875).
    func testWarmCacheIncludeRootReturnsRootLocally() async throws {
        let store = MetadataStore([Self.ownedEntry("local1"), Self.rootEntry()])
        let gate = Gate()
        let transport = Self.gatedTransport(gate, json: Self.serverPage)
        let api = makeAPI(store: store, transport: transport, rootDocId: Self.rootId)

        let items = try await api.ownedDocuments(
            options: MeOwnedDocumentsOptions(includeRoot: true)
        )

        XCTAssertEqual(
            Set(items.map { $0.documentId }), ["local1", Self.rootId],
            "the cache had the root — answered locally, no blocking fetch"
        )
        await gate.open()
        await api.awaitBackgroundRefresh()
        XCTAssertEqual(
            transport.lastCall?.path, "/me/owned-documents?includeRoot=true",
            "the background refresh carries includeRoot too"
        )
    }

    /// Mirror direction, cache miss: `includeRoot: true` with a warm cache
    /// that lacks the root falls through to the server rather than answering
    /// with a list that silently omits it (js-bao `_listImpl` parity).
    func testIncludeRootFallsThroughToNetworkWhenRootNotCached() async throws {
        let store = MetadataStore([Self.ownedEntry("local1")])
        let transport = RecordingTransport(json: Self.serverPageWithRoot)
        let api = makeAPI(store: store, transport: transport, rootDocId: Self.rootId)

        let items = try await api.ownedDocuments(
            options: MeOwnedDocumentsOptions(includeRoot: true)
        )

        XCTAssertEqual(transport.calls.count, 1, "a missing root forces the blocking fetch")
        XCTAssertEqual(transport.lastCall?.path, "/me/owned-documents?includeRoot=true")
        XCTAssertTrue(
            items.contains { $0.documentId == Self.rootId },
            "the server fetch supplies the root the cache lacked"
        )
    }

    /// The `__ROOT_TAG__` sentinel filters the root even when the token
    /// carries no `rootDocId` claim (standalone construction), matching
    /// `DocumentsAPI.filterOutRoot`.
    func testRootTagFiltersWithoutKnownRootDocId() async throws {
        let store = MetadataStore([
            Self.ownedEntry("local1"),
            Self.rootEntry("tagged-root", permission: "owner"),
        ])
        let transport = RecordingTransport(json: Self.serverPage)
        let api = makeAPI(store: store, transport: transport)

        let items = try await api.ownedDocuments()

        XCTAssertEqual(items.map { $0.documentId }, ["local1"])
        await api.awaitBackgroundRefresh()
    }

    /// The cache-only paths (`localOnly` / offline) filter the root too — the
    /// predicate lives with the projection, not with one branch.
    func testCacheOnlyPathsFilterRootDocument() async throws {
        let store = MetadataStore([
            Self.ownedEntry("local1"),
            Self.rootEntry(permission: "owner"),
        ])
        let transport = RecordingTransport(json: Self.serverPage)

        let localOnly = makeAPI(store: store, transport: transport, rootDocId: Self.rootId)
        let localItems = try await localOnly.ownedDocuments(
            options: MeOwnedDocumentsOptions(localOnly: true)
        )
        XCTAssertEqual(localItems.map { $0.documentId }, ["local1"])

        let offline = makeAPI(
            store: store, transport: transport, isOnline: false, rootDocId: Self.rootId
        )
        let offlineItems = try await offline.ownedDocuments()
        XCTAssertEqual(offlineItems.map { $0.documentId }, ["local1"])

        // …and `includeRoot` still surfaces it on those same paths.
        let offlineWithRoot = try await offline.ownedDocuments(
            options: MeOwnedDocumentsOptions(includeRoot: true)
        )
        XCTAssertEqual(Set(offlineWithRoot.map { $0.documentId }), ["local1", Self.rootId])
    }

    /// Defense in depth on the network path: a server row for the root is
    /// dropped when `includeRoot` wasn't asked for, so both paths answer the
    /// same question the same way.
    func testNetworkPathFiltersRootRowFromServer() async throws {
        let store = MetadataStore()
        let transport = RecordingTransport(json: Self.serverPageWithRoot)
        let api = makeAPI(store: store, transport: transport, rootDocId: Self.rootId)

        let items = try await api.ownedDocuments(
            options: MeOwnedDocumentsOptions(waitForLoad: .network)
        )

        XCTAssertEqual(items.map { $0.documentId }, ["srv1"])
    }

    // MARK: - The paged form is carved out of the local-first branch

    /// `ownedDocumentsPage` is the equivalent of js-bao's `returnPage: true`,
    /// which js-bao deliberately excludes from the local-first short-circuit
    /// (`documentsApi.ts:1234-1237`): a local answer ignores `limit` and
    /// carries `cursor == nil`, which a paginating caller reads as "no more
    /// pages". A warm cache must therefore still reach the server.
    func testPagedFormSkipsTheLocalFirstShortCircuit() async throws {
        let store = MetadataStore([Self.ownedEntry("local1"), Self.ownedEntry("local2")])
        let transport = RecordingTransport(json: Self.serverPageWithCursor)
        let api = makeAPI(store: store, transport: transport)

        let page = try await api.ownedDocumentsPage(limit: 1)

        XCTAssertEqual(transport.calls.count, 1, "the paged form must reach the server")
        XCTAssertTrue(
            transport.lastCall?.path.contains("limit=1") ?? false,
            "the requested page size reaches the query string"
        )
        XCTAssertEqual(page.cursor, "next-cursor", "the server's cursor is returned, not nil")
        XCTAssertTrue(
            page.items.contains { $0.documentId == "srv1" },
            "the server page's rows are present"
        )
    }

    /// The flat form keeps the local-first short-circuit — only the paged form
    /// is carved out.
    func testFlatFormStillShortCircuitsOnAWarmCache() async throws {
        let store = MetadataStore([Self.ownedEntry("local1")])
        let gate = Gate()
        let transport = Self.gatedTransport(gate, json: Self.serverPageWithCursor)
        let api = makeAPI(store: store, transport: transport)

        let items = try await api.ownedDocuments(limit: 1)

        XCTAssertEqual(items.map { $0.documentId }, ["local1"])
        await gate.open()
        await api.awaitBackgroundRefresh()
    }

    /// The paged form is carved out of the local *merge* as well, not just the
    /// short-circuit. js-bao returns its page before the by-id union
    /// (`documentsApi.ts:1338-1340`), because appending unpaginated local rows
    /// would push a page past `limit` and repeat those same rows on every page
    /// a cursor walk visits.
    func testPagedFormDoesNotUnionLocalRowsIntoThePage() async throws {
        let store = MetadataStore([Self.ownedEntry("local1"), Self.ownedEntry("local2")])
        let transport = RecordingTransport(json: Self.serverPageWithCursor)
        let api = makeAPI(store: store, transport: transport)

        let page = try await api.ownedDocumentsPage(limit: 1)

        XCTAssertEqual(
            page.items.map { $0.documentId }, ["srv1"],
            "the page is the server page — local-only rows are not appended"
        )
        XCTAssertLessThanOrEqual(page.items.count, 1, "a page never exceeds the requested limit")
        XCTAssertEqual(page.cursor, "next-cursor")
    }

    /// The tag exemption belongs to the server-response filter only. js-bao
    /// admits a tagged root through `getLocalMetadataList`
    /// (`includeRoot || !!tag`) and then re-drops it in the owner-only
    /// `permissionFilter`, whose root exemption is gated on `includeRoot`
    /// alone (`documentsApi.ts:1003-1006`) — the root's permission is
    /// `read-write`, never `owner` (#875). Without this, a warm cache would
    /// return the app root for a tagged query while a cold cache did not.
    func testTaggedRootIsFilteredLocallyWithoutIncludeRoot() async throws {
        let store = MetadataStore([
            LocalMetadataEntry(
                documentId: "local1", title: "Local local1",
                permission: "owner", tags: ["x"]
            ),
            LocalMetadataEntry(
                documentId: Self.rootId, title: "Root",
                permission: "owner", tags: ["__ROOT_TAG__", "x"]
            ),
        ])
        let gate = Gate()
        let transport = Self.gatedTransport(gate, json: Self.serverPage)
        let api = makeAPI(store: store, transport: transport, rootDocId: Self.rootId)

        // A blocking fetch could not answer behind the gate, so this proves
        // the local branch produced the list.
        let items = try await api.ownedDocuments(tag: "x")
        XCTAssertEqual(items.map { $0.documentId }, ["local1"])

        // …and `includeRoot` still surfaces it for the same tagged query.
        let withRoot = try await api.ownedDocuments(
            tag: "x", options: MeOwnedDocumentsOptions(includeRoot: true)
        )
        XCTAssertEqual(Set(withRoot.map { $0.documentId }), ["local1", Self.rootId])

        await gate.open()
        await api.awaitBackgroundRefresh()
    }

    // MARK: - The background refresh never blanks a cached field

    /// `serverDocumentPayload` feeds `DocumentManager.handleServerDocuments`,
    /// which applies any key present. `DocumentInfo` decodes an omitted
    /// `title` to `""`, so an unguarded `title` would blank a good cached
    /// title (e.g. an offline rename not yet synced) on every background
    /// refresh.
    func testServerDocumentPayloadOmitsEmptyStringFields() throws {
        let json = #"{"documentId":"d1","permission":"owner"}"#
        let info = try JSONDecoder().decode(DocumentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.title, "", "an absent server title decodes to the empty string")

        let payload = LocalFirstListing.serverDocumentPayload(info)

        XCTAssertNil(payload["title"], "an empty title must not overwrite the cached one")
        XCTAssertNil(payload["createdBy"])
        XCTAssertNil(payload["createdAt"])
        XCTAssertNil(payload["modifiedAt"])
        XCTAssertEqual(payload["documentId"] as? String, "d1")
        XCTAssertEqual(payload["permission"] as? String, "owner")
    }

    func testServerDocumentPayloadCarriesAPresentTitle() throws {
        let json = #"{"documentId":"d1","title":"Server Doc","permission":"owner"}"#
        let info = try JSONDecoder().decode(DocumentInfo.self, from: Data(json.utf8))

        let payload = LocalFirstListing.serverDocumentPayload(info)

        XCTAssertEqual(payload["title"] as? String, "Server Doc")
    }

    // MARK: - Merge parity with the pre-#2360 network path

    /// `.network` keeps the shipped merge semantics: server rows win by
    /// documentId, local-only owned rows are appended, no duplicates.
    func testNetworkModeMergesServerAndLocalRows() async throws {
        let store = MetadataStore([Self.ownedEntry("local1"), Self.ownedEntry("srv1")])
        let transport = RecordingTransport(json: Self.serverPage)
        let api = makeAPI(store: store, transport: transport)

        let items = try await api.ownedDocuments(
            options: MeOwnedDocumentsOptions(waitForLoad: .network)
        )

        let ids = items.map { $0.documentId }
        XCTAssertEqual(ids.count, Set(ids).count, "merged list is deduped by documentId")
        XCTAssertEqual(Set(ids), ["local1", "srv1"])
        XCTAssertEqual(
            items.first(where: { $0.documentId == "srv1" })?.title, "Server Doc",
            "the server row wins over the local projection"
        )
    }
}

/// A one-shot async gate: `wait()` suspends until `open()` is called.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
