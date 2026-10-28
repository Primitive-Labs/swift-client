import Foundation

/// Manages offline storage for metadata, grants, analytics, and JWT persistence.
/// Replaces IndexedDB-based OfflineStore from the JS client with SQLite-backed storage.
///
/// ## An actor since #1993, Phase D2
///
/// This is one of the async-domain service managers: every operation on it
/// already awaited the storage provider, so there was nothing synchronous worth
/// preserving. Actor isolation replaces the `NSLock` + `@unchecked Sendable`
/// pair outright — no snapshot holder survives, so the whole type is
/// compiler-checked. The provider accessors that used to be synchronous
/// (`setStorageProvider`, `setAuthStorageProvider`, `getStorageProvider`) are
/// isolated now and their callers `await`; `DocumentManager` is the only one in
/// the client, and both of its call sites already sat in `async` functions.
public actor OfflineStore {
    private var storageProvider: StorageProvider?
    private var authStorageProvider: StorageProvider?
    private var currentNamespace: String?
    private var isInitialized = false

    // Store names matching JS constants
    static let storeMetaDocs = "meta"
    static let storeGrants = "grants"
    static let storeAnalytics = "analytics"
    static let storeAnalyticsMeta = "analyticsMeta"
    static let storeAuth = "auth"
    static let storeKv = "kv"

    private static let analyticsQueueKey = "queue"
    private static let analyticsMetaKey = "metadata"

    public init() {}

    // MARK: - Provider Setup

    public func setStorageProvider(_ provider: StorageProvider) {
        self.storageProvider = provider
    }

    public func setAuthStorageProvider(_ provider: StorageProvider) {
        self.authStorageProvider = provider
    }

    public func getStorageProvider() -> StorageProvider? {
        storageProvider
    }

    // MARK: - Initialization

    /// Bind the app+user database, at most once per namespace.
    ///
    /// The three steps are the same three the `NSLock` version had — read the
    /// decision from isolated state, `await` the provider's `initialize` with
    /// nothing held, then write the result back — and the reentrancy story is
    /// unchanged with it: the `await` is a suspension point, so two concurrent
    /// first calls for the same namespace can both pass the guard and both
    /// initialize. That was equally true under the lock (it was released across
    /// the same `await`), and every `StorageProvider` in the client treats a
    /// repeated `initialize` for the same namespace as idempotent. Converting
    /// this to a single-flight would be a behavior change, not part of the
    /// conversion, so it is deliberately left alone.
    public func ensureMetadataDb(appId: String, userId: String) async throws {
        let namespace = "\(appId):\(userId)"
        guard let provider = storageProvider else { return }
        if currentNamespace == namespace && isInitialized { return }

        try await provider.initialize(namespace: namespace)

        currentNamespace = namespace
        isInitialized = true
    }

    // MARK: - Metadata Operations

    public func loadAllMetadata(appId: String, userId: String) async throws -> [LocalMetadataEntry] {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return [] }

        var results: [LocalMetadataEntry] = []
        try await provider.iterate(store: Self.storeMetaDocs) { (record: StorageRecord<LocalMetadataEntry>) in
            results.append(record.value)
        }
        return results
    }

    public func putMetadata(appId: String, userId: String, record: LocalMetadataEntry) async throws {
        _ = try await putMetadataReporting(appId: appId, userId: userId, record: record)
    }

    /// `putMetadata`, but reporting whether anything was actually written.
    ///
    /// With no provider bound this silently wrote nothing, which on a cold
    /// start is how a `documents.create` — metadata-only since #3200 — could
    /// return successfully and leave no durable trace at all. The caller uses
    /// the answer to remember the row and replay it when storage binds.
    @discardableResult
    public func putMetadataReporting(
        appId: String, userId: String, record: LocalMetadataEntry
    ) async throws -> Bool {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return false }
        try await provider.put(store: Self.storeMetaDocs, key: record.documentId, value: record, metadata: nil)
        return true
    }

    public func putMetadataBatch(appId: String, userId: String, records: [LocalMetadataEntry]) async throws {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        let items = records.map { (key: $0.documentId, value: $0, metadata: nil as [String: String]?) }
        try await provider.putBatch(store: Self.storeMetaDocs, records: items)
    }

    public func deleteMetadata(appId: String, userId: String, documentId: String) async throws {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        try await provider.delete(store: Self.storeMetaDocs, key: documentId)
    }

    public func getMetadata(appId: String, userId: String, documentId: String) async throws -> LocalMetadataEntry? {
        try await readMetadata(appId: appId, userId: userId, documentId: documentId).entry
    }

    /// `getMetadata`, but reporting whether the store was actually read.
    ///
    /// `nil` means two different things on a cold start: "no row for this
    /// document" and "no provider bound yet, so nothing could be read". The
    /// local-only classification (#2691) has to tell them apart — the second is
    /// *unknown*, not "ordinary", and a document whose classification is
    /// unknown may not have its content put on the wire.
    public func readMetadata(
        appId: String,
        userId: String,
        documentId: String
    ) async throws -> (entry: LocalMetadataEntry?, readable: Bool) {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return (nil, false) }
        let record: StorageRecord<LocalMetadataEntry>? = try await provider.get(store: Self.storeMetaDocs, key: documentId)
        return (record?.value, true)
    }

    /// Store-level purge of ALL locally persisted document data for this
    /// app's SQLite database: both the metadata store (`meta`) and the Yjs
    /// CRDT store (`yjs_docs`). Both are truncated directly on disk
    /// (`clear` → `DELETE FROM …`), independent of any in-memory document
    /// index — so rows for documents that were never loaded into memory are
    /// removed too. The single app-wide database keys these stores by
    /// `documentId` alone (not by `userId`), so a per-document delete driven
    /// by the current user's in-memory index cannot enforce a fresh-client
    /// boundary. This does, by clearing the on-disk tables outright. Fast
    /// no-op on empty tables (`DELETE FROM` an empty table is instant).
    public func clearAllDocumentData(appId: String, userId: String) async throws {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        try await provider.clear(store: Self.storeMetaDocs)
        try await provider.clear(store: YjsSQLitePersistence.store)
    }

    // MARK: - Grant Operations

    public func putGrant(appId: String, userId: String, key: String, record: OfflineGrant) async throws {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        try await provider.put(store: Self.storeGrants, key: key, value: record, metadata: nil)
    }

    public func getGrant(appId: String, userId: String, key: String) async throws -> OfflineGrant? {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return nil }
        let record: StorageRecord<OfflineGrant>? = try await provider.get(store: Self.storeGrants, key: key)
        return record?.value
    }

    public func deleteGrant(appId: String, userId: String, key: String) async throws {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        try await provider.delete(store: Self.storeGrants, key: key)
    }

    // MARK: - Analytics

    /// Persist the buffered analytics events.
    ///
    /// The payload is `[[String: JSONValue]]`, not `[[String: Any]]` (#1993,
    /// Phase D2): the events cross this type's new isolation boundary, and an
    /// `Any` cannot do that under Swift 6. `JSONValue` is also what the events
    /// already had to be — they are serialized to JSON on the very next line —
    /// so the type now states a constraint the storage format always imposed.
    /// Since Phase D3 `AnalyticsQueue` buffers `[[String: JSONValue]]` itself,
    /// so it hands its rows straight over with no bridging step in between.
    public func persistAnalyticsQueue(appId: String, userId: String, events: [[String: JSONValue]]) async throws {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        let data = try JSONCoding.encodeData(events)
        let jsonString = String(data: data, encoding: .utf8) ?? "[]"
        try await provider.put(
            store: Self.storeAnalytics,
            key: Self.analyticsQueueKey,
            value: jsonString,
            metadata: ["updatedAt": ISO8601DateFormatter().string(from: Date())]
        )
    }

    public func loadAnalyticsQueue(appId: String, userId: String) async throws -> [[String: JSONValue]] {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return [] }
        let record: StorageRecord<String>? = try await provider.get(store: Self.storeAnalytics, key: Self.analyticsQueueKey)
        guard let jsonString = record?.value,
              let data = jsonString.data(using: .utf8),
              let arr = try? JSONCoding.decodeData([[String: JSONValue]].self, from: data) else {
            return []
        }
        return arr
    }

    public func persistAnalyticsMetadata(appId: String, userId: String, metadata: AnalyticsMetadataRecord?) async throws {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        if let metadata = metadata {
            try await provider.put(store: Self.storeAnalyticsMeta, key: Self.analyticsMetaKey, value: metadata, metadata: nil)
        } else {
            try await provider.delete(store: Self.storeAnalyticsMeta, key: Self.analyticsMetaKey)
        }
    }

    public func loadAnalyticsMetadata(appId: String, userId: String) async throws -> AnalyticsMetadataRecord? {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return nil }
        let record: StorageRecord<AnalyticsMetadataRecord>? = try await provider.get(store: Self.storeAnalyticsMeta, key: Self.analyticsMetaKey)
        return record?.value
    }

    // MARK: - Blob upload queue

    /// The upload records of one app and user: one `PersistedUploadRecord`
    /// per queue id. The Swift counterpart of the JS client's
    /// `js-bao:blobs:<app>:<user>` database and its `uploads` store.
    static func blobUploadsStore(appId: String, userId: String) -> String {
        "blobUploads:\(appId):\(userId)"
    }

    /// The queued bytes of one app and user, keyed `<documentId>::<blobId>`.
    static func blobUploadBytesStore(appId: String, userId: String) -> String {
        "blobUploadBytes:\(appId):\(userId)"
    }

    static func blobUploadBytesKey(documentId: String, blobId: String) -> String {
        "\(documentId)::\(blobId)"
    }

    /// Bind the database for an upload write or read without re-binding it.
    ///
    /// The stores name their app and user, so a write for an upload's owner
    /// does not need the database bound to that owner, and it must not move
    /// it: `MemoryStorageProvider.initialize` empties every store, so a
    /// re-bind for another user would take the signed-in user's rows with it.
    private func ensureBlobUploadDb(appId: String, userId: String) async throws {
        if isInitialized { return }
        try await ensureMetadataDb(appId: appId, userId: userId)
    }

    /// Write an upload's record, and its bytes when given. The bytes go
    /// first, so a record is never stored without them.
    func putBlobUpload(appId: String, userId: String, record: PersistedUploadRecord, bytes: Data?) async throws {
        try await ensureBlobUploadDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        if let bytes {
            try await provider.put(
                store: Self.blobUploadBytesStore(appId: appId, userId: userId),
                key: Self.blobUploadBytesKey(documentId: record.documentId, blobId: record.blobId),
                value: bytes,
                metadata: nil
            )
        }
        try await provider.put(
            store: Self.blobUploadsStore(appId: appId, userId: userId), key: record.queueId, value: record, metadata: nil
        )
    }

    /// Delete an upload's record, then its bytes.
    func deleteBlobUpload(appId: String, userId: String, queueId: String, documentId: String, blobId: String) async throws {
        try await ensureBlobUploadDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        try await provider.delete(store: Self.blobUploadsStore(appId: appId, userId: userId), key: queueId)
        try await provider.delete(
            store: Self.blobUploadBytesStore(appId: appId, userId: userId),
            key: Self.blobUploadBytesKey(documentId: documentId, blobId: blobId)
        )
    }

    /// Every upload record of one app and user. A row that does not decode
    /// as a record is skipped; the rest load.
    func loadBlobUploads(appId: String, userId: String) async throws -> [PersistedUploadRecord] {
        try await ensureBlobUploadDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return [] }
        let store = Self.blobUploadsStore(appId: appId, userId: userId)
        var records: [PersistedUploadRecord] = []
        for key in try await provider.keys(store: store) {
            let row: StorageRecord<PersistedUploadRecord>? = try? await provider.get(store: store, key: key)
            if let record = row?.value { records.append(record) }
        }
        return records
    }

    func loadBlobUploadBytes(appId: String, userId: String, documentId: String, blobId: String) async throws -> Data? {
        try await ensureBlobUploadDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return nil }
        let row: StorageRecord<Data>? = try await provider.get(
            store: Self.blobUploadBytesStore(appId: appId, userId: userId),
            key: Self.blobUploadBytesKey(documentId: documentId, blobId: blobId)
        )
        return row?.value
    }

    // MARK: - JWT Persistence

    public func loadPersistedJwt(appId: String, namespace: String) async throws -> PersistedJwtRecord? {
        let provider = authStorageProvider ?? storageProvider
        guard let provider = provider else { return nil }

        let storeKey = "auth:\(appId):\(namespace)"
        try await provider.initialize(namespace: storeKey)

        let record: StorageRecord<PersistedJwtRecord>? = try await provider.get(store: Self.storeAuth, key: "session")
        return record?.value
    }

    public func persistJwt(appId: String, namespace: String, record: PersistedJwtRecord) async throws {
        let provider = authStorageProvider ?? storageProvider
        guard let provider = provider else { return }

        let storeKey = "auth:\(appId):\(namespace)"
        try await provider.initialize(namespace: storeKey)
        try await provider.put(store: Self.storeAuth, key: "session", value: record, metadata: nil)
    }

    public func clearPersistedJwt(appId: String, namespace: String) async throws {
        let provider = authStorageProvider ?? storageProvider
        guard let provider = provider else { return }

        let storeKey = "auth:\(appId):\(namespace)"
        try await provider.initialize(namespace: storeKey)
        try await provider.delete(store: Self.storeAuth, key: "session")
    }

    // MARK: - Lifecycle

    public func closeStorage() async {
        // Read the two providers and reset the init state in one uninterrupted
        // isolated step — no `await` between them, so a concurrent
        // `ensureMetadataDb` cannot observe "still initialized" against a
        // provider that is about to close. (The `lock.withLock` this replaces
        // was doing exactly that job.)
        let provider = storageProvider
        let authProvider = authStorageProvider
        isInitialized = false
        currentNamespace = nil

        // Await both closes so the SQLite handles are fully released
        // before this returns. A subsequent client that opens the same
        // database file would otherwise race the close and hit
        // SQLITE_BUSY ("database is locked").
        await provider?.close()
        await authProvider?.close()
    }
}

// MARK: - Supporting Types

public struct LocalMetadataEntry: Codable, Sendable {
    public var documentId: String
    public var title: String?
    public var permission: String?
    public var createdBy: String?
    public var createdAt: String?
    public var modifiedAt: String?
    public var tags: [String]?
    public var pendingCreate: Bool?
    public var localOnly: Bool?
    public var commitError: CommitError?
    public var metadataSyncedAt: String?
    /// ISO-8601 timestamp of the most recent `openDocument` / persist
    /// for this doc. Drives `setRetentionPolicy` TTL and LRU eviction.
    /// Mirrors js-bao `LocalMetadataEntry.lastOpenedAt`.
    public var lastOpenedAt: String?
    /// Byte length of the doc's Yjs state-as-update at the most recent
    /// persist. Drives `setRetentionPolicy` `maxBytes` enforcement.
    /// Mirrors js-bao `LocalMetadataEntry.localBytes`.
    public var localBytes: Int?
    /// Number of failed background-commit attempts for a pending create.
    /// Mirrors js-bao `LocalMetadataEntry.commitRetryCount`.
    public var commitRetryCount: Int?
    /// ISO-8601 timestamp of the next scheduled background-commit retry.
    /// Mirrors js-bao `LocalMetadataEntry.nextCommitAttemptAt`.
    public var nextCommitAttemptAt: String?
    /// Opaque create-time metadata blob supplied via
    /// `documents.create({ metadata })` / `createDocument(metadata:)`.
    /// Stashed locally so `commitOfflineCreate` can replay it into the
    /// server POST body instead of dropping it. Mirrors js-bao's
    /// `LocalMetadataEntry.docMetadata` (#673).
    public var docMetadata: JSONValue?
    /// The document's format, once this client knows it: `3` for a record-log
    /// document, `1` for an ordinary one. `2` names a large document, which is
    /// no longer served: an open of one is refused.
    ///
    /// `nil` is "not known yet" — a document this client has never completed a
    /// handshake for — and it is a THIRD state, not a synonym for 1. The
    /// socket's receive limit is raised for anything that is not known to be
    /// format 1, because a first open may learn it in a frame the limit
    /// protects. A row written before this
    /// field existed decodes with it absent, which is the same state.
    public var documentFormat: Int?

    // The fields below mirror js-bao's `LocalMetadataEntry`
    // (`src/client/internal/documentManager.ts`) so offline listings can
    // report the same state the JS client reports (#2662, parity C26). All
    // optional: rows written before the widening still decode.

    /// The permission last known for this document, cached locally so an
    /// offline listing can still report access level. Mirrors js-bao
    /// `lastKnownPermission`. `permission` above stays as the raw
    /// server-listing value; this one is written by the permission-apply path.
    public var lastKnownPermission: String?
    /// ISO-8601 timestamp of when `lastKnownPermission` was cached — the age
    /// a caller needs to decide whether to trust it. Mirrors js-bao
    /// `permissionCachedAt`.
    public var permissionCachedAt: String?
    /// ISO-8601 timestamp of the document's last known server-side
    /// modification, tracked separately from `metadataSyncedAt` (which records
    /// when *this client* last refreshed the metadata). Mirrors js-bao
    /// `lastSyncedAt`.
    public var lastSyncedAt: String?
    /// Whether this document holds a local edit that has not reached the
    /// server. Persisted so the flag survives a restart — the in-memory
    /// `unconfirmedLocalWrites` set does not. Mirrors js-bao
    /// `hasUnsyncedLocalChanges`.
    public var hasUnsyncedLocalChanges: Bool?
    /// Blob id of the document's thumbnail, for offline listings that render
    /// one. Mirrors js-bao `thumbnailBlobId`.
    public var thumbnailBlobId: String?
    /// ISO-8601 timestamp of when access to this document was granted.
    /// Mirrors js-bao `grantedAt`.
    public var grantedAt: String?
    /// ISO-8601 timestamp of when a pending create actually committed to the
    /// server. Mirrors js-bao `createCommittedAt`, the #1953 GSI-lag bridge:
    /// the owned-docs merge recency-gates on the later of this and
    /// `createdAt`, so a slow-to-commit offline create is still bridged while
    /// the server's `permissionsForUser` GSI catches up.
    public var createCommittedAt: String?
    /// Whether a local CRDT snapshot exists for this document. Named for
    /// js-bao's `hasIndexedDbSnapshot`; Swift's local store is SQLite, and the
    /// field keeps the JS name so cross-platform consumers read one vocabulary.
    public var hasIndexedDbSnapshot: Bool?
    /// #4921 — a db3 `client.db3.create` made on this device: its pending
    /// create commits through `POST db3` under its id, not `POST /documents`.
    public var db3Create: Bool?
    /// #4921 — the db3 type that commit asks the server to install.
    public var db3Type: String?
    /// #4921 — the server refused this pending db3 create for good (the
    /// refusal is in `commitError`): reconnects do not repeat it, and
    /// `commitOfflineCreate(documentId:)` tries again.
    public var commitRefused: Bool?

    public init(
        documentId: String,
        title: String? = nil,
        permission: String? = nil,
        createdBy: String? = nil,
        createdAt: String? = nil,
        modifiedAt: String? = nil,
        tags: [String]? = nil,
        pendingCreate: Bool? = nil,
        localOnly: Bool? = nil,
        commitError: CommitError? = nil,
        metadataSyncedAt: String? = nil,
        lastOpenedAt: String? = nil,
        localBytes: Int? = nil,
        commitRetryCount: Int? = nil,
        nextCommitAttemptAt: String? = nil,
        docMetadata: JSONValue? = nil,
        lastKnownPermission: String? = nil,
        permissionCachedAt: String? = nil,
        lastSyncedAt: String? = nil,
        hasUnsyncedLocalChanges: Bool? = nil,
        thumbnailBlobId: String? = nil,
        grantedAt: String? = nil,
        createCommittedAt: String? = nil,
        hasIndexedDbSnapshot: Bool? = nil,
        db3Create: Bool? = nil,
        db3Type: String? = nil,
        commitRefused: Bool? = nil
    ) {
        self.documentId = documentId
        self.title = title
        self.permission = permission
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.tags = tags
        self.pendingCreate = pendingCreate
        self.localOnly = localOnly
        self.commitError = commitError
        self.metadataSyncedAt = metadataSyncedAt
        self.lastOpenedAt = lastOpenedAt
        self.localBytes = localBytes
        self.commitRetryCount = commitRetryCount
        self.nextCommitAttemptAt = nextCommitAttemptAt
        self.docMetadata = docMetadata
        self.lastKnownPermission = lastKnownPermission
        self.permissionCachedAt = permissionCachedAt
        self.lastSyncedAt = lastSyncedAt
        self.hasUnsyncedLocalChanges = hasUnsyncedLocalChanges
        self.thumbnailBlobId = thumbnailBlobId
        self.grantedAt = grantedAt
        self.createCommittedAt = createCommittedAt
        self.hasIndexedDbSnapshot = hasIndexedDbSnapshot
        self.db3Create = db3Create
        self.db3Type = db3Type
        self.commitRefused = commitRefused
    }
}

public struct CommitError: Codable, Sendable {
    public var message: String
    public var at: String
    /// The server's refusal code, for a pending db3 create the server refused (#4921).
    public var code: String?

    public init(message: String, at: String, code: String? = nil) {
        self.message = message
        self.at = at
        self.code = code
    }
}

public struct OfflineGrant: Codable, Sendable {
    public var key: String
    public var userId: String
    public var appId: String
    public var rootDocId: String?
    public var email: String?
    public var name: String?
    public var expiresAt: String?
    public var method: String?
}

public struct PersistedJwtRecord: Codable, Sendable {
    public var key: String
    public var token: String
    public var expiresAt: String?
    public var storedAt: String?
    public var userId: String?
    public var version: Int?
}

/// One queued upload as the client keeps it across launches: the JS client's
/// `UploadRecord` (`src/client/internal/blobManager.ts`), field for field, so
/// both clients describe an upload the same way. Times are ms since the
/// epoch. `status` is `pending`, `uploading`, `paused` or `failed`;
/// `uploaded` is never written. `destination` is set for a session upload
/// and a db3 upload only, and a record without one is a document upload.
struct PersistedUploadRecord: Codable, Sendable, Equatable {
    var queueId: String
    var documentId: String
    var blobId: String
    var filename: String
    var contentType: String
    var sha256Base64: String
    var disposition: String?
    var retainLocal: Bool?
    var numBytes: Int
    var status: String
    var attempts: Int
    var nextAttemptAt: Double
    var createdAt: Double
    var updatedAt: Double
    var lastError: String?
    var lastErrorCode: String?
    var destination: UploadDestination?

    init(
        queueId: String, documentId: String, blobId: String, filename: String, contentType: String,
        sha256Base64: String, disposition: String?, retainLocal: Bool?, numBytes: Int, status: String,
        attempts: Int, nextAttemptAt: Double, createdAt: Double, updatedAt: Double,
        lastError: String?, lastErrorCode: String?, destination: UploadDestination?
    ) {
        self.queueId = queueId
        self.documentId = documentId
        self.blobId = blobId
        self.filename = filename
        self.contentType = contentType
        self.sha256Base64 = sha256Base64
        self.disposition = disposition
        self.retainLocal = retainLocal
        self.numBytes = numBytes
        self.status = status
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastError = lastError
        self.lastErrorCode = lastErrorCode
        self.destination = destination
    }

    private enum CodingKeys: String, CodingKey {
        case queueId, documentId, blobId, filename, contentType, sha256Base64, disposition, retainLocal
        case numBytes, status, attempts, nextAttemptAt, createdAt, updatedAt, lastError, lastErrorCode, destination
    }

    /// Tolerant, as JS `hydrateUploadsForIdentity` is: unknown keys are
    /// ignored, and a missing field takes the default JS gives it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        blobId = try c.decode(String.self, forKey: .blobId)
        queueId = try c.decodeIfPresent(String.self, forKey: .queueId) ?? blobId
        documentId = try c.decode(String.self, forKey: .documentId)
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? blobId
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? "application/octet-stream"
        sha256Base64 = try c.decodeIfPresent(String.self, forKey: .sha256Base64) ?? ""
        disposition = try c.decodeIfPresent(String.self, forKey: .disposition)
        retainLocal = try c.decodeIfPresent(Bool.self, forKey: .retainLocal)
        numBytes = try c.decodeIfPresent(Int.self, forKey: .numBytes) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextAttemptAt = try c.decodeIfPresent(Double.self, forKey: .nextAttemptAt) ?? now
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? now
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? now
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastErrorCode = try c.decodeIfPresent(String.self, forKey: .lastErrorCode)
        destination = try? c.decodeIfPresent(UploadDestination.self, forKey: .destination)
    }
}

/// The JS record's `destination`: `{ kind: "agent-session", sessionId }` for
/// a session upload, `{ kind: "db3", documentId }` for a db3 upload. A
/// `document` destination is read but never written, and an unknown kind
/// reads as one.
extension UploadDestination: Codable {
    private enum CodingKeys: String, CodingKey { case kind, sessionId, documentId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "agent-session":
            self = .agentSession(try c.decode(String.self, forKey: .sessionId))
        case "db3":
            self = .db3(try c.decode(String.self, forKey: .documentId))
        default:
            self = .document
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .document:
            try c.encode("document", forKey: .kind)
        case .db3(let documentId):
            try c.encode("db3", forKey: .kind)
            try c.encode(documentId, forKey: .documentId)
        case .agentSession(let sessionId):
            try c.encode("agent-session", forKey: .kind)
            try c.encode(sessionId, forKey: .sessionId)
        }
    }
}

public struct AnalyticsMetadataRecord: Codable, Sendable {
    public var lastDailyAuthDate: String?
    public var lastReturnActiveAt: String?
    public var firstDocOpenEmitted: Bool?
    public var firstDocEditEmitted: Bool?
}
