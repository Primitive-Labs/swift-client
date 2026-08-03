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

    private static let defaultRefreshIfOlderThanMs = 5 * 60 * 1000 // 5 minutes

    /// Designated initializer — the typed transport spine.
    public init(
        transport: any Transport,
        cache: CacheFacade? = nil,
        localMetadata: @escaping () -> [String: LocalMetadataEntry] = { [:] },
        isOnline: @escaping () -> Bool = { true }
    ) {
        self.transport = transport
        self.cache = cache
        self.localMetadata = localMetadata
        self.isOnline = isOnline
    }

    @available(*, deprecated, message: "Use init(transport:cache:localMetadata:isOnline:) — the untyped makeRequest closure is removed in the next major release.")
    public convenience init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        cache: CacheFacade? = nil,
        makeRawRequest: ((String, String, Data?, [String: String]) async throws -> (Data, Int))? = nil,
        localMetadata: @escaping () -> [String: LocalMetadataEntry] = { [:] },
        isOnline: @escaping () -> Bool = { true }
    ) {
        self.init(
            transport: ClosureTransport(makeRequest: makeRequest, makeRawRequest: makeRawRequest),
            cache: cache,
            localMetadata: localMetadata,
            isOnline: isOnline
        )
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
            refreshIfOlderThanMs: options?.refreshIfOlderThanMs ?? Self.defaultRefreshIfOlderThanMs,
            serverTimeoutMs: options?.serverTimeoutMs
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
        let localShared = Self.filteredLocalMetadata(
            localMetadata(),
            tag: tag,
            predicate: Self.isShared
        )

        // Offline: return the local cache subset only — no server call.
        if !isOnline() {
            let items = localShared.map { Self.sharedDocument(from: $0) }
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
        // server page didn't return. (Mirrors js-bao `_listImpl`'s by-id map:
        // server items seed the map, local entries only fill gaps.)
        var seen = Set<String>()
        var merged: [SharedDocument] = []
        for item in page.items {
            if seen.insert(item.document.documentId).inserted {
                merged.append(item)
            }
        }
        for entry in localShared where !seen.contains(entry.documentId) {
            seen.insert(entry.documentId)
            merged.append(Self.sharedDocument(from: entry))
        }
        return SharedDocumentListResult(items: merged, cursor: page.cursor)
    }

    /// List documents the current user owns (live owner, not creator —
    /// ownership transfer is reflected here). Mirrors js-bao's
    /// `client.me.ownedDocuments(options)`, whose default return is a flat
    /// `DocumentInfo[]`. Accepts both a bare-array response and an
    /// `{ items, cursor? }` envelope.
    ///
    /// Offline-first (#938): when online, fetches the server list AND merges
    /// in owner rows from the local metadata cache (deduped by `documentId`,
    /// server rows winning on conflict) so freshly-created `pendingCreate`
    /// docs and other locally-known owned docs the server list didn't return
    /// still appear. When offline, returns the owner subset of the local
    /// cache only. The owner predicate is the discriminator: a row counts as
    /// owned when `permission == "owner"`, or — as a fallback for entries that
    /// predate the permission field — when it is a local-only / pending-create
    /// doc (the creator is the owner).
    public func ownedDocuments(
        cursor: String? = nil,
        limit: Int? = nil,
        tag: String? = nil,
        options: MeOwnedDocumentsOptions? = nil
    ) async throws -> [DocumentInfo] {
        let page = try await ownedDocumentsImpl(
            cursor: cursor, limit: limit, tag: tag, options: options
        )
        return page.items
    }

    /// `me.ownedDocuments` returning the `{ items, cursor }` page envelope.
    /// Mirrors js-bao's `ownedDocuments({ returnPage: true })` overload, which
    /// statically resolves to `Promise<DocumentListPage>`. Swift can't express
    /// the union return of the JS overload set, so the page form is a separate
    /// entry point. Equivalent to passing `options.returnPage = true`.
    public func ownedDocumentsPage(
        cursor: String? = nil,
        limit: Int? = nil,
        tag: String? = nil,
        options: MeOwnedDocumentsOptions? = nil
    ) async throws -> DocumentListPage {
        try await ownedDocumentsImpl(
            cursor: cursor, limit: limit, tag: tag, options: options
        )
    }

    /// Shared core for `ownedDocuments` / `ownedDocumentsPage`. Threads the
    /// `MeOwnedDocumentsOptions` into the query string (`includeRoot`,
    /// `forward`) and the local-vs-network behavior (`localOnly` /
    /// `refreshFromServer == false` short-circuit to the local cache,
    /// matching js-bao `_listImpl`'s `localOnly` / `refreshFromServer`
    /// branches), then returns the merged page. The flat-array and page
    /// callers differ only in whether they keep the cursor.
    private func ownedDocumentsImpl(
        cursor: String?,
        limit: Int?,
        tag: String?,
        options: MeOwnedDocumentsOptions?
    ) async throws -> DocumentListPage {
        // Local owner subset, tag-filtered.
        let localOwned = Self.filteredLocalMetadata(
            localMetadata(),
            tag: tag,
            predicate: Self.isOwned
        )

        // JS `_listImpl`: `localOnly` forces `refreshFromServer` off; otherwise
        // a server fetch happens unless `refreshFromServer === false`.
        let localOnly = options?.localOnly == true
        let refreshFromServer = localOnly ? false : (options?.refreshFromServer != false)

        // Offline, `localOnly`, or `refreshFromServer == false`: return the
        // local cache subset only — no server call. (Mirrors js-bao's
        // localOnly / !refreshFromServer short-circuits.)
        if !isOnline() || localOnly || !refreshFromServer {
            let items = localOwned.map { Self.documentInfo(from: $0) }
            return DocumentListPage(items: items, cursor: nil)
        }

        var query = URLQuery()
        // JS order: includeRoot, limit, cursor, tag, forward.
        if options?.includeRoot == true { query.append("includeRoot", "true") }
        if let limit { query.append("limit", limit) }
        query.appendIfPresent("cursor", cursor)
        query.appendIfPresent("tag", tag)
        if options?.forward == true { query.append("forward", "true") }
        // Accept either a bare array or an `{ items, cursor }` (legacy
        // `{ documents }`) envelope — matching `documents.list`.
        let page: DocumentListEnvelope = try await transport.request(
            method: .get,
            path: "/me/owned-documents\(query.queryString)"
        )
        let serverItems = page.items
        let serverCursor = page.cursor

        // Merge: server rows win on `documentId`; append local-only owned docs
        // the server list didn't return (e.g. a just-created pendingCreate doc
        // not yet committed). Mirrors js-bao `_listImpl`'s by-id map.
        var seen = Set<String>()
        var merged: [DocumentInfo] = []
        for item in serverItems {
            if seen.insert(item.documentId).inserted {
                merged.append(item)
            }
        }
        for entry in localOwned where !seen.contains(entry.documentId) {
            seen.insert(entry.documentId)
            merged.append(Self.documentInfo(from: entry))
        }
        return DocumentListPage(items: merged, cursor: serverCursor)
    }

    // MARK: - Offline-first merge helpers (#938)

    /// Owner discriminator. A local row is "owned" when its permission is
    /// `owner`. Fallback for entries lacking a recorded permission: treat a
    /// local-only or pending-create doc as owned, since the creator is the
    /// owner of a doc that only exists locally.
    private static func isOwned(_ entry: LocalMetadataEntry) -> Bool {
        if let permission = entry.permission {
            return permission == DocumentPermission.owner.rawValue
        }
        return entry.localOnly == true || entry.pendingCreate == true
    }

    /// Shared discriminator: a recorded permission that is non-owner. Rows
    /// with no permission are NOT classified as shared (they belong to the
    /// owned fallback above, or are too ambiguous to surface as a share).
    private static func isShared(_ entry: LocalMetadataEntry) -> Bool {
        guard let permission = entry.permission else { return false }
        return permission != DocumentPermission.owner.rawValue
    }

    /// Local metadata rows matching `predicate`, optionally tag-filtered.
    /// Mirrors js-bao `getLocalMetadataList`'s tag + permission filtering.
    private static func filteredLocalMetadata(
        _ index: [String: LocalMetadataEntry],
        tag: String?,
        predicate: (LocalMetadataEntry) -> Bool
    ) -> [LocalMetadataEntry] {
        index.values.filter { entry in
            guard predicate(entry) else { return false }
            if let tag {
                return (entry.tags ?? []).contains(tag)
            }
            return true
        }
    }

    /// Build the JSON object backing a `DocumentInfo` / `SharedDocument` from
    /// a `LocalMetadataEntry`. Reuses the types' own `Decodable` initializers
    /// (they expose no memberwise init) via `JSONCoding`, keeping a single
    /// source of truth for field defaults. Local rows only carry a subset of
    /// the server fields; the rest fall back to the decoders' defaults
    /// (`createdBy`/`createdAt` → `""`, `permission` → `reader`).
    private static func documentJSON(from entry: LocalMetadataEntry) -> [String: JSONValue] {
        var obj: [String: JSONValue] = ["documentId": .string(entry.documentId)]
        if let title = entry.title { obj["title"] = .string(title) }
        if let permission = entry.permission { obj["permission"] = .string(permission) }
        if let createdBy = entry.createdBy { obj["createdBy"] = .string(createdBy) }
        if let createdAt = entry.createdAt { obj["createdAt"] = .string(createdAt) }
        if let modifiedAt = entry.modifiedAt { obj["modifiedAt"] = .string(modifiedAt) }
        if let tags = entry.tags { obj["tags"] = .array(tags.map { .string($0) }) }
        return obj
    }

    /// Decode one of the local-row projections above. The dictionary is
    /// built from a `LocalMetadataEntry` in this file, so encoding it never
    /// realistically fails — a `nil` here means the target type rejected the
    /// subset of fields a local row carries.
    private static func decodeLocalRow<T: Decodable>(
        _ type: T.Type,
        from object: [String: JSONValue]
    ) -> T? {
        guard let data = try? JSONCoding.encodeData(object) else { return nil }
        return try? JSONCoding.decodeData(T.self, from: data)
    }

    /// Map a local owner row to the `DocumentInfo` result element. On the
    /// (practically impossible) decode failure, falls back to a minimal row
    /// carrying just the id so the doc still surfaces.
    private static func documentInfo(from entry: LocalMetadataEntry) -> DocumentInfo {
        if let info = decodeLocalRow(DocumentInfo.self, from: documentJSON(from: entry)) {
            return info
        }
        return decodeLocalRow(
            DocumentInfo.self,
            from: ["documentId": .string(entry.documentId)]
        )!
    }

    /// Map a local shared row to the `SharedDocument` result element. The
    /// shared-only extras (`grantedBy`/`source`/`invitationId`) aren't tracked
    /// in the local cache, so `grantedBy` decodes to `""` and the rest to
    /// `nil` — the base document fields are what the merge needs.
    private static func sharedDocument(from entry: LocalMetadataEntry) -> SharedDocument {
        var obj = documentJSON(from: entry)
        if let createdBy = entry.createdBy { obj["grantedBy"] = .string(createdBy) }
        if let info = decodeLocalRow(SharedDocument.self, from: obj) {
            return info
        }
        return decodeLocalRow(
            SharedDocument.self,
            from: ["documentId": .string(entry.documentId)]
        )!
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
