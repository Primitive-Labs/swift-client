import Foundation

/// A record stored in a key-value store.
public struct StorageRecord<T: Codable>: Codable, Sendable where T: Sendable {
    public let key: String
    public let value: T
    public let metadata: [String: String]?
    public let updatedAt: String?

    public init(key: String, value: T, metadata: [String: String]? = nil, updatedAt: String? = nil) {
        self.key = key
        self.value = value
        self.metadata = metadata
        self.updatedAt = updatedAt
    }
}

/// Protocol matching the JS StorageProvider interface.
///
/// Provides a key-value store organized by named stores (analogous to
/// IndexedDB object stores). Each store contains records keyed by string,
/// with JSON-serializable values and optional metadata.
public protocol StorageProvider: AnyObject, Sendable {
    /// Initialize the storage provider with a namespace (used to isolate data per client instance).
    func initialize(namespace: String) async throws

    /// Close the storage provider and release resources.
    func close() async

    /// Whether the provider has been initialized and is ready for use.
    func isReady() -> Bool

    /// Get a single record by store and key. Returns nil if not found.
    func get<T: Codable>(store: String, key: String) async throws -> StorageRecord<T>?

    /// Put a single record into a store, upserting by key.
    func put<T: Codable>(store: String, key: String, value: T, metadata: [String: String]?) async throws

    /// Put multiple records into a store in a single transaction.
    func putBatch<T: Codable>(store: String, records: [(key: String, value: T, metadata: [String: String]?)]) async throws

    /// Delete a single record by store and key.
    func delete(store: String, key: String) async throws

    /// Clear all records in a store.
    func clear(store: String) async throws

    /// Iterate over all records in a store, invoking the callback for each.
    func iterate<T: Codable>(store: String, callback: @escaping (StorageRecord<T>) throws -> Void) async throws

    /// Return all keys in a store.
    func keys(store: String) async throws -> [String]

    /// Check whether a key exists in a store.
    func has(store: String, key: String) async throws -> Bool
}
