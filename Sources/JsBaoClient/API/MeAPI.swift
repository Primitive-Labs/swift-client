import Foundation

// MARK: - MeAPI

public final class MeAPI: @unchecked Sendable {
    private let transport: any Transport
    private let cache: CacheFacade?
    /// Snapshot of the local document-metadata cache (`documentId` →
    /// `LocalMetadataEntry`). Drives the offline-first merge in
    /// `ownedDocuments` / `sharedDocuments` (#938). Defaults to empty when
    /// MeAPI is constructed standalone (e.g. in unit tests), which makes both
    /// methods degrade gracefully to a bare network fetch.
    private let localMetadata: () -> [String: LocalMetadataEntry]
    /// Whether the client currently has a live connection. When `false`,
    /// `ownedDocuments` / `sharedDocuments` skip the server and return the
    /// filtered local-cache subset. Defaults to `true` for standalone
    /// construction so the network path is taken.
    private let isOnline: () -> Bool
    /// Writes a freshly-fetched server list back into the local document
    /// metadata cache, so the next local-first `ownedDocuments` call sees it
    /// (#2360). Wired to `DocumentManager.handleServerDocuments` by
    /// `JsBaoClient.setupSubApis`; a no-op for standalone construction.
    private let syncServerDocuments: ([DocumentInfo]) async -> Void
    /// The token's `rootDocId`, so the local-first paths can apply the same
    /// root predicate the server applies to `/me/owned-documents` (#848 /
    /// #2360). Wired to `JsBaoClient.getRootDocId()`; `nil` for standalone
    /// construction, where the `__ROOT_TAG__` sentinel still catches a
    /// tagged root row.
    private let rootDocId: () -> String?
    /// Debug-level path logging (`local` / `local+refresh` / `network`) so a
    /// support case can tell which branch answered a list call.
    private let logger: Logger?

    /// Guards the background-refresh state below — the only mutable state on
    /// this class.
    private let refreshLock = NSLock()
    /// The most recently spawned background refresh. Kept so tests can await
    /// it; production callers never do.
    private var backgroundRefresh: Task<Void, Never>?
    /// Whether a background refresh is running. One at a time: an overlapping
    /// local-first call skips spawning a second concurrent fetch.
    private var refreshInFlight = false

    private static let defaultRefreshIfOlderThan: TimeInterval = 5 * 60 // 5 minutes

    /// JS's `serverTimeoutMs` default for list calls
    /// (`documentsApi.ts`: `?? 10000`).
    private static let defaultServerTimeout: TimeInterval = 10

    /// Public initializer — the typed transport spine. `Logger` is internal,
    /// so the logger-carrying designated initializer below is too; the SDK
    /// wires it from `JsBaoClient.setupSubApis`.
    public convenience init(
        transport: any Transport,
        cache: CacheFacade? = nil,
        localMetadata: @escaping () -> [String: LocalMetadataEntry] = { [:] },
        isOnline: @escaping () -> Bool = { true },
        syncServerDocuments: @escaping ([DocumentInfo]) async -> Void = { _ in },
        rootDocId: @escaping () -> String? = { nil }
    ) {
        self.init(
            transport: transport,
            cache: cache,
            localMetadata: localMetadata,
            isOnline: isOnline,
            syncServerDocuments: syncServerDocuments,
            rootDocId: rootDocId,
            logger: nil
        )
    }

    /// Designated initializer.
    init(
        transport: any Transport,
        cache: CacheFacade?,
        localMetadata: @escaping () -> [String: LocalMetadataEntry],
        isOnline: @escaping () -> Bool,
        syncServerDocuments: @escaping ([DocumentInfo]) async -> Void,
        rootDocId: @escaping () -> String? = { nil },
        logger: Logger?
    ) {
        self.transport = transport
        self.cache = cache
        self.localMetadata = localMetadata
        self.isOnline = isOnline
        self.syncServerDocuments = syncServerDocuments
        self.rootDocId = rootDocId
        self.logger = logger
    }

    /// Retrieves the current user's profile, using the cache when available.
    /// Returns `nil` when there is no current user. Mirrors js-bao's
    /// `me.get(options)` → `UserProfile | null`. `FetchCachedOptions` maps
    /// field-for-field to JS's `GetMeOptions`.
    ///
    /// Deliberately lenient about the response body (JS parity): an empty
    /// body **and** a body that doesn't decode as a `UserProfile` both yield
    /// `nil` rather than throwing — the `try?` here is the one intentional
    /// response-body leniency left on the typed path. Non-2xx statuses still
    /// throw, as everywhere else.
    public func get(options: FetchCachedOptions? = nil) async throws -> UserProfile? {
        guard let cache = cache else {
            return Self.userProfile(from: try await fetchProfile())
        }

        let mergedOptions = FetchCachedOptions(
            waitForLoad: options?.waitForLoad,
            refreshNetwork: options?.refreshNetwork,
            refreshIfOlderThan: options?.refreshIfOlderThan ?? Self.defaultRefreshIfOlderThan,
            serverTimeout: options?.serverTimeout
        )

        let value = try await cache.fetchCachedJSON(
            key: "me",
            fetcher: { [weak self] in
                guard let self = self else { return nil }
                return try await self.fetchProfile()
            },
            options: mergedOptions
        )
        return Self.userProfile(from: value)
    }

    /// One `GET /me`, tolerant of a body that is not a decodable profile.
    ///
    /// `requestOptional` already maps an empty 2xx body to `nil`; the catch
    /// restores the other half of the legacy leniency — before the typed
    /// spine, a malformed JSON body came back as text and the `try?` decode
    /// turned it into `nil`. Only a decode failure is swallowed; non-2xx and
    /// transport errors still propagate.
    private func fetchProfile() async throws -> JSONValue? {
        do {
            return try await transport.requestOptional(method: .get, path: "/me")
        } catch let error as HttpError where error.serverCode == HttpError.decodingFailedCode {
            return nil
        }
    }

    /// Decode the cached/fetched JSON document as a `UserProfile`, or `nil`
    /// when it isn't one.
    private static func userProfile(from value: JSONValue?) -> UserProfile? {
        guard let value = value, let data = try? JSONCoding.encodeData(value) else { return nil }
        return try? JSONCoding.decodeData(UserProfile.self, from: data)
    }

    /// Returns cache metadata for the current user's profile entry.
    public func cacheInfo() async -> MeCacheInfo {
        guard let cache = cache else { return MeCacheInfo(updatedAt: nil, ageMs: nil) }
        let info = await cache.info(key: "me")
        return MeCacheInfo(updatedAt: info.updatedAt, ageMs: info.ageMs)
    }

    /// Clears the cached profile so the next get() fetches fresh data.
    public func clearCache() async {
        guard let cache = cache else { return }
        await cache.clear(key: "me")
    }

    /// List documents the current user has access to but doesn't own
    /// (the "shared with me" filter). Mirrors js-bao's
    /// `client.me.sharedDocuments(options)`. Returns the unified
    /// `{ items, cursor? }` envelope as a typed `SharedDocumentListResult`.
    ///
    /// - Parameters:
    ///   - cursor: opaque pagination cursor returned by the previous call
    ///   - limit: page size
    ///   - tag: filter to documents bearing this tag
    ///
    /// Offline-first (#938): when online, fetches the server page AND merges
    /// in non-owner rows from the local metadata cache (deduped by
    /// `documentId`, server rows winning on conflict) so locally-known shares
    /// the server page didn't return still appear. When offline, returns the
    /// non-owner subset of the local cache only. The non-owner predicate is
    /// the discriminator: rows with `permission == "owner"` (or no permission)
    /// belong to `ownedDocuments` and are excluded here.
    public func sharedDocuments(
        cursor: String? = nil,
        limit: Int? = nil,
        tag: String? = nil
    ) async throws -> SharedDocumentListResult {
        // Local non-owner subset (the "shared with me" cache rows), tag-filtered.
        let localShared = LocalFirstListing.filteredLocalMetadata(
            localMetadata(),
            tag: tag,
            predicate: LocalFirstListing.isShared
        )

        // Offline: return the local cache subset only — no server call.
        if !isOnline() {
            let items = localShared.map { LocalFirstListing.sharedDocument(from: $0) }
            return SharedDocumentListResult(items: items, cursor: nil)
        }

        var query = URLQuery()
        query.appendIfPresent("cursor", cursor)
        if let limit { query.append("limit", limit) }
        query.appendIfPresent("tag", tag)
        let page: SharedDocumentListResult = try await transport.request(
            method: .get,
            path: "/me/shared-documents\(query.queryString)"
        )

        // Merge: server rows win on `documentId`; append local-only shares the
        // server page didn't return.
        let merged = LocalFirstListing.merge(
            server: page.items,
            local: localShared,
            id: { $0.document.documentId },
            project: { LocalFirstListing.sharedDocument(from: $0) }
        )
        return SharedDocumentListResult(items: merged, cursor: page.cursor)
    }

    /// List documents the current user owns (live owner, not creator —
    /// ownership transfer is reflected here). Mirrors js-bao's
    /// `client.me.ownedDocuments(options)`, whose default return is a flat
    /// `DocumentInfo[]`. Accepts both a bare-array response and an
    /// `{ items, cursor? }` envelope.
    ///
    /// Offline-first (#938, widened in #2360): the default `waitForLoad`
    /// (`.localIfAvailableElseNetwork`) returns the local metadata cache's
    /// owner rows immediately when it has any and refreshes from the server in
    /// the background, so the next call is fresh — js-bao parity, and a
    /// freshness change from the pre-#2360 Swift behavior, which always
    /// blocked on the server. Pass `waitForLoad: .network` for the old
    /// always-fresh semantics. A server fetch merges its rows with the local
    /// ones (deduped by `documentId`, server rows winning) so freshly-created
    /// `pendingCreate` docs and other locally-known owned docs the server list
    /// didn't return still appear. When offline, returns the owner subset of
    /// the local cache only. The owner predicate is the discriminator: a row
    /// counts as owned when `permission == "owner"`, or — as a fallback for
    /// entries that predate the permission field — when it is a local-only /
    /// pending-create doc (the creator is the owner).
    ///
    /// See `MeOwnedDocumentsOptions` for the full resolution order.
    public func ownedDocuments(
        cursor: String? = nil,
        limit: Int? = nil,
        tag: String? = nil,
        options: MeOwnedDocumentsOptions? = nil
    ) async throws -> [DocumentInfo] {
        let page = try await ownedDocumentsImpl(
            cursor: cursor, limit: limit, tag: tag, options: options, paged: false
        )
        return page.items
    }

    /// `me.ownedDocuments` returning the `{ items, cursor }` page envelope.
    /// Mirrors js-bao's `ownedDocuments({ returnPage: true })` overload, which
    /// statically resolves to `Promise<DocumentListPage>`. Swift can't express
    /// the union return of the JS overload set, so the page form is a separate
    /// entry point. Equivalent to passing `options.returnPage = true`.
    ///
    /// The paged form never takes the local-first short-circuit: a local
    /// answer ignores `limit` and reports `cursor == nil`, which a paginating
    /// caller reads as "no more pages". js-bao carves the paged form out of
    /// that branch for the same reason (`documentsApi.ts:1234-1237`), so under
    /// the default `waitForLoad` this always goes to the server. The
    /// cache-only modes (`localOnly`, `refreshFromServer: false`,
    /// `waitForLoad: .local`) and the offline fallback still answer locally —
    /// they asked for the cache explicitly — returning every matching row with
    /// `cursor == nil`, which is also what js-bao does.
    public func ownedDocumentsPage(
        cursor: String? = nil,
        limit: Int? = nil,
        tag: String? = nil,
        options: MeOwnedDocumentsOptions? = nil
    ) async throws -> DocumentListPage {
        try await ownedDocumentsImpl(
            cursor: cursor, limit: limit, tag: tag, options: options, paged: true
        )
    }

    /// Shared core for `ownedDocuments` / `ownedDocumentsPage`. Threads the
    /// `MeOwnedDocumentsOptions` into the query string (`includeRoot`,
    /// `forward`) and into the local-vs-network resolution below. The
    /// flat-array and page callers differ only in whether they keep the
    /// cursor.
    ///
    /// Resolution order (#2360 — `waitForLoad` / `serverTimeoutMs` used to be
    /// declared and never read):
    ///
    /// 1. `localOnly`, `refreshFromServer == false`, or `waitForLoad == .local`
    ///    → local cache rows only, no HTTP request, `cursor == nil`.
    /// 2. Offline → `.network` throws `.listUnavailableOffline`; any other
    ///    mode returns local cache rows.
    /// 3. Default `.localIfAvailableElseNetwork` with a non-empty local
    ///    cache → return the local rows immediately and refresh from the
    ///    server in the background so the next call is fresh (js-bao
    ///    `_listImpl` parity — sponsor decision on #2360; before this the
    ///    default always blocked on the server).
    /// 4. Otherwise (`.network`, or an empty local cache) → blocking server
    ///    fetch merged with the local rows, server rows winning by
    ///    `documentId`.
    ///
    /// Every server fetch — blocking or background — is bounded by
    /// `serverTimeoutMs` (default 10000, JS parity; `0` means unbounded, the
    /// `KvCache` precedent). A blocking fetch that exceeds it throws
    /// `.listTimeout` rather than falling back to the local rows: a caller
    /// that asked to wait for the server is told the server didn't answer.
    ///
    /// `limit` / `cursor` are ignored on every local path — the local cache
    /// isn't paginated — and the returned `cursor` is `nil` there. Because of
    /// that, `paged` (set by `ownedDocumentsPage`) suppresses step 3: a paged
    /// caller handed a `nil` cursor reads it as "no more pages", so the paged
    /// form goes to the server rather than short-circuiting on a warm cache.
    /// js-bao gates the same branch on `!returnPage`
    /// (`documentsApi.ts:1234-1237`). Steps 1 and 2 are unaffected — the
    /// caller asked for the cache there, and js-bao answers those locally
    /// under `returnPage` too. For the same reason `paged` also skips step
    /// 4's local merge and returns the server page as-is: unioning
    /// unpaginated local rows into a page would exceed `limit` and repeat
    /// those rows on every page (js-bao returns before its union at
    /// `documentsApi.ts:1338-1340`).
    ///
    /// The app root document is filtered identically on every path (#848):
    /// local rows and server rows alike drop it unless `includeRoot` is set,
    /// matched by id (`getRootDocId()`) or the `__ROOT_TAG__` sentinel rather
    /// than by permission, since the root's permission is `read-write` and
    /// never `owner` (#875). And a local-first call that asked for
    /// `includeRoot` whose cache lacks the root falls through to the server
    /// instead of quietly answering without it — js-bao `_listImpl` parity.
    private func ownedDocumentsImpl(
        cursor: String?,
        limit: Int?,
        tag: String?,
        options: MeOwnedDocumentsOptions?,
        paged: Bool
    ) async throws -> DocumentListPage {
        let includeRoot = options?.includeRoot == true
        let rootId = rootDocId()
        // The server-response filter's rule. A tag query exempts the root
        // there: js-bao's `filterRoot` skips the root filter when a tag was
        // requested (`documentsApi.ts:939-948`), because a root carrying the
        // requested tag should come back.
        //
        // This is deliberately NOT the local predicate's rule. js-bao stacks
        // two filters on local rows: `getLocalMetadataList` admits the root
        // under `includeRoot || !!tag` (`:974-977`), and then `permissionFilter`
        // — for an owner-only endpoint like this one — re-drops it unless
        // `includeRoot` alone is set (`:1003-1006`), since the root's
        // permission is `read-write` and never `owner` (#875). Net: on
        // `me.ownedDocuments` the tag exemption never survives, and only
        // `documents.list` (`ownerOnly: false`, no permission filter) returns a
        // tagged root. Using `keepRoot` locally would make a warm cache return
        // the app root for `ownedDocuments(tag:)` while a cold cache did not.
        let keepRoot = includeRoot || tag != nil

        // Local owner subset, tag-filtered, with the same root predicate the
        // server applies to `/me/owned-documents` (#848): the app root is
        // excluded unless `includeRoot` asked for it. The root is matched by
        // identity rather than permission because its permission is
        // `read-write`, never `owner` (#875) — so under `includeRoot` it has
        // to be admitted past the owner predicate, and otherwise it has to be
        // dropped even though a stale row could still claim `owner`.
        let localOwned = LocalFirstListing.filteredLocalMetadata(
            localMetadata(),
            tag: tag,
            predicate: { entry in
                if LocalFirstListing.isRoot(entry, rootDocId: rootId) {
                    // `includeRoot` alone, not `keepRoot` — js-bao's
                    // owner-only `permissionFilter` exempts the root on
                    // `includeRoot` only (`documentsApi.ts:1003-1006`).
                    return includeRoot
                }
                return LocalFirstListing.isOwned(entry)
            }
        )
        func localPage() -> DocumentListPage {
            DocumentListPage(
                items: localOwned.map { LocalFirstListing.documentInfo(from: $0) },
                cursor: nil
            )
        }

        // JS `_listImpl`: `localOnly` forces `refreshFromServer` off; otherwise
        // a server fetch happens unless `refreshFromServer === false`.
        let localOnly = options?.localOnly == true
        let refreshFromServer = localOnly ? false : (options?.refreshFromServer != false)
        let waitForLoad = options?.waitForLoad ?? .localIfAvailableElseNetwork
        let timeoutMs = (options?.serverTimeout ?? Self.defaultServerTimeout).wholeMilliseconds

        // 1. Caller asked for the cache: no server call at all.
        if localOnly || !refreshFromServer || waitForLoad == .local {
            logger?.debug("[me.ownedDocuments] path: local")
            return localPage()
        }

        // 2. Offline. `.network` asked for the server specifically, so it gets
        // a typed error instead of a silently-local answer.
        if !isOnline() {
            if waitForLoad == .network {
                throw JsBaoError(
                    code: .listUnavailableOffline,
                    message: "me.ownedDocuments(waitForLoad: .network) requires a connection"
                )
            }
            logger?.debug("[me.ownedDocuments] path: local (offline)")
            return localPage()
        }

        var query = URLQuery()
        // JS order: includeRoot, limit, cursor, tag, forward.
        if includeRoot { query.append("includeRoot", "true") }
        if let limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", cursor)
        query.appendIfPresent("tag", tag)
        if options?.forward == true { query.append("forward", "true") }
        let path = "/me/owned-documents\(query.queryString)"

        // 3. Local-first default with a warm cache: answer now, refresh behind.
        // Skipped for the paged form (`ownedDocumentsPage`): a local answer
        // ignores `limit` and carries `cursor == nil`, which a paginating
        // caller reads as "no more pages" — js-bao gates this branch on
        // `!returnPage` for exactly that reason
        // (`documentsApi.ts:1234-1237`).
        // Exception (js-bao `_listImpl` parity): a caller that asked for
        // `includeRoot` and whose cache doesn't hold the root falls through to
        // the server rather than being handed a list that silently lacks it.
        if waitForLoad == .localIfAvailableElseNetwork, !paged, !localOwned.isEmpty {
            let rootMissingLocally = includeRoot
                && rootId != nil
                && !localOwned.contains { $0.documentId == rootId }
            if !rootMissingLocally {
                logger?.debug("[me.ownedDocuments] path: local + background refresh")
                startBackgroundRefresh(path: path, timeoutMs: timeoutMs)
                return localPage()
            }
            logger?.debug("[me.ownedDocuments] path: network (includeRoot, root not cached)")
        }

        // 4. Blocking server fetch.
        logger?.debug("[me.ownedDocuments] path: network")
        let page = try await fetchOwnedDocuments(path: path, timeoutMs: timeoutMs)
        // The server already excludes the root without `includeRoot`; this is
        // defense in depth, and mirrors `DocumentsAPI._listImpl`'s
        // `filterOutRoot` (js-bao `documentsApi.ts:939-948`), tag exemption
        // included.
        var serverItems = page.items
        if !keepRoot {
            serverItems = serverItems.filter { item in
                let isIdRoot = rootId != nil && item.documentId == rootId
                let isRootTagged =
                    item.tags?.contains(LocalFirstListing.rootDocumentTag) ?? false
                return !isIdRoot && !isRootTagged
            }
        }

        // The paged form returns the server page as-is. js-bao returns
        // `pageForReturn` before its `byId` union for the same reason
        // (`documentsApi.ts:1338-1340`): unioning unpaginated local rows into
        // a page would push it past `limit` and repeat the same local-only
        // rows on every page a cursor walk visits.
        if paged {
            return DocumentListPage(items: serverItems, cursor: page.cursor)
        }

        // Merge: server rows win on `documentId`; append local-only owned docs
        // the server list didn't return (e.g. a just-created pendingCreate doc
        // not yet committed).
        let merged = LocalFirstListing.merge(
            server: serverItems,
            local: localOwned,
            id: { $0.documentId },
            project: { LocalFirstListing.documentInfo(from: $0) }
        )
        return DocumentListPage(items: merged, cursor: page.cursor)
    }

    /// One `GET /me/owned-documents`, bounded by `serverTimeoutMs`.
    ///
    /// Accepts either a bare array or an `{ items, cursor }` (legacy
    /// `{ documents }`) envelope — matching `documents.list`. `timeoutMs <= 0`
    /// means unbounded, matching `KvCache`'s reading of the same option.
    private func fetchOwnedDocuments(
        path: String,
        timeoutMs: Int
    ) async throws -> DocumentListEnvelope {
        let transport = self.transport
        let fetch: @Sendable () async throws -> DocumentListEnvelope = {
            try await transport.request(method: .get, path: path)
        }
        guard timeoutMs > 0 else { return try await fetch() }
        do {
            return try await withTimeout(ms: timeoutMs, fetch)
        } catch is AsyncTimeoutError {
            throw JsBaoError(
                code: .listTimeout,
                message: "me.ownedDocuments exceeded serverTimeoutMs (\(timeoutMs)ms)"
            )
        }
    }

    /// Fetch the server list behind an already-returned local-first result and
    /// merge it into the local metadata cache, so the next call is fresh.
    ///
    /// At most one runs at a time: an overlapping local-first call joins the
    /// in-flight refresh instead of issuing a second fetch. Failures are
    /// deliberately silent — the caller already has its result, and nothing is
    /// waiting on this task.
    private func startBackgroundRefresh(path: String, timeoutMs: Int) {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        if refreshInFlight { return }
        refreshInFlight = true
        backgroundRefresh = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshLock.withLock { self.refreshInFlight = false } }
            do {
                let page = try await self.fetchOwnedDocuments(path: path, timeoutMs: timeoutMs)
                await self.syncServerDocuments(page.items)
                // `Logger.debug` isn't autoclosure'd, so the interpolation
                // would run at every log level without this guard.
                if let logger = self.logger, logger.shouldLog(level: .debug) {
                    logger.debug("[me.ownedDocuments] background refresh merged \(page.items.count) row(s)")
                }
            } catch {
                if let logger = self.logger, logger.shouldLog(level: .debug) {
                    logger.debug("[me.ownedDocuments] background refresh failed: \(error)")
                }
            }
        }
    }

    /// Wait for the in-flight background refresh, if any. Test-only hook —
    /// production callers never wait on a refresh by design.
    func awaitBackgroundRefresh() async {
        let task = refreshLock.withLock { backgroundRefresh }
        await task?.value
    }

    /// Lists pending document invitations for the current user.
    public func pendingDocumentInvitations() async throws -> [PendingDocumentInvitation] {
        try await transport.request(method: .get, path: "/me/document-invitations")
    }

    /// Update the current user's profile (name and/or external avatar URL).
    /// Mirrors js-bao's `me.update(params)` → `UserProfile`. Pass
    /// `avatarUrl: .clear` to remove the current avatar (JS `avatarUrl: null`).
    public func update(params: UpdateMeParams) async throws -> UserProfile {
        // The cache is cleared whether or not the response body decodes: on a
        // 2xx the server-side update has already happened, so a cached profile
        // is stale either way. A rejected update (400/403/404/409) changed
        // nothing server-side, so its cache entry is still good and is kept —
        // an offline-first `me.get()` after a rejected update still has a
        // profile to serve.
        do {
            let profile: UserProfile = try await transport.request(
                method: .patch,
                path: "/me",
                body: params
            )
            await clearCache()
            return profile
        } catch let error as HttpError
            where error.serverCode == HttpError.decodingFailedCode
                || error.serverCode == HttpError.emptyBodyCode {
            await clearCache()
            throw error
        }
    }

    /// Upload an avatar image for the current user. Sends the bytes as
    /// the raw HTTP body with the supplied `Content-Type` header (matches
    /// js-bao's `me.uploadAvatar(blob, contentType)` shape). Returns
    /// `{ "avatarUrl": String }`.
    ///
    /// - Parameter contentType: One of the four `AvatarContentType` cases
    ///   (`image/png`, `image/jpeg`, `image/gif`, `image/webp`) — mirrors
    ///   js-bao's typed union, so an invalid MIME is a compile error rather
    ///   than a server-side rejection. Routed via the `Content-Type` header
    ///   on the raw-bytes request.
    ///
    /// Returns a typed `AvatarUploadResult` carrying the new `avatarUrl`,
    /// mirroring js-bao's `{ avatarUrl }`.
    public func uploadAvatar(imageData: Data, contentType: AvatarContentType) async throws -> AvatarUploadResult {
        let (body, status) = try await transport.requestData(
            method: .post,
            path: "/me/avatar",
            body: imageData,
            options: RequestOptions(customHeaders: ["Content-Type": contentType.rawValue])
        )
        guard (200..<300).contains(status) else {
            throw HttpError(
                status: status, message: "Avatar upload failed",
                body: String(data: body, encoding: .utf8)
            )
        }
        await clearCache()
        return try JSONCoding.decodeData(AvatarUploadResult.self, from: body)
    }
}
