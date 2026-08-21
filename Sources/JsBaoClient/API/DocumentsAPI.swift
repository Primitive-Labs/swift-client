import Foundation
import YSwift

// MARK: - DocumentsAPI

public final class DocumentsAPI: @unchecked Sendable {
    private let transport: any Transport
    private let blobManager: BlobManager
    /// Optional document-manager hook for local-only operations
    /// (`isOpen`, `listPendingCreates`, `cancelPendingCreate`,
    /// `getLocalMetadata`, `getDocumentPermission`, …). When `nil`
    /// the local-only methods throw `unavailable`. Set by
    /// `JsBaoClient.setupSubApis` in practice.
    private weak var documentManager: DocumentManager?

    /// Optional weak ref to the owning client. Lets the ergonomic
    /// wrappers (`open`, `openRoot`, `close`, `evict`, `waitForSync`, …)
    /// route through the top-level methods that already own the
    /// authoritative implementation. `nil` when DocumentsAPI is
    /// constructed in isolation (tests).
    private weak var client: JsBaoClient?

    /// Suspends until the owning client has finished binding storage — token
    /// restored, user-scoped managers bound, and the persisted `meta` rows read
    /// back into `DocumentManager`'s index — reporting whether that happened
    /// within the wait.
    ///
    /// The listing reconciliation needs it: it decides whether to walk the
    /// scope by asking which cached documents the response failed to account
    /// for, and before the load that index is empty, so a launch-time
    /// `documents.list()` would find nothing to evict and the server-deleted
    /// row would be restored from disk right after (#2827).
    ///
    /// Wired once by `JsBaoClient.setupSubApis`, before any call can reach the
    /// API; `nil` when `DocumentsAPI` is constructed in isolation (tests),
    /// where there is no such load to wait for.
    private var storageReadyGate: (@Sendable () async -> Bool)?

    /// Wire the storage-readiness gate. Called once during client setup.
    func setStorageReadyGate(_ gate: @escaping @Sendable () async -> Bool) {
        storageReadyGate = gate
    }

    public let aliases: DocumentAliasesAPI

    /// Designated initializer — the typed transport spine.
    public init(
        transport: any Transport,
        blobManager: BlobManager,
        documentManager: DocumentManager? = nil,
        client: JsBaoClient? = nil
    ) {
        self.transport = transport
        self.blobManager = blobManager
        self.documentManager = documentManager
        self.client = client
        self.aliases = DocumentAliasesAPI(transport: transport)
    }

    // MARK: - CRUD

    /// Create a new document. **Local-first**, mirroring js-bao's
    /// `documents.create(options)`, which simply forwards to
    /// `client.createDocument`: the doc is created locally and is
    /// immediately writable, the server commit races in the background,
    /// and `localOnly: true` keeps it on-device. A create issued while
    /// offline therefore queues instead of failing.
    ///
    /// The response carries only the document's `metadata` blob — not its
    /// id (use `createWithAlias` when you need the id back). When no owning
    /// client is wired (isolated/test construction) it falls back to the
    /// legacy blocking `POST /documents`.
    public func create(options: CreateDocumentOptions = CreateDocumentOptions()) async throws -> CreateDocumentResult {
        guard let client else {
            // No client to route through (tests / isolated construction):
            // fall back to the direct server POST.
            return try await transport.request(method: .post, path: "/documents", body: options)
        }

        // Delegate to the authoritative local-first create, exactly as
        // js-bao's `DocumentsAPI.create` forwards to `client.createDocument`
        // — which itself returns the `{ metadata }` result since #1108.
        return try await client.createDocument(options: options)
    }

    /// List documents accessible to the current user.
    ///
    /// - Parameter includeRoot: when `false` (default), the app's root
    ///   document is filtered out of the returned items. Pass `true` to
    ///   keep it. The server endpoint always returns the root; we filter
    ///   client-side to match js-bao behavior.
    ///
    /// Deprecated: this returns the legacy owner + read-write + reader
    /// union and will eventually be removed. Migrate to
    /// `client.me.ownedDocuments(...)` for the owner-only subset and
    /// `client.me.sharedDocuments(...)` for the non-owner subset.
    /// Mirrors js-bao's `@deprecated` annotation on `DocumentsAPI.list`
    /// (issue #628).
    @available(*, deprecated, message: "documents.list() returns the legacy owner+read-write+reader union. Use client.me.ownedDocuments(...) for owned docs and client.me.sharedDocuments(...) for shared docs.")
    public func list(
        options: ListDocumentsOptions? = nil,
        includeRoot: Bool = false
    ) async throws -> [DocumentInfo] {
        let page = try await _listImpl(options: options, includeRoot: includeRoot)
        return page.items
    }

    /// Page-returning form of `documents.list`. Mirrors js-bao's
    /// `list(options & { returnPage: true })` overload — returns a
    /// `DocumentListPage` (items + pagination cursor) instead of a flat array.
    @available(*, deprecated, message: "documents.list() returns the legacy owner+read-write+reader union. Use client.me.ownedDocuments(...) for owned docs and client.me.sharedDocuments(...) for shared docs.")
    public func listPage(
        options: ListDocumentsOptions? = nil,
        includeRoot: Bool = false
    ) async throws -> DocumentListPage {
        return try await _listImpl(options: options, includeRoot: includeRoot, returnPage: true)
    }

    /// Underscore-prefixed implementation that internal callers (e.g.
    /// `PrimitiveAppState`-style consumers that want to migrate
    /// gradually) can reach without tripping the deprecation warning.
    /// Mirrors js-bao's `_internalListImpl` pattern from `documentsApi.ts`.
    ///
    /// Threads the implemented `ListDocumentsOptions` fields
    /// (`limit`/`cursor`/`tag`/`forward`/`includeRoot`) into the query string
    /// and returns a `DocumentListPage`; the public `list` unwraps `.items`,
    /// `listPage` returns the page directly.
    ///
    /// This is always a blocking server fetch. The struct's local-first
    /// fields (`refreshFromServer`, `localOnly`, `serverTimeoutMs`,
    /// `waitForLoad`) are not implemented here and carry a deprecation warning
    /// saying so — `client.me.ownedDocuments(...)` is where they work (#2360).
    ///
    /// `returnPage` says the caller asked for the page shape (`listPage`).
    /// Only the reconciliation reads it: a page is a subset of the cached
    /// scope, so it may not evict.
    public func _listImpl(
        options: ListDocumentsOptions? = nil,
        includeRoot includeRootArg: Bool = false,
        returnPage: Bool = false
    ) async throws -> DocumentListPage {
        // `includeRoot` may arrive either as the dedicated parameter (legacy
        // Swift call sites) or inside `options` (js-bao parity). Either enables it.
        let includeRoot = includeRootArg || (options?.includeRoot == true)
        var query = URLQuery()
        if includeRoot { query.append("includeRoot", "true") }
        if let limit = options?.limit, limit > 0 {
            query.append("limit", limit)
        }
        if let cursor = options?.cursor, !cursor.isEmpty {
            query.append("cursor", cursor)
        }
        if let tag = options?.tag, !tag.isEmpty {
            query.append("tag", tag)
        }
        if options?.forward == true { query.append("forward", "true") }
        // The server may return either a bare array or an `{ items, cursor }`
        // (or legacy `{ documents }`) envelope — accept both.
        let response: DocumentListEnvelope = try await transport.request(
            method: .get,
            path: "/documents\(query.queryString)"
        )
        var items = response.items
        let cursor = response.cursor
        // Documents the server listed but the client-side root filter drops.
        // They are still on the server, so the reconciliation must retain
        // them rather than read their absence as a deletion.
        var retainIds: Set<String> = []
        // Do not filter the root when filtering by tag — a root that carries
        // the requested tag should be returned (mirrors js-bao's `filterRoot`).
        if !includeRoot, options?.tag == nil {
            var rootDocId: String? = nil
            if let client { rootDocId = client.rootDocId }
            items = Self.filterOutRoot(items, rootDocId: rootDocId)
            // js-bao retains the root by id (`syncMetadata({ includeRoot })`
            // → `retainIds`); retaining every filtered row on top of that also
            // covers a token whose payload carries no `rootDocId` claim.
            if let rootDocId { retainIds.insert(rootDocId) }
            let kept = Set(items.map { $0.documentId })
            retainIds.formUnion(
                response.items.map { $0.documentId }.filter { !kept.contains($0) }
            )
        }
        // The caller's own response never evicts. An unpaged `GET /documents`
        // is a bare array with no cursor and no `hasMore` (#858), and the
        // controller silently truncates it at dynamo-bao's 100-row
        // `defaultQueryLimit` — a truncated listing and a complete one are the
        // same bytes. So merge what the caller got, then, only when the cache
        // holds documents that response did not mention, walk the scope
        // through the paged envelope and let *that* union do the evicting.
        //
        // Both halves run against the loaded metadata index: before the client
        // has read the persisted `meta` rows back, the cache looks empty, so
        // the merge would be undone by the load and the walk would find nothing
        // to evict (#2827).
        let metadataIsLoaded = await localMetadataIsLoaded()
        await reconcileIntoLocalCache(items, authoritative: false, retainIds: retainIds)
        if Self.listingScopeIsReconcilable(options: options, returnPage: returnPage),
           metadataIsLoaded {
            await reconcileByWalkingScope(
                seenIds: Set(response.items.map { $0.documentId }),
                retainIds: retainIds
            )
        }
        return DocumentListPage(items: items, cursor: cursor)
    }

    /// Whether this request asked about the whole scope, and so may be
    /// reconciled authoritatively (after the scope walk confirms what that
    /// scope contains). Mirrors js-bao's `isPaged` rule (`documentsApi.ts`): a
    /// limit, a cursor, a tag filter, `forward`, or the page-returning form
    /// each make the request a question about a slice, and a slice's absences
    /// prove nothing. `internal` for unit testing.
    static func listingScopeIsReconcilable(
        options: ListDocumentsOptions?,
        returnPage: Bool
    ) -> Bool {
        if returnPage { return false }
        guard let options else { return true }
        if options.limit != nil { return false }
        if !(options.cursor ?? "").isEmpty { return false }
        if !(options.tag ?? "").isEmpty { return false }
        if options.forward == true { return false }
        return true
    }

    /// Write a listing response back into the local metadata cache. When the
    /// listing is authoritative it is the server's whole view of the scope: a
    /// cached document it omits is evicted (metadata row *and* `yjs_docs`
    /// snapshot) and emits a `deleted` metadata event.
    ///
    /// This is js-bao's `reconcileFromResponse` →
    /// `syncMetadata({ scope: "all", payload, authoritative })`
    /// (`src/client/api/documentsApi.ts`). Swift kept the listing purely as a
    /// return value, so a document deleted server-side stayed on the device
    /// through every later launch (#2827).
    private func reconcileIntoLocalCache(
        _ items: [DocumentInfo],
        authoritative: Bool,
        retainIds: Set<String>,
        evictOnly: [DocumentManager.EvictionCandidate]? = nil
    ) async {
        guard let documentManager else { return }
        await documentManager.handleServerDocuments(
            items.map { LocalFirstListing.serverDocumentPayload($0) },
            authoritative: authoritative,
            retainIds: retainIds,
            evictOnly: evictOnly
        )
    }

    /// Whether the persisted metadata rows have been read back into the local
    /// index, so "which cached documents did this listing not account for?" has
    /// a truthful answer. A gate that times out reports `false`, and the
    /// listing then merges without ever evicting — the safe direction: the next
    /// whole-scope listing reconciles instead.
    private func localMetadataIsLoaded() async -> Bool {
        guard let storageReadyGate else { return true }
        return await storageReadyGate()
    }

    /// Page size for the scope walk. The server caps `limit` at 100
    /// (`parseListLimitParam`), so asking for more buys nothing.
    private static let scopeWalkPageSize = 100

    /// Shortest gap between two whole-scope reconciliations. A walk costs one
    /// request per 100 documents, so a client reconnecting through a flaky
    /// network must not pay for it on every socket.
    private static let scopeReconcileMinInterval: TimeInterval = 5 * 60

    /// Guards the reconciliation's schedule: when the last walk finished
    /// (completed or not) and the one currently running, so concurrent
    /// connects share it rather than each walking the scope.
    private let scopeReconcileLock = NSLock()
    private var scopeReconcileLastRunAt: Date?
    private var scopeReconcileInFlight: Task<Void, Never>?
    /// Bumped whenever the schedule is re-armed. A walk carries the generation
    /// it started under and does nothing once that is stale: neither applying
    /// the scope it read nor writing back a schedule that now belongs to
    /// somebody else. Mirrors js-bao's `scopeReconcileGeneration`.
    private var scopeReconcileGeneration: UInt64 = 0
    /// The user the current schedule was set for. A walk is about one user's
    /// documents, so a different one signing in — including the sign-out /
    /// sign-in pair, where no token-change handler sees both identities —
    /// re-arms rather than inheriting the previous account's window.
    private var scopeReconcileUserId: String?

    /// How many pages the walk will follow before giving up. 100 pages × 100
    /// rows bounds it at 10k documents; a scope larger than that (or a server
    /// handing back an endless cursor) simply does not get reconciled, which
    /// is the safe direction — nothing is deleted.
    private static let scopeWalkMaxPages = 100

    /// Read the caller's whole document scope and reconcile the union of it
    /// authoritatively, evicting the cached documents the server no longer
    /// lists.
    ///
    /// The walk exists because the caller's own response cannot carry the
    /// signal this needs: the unpaged `GET /documents` returns a bare array
    /// truncated at the server's default query limit, so it is indistinguishable
    /// from a complete listing. The paged form returns the
    /// `{ items, hasMore, nextCursor }` envelope, which is followed here to
    /// exhaustion. Anything short of a completed walk — a request that failed,
    /// a server that answers the paged request with a bare array (and so
    /// ignores `limit` and says nothing about completeness), a cursor that
    /// stops advancing, the page cap — evicts nothing at all.
    ///
    /// `seenIds` is what the caller's response already accounted for. When no
    /// cached document is missing from it there is nothing an authoritative
    /// pass could delete, and the walk is skipped: an app whose scope fits in
    /// one unpaged response pays no extra request.
    ///
    /// Those same missing documents are also the *only* ones the walk may
    /// evict, captured here with their metadata stamps and handed back to the
    /// reconciliation: the walk spans several round trips, and a document
    /// granted, created or re-confirmed while it runs can be genuinely absent
    /// from the union — its page had already gone by — without having been
    /// deleted server-side.
    ///
    /// `isCurrent` is asked, between round trips and again before anything is
    /// applied, whether the scope being walked is still the one the client
    /// cares about. The connect-time reconciliation passes an identity check
    /// there: a user switch mid-walk would otherwise merge one account's
    /// documents into the next account's cache — authoritatively, so the
    /// documents the new user actually has would be the ones evicted.
    private func reconcileByWalkingScope(
        seenIds: Set<String>,
        retainIds: Set<String>,
        isCurrent: @Sendable () -> Bool = { true }
    ) async {
        guard let documentManager else { return }
        let candidates = documentManager.evictionCandidateSnapshot(
            seenIds: seenIds, retainIds: retainIds
        )
        guard !candidates.isEmpty else { return }

        var union: [DocumentInfo] = []
        var unionIds: Set<String> = []
        var cursor: String? = nil

        for _ in 0..<Self.scopeWalkMaxPages {
            var query = URLQuery()
            // The server returns the root whatever this says; asking for it
            // keeps the union a superset of what the caller's response could
            // have contained.
            query.append("includeRoot", "true")
            query.append("limit", Self.scopeWalkPageSize)
            if let cursor, !cursor.isEmpty { query.append("cursor", cursor) }

            guard isCurrent() else { return }
            let page: DocumentListEnvelope
            do {
                page = try await transport.request(
                    method: .get,
                    path: "/documents\(query.queryString)"
                )
            } catch {
                return
            }
            // A bare array in answer to `limit` means the server ignored it.
            guard !page.isBareArray else { return }
            // A body that never mentioned `items` (or legacy `documents`) is
            // not a page of this scope — decoding it leaves an empty list, and
            // an empty list read as the whole scope evicts everything.
            guard page.listsItems else { return }

            for item in page.items where unionIds.insert(item.documentId).inserted {
                union.append(item)
            }

            guard let next = page.cursor, !next.isEmpty else {
                // No continuation token. If the page nevertheless says more
                // rows remain, the walk cannot ask for them and so never
                // reached the end of the scope — an inconsistent envelope
                // authorizes nothing.
                guard !page.hasMore else { return }
                // A scope walked as one user says nothing about the one signed
                // in now.
                guard isCurrent() else { return }
                // The walk reached the end of the scope and the union is the
                // server's whole view of it.
                await reconcileIntoLocalCache(
                    union,
                    authoritative: true,
                    retainIds: retainIds,
                    evictOnly: candidates
                )
                return
            }
            if next == cursor { return }
            cursor = next
        }
    }

    /// Reconcile the local cache against the user's whole document scope,
    /// evicting the documents the server no longer has (#2852).
    ///
    /// Eviction used to happen only inside `documents.list()`, whose response
    /// is what gets reconciled. Both clients steer developers off that method
    /// (#628) and onto `me.ownedDocuments` / `me.sharedDocuments`, which are
    /// strict subsets of the cached scope and so merge only — correct for a
    /// subset, but it left an app that never calls the deprecated method with
    /// no eviction path at all: `meta` rows and multi-megabyte `yjs_docs`
    /// snapshots of deleted documents accumulated for as long as it kept
    /// launching.
    ///
    /// So this runs on its own schedule — from the connect handler
    /// (`JsBaoClient.webSocketManagerOnConnected`), and at most once per
    /// `scopeReconcileMinInterval` — rather than as a side effect of a listing
    /// call, which would put a full scope walk behind every list. Concurrent
    /// callers share the one walk.
    ///
    /// It is the same walk `documents.list()` uses, with nothing seen: every
    /// cached document is a candidate, and only a walk followed to the end of
    /// the scope evicts any of them. Mirrors js-bao's
    /// `JsBaoClient.reconcileDocumentScope`.
    func reconcileScopeAtConnect(force: Bool = false) async {
        // Read outside the lock: it goes through `AuthController`'s own.
        let currentUser = client?.userId
        typealias Walk = Task<Void, Never>
        let (stale, task): (Walk?, Walk?) = scopeReconcileLock.withLock {
            var cancelled: Task<Void, Never>?
            if scopeReconcileUserId != currentUser {
                // The schedule belongs to another account. Whatever it holds —
                // a spent window, a walk still fetching that account's pages —
                // says nothing about this one's documents.
                cancelled = rearmScopeReconcileLocked()
                scopeReconcileUserId = currentUser
            }
            if let inFlight = scopeReconcileInFlight { return (cancelled, inFlight) }
            if !force, let last = scopeReconcileLastRunAt,
               Date().timeIntervalSince(last) < Self.scopeReconcileMinInterval {
                return (cancelled, nil)
            }
            let generation = scopeReconcileGeneration
            let task = Task<Void, Never> { [weak self] in
                await self?.runScopeReconcile(generation: generation)
            }
            scopeReconcileInFlight = task
            return (cancelled, task)
        }
        stale?.cancel()
        await task?.value
    }

    /// Forget the staleness window, so the next connect reconciles rather than
    /// skipping. Called when the signed-in user changes: the window was spent
    /// on the previous user's scope and says nothing about this one's.
    func resetScopeReconcileSchedule() {
        let stale = scopeReconcileLock.withLock { rearmScopeReconcileLocked() }
        stale?.cancel()
    }

    /// Re-arm the schedule, returning the walk that was running so the caller
    /// can cancel it outside the lock.
    ///
    /// Bumping the generation is what actually detaches that walk: clearing
    /// `scopeReconcileInFlight` alone would leave it free to apply the previous
    /// account's scope and to stamp `scopeReconcileLastRunAt` on its way out,
    /// skipping the new user's first reconciliation for the whole window.
    /// Cancellation is the courtesy on top — it is cooperative, and the
    /// generation check is what the correctness rests on.
    private func rearmScopeReconcileLocked() -> Task<Void, Never>? {
        scopeReconcileGeneration &+= 1
        scopeReconcileLastRunAt = nil
        let running = scopeReconcileInFlight
        scopeReconcileInFlight = nil
        return running
    }

    /// Whether a walk started under `generation` is still the current one.
    private func scopeReconcileIsCurrent(_ generation: UInt64) -> Bool {
        scopeReconcileLock.withLock { scopeReconcileGeneration == generation }
    }

    private func runScopeReconcile(generation: UInt64) async {
        defer {
            scopeReconcileLock.withLock {
                // A walk the user signed out from under neither starts the next
                // user's staleness window nor clears a walk started for them.
                guard scopeReconcileGeneration == generation else { return }
                scopeReconcileLastRunAt = Date()
                scopeReconcileInFlight = nil
            }
        }
        // Before the persisted `meta` rows are read back the index is empty, so
        // the walk would find nothing to evict and the server-deleted row would
        // come back off disk moments later (#2827).
        guard await localMetadataIsLoaded() else { return }
        var retainIds: Set<String> = []
        // The walk asks for the root, so the union carries it — retaining it by
        // id as well covers a token whose payload has no `rootDocId` claim.
        if let rootDocId = client?.rootDocId { retainIds.insert(rootDocId) }
        await reconcileByWalkingScope(
            seenIds: [],
            retainIds: retainIds,
            isCurrent: { [weak self] in self?.scopeReconcileIsCurrent(generation) ?? false }
        )
    }

    /// Sentinel tag the server attaches to a root document. Mirrors
    /// js-bao's `ROOT_DOCUMENT_TAG` in `documentsApi.ts`. Defined once in
    /// `LocalFirstListing` so this filter and `me.ownedDocuments`' local-path
    /// filter test the same sentinel.
    private static let rootDocumentTag = LocalFirstListing.rootDocumentTag

    /// Strip the app root document from a list response, matching js-bao's
    /// `_listImpl` filter exactly: drop any entry whose `documentId` equals
    /// the known root id, OR whose `tags` include the `__ROOT_TAG__`
    /// sentinel. The tag check runs even when `rootDocId` is unknown (e.g. a
    /// JWT without the `rootDocId` claim), so the root never leaks on tokens
    /// that lack the claim.
    private static func filterOutRoot(
        _ items: [DocumentInfo],
        rootDocId: String?
    ) -> [DocumentInfo] {
        items.filter { item in
            let isIdRoot = rootDocId != nil && item.documentId == rootDocId
            let isRootTagged = item.tags?.contains(Self.rootDocumentTag) ?? false
            return !isIdRoot && !isRootTagged
        }
    }

    /// Get a document by ID.
    public func get(documentId: String) async throws -> DocumentInfo {
        try await transport.request(method: .get, path: "/documents/\(documentId)")
    }

    /// Update a document's metadata.
    public func update(documentId: String, data: UpdateDocumentData) async throws -> DocumentInfo {
        try await transport.request(method: .put, path: "/documents/\(documentId)", body: data)
    }

    /// Delete a document.
    ///
    /// - Parameter options: pass `forceCloseIfOpen: true` to have the local
    ///   `DocumentManager` close the doc before the server DELETE lands.
    ///   Mirrors js-bao's `documents.delete(id, { forceCloseIfOpen: true })`.
    ///   Without it, deleting a still-open doc surfaces stale state.
    public func delete(
        documentId: String,
        options: DeleteDocumentOptions = DeleteDocumentOptions()
    ) async throws {
        // Root-document guard — mirrors js-bao (documentsApi.ts:1296-1297).
        if client?.isRootDocument(documentId) == true {
            throw JsBaoError(code: .invalidArgument, message: "Root documents cannot be deleted")
        }
        // Open-without-force guard — mirrors js-bao (documentsApi.ts:1300-1307):
        // deleting an open doc without `forceCloseIfOpen` would leave the local
        // YDocument live against a server-side delete.
        let isOpen = documentManager?.isOpen(documentId) == true
        if isOpen, options.forceCloseIfOpen != true {
            throw JsBaoError(
                code: .invalidArgument,
                message: "Cannot delete open document \(documentId); close it first or pass forceCloseIfOpen: true."
            )
        }
        if isOpen, options.forceCloseIfOpen == true {
            await documentManager?.closeDocument(documentId: documentId)
        }
        do {
            try await transport.send(method: .delete, path: "/documents/\(documentId)")
        } catch {
            // js-bao treats not-found / offline / pending-create deletes as a
            // successful *local* delete and still reconciles (documentsApi.ts:
            // 1342-1392). Anything else propagates.
            let isPending = client?.isPendingCreate(documentId) == true
            guard Self.isNotFoundError(error) || Self.isOfflineError(error) || isPending else {
                throw error
            }
            if isPending {
                await client?.cancelPendingCreate(documentId, evictLocal: false)
            }
        }
        // Reconcile local state to match js-bao: evict the document's local
        // data and notify listeners via `documentMetadataChanged` (#961).
        await client?.evictLocalDocument(documentId)
        client?.eventEmitter.emit(
            DocumentMetadataChangedEvent(documentId: documentId, action: "deleted", source: "local")
        )
    }

    /// Returns `true` for a not-found (HTTP 404) error, used to treat a
    /// delete of an already-absent document as success.
    private static func isNotFoundError(_ error: Error) -> Bool {
        if let e = error as? JsBaoError, e.code == .notFound { return true }
        let msg = String(describing: error)
        return msg.contains("HTTP 404") || msg.contains("status: 404")
    }

    /// Returns `true` for an offline error — mirrors js-bao's `err.code ===
    /// "OFFLINE"` branch so an offline delete reconciles locally.
    private static func isOfflineError(_ error: Error) -> Bool {
        if let e = error as? JsBaoError {
            return e.code == .offline || e.code == .documentUnavailableOffline
        }
        return false
    }

    // MARK: - Permissions

    /// Get the list of members (permission entries) for a document.
    public func getPermissions(documentId: String) async throws -> [DocumentPermissionEntry] {
        try await transport.request(method: .get, path: "/documents/\(documentId)/permissions")
    }

    /// Revoke a user's access, or cancel a pending email invitation. `target`
    /// mirrors js-bao's `string | { userId } | { email }` union: a bare string
    /// literal (or `.userId(...)`) targets a user id; `.email(...)` cancels an
    /// email-targeted permission (live `DocumentPermission` if the email
    /// resolves to a member, otherwise the matching unresolved
    /// `DeferredDocumentPermission` rows — issue #619).
    public func removePermission(documentId: String, _ target: DocumentPermissionTarget) async throws {
        // Root-document guard — mirrors js-bao (documentsApi.ts:1834).
        if client?.isRootDocument(documentId) == true {
            throw JsBaoError(code: .invalidArgument, message: "Root documents cannot be shared")
        }
        switch target {
        case let .email(email):
            var query = URLQuery()
            query.append("email", email)
            try await transport.send(
                method: .delete,
                path: "/documents/\(documentId)/permissions\(query.queryString)"
            )
        case let .userId(userId):
            try await transport.send(
                method: .delete,
                path: "/documents/\(documentId)/permissions/\(userId)"
            )
            // Self-removal: revoking your own access drops local sync — notify
            // and evict, matching js-bao (documentsApi.ts:1837-1862) (#961).
            if userId == client?.userId {
                client?.eventEmitter.emit(
                    DocumentMetadataChangedEvent(documentId: documentId, action: "deleted", source: "local")
                )
                await client?.evictLocalDocument(documentId)
            }
        }
    }

    /// Transfer ownership of a document to another user.
    public func transferOwnership(documentId: String, newOwnerId: String) async throws {
        try await transport.send(
            method: .post,
            path: "/documents/\(documentId)/permissions/transfer",
            body: ["newOwnerId": newOwnerId]
        )
    }

    // MARK: - Group Permissions

    /// List group permissions for a document.
    ///
    /// - Parameter includeSystem: when `true`, platform-managed internal
    ///   groups (those whose `groupType` is prefixed with `_`, e.g. the
    ///   `_col-*` groups backing collection sharing) are included. They are
    ///   excluded by default. Mirrors js-bao's `{ includeSystem }` option
    ///   (#506).
    ///
    /// The flag is sent as `?includeSystem=true` because the server decides
    /// what to return — it strips system rows unless asked (#2360; JS has sent
    /// the param since #506). The client-side `_`-prefix filter runs only on
    /// the default (`false`) branch, where it guards against a server
    /// predating #506 that returns system rows unconditionally.
    public func listGroupPermissions(documentId: String, includeSystem: Bool = false) async throws -> [DocumentGroupPermissionEntry] {
        var query = URLQuery()
        if includeSystem { query.append("includeSystem", "true") }
        let all: [DocumentGroupPermissionEntry] = try await transport.request(
            method: .get,
            path: "/documents/\(documentId)/group-permissions\(query.queryString)"
        )
        return includeSystem ? all : all.filter { !$0.groupType.hasPrefix("_") }
    }

    /// Grant a group permission on a document.
    public func grantGroupPermission(documentId: String, params: GrantGroupPermissionParams) async throws -> DocumentGroupPermissionEntry {
        try await transport.request(
            method: .post,
            path: "/documents/\(documentId)/group-permissions",
            body: params
        )
    }

    // MARK: - Access

    /// Validate the current user's access to a document. Also accepts or
    /// upgrades any pending invitation the caller has on the document.
    ///
    /// Sends `POST /documents/:documentId/validate-access` — the same route
    /// js-bao uses (`documentsApi.ts` `validateAccess`). There is no
    /// `/documents/:documentId/access` route on the server (#2358).
    public func validateAccess(documentId: String) async throws -> DocumentAccessResult {
        try await transport.request(method: .post, path: "/documents/\(documentId)/validate-access")
    }

    // MARK: - Invitations

    /// List pending deferred-grant invitations for a document. Returns
    /// rows from the new `DeferredDocumentPermission` model (the
    /// replacement for the legacy `DocumentInvitation` model).
    /// Mirrors js-bao's `documents.listPendingInvitations` (issue #619).
    /// Sends `GET /documents/:documentId/pending-invitations`.
    public func listPendingInvitations(documentId: String) async throws -> [PendingInvitationEntry] {
        let response: ItemsEnvelope<PendingInvitationEntry> = try await transport.request(
            method: .get,
            path: "/documents/\(documentId)/pending-invitations"
        )
        return response.items
    }

    /// Update document permissions for a user.
    ///
    /// Idempotent email-based share — the standard verb for "invite X to
    /// this doc" since the deprecation of `sendInvitation`. Routes
    /// through the unified deferred-grant flow:
    ///  * if the email already maps to an app user → live `DocumentPermission` row;
    ///  * otherwise → `DeferredDocumentPermission` row that resolves on signup.
    ///
    /// Build `params` with the `.user(...)`, `.email(...)`, or `.batch(...)`
    /// factories on `UpdatePermissionsData`.
    public func updatePermissions(documentId: String, params: UpdatePermissionsData) async throws -> PermissionUpdateResult {
        try await transport.request(
            method: .put,
            path: "/documents/\(documentId)/permissions",
            body: params
        )
    }

    // MARK: - Link Access ("anyone with the link")

    /// Turn on "anyone with the link" access for a document. Any signed-in app
    /// user who has the document id then resolves to at least `level` without
    /// an explicit grant. Requires document owner, app owner, or read-write
    /// editor. Mirrors js-bao's `documents.setLinkAccess(id, level)`.
    ///
    /// - Parameters:
    ///   - documentId: The document to share via link.
    ///   - level: The shared level — `.reader` or `.readWrite`.
    @discardableResult
    public func setLinkAccess(
        documentId: String,
        level: DocumentLinkAccessLevel
    ) async throws -> LinkAccessResult {
        // Root-document guard — mirrors js-bao (documentsApi.ts:1863-1865).
        if client?.isRootDocument(documentId) == true {
            throw JsBaoError(code: .invalidArgument, message: "Root documents cannot be shared")
        }
        return try await transport.request(
            method: .put,
            path: "/documents/\(documentId)/link-access",
            body: ["level": level.rawValue]
        )
    }

    /// Read the current "anyone with the link" state for a document.
    /// Authorized for any caller who can read the document OR manage its
    /// sharing (document owner, app owner, or read-write editor), so an app
    /// owner can inspect the state without a content grant — which the
    /// content-gated `get(documentId:)` would refuse. Returns
    /// `linkAccess == nil` when link access is off.
    ///
    /// Mirrors js-bao's `documents.getLinkAccess(id)`. No client-side
    /// root-document guard: the server answers root documents with a 403,
    /// matching js-bao, which does not pre-check either.
    public func getLinkAccess(documentId: String) async throws -> LinkAccessResult {
        try await transport.request(method: .get, path: "/documents/\(documentId)/link-access")
    }

    /// Turn off "anyone with the link" access for a document. Existing explicit
    /// grants are unaffected; link-only viewers lose access. Mirrors js-bao's
    /// `documents.clearLinkAccess(id)`.
    ///
    /// - Parameter documentId: The document to stop sharing via link.
    @discardableResult
    public func clearLinkAccess(documentId: String) async throws -> LinkAccessResult {
        // Root-document guard — mirrors js-bao (documentsApi.ts:1880-1882).
        if client?.isRootDocument(documentId) == true {
            throw JsBaoError(code: .invalidArgument, message: "Root documents cannot be shared")
        }
        return try await transport.request(
            method: .delete,
            path: "/documents/\(documentId)/link-access"
        )
    }

    // MARK: - Root Document

    /// Get metadata for the app's root document.
    ///
    /// Resolves the root document id locally from the JWT
    /// (`client.rootDocId`) and fetches that document, matching js-bao
    /// (`documentsApi.ts` `getRoot`). The server has no `/documents/root`
    /// alias — that path resolves as `GET /documents/:documentId` with the
    /// literal id `"root"` and fails (#2358).
    public func getRoot() async throws -> DocumentInfo {
        guard let client else {
            throw JsBaoError(
                code: .unavailable,
                message: "DocumentsAPI.getRoot requires a wired JsBaoClient"
            )
        }
        guard let docId = client.rootDocId else {
            throw JsBaoError(
                code: .notFound,
                message: "Root document not available (no rootDocId in token)"
            )
        }
        return try await get(documentId: docId)
    }

    // MARK: - Tags

    /// Add a tag to a document. Returns the updated tag list (matches
    /// js-bao's `[String]` return). Falls back to an empty list if
    /// the server response is shaped differently.
    public func addTag(documentId: String, tag: String) async throws -> [String] {
        let response: TagListResponse? = try await transport.requestOptional(
            method: .post,
            path: "/documents/\(documentId)/tags",
            body: ["tag": tag]
        )
        return response?.tags ?? []
    }

    /// Remove a tag from a document. Returns the updated tag list.
    public func removeTag(documentId: String, tag: String) async throws -> [String] {
        let encodedTag = URLEncoding.encodeComponent(tag)
        let response: TagListResponse? = try await transport.requestOptional(
            method: .delete,
            path: "/documents/\(documentId)/tags/\(encodedTag)"
        )
        return response?.tags ?? []
    }

    // MARK: - Create With Alias

    /// Create a document with an alias atomically.
    public func createWithAlias(options: CreateWithAliasOptions) async throws -> CreateWithAliasResult {
        // Match JS guards (documentsApi.ts:523-533): non-empty title + aliasKey.
        // (`scope` is a closed enum here, so the JS scope check is unrepresentable.)
        guard !options.title.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "title is required")
        }
        guard !options.alias.aliasKey.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "alias.aliasKey is required")
        }
        return try await transport.request(
            method: .post,
            path: "/documents/create-with-alias",
            body: options
        )
    }

    // MARK: - Group permissions

    /// Revoke a group's permission on a document.
    public func revokeGroupPermission(
        documentId: String,
        groupType: String,
        groupId: String
    ) async throws -> SuccessResult {
        let gType = URLEncoding.encodeComponent(groupType)
        let gId = URLEncoding.encodeComponent(groupId)
        return try await transport.request(
            method: .delete,
            path: "/documents/\(documentId)/group-permissions/\(gType)/\(gId)"
        )
    }

    // MARK: - Access requests

    /// Request access to a document the current user doesn't have a
    /// permission grant on. Owners (and app admins) can approve/deny
    /// via `listAccessRequests` / `approveAccessRequest` /
    /// `denyAccessRequest`.
    public func requestAccess(
        documentId: String,
        options: RequestAccessOptions
    ) async throws -> DocumentAccessRequestResponse {
        try await transport.request(
            method: .post,
            path: "/documents/\(documentId)/access-requests",
            body: options
        )
    }

    /// List pending access requests for a document. Owner/admin only.
    public func listAccessRequests(
        documentId: String
    ) async throws -> [DocumentAccessRequest] {
        try await transport.request(
            method: .get,
            path: "/documents/\(documentId)/access-requests"
        )
    }

    /// Approve a pending access request. Owner/admin only.
    public func approveAccessRequest(
        documentId: String,
        requestId: String,
        options: ApproveAccessRequestOptions? = nil
    ) async throws -> AccessRequestResult {
        // A `nil` options object sends `{}`, as the untyped body did — every
        // field is optional, so the default value encodes to an empty object.
        try await transport.request(
            method: .post,
            path: "/documents/\(documentId)/access-requests/\(requestId)/approve",
            body: options ?? ApproveAccessRequestOptions()
        )
    }

    /// Deny a pending access request. Owner/admin only.
    public func denyAccessRequest(
        documentId: String,
        requestId: String,
        options: DenyAccessRequestOptions? = nil
    ) async throws -> AccessRequestResult {
        // A `nil` options object sends `{}`, as the untyped body did.
        try await transport.request(
            method: .post,
            path: "/documents/\(documentId)/access-requests/\(requestId)/deny",
            body: options ?? DenyAccessRequestOptions()
        )
    }

    // MARK: - Local-only methods (delegate to DocumentManager)

    /// Check whether a document is currently open locally. Does NOT
    /// hit the server. Requires the `documentManager` to be wired by
    /// `JsBaoClient.setupSubApis`.
    public func isOpen(documentId: String) -> Bool {
        return documentManager?.isOpen(documentId) ?? false
    }

    /// Check whether a document has a pending local create that has
    /// not been committed to the server.
    public func isPendingCreate(documentId: String) -> Bool {
        return documentManager?.isPendingCreate(documentId) ?? false
    }

    /// Check whether a document has a local copy stored on this device.
    public func hasLocalCopy(documentId: String) -> Bool {
        return documentManager?.hasLocalCopy(documentId) ?? false
    }

    /// Check whether a document is read-only for the current user (i.e. the
    /// cached permission is `reader`). Local-only check. Mirrors js-bao's
    /// `documents.isReadOnly(documentId)`.
    public func isReadOnly(documentId: String) -> Bool {
        return documentManager?.getPermission(documentId) == .reader
    }

    /// List the IDs of all currently open documents. Local-only. Mirrors
    /// js-bao's `documents.listOpen()`.
    public func listOpen() -> [String] {
        return documentManager?.listOpenDocuments() ?? []
    }

    /// Check whether a document's local state is synced with the server.
    /// Synchronous local read — an alias of `inSync`. Mirrors js-bao's
    /// `documents.isSynced(documentId)`.
    public func isSynced(documentId: String) -> Bool {
        return documentManager?.isSynced(documentId) ?? false
    }

    /// List all documents created locally but not yet committed to the
    /// server, as `{ documentId, title?, createdAt }` entries sourced from
    /// local metadata. Mirrors js-bao's async `documents.listPendingCreates()`.
    public func listPendingCreates() async -> [PendingCreateInfo] {
        guard let mgr = documentManager else { return [] }
        return mgr.listPendingCreates().map { id in
            let meta = mgr.getLocalMetadata(id)
            return PendingCreateInfo(
                documentId: id,
                title: meta?.title,
                createdAt: meta?.createdAt ?? ""
            )
        }
    }

    /// Get the pending-create entry for a single document, or `nil` when
    /// the document has no uncommitted local create. Same entry shape as
    /// `listPendingCreates()` (`{ documentId, title?, createdAt }`),
    /// sourced from local metadata — no network (#1111).
    public func getPendingCreate(documentId: String) async -> PendingCreateInfo? {
        guard let mgr = documentManager, mgr.isPendingCreate(documentId) else { return nil }
        let meta = mgr.getLocalMetadata(documentId)
        return PendingCreateInfo(
            documentId: documentId,
            title: meta?.title,
            createdAt: meta?.createdAt ?? ""
        )
    }

    /// Cancel a pending local document create. With `options.evictLocal`,
    /// the document's local data is also evicted after cancellation.
    /// Mirrors js-bao's `documents.cancelPendingCreate(documentId, { evictLocal })`.
    public func cancelPendingCreate(
        documentId: String,
        options: CancelPendingCreateOptions = CancelPendingCreateOptions()
    ) async {
        guard let client else {
            await documentManager?.cancelPendingCreate(documentId)
            return
        }
        await client.cancelPendingCreate(documentId, evictLocal: options.evictLocal)
    }

    /// Commit a locally-created (`localOnly`, or created while offline)
    /// document to the server, replaying its stashed title/tags/metadata
    /// into the create POST. Namespaced to match js-bao's
    /// `documents.commitOfflineCreate(documentId, { onExists })` (Swift also
    /// keeps the top-level `client.commitOfflineCreate` this forwards to).
    public func commitOfflineCreate(
        documentId: String,
        options: CommitOfflineCreateOptions = CommitOfflineCreateOptions()
    ) async throws -> CommitOfflineCreateResult {
        guard let client else {
            throw JsBaoError(
                code: .unavailable,
                message: "DocumentsAPI.commitOfflineCreate requires a wired JsBaoClient"
            )
        }
        let result = try await client.commitOfflineCreate(
            documentId: documentId,
            onExists: options.onExists.rawValue
        )
        return CommitOfflineCreateResult(
            created: (result["created"] as? Bool) ?? false,
            linked: result["linked"] as? Bool,
            reason: result["reason"] as? String
        )
    }

    /// Get the current user's permission level for a document, as
    /// last observed by the local document manager. Returns `nil`
    /// when the document isn't open locally.
    public func getDocumentPermission(documentId: String) -> DocumentPermission? {
        return documentManager?.getPermission(documentId)
    }

    /// Get locally cached metadata for a document. Returns `nil` when no
    /// metadata is stored. Declared `async` to match js-bao's async
    /// accessor (whose IndexedDB read is inherently asynchronous); the
    /// Swift read itself is a synchronous SQLite / in-memory lookup.
    public func getLocalMetadata(documentId: String) async -> LocalMetadataEntry? {
        return documentManager?.getLocalMetadata(documentId)
    }

    // MARK: - Blob Context

    /// Get a blob context scoped to a specific document.
    public func blobs(documentId: String) -> DocumentBlobContext {
        return DocumentBlobContext(
            documentId: documentId,
            transport: transport,
            blobManager: blobManager
        )
    }

    // MARK: - App-wide blob upload queue (cross-document)
    //
    // js-bao exposes the upload-queue verbs on `DocumentsAPI` with an
    // **optional** `documentId` — omit it to operate across every open
    // document (`documentsApi.ts:631`/`644`/`657`/`669`/`680`/`691`/`696`).
    // Swift's per-document equivalents live on `DocumentBlobContext`
    // (via `blobs(documentId:)`); these app-wide forms forward to the
    // already cross-document-capable `BlobManager` (`documentId: nil`).

    // `BlobManager` became an `actor` in #2172, so none of these can read or
    // mutate the queue synchronously any more. Every one of them is an
    // `…Async` form now: the deprecated fire-and-forget void twins
    // (`pauseAllUploads`, `resumeAllUploads`, `setUploadConcurrency`) were
    // removed in #2367 along with the rest of the deprecation window.
    //
    // `uploads` / `pauseUpload` / `resumeUpload` keep an
    // `@available(*, unavailable, renamed:)` stub so the compiler answers a
    // migrating call with a one-click rename fix-it instead of "no such
    // member". `getUploadConcurrency` has no stub because it did not merely
    // gain an `Async` suffix — it became the `uploadConcurrency` async
    // property, and `renamed:` cannot point a function at a property.
    //
    // The twins are deliberately **distinctly named** rather than same-name
    // `async` overloads: Swift prefers an `async` overload in an asynchronous
    // context, so a same-name twin would have turned every existing
    // un-`await`ed call into a compile error before the batch, which is the
    // break the window existed to avoid.

    /// List tracked blob uploads, newest first. With `documentId == nil`
    /// (the default) returns uploads across **all** documents; pass a
    /// `documentId` to scope to one. Mirrors JS `documents.uploads(documentId?)`.
    @available(*, unavailable, renamed: "uploadsAsync(documentId:)")
    public func uploads(documentId: String? = nil) -> [BlobUploadStatus] {
        fatalError("unavailable — use uploadsAsync(documentId:)")
    }

    /// List tracked blob uploads, newest first. With `documentId == nil`
    /// (the default) returns uploads across **all** documents; pass a
    /// `documentId` to scope to one. Mirrors JS `documents.uploads(documentId?)`.
    public func uploadsAsync(documentId: String? = nil) async -> [BlobUploadStatus] {
        return await blobManager.listUploads(documentId: documentId)
    }

    /// Pause a tracked upload by blob ID. With `documentId == nil` the
    /// blob is matched across all documents; pass a `documentId` to scope
    /// the match. Returns `false` if no matching, pausable upload is
    /// tracked. Mirrors JS `documents.pauseUpload(documentId, blobId)`
    /// (Swift makes `documentId` optional for the cross-document form).
    @available(*, unavailable, renamed: "pauseUploadAsync(blobId:documentId:)")
    @discardableResult
    public func pauseUpload(blobId: String, documentId: String? = nil) -> Bool {
        fatalError("unavailable — use pauseUploadAsync(blobId:documentId:)")
    }

    /// Pause a tracked upload by blob ID. With `documentId == nil` the
    /// blob is matched across all documents; pass a `documentId` to scope
    /// the match. Returns `false` if no matching, pausable upload is
    /// tracked. Mirrors JS `documents.pauseUpload(documentId, blobId)`.
    @discardableResult
    public func pauseUploadAsync(blobId: String, documentId: String? = nil) async -> Bool {
        return await blobManager.pauseUpload(blobId, documentId: documentId)
    }

    /// Resume a paused upload by blob ID. With `documentId == nil` the
    /// blob is matched across all documents; pass a `documentId` to scope
    /// the match. Returns `false` if no matching, paused upload is
    /// tracked. Mirrors JS `documents.resumeUpload(documentId, blobId)`.
    @available(*, unavailable, renamed: "resumeUploadAsync(blobId:documentId:)")
    @discardableResult
    public func resumeUpload(blobId: String, documentId: String? = nil) -> Bool {
        fatalError("unavailable — use resumeUploadAsync(blobId:documentId:)")
    }

    /// Resume a paused upload by blob ID. With `documentId == nil` the
    /// blob is matched across all documents; pass a `documentId` to scope
    /// the match. Returns `false` if no matching, paused upload is
    /// tracked. Mirrors JS `documents.resumeUpload(documentId, blobId)`.
    @discardableResult
    public func resumeUploadAsync(blobId: String, documentId: String? = nil) async -> Bool {
        return await blobManager.resumeUpload(blobId, documentId: documentId)
    }

    /// Pause all in-progress uploads, returning once every matching upload is
    /// paused. With `documentId == nil` (the default) pauses uploads across
    /// **all** documents; pass a `documentId` to scope.
    public func pauseAllUploadsAsync(documentId: String? = nil) async {
        await blobManager.pauseAll(documentId: documentId)
    }

    /// Resume all paused uploads, returning once every matching upload is back
    /// in the retry rotation. With `documentId == nil` (the default) resumes
    /// uploads across **all** documents; pass a `documentId` to scope.
    public func resumeAllUploadsAsync(documentId: String? = nil) async {
        await blobManager.resumeAll(documentId: documentId)
    }

    /// Set the maximum number of concurrent blob uploads (app-wide),
    /// returning once the setting is in effect.
    public func setUploadConcurrencyAsync(_ concurrency: Int) async {
        await blobManager.setUploadConcurrency(concurrency)
    }

    /// The current maximum number of concurrent blob uploads (app-wide).
    /// Mirrors JS `documents.getUploadConcurrency()`.
    ///
    /// `BlobManager` is an actor, so this is an `async` property: a
    /// synchronous snapshot would answer from a stale image.
    public var uploadConcurrency: Int {
        get async { await blobManager.getUploadConcurrency() }
    }

    // MARK: - Get-or-create with alias (P1)

    /// Atomic upsert against an alias: if a doc already exists at the
    /// alias return it, otherwise create one. Used for singleton docs
    /// like "the user's notes doc". Mirrors js-bao's
    /// `documents.getOrCreateWithAlias(options)`.
    ///
    /// For `scope: .user`, `alias.userId` defaults to the current user
    /// when omitted.
    public func getOrCreateWithAlias(
        options: GetOrCreateWithAliasOptions
    ) async throws -> GetOrCreateWithAliasResult {
        let alias = options.alias
        // Match JS guard (documentsApi.ts:583-584): aliasKey must be non-empty.
        guard !alias.aliasKey.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "alias.aliasKey is required")
        }
        var userId = alias.userId
        if alias.scope == .user, userId == nil {
            userId = client?.userId
        }

        let body = GetOrCreateWithAliasBody(
            alias: GetOrCreateWithAliasBody.Alias(
                scope: alias.scope.rawValue,
                aliasKey: alias.aliasKey,
                userId: userId
            ),
            title: options.title,
            tags: (options.tags?.isEmpty == false) ? options.tags : nil
        )

        return try await transport.request(
            method: .post,
            path: "/documents/get-or-create-with-alias",
            body: body
        )
    }

    // MARK: - Ergonomic wrappers around top-level client methods (P1)
    //
    // js-bao surfaces `documents.open()` / `openRoot()` / `close()` as
    // thin wrappers around the client root's `openDocument` / etc.
    // Swift's top-level versions own the implementation; these are
    // sub-API forwarders so cross-platform code that calls
    // `client.documents.open(id)` works.

    /// Open a document. Forwards to `client.openDocument(_:options:)`.
    ///
    /// Returns `{ doc, metadata }`, mirroring js-bao's `documents.open`
    /// (`documentsApi.ts`): the live `YDocument` plus the document's locally
    /// cached metadata at open time (`getLocalMetadata`, `nil` when none).
    public func open(
        _ documentId: String,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) async throws -> OpenDocumentResult {
        guard let client else {
            throw JsBaoError(
                code: .unavailable,
                message: "DocumentsAPI.open requires a wired JsBaoClient"
            )
        }
        let doc = try await client.openDocument(documentId, options: options)
        let metadata = documentManager?.getLocalMetadata(documentId)
        return OpenDocumentResult(doc: doc, metadata: metadata)
    }

    /// Open the app's root document (the one returned by
    /// `getRootDocId()`). Throws `notFound` if the app has no root.
    ///
    /// Returns `{ doc, metadata }` like `open`.
    public func openRoot(
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) async throws -> OpenDocumentResult {
        guard let client else {
            throw JsBaoError(
                code: .unavailable,
                message: "DocumentsAPI.openRoot requires a wired JsBaoClient"
            )
        }
        guard let docId = client.rootDocId else {
            throw JsBaoError(
                code: .notFound,
                message: "App has no root document"
            )
        }
        return try await open(docId, options: options)
    }

    /// Close a document. Forwards to `client.closeDocument(_:options:)`.
    ///
    /// When `options.evictLocal` is set, the document's local data is only
    /// evicted if the server already has all of this client's writes —
    /// matching js-bao, which skips eviction (and reports `evicted: false`)
    /// when local writes are still outstanding (#961).
    @discardableResult
    public func close(
        _ documentId: String,
        options: CloseDocumentOptions = CloseDocumentOptions()
    ) async -> CloseDocumentResult {
        // The write-confirmation guard lives in `client.closeDocument` since
        // #2668 — it has to, because a document opened with `retainLocal: false`
        // evicts at close without anyone passing `evictLocal`. Running the
        // 500ms/100ms state-vector poll here as well would double the round trip
        // on every eviction, so this forwards and reports what close decided.
        guard let client else { return CloseDocumentResult(evicted: false) }
        return await client.closeDocument(documentId, options: options)
    }

    /// Resolve an alias and open the document it points at, in one call.
    /// Mirrors js-bao's `documents.openAlias(params, options?)`; returns
    /// `{ doc, metadata }` (as `open` does).
    public func openAlias(
        _ params: AliasRef,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) async throws -> OpenDocumentResult {
        guard let info = try await aliases.resolve(params) else {
            throw JsBaoError(
                code: .aliasNotFound,
                message: "Alias `\(params.aliasKey)` did not resolve to a document"
            )
        }
        return try await open(info.documentId, options: options)
    }

    // MARK: - Sync-state predicates (P2)

    /// Whether the server holds all of this client's writes for the doc.
    /// Async WebSocket state-vector round-trip (`stateVectorCheck`),
    /// mirroring js-bao's `documents.includesWrites(documentId, timeoutMs?)`.
    /// Resolves `false` when offline or the check times out.
    public func includesWrites(documentId: String, timeout: TimeInterval = 5) async -> Bool {
        guard let client else { return false }
        return await client.checkStateVector(documentId: documentId, timeout: timeout).includesWrites
    }

    /// Whether client and server hold identical document state. Async
    /// WebSocket state-vector round-trip (`stateVectorCheck`), mirroring
    /// js-bao's `documents.inSync(documentId, timeoutMs?)`. Resolves
    /// `false` when offline or the check times out. (For a cheap
    /// synchronous read of the last-known local sync state, use
    /// `isSynced(documentId)`.)
    public func inSync(documentId: String, timeout: TimeInterval = 5) async -> Bool {
        guard let client else { return false }
        return await client.checkStateVector(documentId: documentId, timeout: timeout).inSync
    }

    // MARK: - waitFor* sub-API wrappers (P2)
    //
    // Top-level versions live on `JsBaoClient`; these forward so
    // cross-platform call sites can use either path.

    /// Wait until the server confirms it has all of this client's writes,
    /// returning `true` once confirmed and `false` on timeout. Polls the
    /// `stateVectorCheck` round-trip's `includesWrites`, mirroring js-bao's
    /// `documents.waitForWriteConfirmation(documentId, timeoutMs?, pollMs?)` (ms on JS)
    /// — which resolves to a `boolean` rather than throwing on timeout.
    public func waitForWriteConfirmation(
        documentId: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.2
    ) async -> Bool {
        guard let client else { return false }
        // Monotonic, not wall-clock: a clock adjustment mid-wait must not cut
        // the poll loop short or extend it. `DispatchTime + Double` takes the
        // seconds directly, so the `timeoutMs: Int` → `TimeInterval` rename
        // (#2367) did not need this to become a `Date`.
        let deadline = DispatchTime.now() + timeout
        while DispatchTime.now() < deadline {
            if await client.checkStateVector(documentId: documentId).includesWrites {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(max(0, pollInterval) * 1_000_000_000))
        }
        return false
    }

    public func waitForInSync(
        documentId: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.2
    ) async throws {
        guard let client else {
            throw JsBaoError(code: .unavailable, message: "client unset")
        }
        try await client.waitForInSync(
            documentId: documentId, timeout: timeout, pollInterval: pollInterval
        )
    }

    // MARK: - Local-eviction sub-API wrappers (P2)

    /// Evict a single document's local data. Forwards to the top-level
    /// `client.evictLocalDocument(_:)`. Mirrors js-bao's
    /// `documents.evict(documentId, { force })`: a doc with unsynced local
    /// changes (a pending offline create, or open writes that haven't
    /// drained) throws unless `options.force` is set.
    public func evict(
        documentId: String,
        options: EvictDocumentOptions = EvictDocumentOptions()
    ) async throws {
        if !options.force, documentManager?.hasUnsyncedLocalChanges(documentId) == true {
            // Mirror js-bao's `documentManager.evictLocalDocument`
            // (`src/client/internal/documentManager.ts`), which throws a plain
            // `Error("Cannot evict …: has unsynced local changes …")` with no
            // dedicated code. JS has no `UNSYNCED_CHANGES` `JsBaoErrorCode`, so
            // we surface the nearest JS-shared code (`INVALID_ARGUMENT`) with
            // the identical message rather than a Swift-only error code.
            throw JsBaoError(
                code: .invalidArgument,
                message: "Cannot evict \(documentId): has unsynced local changes (use force to override)"
            )
        }
        await client?.evictLocalDocument(documentId)
    }

    /// Evict every doc's local data. Walks the metadata index and evicts
    /// each entry. Mirrors js-bao's `documents.evictAll({ onlySynced })`:
    /// with `options.onlySynced`, docs holding unsynced local changes are
    /// skipped rather than dropped. The top-level client doesn't expose a
    /// dedicated `evictAll` — we walk the index here.
    public func evictAll(
        options: EvictAllDocumentsOptions = EvictAllDocumentsOptions()
    ) async {
        guard let client else { return }
        let metadata = client.listLocalDocuments()
        for documentId in metadata.keys {
            if options.onlySynced, documentManager?.hasUnsyncedLocalChanges(documentId) == true {
                continue
            }
            await client.evictLocalDocument(documentId)
        }
    }
}

// MARK: - DocumentAliasesAPI

public final class DocumentAliasesAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    /// Create or update a document alias.
    public func set(_ params: SetAliasParams) async throws -> DocumentAliasInfo {
        let encodedKey = URLEncoding.encodeComponent(params.aliasKey)
        let body = SetAliasBody(
            documentId: params.documentId,
            userId: params.userId,
            mustNotExist: params.mustNotExist == true ? true : nil
        )
        return try await transport.request(
            method: .put,
            path: "/document-aliases/\(params.scope.rawValue)/\(encodedKey)",
            body: body
        )
    }

    /// Resolve a document alias, returning nil if not found.
    public func resolve(_ params: AliasRef) async throws -> DocumentAliasInfo? {
        let encodedKey = URLEncoding.encodeComponent(params.aliasKey)
        var path = "/document-aliases/\(params.scope.rawValue)/\(encodedKey)"
        if params.scope == .user, let userId = params.userId {
            var query = URLQuery()
            query.append("userId", userId)
            path += query.queryString
        }
        do {
            let info: DocumentAliasInfo = try await transport.request(method: .get, path: path)
            return info
        } catch {
            if isNotFoundError(error) { return nil }
            throw error
        }
    }

    /// Delete a document alias.
    public func delete(_ params: AliasRef) async throws {
        let encodedKey = URLEncoding.encodeComponent(params.aliasKey)
        var path = "/document-aliases/\(params.scope.rawValue)/\(encodedKey)"
        if params.scope == .user, let userId = params.userId {
            var query = URLQuery()
            query.append("userId", userId)
            path += query.queryString
        }
        do {
            try await transport.send(method: .delete, path: path)
        } catch {
            if isNotFoundError(error) { return }
            throw error
        }
    }

    /// List all aliases for a document.
    ///
    /// Decodes each entry independently and drops entries that fail —
    /// a server deployed before #1168's server-side filter can still
    /// return retained legacy `scope: "app"` rows, and one such row must
    /// not fail the whole response (the remaining user aliases are valid).
    public func listForDocument(documentId: String) async throws -> [DocumentAliasInfo] {
        let entries: [FailableEntry<DocumentAliasInfo>] = try await transport.request(
            method: .get,
            path: "/documents/\(documentId)/aliases"
        )
        return entries.compactMap(\.value)
    }

    /// Wrapper that swallows a single element's decode failure instead of
    /// failing the surrounding array.
    private struct FailableEntry<T: Decodable & Sendable>: Decodable, Sendable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    private func isNotFoundError(_ error: Error) -> Bool {
        let msg = String(describing: error)
        return msg.contains("HTTP 404") || msg.contains("status: 404")
    }
}

// MARK: - DocumentBlobContext

public final class DocumentBlobContext: @unchecked Sendable {
    private let documentId: String
    private let transport: any Transport
    private let blobManager: BlobManager

    /// Designated initializer — the typed transport spine.
    public init(
        documentId: String,
        transport: any Transport,
        blobManager: BlobManager
    ) {
        self.documentId = documentId
        self.transport = transport
        self.blobManager = blobManager
    }

    /// Upload a blob to the document.
    public func upload(data: Data, options: BlobUploadSourceOptions = BlobUploadSourceOptions()) async throws -> BlobUploadResult {
        return try await blobManager.uploadFromSource(
            documentId: documentId,
            source: data,
            options: options
        )
    }

    /// List blobs attached to the document.
    ///
    /// Returns a typed page (`items` + optional pagination `cursor`), mirroring
    /// JS `BlobListResult<BlobInfo>`. A bare-array response (no envelope) is
    /// normalized into a result with `cursor == nil`.
    public func list(limit: Int? = nil, cursor: String? = nil) async throws -> DocumentBlobListResult {
        var query = URLQuery()
        if let limit = limit {
            query.append("limit", limit)
        }
        if let cursor = cursor, !cursor.isEmpty {
            query.append("cursor", cursor)
        }
        let path = "/documents/\(documentId)/blobs\(query.queryString)"
        let response: DocumentBlobListResponse = try await transport.request(
            method: .get,
            path: path
        )
        return response.result
    }

    /// Get metadata for a specific blob.
    public func get(blobId: String) async throws -> BlobInfo {
        try await transport.request(method: .get, path: "/documents/\(documentId)/blobs/\(blobId)")
    }

    /// Build a download URL for a blob.
    ///
    /// - Parameters:
    ///   - disposition: serve `inline` (display) or `attachment` (download).
    ///   - attachmentFilename: override the download filename (RFC 5987-encoded),
    ///     mirroring JS `BlobDownloadUrlParams.attachmentFilename`.
    public func downloadUrl(
        blobId: String,
        disposition: BlobDisposition? = nil,
        attachmentFilename: String? = nil
    ) -> String {
        return blobManager.downloadUrl(
            documentId: documentId,
            blobId: blobId,
            disposition: disposition,
            attachmentFilename: attachmentFilename
        )
    }

    /// Delete a blob from the document. Returns `{ deleted }`, mirroring JS.
    ///
    /// Also cancels any queued upload for the blob and evicts it from the local
    /// `BlobManager` cache, matching JS `delete`: a delete issued mid-upload
    /// cancels the in-flight transfer, a later `read` won't serve the deleted
    /// blob stale from cache, and `queue-drained` fires once the queue empties.
    public func delete(blobId: String) async throws -> BlobDeleteResult {
        let result: BlobDeleteResult = try await transport.request(
            method: .delete,
            path: "/documents/\(documentId)/blobs/\(blobId)"
        )
        await blobManager.cancelQueuedUpload(documentId: documentId, blobId: blobId)
        return result
    }

    /// Read (download) the raw blob data.
    ///
    /// - Parameters:
    ///   - force: when `true`, bypass the local cache and re-download from the
    ///     server. Mirrors JS `BlobReadOptions.forceRedownload`.
    ///   - disposition: serve the download `inline` (display) or as an
    ///     `attachment`. Mirrors JS `BlobReadOptions.disposition`; threaded into
    ///     the cache key and download URL so an `inline` and an `attachment`
    ///     read don't collide in cache.
    public func read(blobId: String, force: Bool = false, disposition: BlobDisposition? = nil) async throws -> Data {
        return try await blobManager.read(documentId: documentId, blobId: blobId, force: force, disposition: disposition)
    }

    /// Read a blob and decode it as a UTF-8 `String`. Mirrors JS `read(blobId, { as: "text" })`.
    public func read(blobId: String, as type: String.Type, force: Bool = false, disposition: BlobDisposition? = nil) async throws -> String {
        let data = try await blobManager.read(documentId: documentId, blobId: blobId, force: force, disposition: disposition)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JsBaoError(code: .invalidArgument, message: "Blob \(blobId) is not valid UTF-8 text")
        }
        return string
    }

    /// Read a blob and JSON-decode it into a `Decodable` type. Built on the
    /// raw `read(blobId:)`; mirrors a typed JSON read over the JS `read` bytes.
    public func read<T: Decodable>(blobId: String, as type: T.Type, force: Bool = false, disposition: BlobDisposition? = nil) async throws -> T {
        let data = try await blobManager.read(documentId: documentId, blobId: blobId, force: force, disposition: disposition)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }

    /// Pre-download one or more blobs into the local cache without returning
    /// their bytes. Failures for individual blobs are swallowed (best-effort),
    /// mirroring JS `prefetch(blobIds, { concurrency })`.
    ///
    /// - Parameters:
    ///   - blobIds: the blobs to warm into the cache.
    ///   - concurrency: max concurrent downloads (defaults to 2, matching JS).
    public func prefetch(blobIds: [String], concurrency: Int = 2) async {
        await blobManager.prefetch(
            documentId: documentId,
            blobIds: blobIds,
            concurrency: concurrency
        )
    }

    // MARK: - Upload queue

    /// Upload a file and queue it for background transfer when the immediate
    /// upload can't complete. Mirrors JS `uploadFile`: it shares the upload
    /// path with `upload(data:)` but returns the narrowed `{ blobId, numBytes,
    /// bytesTransferred }` queue shape rather than the full result.
    @discardableResult
    public func uploadFile(data: Data, options: BlobUploadSourceOptions = BlobUploadSourceOptions()) async throws -> BlobUploadFileResult {
        let result = try await blobManager.uploadFromSource(
            documentId: documentId,
            source: data,
            options: options
        )
        return BlobUploadFileResult(
            blobId: result.blobId,
            numBytes: result.numBytes,
            bytesTransferred: result.bytesTransferred
        )
    }

    // The per-document mirror of the app-wide surface on `DocumentsAPI` — same
    // two shapes for the same reasons (#2172): `unavailable, renamed:` stubs
    // for the reads and the result-returning mutators, deprecated
    // fire-and-forget originals beside `Async` twins for the void mutators.
    // `downloadUrl` above is deliberately untouched: it stays synchronous
    // permanently.

    /// The current status of all tracked uploads for this document, newest
    /// first. Mirrors JS `uploads()` (scoped to this document's id).
    @available(*, unavailable, renamed: "uploadsAsync()")
    public func uploads() -> [BlobUploadStatus] {
        fatalError("unavailable — use uploadsAsync()")
    }

    /// The current status of all tracked uploads for this document, newest
    /// first. Mirrors JS `uploads()` (scoped to this document's id).
    public func uploadsAsync() async -> [BlobUploadStatus] {
        return await blobManager.listUploads(documentId: documentId)
    }

    /// Pause an in-progress upload for this document by blob ID. Returns `false`
    /// if no matching, pausable upload is tracked. Mirrors JS `pauseUpload`.
    @available(*, unavailable, renamed: "pauseUploadAsync(blobId:)")
    @discardableResult
    public func pauseUpload(blobId: String) -> Bool {
        fatalError("unavailable — use pauseUploadAsync(blobId:)")
    }

    /// Pause an in-progress upload for this document by blob ID. Returns `false`
    /// if no matching, pausable upload is tracked. Mirrors JS `pauseUpload`.
    @discardableResult
    public func pauseUploadAsync(blobId: String) async -> Bool {
        return await blobManager.pauseUpload(blobId, documentId: documentId)
    }

    /// Resume a paused upload for this document by blob ID. Returns `false` if
    /// no matching, paused upload is tracked. Mirrors JS `resumeUpload`.
    @available(*, unavailable, renamed: "resumeUploadAsync(blobId:)")
    @discardableResult
    public func resumeUpload(blobId: String) -> Bool {
        fatalError("unavailable — use resumeUploadAsync(blobId:)")
    }

    /// Resume a paused upload for this document by blob ID. Returns `false` if
    /// no matching, paused upload is tracked. Mirrors JS `resumeUpload`.
    @discardableResult
    public func resumeUploadAsync(blobId: String) async -> Bool {
        return await blobManager.resumeUpload(blobId, documentId: documentId)
    }

    /// Pause all in-progress uploads for this document, returning once they
    /// are paused. Mirrors JS `pauseAll`.
    public func pauseAllAsync() async {
        await blobManager.pauseAll(documentId: documentId)
    }

    /// Resume all paused uploads for this document, returning once they are
    /// back in the retry rotation. Mirrors JS `resumeAll`.
    public func resumeAllAsync() async {
        await blobManager.resumeAll(documentId: documentId)
    }
}

// MARK: - Request / response shims

/// Body of `POST /documents/get-or-create-with-alias`. `userId` / `title` /
/// `tags` are omitted when `nil`, matching the conditional inserts the untyped
/// dictionary body used.
private struct GetOrCreateWithAliasBody: Encodable, Sendable {
    struct Alias: Encodable, Sendable {
        let scope: String
        let aliasKey: String
        let userId: String?
    }

    let alias: Alias
    let title: String?
    let tags: [String]?
}

/// Body of `PUT /document-aliases/:scope/:key`.
private struct SetAliasBody: Encodable, Sendable {
    let documentId: String
    let userId: String?
    let mustNotExist: Bool?
}



/// The tag endpoints answer with either a bare `[String]` array or a
/// `{ tags }` envelope; anything else yields an empty list — the same
/// tolerance the previous `extractTags` cast chain had. An empty response
/// body is handled one level up by `requestOptional`.
private struct TagListResponse: Decodable, Sendable {
    let tags: [String]

    private enum CodingKeys: String, CodingKey { case tags }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let list = try? container.decode([String].self) {
            tags = list
            return
        }
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let list = try? container.decode([String].self, forKey: .tags) {
            tags = list
            return
        }
        tags = []
    }
}

/// The document blob-list endpoint returns either a bare array of blobs or an
/// `{ items, cursor }` envelope. A bare array is normalized into a result with
/// no cursor.
private struct DocumentBlobListResponse: Decodable, Sendable {
    let result: DocumentBlobListResult

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let list = try? container.decode([BlobInfo].self) {
            result = DocumentBlobListResult(items: list, cursor: nil)
            return
        }
        result = try DocumentBlobListResult(from: decoder)
    }
}
