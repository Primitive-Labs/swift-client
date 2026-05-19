import Foundation

/// Manages offline storage for metadata, grants, analytics, and JWT persistence.
/// Replaces IndexedDB-based OfflineStore from the JS client with SQLite-backed storage.
public final class OfflineStore: @unchecked Sendable {
    private let lock = NSLock()
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
        lock.lock()
        self.storageProvider = provider
        lock.unlock()
    }

    public func setAuthStorageProvider(_ provider: StorageProvider) {
        lock.lock()
        self.authStorageProvider = provider
        lock.unlock()
    }

    public func getStorageProvider() -> StorageProvider? {
        lock.lock()
        defer { lock.unlock() }
        return storageProvider
    }

    // MARK: - Initialization

    public func ensureMetadataDb(appId: String, userId: String) async throws {
        let namespace = "\(appId):\(userId)"
        lock.lock()
        guard let provider = storageProvider else {
            lock.unlock()
            return
        }
        let alreadyInit = currentNamespace == namespace && isInitialized
        lock.unlock()

        if alreadyInit { return }

        try await provider.initialize(namespace: namespace)

        lock.lock()
        currentNamespace = namespace
        isInitialized = true
        lock.unlock()
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

    public func persistAnalyticsQueue(appId: String, userId: String, events: [[String: Any]]) async throws {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return }
        let data = try JSONSerialization.data(withJSONObject: events)
        let jsonString = String(data: data, encoding: .utf8) ?? "[]"
        try await provider.put(
            store: Self.storeAnalytics,
            key: Self.analyticsQueueKey,
            value: jsonString,
            metadata: ["updatedAt": ISO8601DateFormatter().string(from: Date())]
        )
    }

    public func loadAnalyticsQueue(appId: String, userId: String) async throws -> [[String: Any]] {
        try await ensureMetadataDb(appId: appId, userId: userId)
        guard let provider = storageProvider else { return [] }
        let record: StorageRecord<String>? = try await provider.get(store: Self.storeAnalytics, key: Self.analyticsQueueKey)
        guard let jsonString = record?.value,
              let data = jsonString.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
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
        lock.lock()
        let provider = storageProvider
        let authProvider = authStorageProvider
        isInitialized = false
        currentNamespace = nil
        lock.unlock()

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
        metadataSyncedAt: String? = nil
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
