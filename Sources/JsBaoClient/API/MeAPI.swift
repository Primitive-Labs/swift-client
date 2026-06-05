import Foundation

// MARK: - MeAPI

public final class MeAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any
    private let makeRawRequest: ((String, String, Data?, [String: String]) async throws -> (Data, Int))?
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

    public init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        cache: CacheFacade? = nil,
        makeRawRequest: ((String, String, Data?, [String: String]) async throws -> (Data, Int))? = nil,
        localMetadata: @escaping () -> [String: LocalMetadataEntry] = { [:] },
        isOnline: @escaping () -> Bool = { true }
    ) {
        self.makeRequest = makeRequest
        self.cache = cache
        self.makeRawRequest = makeRawRequest
        self.localMetadata = localMetadata
        self.isOnline = isOnline
    }

    /// Retrieves the current user's profile, using the cache when available.
    /// Returns `nil` when there is no current user. Mirrors js-bao's
    /// `me.get(options)` → `UserProfile | null`. `FetchCachedOptions` maps
    /// field-for-field to JS's `GetMeOptions`.
    public func get(options: FetchCachedOptions? = nil) async throws -> UserProfile? {
        guard let cache = cache else {
            let result = try await makeRequest("GET", "/me", nil)
            return try? JSONCoding.decode(UserProfile.self, from: result)
        }

        let mergedOptions = FetchCachedOptions(
            waitForLoad: options?.waitForLoad,
            refreshNetwork: options?.refreshNetwork,
            refreshIfOlderThanMs: options?.refreshIfOlderThanMs ?? Self.defaultRefreshIfOlderThanMs,
            serverTimeoutMs: options?.serverTimeoutMs
        )

        let value = try await cache.fetchCached(
            key: "me",
            fetcher: { [makeRequest] in
                try await makeRequest("GET", "/me", nil)
            },
            options: mergedOptions
        )
        return try? JSONCoding.decode(UserProfile.self, from: value)
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

        var qs: [String] = []
        if let cursor,
           let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("cursor=\(escaped)")
        }
        if let limit { qs.append("limit=\(limit)") }
        if let tag,
           let escaped = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("tag=\(escaped)")
        }
        let path = qs.isEmpty
            ? "/me/shared-documents"
            : "/me/shared-documents?\(qs.joined(separator: "&"))"
        let result = try await makeRequest("GET", path, nil)
        let page = try JSONCoding.decode(SharedDocumentListResult.self, from: result)

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

        var qs: [String] = []
        // JS order: includeRoot, limit, cursor, tag, forward.
        if options?.includeRoot == true { qs.append("includeRoot=true") }
        if let limit { qs.append("limit=\(limit)") }
        if let cursor,
           let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("cursor=\(escaped)")
        }
        if let tag,
           let escaped = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("tag=\(escaped)")
        }
        if options?.forward == true { qs.append("forward=true") }
        let path = qs.isEmpty
            ? "/me/owned-documents"
            : "/me/owned-documents?\(qs.joined(separator: "&"))"
        let result = try await makeRequest("GET", path, nil)
        // Accept either a bare array or an `{ items, cursor }` (legacy
        // `{ documents }`) envelope — matching `documents.list`.
        let serverItems: [DocumentInfo]
        let serverCursor: String?
        if let arr = try? JSONCoding.decode([DocumentInfo].self, from: result) {
            serverItems = arr
            serverCursor = nil
        } else {
            let decoded = try JSONCoding.decode(DocumentListPage.self, from: result)
            serverItems = decoded.items
            serverCursor = decoded.cursor
        }

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
    private static func documentJSON(from entry: LocalMetadataEntry) -> [String: Any] {
        var obj: [String: Any] = ["documentId": entry.documentId]
        if let title = entry.title { obj["title"] = title }
        if let permission = entry.permission { obj["permission"] = permission }
        if let createdBy = entry.createdBy { obj["createdBy"] = createdBy }
        if let createdAt = entry.createdAt { obj["createdAt"] = createdAt }
        if let modifiedAt = entry.modifiedAt { obj["modifiedAt"] = modifiedAt }
        if let tags = entry.tags { obj["tags"] = tags }
        return obj
    }

    /// Map a local owner row to the `DocumentInfo` result element. On the
    /// (practically impossible) decode failure, falls back to a minimal row
    /// carrying just the id so the doc still surfaces.
    private static func documentInfo(from entry: LocalMetadataEntry) -> DocumentInfo {
        if let info = try? JSONCoding.decode(DocumentInfo.self, from: documentJSON(from: entry)) {
            return info
        }
        return (try? JSONCoding.decode(
            DocumentInfo.self,
            from: ["documentId": entry.documentId]
        ))!
    }

    /// Map a local shared row to the `SharedDocument` result element. The
    /// shared-only extras (`grantedBy`/`source`/`invitationId`) aren't tracked
    /// in the local cache, so `grantedBy` decodes to `""` and the rest to
    /// `nil` — the base document fields are what the merge needs.
    private static func sharedDocument(from entry: LocalMetadataEntry) -> SharedDocument {
        var obj = documentJSON(from: entry)
        if let createdBy = entry.createdBy { obj["grantedBy"] = createdBy }
        if let info = try? JSONCoding.decode(SharedDocument.self, from: obj) {
            return info
        }
        return (try? JSONCoding.decode(
            SharedDocument.self,
            from: ["documentId": entry.documentId]
        ))!
    }

    /// Lists pending document invitations for the current user.
    public func pendingDocumentInvitations() async throws -> [PendingDocumentInvitation] {
        let result = try await makeRequest("GET", "/me/document-invitations", nil)
        return try JSONCoding.decode([PendingDocumentInvitation].self, from: result)
    }

    /// Update the current user's profile (name and/or external avatar URL).
    /// Mirrors js-bao's `me.update(params)` → `UserProfile`. Pass
    /// `avatarUrl: .clear` to remove the current avatar (JS `avatarUrl: null`).
    public func update(params: UpdateMeParams) async throws -> UserProfile {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("PATCH", "/me", body)
        await clearCache()
        return try JSONCoding.decode(UserProfile.self, from: result)
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
    ///   when the raw HTTP closure is wired (always in production); the
    ///   previous build silently dropped this argument, so any server
    ///   that strictly validated `Content-Type` would reject the upload.
    ///
    /// Returns a typed `AvatarUploadResult` carrying the new `avatarUrl`,
    /// mirroring js-bao's `{ avatarUrl }`.
    public func uploadAvatar(imageData: Data, contentType: AvatarContentType) async throws -> AvatarUploadResult {
        if let makeRawRequest {
            let headers = ["Content-Type": contentType.rawValue]
            let (body, status) = try await makeRawRequest("POST", "/me/avatar", imageData, headers)
            guard (200..<300).contains(status) else {
                throw HttpError(
                    status: status, message: "Avatar upload failed",
                    body: String(data: body, encoding: .utf8)
                )
            }
            await clearCache()
            return try JSONCoding.decoder.decode(AvatarUploadResult.self, from: body)
        }
        // Fallback when no raw closure is wired (tests that construct
        // MeAPI directly): use the JSON path. The server typically
        // accepts the bytes either way for the avatar endpoint.
        let result = try await makeRequest("POST", "/me/avatar", imageData)
        await clearCache()
        return try JSONCoding.decode(AvatarUploadResult.self, from: result)
    }
}
