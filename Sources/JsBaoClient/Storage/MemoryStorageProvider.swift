import Foundation

/// In-memory implementation of ``StorageProvider``.
///
/// Useful for tests or ephemeral sessions where persistence is not needed.
/// Thread safety is provided via `NSLock`.
public final class MemoryStorageProvider: StorageProvider, @unchecked Sendable {

    // MARK: - Private state

    /// Storage is organized as `[store: [key: Entry]]`.
    private struct Entry {
        let valueData: Data
        let metadata: [String: String]?
        let updatedAt: String?
    }

    private var stores: [String: [(key: String, entry: Entry)]] = [:]
    private let lock = NSLock()
    private var _isReady = false

    // MARK: - Init

    public init() {}

    // MARK: - StorageProvider

    public func initialize(namespace: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        stores = [:]
        _isReady = true
    }

    public func close() async {
        lock.lock()
        defer { lock.unlock() }
        stores = [:]
        _isReady = false
    }

    public func isReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isReady
    }

    public func get<T: Codable>(store: String, key: String) async throws -> StorageRecord<T>? {
        lock.lock()
        defer { lock.unlock() }

        guard let entries = stores[store],
              let pair = entries.first(where: { $0.key == key }) else {
            return nil
        }
        return try decodeRecord(key: key, entry: pair.entry)
    }

    public func put<T: Codable>(store: String, key: String, value: T, metadata: [String: String]?) async throws {
        let data = try JSONEncoder().encode(value)
        let now = Self.iso8601Now()
        let entry = Entry(valueData: data, metadata: metadata, updatedAt: now)

        lock.lock()
        defer { lock.unlock() }

        var entries = stores[store] ?? []
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index] = (key: key, entry: entry)
        } else {
            entries.append((key: key, entry: entry))
        }
        stores[store] = entries
    }

    public func putBatch<T: Codable>(store: String, records: [(key: String, value: T, metadata: [String: String]?)]) async throws {
        let now = Self.iso8601Now()
        var encoded: [(key: String, entry: Entry)] = []
        for record in records {
            let data = try JSONEncoder().encode(record.value)
            let entry = Entry(valueData: data, metadata: record.metadata, updatedAt: now)
            encoded.append((key: record.key, entry: entry))
        }

        lock.lock()
        defer { lock.unlock() }

        var entries = stores[store] ?? []
        for item in encoded {
            if let index = entries.firstIndex(where: { $0.key == item.key }) {
                entries[index] = item
            } else {
                entries.append(item)
            }
        }
        stores[store] = entries
    }

    public func delete(store: String, key: String) async throws {
        lock.lock()
        defer { lock.unlock() }

        stores[store]?.removeAll(where: { $0.key == key })
    }

    public func clear(store: String) async throws {
        lock.lock()
        defer { lock.unlock() }

        stores[store] = nil
    }

    public func iterate<T: Codable>(store: String, callback: @escaping (StorageRecord<T>) throws -> Void) async throws {
        let snapshot: [(key: String, entry: Entry)]
        lock.lock()
        snapshot = stores[store] ?? []
        lock.unlock()

        for pair in snapshot {
            let record: StorageRecord<T> = try decodeRecord(key: pair.key, entry: pair.entry)
            try callback(record)
        }
    }

    public func keys(store: String) async throws -> [String] {
        lock.lock()
        defer { lock.unlock() }

        return (stores[store] ?? []).map { $0.key }
    }

    public func has(store: String, key: String) async throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return stores[store]?.contains(where: { $0.key == key }) ?? false
    }

    // MARK: - Private helpers

    private func decodeRecord<T: Codable>(key: String, entry: Entry) throws -> StorageRecord<T> {
        let value = try JSONDecoder().decode(T.self, from: entry.valueData)
        return StorageRecord(key: key, value: value, metadata: entry.metadata, updatedAt: entry.updatedAt)
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
