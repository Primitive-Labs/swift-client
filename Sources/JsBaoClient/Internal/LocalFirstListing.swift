import Foundation

/// Projection and merge helpers behind the offline-first `me.*` document
/// lists (#938 / #1058, widened by #2360).
///
/// Deliberately narrow: this owns only the two things both `me.ownedDocuments`
/// and `me.sharedDocuments` do to local metadata rows — classify + project
/// them into result elements, and merge them behind a server page. Endpoint
/// routing, query construction, offline policy, and timeout policy stay with
/// the calling API, which is where they differ (sponsor decision on #2360:
/// no generalized listing subsystem for two non-identical consumers).
enum LocalFirstListing {

    // MARK: - Row classification

    /// Owner discriminator. A local row is "owned" when its permission is
    /// `owner`. Fallback for entries lacking a recorded permission: treat a
    /// local-only or pending-create doc as owned, since the creator is the
    /// owner of a doc that only exists locally.
    static func isOwned(_ entry: LocalMetadataEntry) -> Bool {
        if let permission = entry.permission {
            return permission == DocumentPermission.owner.rawValue
        }
        return entry.localOnly == true || entry.pendingCreate == true
    }

    /// Sentinel tag the server attaches to a root document. Mirrors js-bao's
    /// `ROOT_DOCUMENT_TAG` in `documentsApi.ts`. Shared with
    /// `DocumentsAPI.filterOutRoot` so both list paths test the same sentinel.
    static let rootDocumentTag = "__ROOT_TAG__"

    /// Root-document identity for a local cache row: the id matches the
    /// token's `rootDocId`, or the row carries the `__ROOT_TAG__` sentinel.
    /// The tag check runs even when `rootDocId` is unknown (a JWT without the
    /// claim), so the root never leaks from the local cache either. Mirrors
    /// js-bao's `isRootEntry` in `documentsApi.ts`.
    static func isRoot(_ entry: LocalMetadataEntry, rootDocId: String?) -> Bool {
        let isIdRoot = rootDocId != nil && entry.documentId == rootDocId
        let isRootTagged = entry.tags?.contains(rootDocumentTag) ?? false
        return isIdRoot || isRootTagged
    }

    /// Shared discriminator: a recorded permission that is non-owner. Rows
    /// with no permission are NOT classified as shared (they belong to the
    /// owned fallback above, or are too ambiguous to surface as a share).
    static func isShared(_ entry: LocalMetadataEntry) -> Bool {
        guard let permission = entry.permission else { return false }
        return permission != DocumentPermission.owner.rawValue
    }

    /// Local metadata rows matching `predicate`, optionally tag-filtered.
    /// Mirrors js-bao `getLocalMetadataList`'s tag + permission filtering.
    static func filteredLocalMetadata(
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

    // MARK: - Merge

    /// Merge a server page with local rows the server didn't return: server
    /// rows win on `documentId`, local-only rows are appended. Mirrors js-bao
    /// `_listImpl`'s by-id map (server items seed it, local entries only fill
    /// gaps). One implementation for both `ownedDocuments` and
    /// `sharedDocuments`, which differ only in the element type and its
    /// projection.
    static func merge<T>(
        server: [T],
        local: [LocalMetadataEntry],
        id: (T) -> String,
        project: (LocalMetadataEntry) -> T
    ) -> [T] {
        var seen = Set<String>()
        var merged: [T] = []
        for item in server where seen.insert(id(item)).inserted {
            merged.append(item)
        }
        for entry in local where !seen.contains(entry.documentId) {
            seen.insert(entry.documentId)
            merged.append(project(entry))
        }
        return merged
    }

    // MARK: - Projections

    /// Build the JSON object backing a `DocumentInfo` / `SharedDocument` from
    /// a `LocalMetadataEntry`. Reuses the types' own `Decodable` initializers
    /// (they expose no memberwise init) via `JSONCoding`, keeping a single
    /// source of truth for field defaults. Local rows only carry a subset of
    /// the server fields; the rest fall back to the decoders' defaults
    /// (`createdBy`/`createdAt` → `""`, `permission` → `reader`).
    static func documentJSON(from entry: LocalMetadataEntry) -> [String: JSONValue] {
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
    /// built from a `LocalMetadataEntry` here, so encoding it never
    /// realistically fails — a `nil` means the target type rejected the
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
    static func documentInfo(from entry: LocalMetadataEntry) -> DocumentInfo {
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
    static func sharedDocument(from entry: LocalMetadataEntry) -> SharedDocument {
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

    // MARK: - Writing server rows back into the local cache

    /// The untyped payload `DocumentManager.handleServerDocuments` consumes,
    /// built from a typed server list row. This is how a background refresh
    /// makes the *next* local-first call fresh (#2360): the rows it fetched
    /// land in the local metadata cache the local-first path reads.
    static func serverDocumentPayload(_ info: DocumentInfo) -> [String: Any] {
        // Every optional-on-the-wire field is guarded: `DocumentInfo` decodes
        // an absent `title`/`createdBy`/`createdAt`/`modifiedAt` to `""`, and
        // `DocumentManager.handleServerDocuments` applies whatever key is
        // present — so writing an empty string here would blank a good cached
        // value (e.g. an offline rename not yet synced).
        var payload: [String: Any] = [
            "documentId": info.documentId,
            "permission": info.permission.rawValue,
        ]
        if !info.title.isEmpty { payload["title"] = info.title }
        if !info.createdBy.isEmpty { payload["createdBy"] = info.createdBy }
        if !info.createdAt.isEmpty { payload["createdAt"] = info.createdAt }
        if !info.lastModified.isEmpty { payload["modifiedAt"] = info.lastModified }
        if let tags = info.tags { payload["tags"] = tags }
        return payload
    }
}
