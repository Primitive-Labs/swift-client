import XCTest
import SQLite3
import YSwift
@testable import JsBaoClient

/// What a format-3 save costs, measured rather than argued (principle 9), beside
/// the format-2 figures of `Format2LatencyHermeticTests`. Nothing is thresholded:
/// a number that depends on the machine is a finding to read. The one claim
/// enforced is that every measurement was taken.
final class RecordLogLatencyHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "views": FieldDescriptor(type: .number, indexed: true)]
    )

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/rl-latency-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// A host that adopts only the public protocol: every save commits on its own.
    private final class PlainHost: Format2SqlHost, @unchecked Sendable {
        let inner: SQLiteStorageProvider
        init(_ inner: SQLiteStorageProvider) { self.inner = inner }
        func withConnection<T>(_ body: (any Format2SqlConnection) throws -> T) throws -> T { try inner.withConnection(body) }
    }

    private final class Commits: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func reset() { lock.withLock { _count = 0 } }
        func install(on provider: SQLiteStorageProvider) throws {
            let context = Unmanaged.passUnretained(self).toOpaque()
            _ = try provider.withRecordLogConnection { connection in
                sqlite3_commit_hook(connection.rawHandle, { context in
                    let commits = Unmanaged<Commits>.fromOpaque(context!).takeUnretainedValue()
                    commits.lock.withLock { commits._count += 1 }
                    return 0
                }, context)
            }
        }
    }

    private func model(_ host: any Format2SqlHost, provider: SQLiteStorageProvider) throws -> (DynamicModel, RecordLogDocumentBinding) {
        let binding = try RecordLogDocumentBinding(
            host: host, documentId: "doc-\(UUID().uuidString.prefix(6))", clientId: "client",
            engine: BaoModelQueryEngine(host: provider)
        )
        let member = MultiDocModel(schema: Self.schema).connect(docId: binding.documentId, doc: YDocument())
        try member.bindRecordLog(binding)
        return (member, binding)
    }

    private func millis(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testTheCostOfAFormatThreeSaveAndOfFiveHundredTogether() async throws {
        let provider = try await makeProvider()
        let commits = Commits()
        try commits.install(on: provider)

        // One save at a time: p50 and p95 of 200.
        let (single, _) = try model(provider, provider: provider)
        var timings: [Double] = []
        for index in 0..<200 {
            timings.append(try millis { _ = try single.save(id: "s\(index)", values: ["title": .string("t"), "views": .number(Double(index))]) })
        }
        let sorted = timings.sorted()
        print(String(format: "[#4309 latency] format-3 facade save — p50 %.4f ms, p95 %.4f ms (200 samples)",
                     sorted[100], sorted[189]))

        // 500 saves in a loop with the group commit on.
        let (grouped, groupedBinding) = try model(provider, provider: provider)
        try groupedBinding.store.flush()
        commits.reset()
        let groupedMs = try millis {
            for index in 0..<500 { _ = try grouped.save(id: "g\(index)", values: ["title": .string("t")]) }
            try groupedBinding.store.flush()
        }
        let groupedCommits = commits.count
        print(String(format: "[#4309 latency] 500 saves, group commit on — %.1f ms, %d commits", groupedMs, groupedCommits))

        // The same loop on a host that cannot defer a commit: one per save.
        let (plain, _) = try model(PlainHost(provider), provider: provider)
        commits.reset()
        let plainMs = try millis {
            for index in 0..<500 { _ = try plain.save(id: "p\(index)", values: ["title": .string("t")]) }
        }
        let plainCommits = commits.count
        print(String(format: "[#4309 latency] 500 saves, group commit off — %.1f ms, %d commits", plainMs, plainCommits))

        // 500 saves in one transact: one entry.
        let (batched, batchedBinding) = try model(provider, provider: provider)
        let transactMs = try millis {
            try batched.transact {
                for index in 0..<500 { _ = try batched.save(id: "b\(index)", values: ["title": .string("t")]) }
            }
            try batchedBinding.store.flush()
        }
        let entries = try batchedBinding.store.pendingOf(batchedBinding.writer).count
        print(String(format: "[#4309 latency] 500 saves in one transact — %.1f ms, %d entry", transactMs, entries))

        XCTAssertEqual(timings.count, 200, "every save was measured")
        XCTAssertGreaterThan(groupedCommits, 0)
        XCTAssertLessThan(groupedCommits, plainCommits, "saves issued together share commits")
        XCTAssertGreaterThanOrEqual(plainCommits, 500)
        XCTAssertEqual(entries, 1)
    }
}
