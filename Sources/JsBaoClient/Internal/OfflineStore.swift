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
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        try await provider.put(store: Self.storeMetaDocs, key: record.documentId, value: record, metadata: nil)
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
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return nil }
        let record: StorageRecord<LocalMetadataEntry>? = try await provider.get(store: Self.storeMetaDocs, key: documentId)
        return record?.value
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
        docMetadata: JSONValue? = nil
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
    }
}

public struct CommitError: Codable, Sendable {
    public var message: String
    public var at: String

    public init(message: String, at: String) {
        self.message = message
        self.at = at
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

public struct AnalyticsMetadataRecord: Codable, Sendable {
    public var lastDailyAuthDate: String?
    public var lastReturnActiveAt: String?
    public var firstDocOpenEmitted: Bool?
    public var firstDocEditEmitted: Bool?
}
