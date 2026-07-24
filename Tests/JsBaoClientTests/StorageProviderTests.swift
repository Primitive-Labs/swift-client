import XCTest
@testable import JsBaoClient

final class StorageProviderTests: XCTestCase {

    // MARK: - SQLite Basic Operations

    func testSQLiteBasicOperations() async throws {
        let tmpDir = NSTemporaryDirectory() + "jsbao-storage-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let dbPath = (tmpDir as NSString).appendingPathComponent("test.sqlite")
        let provider = SQLiteStorageProvider(path: dbPath)
        try await provider.initialize(namespace: "test")

        XCTAssertTrue(provider.isReady())

        // put and get
        try await provider.put(store: "mystore", key: "key1", value: "hello", metadata: ["tag": "v1"])

        let record: StorageRecord<String>? = try await provider.get(store: "mystore", key: "key1")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.key, "key1")
        XCTAssertEqual(record?.value, "hello")
        XCTAssertEqual(record?.metadata?["tag"], "v1")
        XCTAssertNotNil(record?.updatedAt)

        // has
        let exists = try await provider.has(store: "mystore", key: "key1")
        XCTAssertTrue(exists)

        let notExists = try await provider.has(store: "mystore", key: "nonexistent")
        XCTAssertFalse(notExists)

        // keys
        try await provider.put(store: "mystore", key: "key2", value: "world", metadata: nil)
        let allKeys = try await provider.keys(store: "mystore")
        XCTAssertEqual(Set(allKeys), Set(["key1", "key2"]))

        // iterate
        var iteratedRecords: [String] = []
        try await provider.iterate(store: "mystore") { (record: StorageRecord<String>) in
            iteratedRecords.append(record.key)
        }
        XCTAssertEqual(Set(iteratedRecords), Set(["key1", "key2"]))

        // delete
        try await provider.delete(store: "mystore", key: "key1")
        let deleted: StorageRecord<String>? = try await provider.get(store: "mystore", key: "key1")
        XCTAssertNil(deleted)

        // clear
        try await provider.clear(store: "mystore")
        let keysAfterClear = try await provider.keys(store: "mystore")
        XCTAssertTrue(keysAfterClear.isEmpty)

        await provider.close()
        XCTAssertFalse(provider.isReady())
    }

    // MARK: - SQLite Batch Put

    func testSQLiteBatchPut() async throws {
        let tmpDir = NSTemporaryDirectory() + "jsbao-batch-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let dbPath = (tmpDir as NSString).appendingPathComponent("batch.sqlite")
        let provider = SQLiteStorageProvider(path: dbPath)
        try await provider.initialize(namespace: "batch")

        let records: [(key: String, value: Int, metadata: [String: String]?)] = [
            (key: "a", value: 1, metadata: nil),
            (key: "b", value: 2, metadata: ["source": "test"]),
            (key: "c", value: 3, metadata: nil),
        ]

        try await provider.putBatch(store: "numbers", records: records)

        let keys = try await provider.keys(store: "numbers")
        XCTAssertEqual(Set(keys), Set(["a", "b", "c"]))

        let recordB: StorageRecord<Int>? = try await provider.get(store: "numbers", key: "b")
        XCTAssertEqual(recordB?.value, 2)
        XCTAssertEqual(recordB?.metadata?["source"], "test")

        // Batch upsert: update existing key
        let upsertRecords: [(key: String, value: Int, metadata: [String: String]?)] = [
            (key: "b", value: 20, metadata: ["source": "updated"]),
            (key: "d", value: 4, metadata: nil),
        ]
        try await provider.putBatch(store: "numbers", records: upsertRecords)

        let updatedB: StorageRecord<Int>? = try await provider.get(store: "numbers", key: "b")
        XCTAssertEqual(updatedB?.value, 20)

        let allKeys = try await provider.keys(store: "numbers")
        XCTAssertEqual(Set(allKeys), Set(["a", "b", "c", "d"]))

        await provider.close()
    }

    // MARK: - Memory Basic Operations

    func testMemoryBasicOperations() async throws {
        let provider = MemoryStorageProvider()
        try await provider.initialize(namespace: "mem-test")

        XCTAssertTrue(provider.isReady())

        // put and get
        try await provider.put(store: "mystore", key: "key1", value: "hello", metadata: ["tag": "v1"])

        let record: StorageRecord<String>? = try await provider.get(store: "mystore", key: "key1")
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.key, "key1")
        XCTAssertEqual(record?.value, "hello")
        XCTAssertEqual(record?.metadata?["tag"], "v1")

        // has
        let exists = try await provider.has(store: "mystore", key: "key1")
        XCTAssertTrue(exists)

        let notExists = try await provider.has(store: "mystore", key: "nonexistent")
        XCTAssertFalse(notExists)

        // keys
        try await provider.put(store: "mystore", key: "key2", value: "world", metadata: nil)
        let allKeys = try await provider.keys(store: "mystore")
        XCTAssertEqual(Set(allKeys), Set(["key1", "key2"]))

        // iterate
        var iteratedRecords: [String] = []
        try await provider.iterate(store: "mystore") { (record: StorageRecord<String>) in
            iteratedRecords.append(record.key)
        }
        XCTAssertEqual(Set(iteratedRecords), Set(["key1", "key2"]))

        // delete
        try await provider.delete(store: "mystore", key: "key1")
        let deleted: StorageRecord<String>? = try await provider.get(store: "mystore", key: "key1")
        XCTAssertNil(deleted)

        // clear
        try await provider.clear(store: "mystore")
        let keysAfterClear = try await provider.keys(store: "mystore")
        XCTAssertTrue(keysAfterClear.isEmpty)

        await provider.close()
        XCTAssertFalse(provider.isReady())
    }

    // MARK: - Memory Concurrency (issue #1910 — NSLock → withLock)

    /// Concurrent fan-out over `MemoryStorageProvider`'s lock-guarded public
    /// ops after the `NSLock.lock()/unlock()` → `withLock` conversion. Many
    /// tasks race `put`/`get`/`has` against the same store; the invariant is
    /// no lost update — every key written must be readable and `keys()` must
    /// contain all of them. A non-atomic critical section (e.g. a dropped
    /// `withLock` around the entries read-modify-write) would lose writes.
    func testMemoryProviderConcurrentPutsDoNotLoseUpdates() async throws {
        let provider = MemoryStorageProvider()
        try await provider.initialize(namespace: "concurrency")

        let count = 300
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    try await provider.put(store: "s", key: "key-\(i)", value: i, metadata: nil)
                    // Interleave reads with the writes to exercise the lock
                    // under mixed access.
                    _ = try await provider.has(store: "s", key: "key-\(i)")
                }
            }
            try await group.waitForAll()
        }

        let keys = try await provider.keys(store: "s")
        XCTAssertEqual(keys.count, count, "every concurrent put must survive — no lost update")
        XCTAssertEqual(Set(keys), Set((0..<count).map { "key-\($0)" }))

        // Spot-check a sample of values round-tripped correctly.
        for i in stride(from: 0, to: count, by: 37) {
            let record: StorageRecord<Int>? = try await provider.get(store: "s", key: "key-\(i)")
            XCTAssertEqual(record?.value, i)
        }

        await provider.close()
    }
}
