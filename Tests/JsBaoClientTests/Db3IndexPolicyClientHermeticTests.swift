import XCTest
@testable import JsBaoClient

/// #5322 behaviors 26 (its session and refresher half) and 28, edge cases 31
/// and 44 (Swift) — the Swift client hears that a db3's index list changed,
/// and reads on indexes this device declined.
///
/// - 26: a `record.indexes` frame calls the session host's `indexesChanged`;
///   `RecordLogIndexRefresher.noticed(_:)` reads now, or once after a read on
///   its way, and drops a notice for an unbound db3.
/// - 31: a notice with the socket down reads nothing and raises nothing.
/// - 28: the public types; a `$search` on a declined text index is refused
///   `.db3IndexDeclinedOnDevice` with js-bao's details through
///   `DynamicModel`, the shared model and `client.db3.records`; a
///   scalar filter, `$contains` and a facet on declined indexes answer the
///   same rows with no SQL error.
/// - 44: a member read never names an absent table: after a decline and
///   under a `deviceIndexes` default that leaves members out.
final class Db3IndexPolicyClientHermeticTests: XCTestCase {

    // MARK: - The public types (behavior 28)

    func testThePublicTypes() {
        XCTAssertEqual(Db3LocalIndexStatus.allCases.map(\.rawValue), ["built", "building", "unbuilt", "declined"])
        let index = Db3LocalIndex(name: "idx_text_note", model: "Note", fields: ["title"], kind: .text, on: .device, status: .declined, reason: "declined on this device")
        XCTAssertEqual(index.reason, "declined on this device")
        XCTAssertEqual(JsBaoClientOptions(apiUrl: "https://a.test", wsUrl: "wss://a.test", appId: "app").deviceIndexes, .all)
        XCTAssertEqual(
            JsBaoClientOptions(apiUrl: "https://a.test", wsUrl: "wss://a.test", appId: "app", deviceIndexes: .kinds([.scalar])).deviceIndexes,
            .kinds([.scalar])
        )
        XCTAssertEqual(JsBaoErrorCode.db3IndexDeclinedOnDevice.rawValue, "DB3_INDEX_DECLINED_ON_DEVICE")
        let state = Db3State(
            id: "db3", resident: false, subscribed: false, phase: .idle, progress: nil, cursor: 0, rows: 0, lastSyncAt: nil,
            pendingWrites: 0, permission: nil, error: nil
        )
        XCTAssertNil(state.indexes)
        let listed = Db3State(
            id: "db3", resident: true, subscribed: false, phase: .idle, progress: nil, cursor: 0, rows: 0, lastSyncAt: nil,
            pendingWrites: 0, permission: nil, error: nil, indexes: [index]
        )
        XCTAssertEqual(listed.indexes, [index])
    }

    // MARK: - The session hears record.indexes (behavior 26)

    final class Connection: RecordLogConnection, @unchecked Sendable {
        func send(_ frame: [String: JSONValue]) {}
        func connected() -> Bool { true }
    }

    func testARecordIndexesFrameCallsTheHostOnceAndChangesNothingInTheStore() async throws {
        let directory = NSTemporaryDirectory() + "/db3-index-notice-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(host: provider, documentId: "doc-1", clientId: "client-1", logger: Logger(level: .none))
        let heard = LockedBox<[String]>([])
        let connection = Connection()
        var host = RecordLogSessionHost(connection: { connection }, declarations: { [:] }, synced: { _ in }, syncFailed: { _, _ in })
        host.indexesChanged = { documentId in heard.withValue { $0.append(documentId) } }
        let session = RecordLogSession(documentId: "doc-1", binding: binding, host: host, logger: Logger(level: .none))
        await session.attach()
        let marks = try binding.store.marks()
        await session.receive(["type": "record.indexes", "documentId": "doc-1", "added": ["idx_text_note"], "removed": []])
        XCTAssertEqual(heard.withValue { $0 }, ["doc-1"])
        XCTAssertEqual(try binding.store.marks(), marks)
    }

    // MARK: - The refresher's notice (behavior 26, edge case 31)

    final class World: @unchecked Sendable {
        private let lock = NSLock()
        var reads = 0
        var held: [CheckedContinuation<[RecordLogIndexEntry], Error>] = []
        var hold = false
        var applied: [[RecordLogIndexEntry]] = []
        var bound = true
        var socket = true

        func with<T>(_ body: (World) -> T) -> T { lock.withLock { body(self) } }

        func deps() -> RecordLogIndexRefresherDeps {
            RecordLogIndexRefresherDeps(
                read: { [self] _ in
                    let holding = with { world -> Bool in
                        world.reads += 1
                        return world.hold
                    }
                    guard holding else { return [] }
                    return try await withCheckedThrowingContinuation { continuation in with { $0.held.append(continuation) } }
                },
                apply: { [self] _, entries, whileLatest in _ = try whileLatest { with { $0.applied.append(entries) } } },
                bound: { [self] _ in with { $0.bound } },
                socketUp: { [self] in with { $0.socket } },
                declares: { _ in false }
            )
        }

        func answer(_ name: String) {
            let next = with { world -> CheckedContinuation<[RecordLogIndexEntry], Error>? in
                world.held.isEmpty ? nil : world.held.removeFirst()
            }
            next?.resume(returning: [RecordLogIndexEntry(name: name, model: "Note", fields: [name], unique: false)])
        }
    }

    private static let id = "01JD5322NOT1CESWIFTXXXXXXX"

    func testANoticeReadsNowOrOnceAfterTheReadOnItsWay() async throws {
        let world = World()
        let refresher = RecordLogIndexRefresher(deps: world.deps())
        try await refresher.opened(Self.id).value
        XCTAssertEqual(world.with { $0.reads }, 1)
        refresher.noticed(Self.id)
        try await eventually(description: "a read on the notice") { world.with { $0.applied.count } == 2 }

        world.with { $0.hold = true }
        let reading = refresher.declared(Self.id)
        try await eventually(description: "the declared read") { world.with { $0.held.count } == 1 }
        for _ in 0..<5 { refresher.noticed(Self.id) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(world.with { $0.reads }, 3, "a notice while a read is on its way waits for it")
        XCTAssertFalse(refresher.settled(Self.id))
        world.answer("declared")
        try await reading.value
        try await eventually(description: "the one follow-up read") { world.with { $0.held.count } == 1 }
        XCTAssertEqual(world.with { $0.reads }, 4)
        world.answer("noticed")
        try await eventually(description: "the follow-up applied") { world.with { $0.applied.last?.first?.name } == "noticed" }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(world.with { $0.reads }, 4)
        XCTAssertTrue(refresher.settled(Self.id))
    }

    func testANoticeForAnUnboundDb3OrWithTheSocketDownReadsNothing() async throws {
        let world = World()
        let refresher = RecordLogIndexRefresher(deps: world.deps())
        try await refresher.opened(Self.id).value
        world.with { $0.bound = false }
        refresher.noticed(Self.id)
        world.with {
            $0.bound = true
            $0.socket = false
        }
        refresher.noticed(Self.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(world.with { $0.reads }, 1)
    }

    // MARK: - Reads on declined indexes (behavior 28, edge case 44)

    private static let schema = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "year": FieldDescriptor(type: .number),
        "tags": FieldDescriptor(type: .stringset),
    ])

    private static let entries = [
        RecordLogIndexEntry(name: "idx_text_note", model: "Note", fields: ["title"], unique: false, kind: .text, on: .both),
        RecordLogIndexEntry(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, kind: .members, on: .device),
        RecordLogIndexEntry(name: "idx_records_note_year", model: "Note", fields: ["year"], unique: false, on: .device),
    ]

    private static let rows: [JSONValue] = [
        ["id": "a", "title": "red apple", "year": 2001, "tags": ["fruit", "sweet"]],
        ["id": "b", "title": "green pear", "year": 2002, "tags": ["fruit"]],
        ["id": "c", "title": "apple pie", "year": 2001, "tags": ["sweet"]],
    ]

    private func refusal(_ body: () throws -> Void) -> JsBaoError? {
        do {
            try body()
            return nil
        } catch {
            return error as? JsBaoError
        }
    }

    func testASearchOnADeclinedTextIndexIsRefusedAndScalarAndMemberReadsScan() async throws {
        let fixture = try await RecordLogViewFixture.make("declined-reads")
        defer { fixture.remove() }
        let notes = try fixture.member(Self.schema, "db3-d")
        let binding = try fixture.open("db3-d")
        try binding.store.syncIndexes(Self.entries)
        try fixture.seed("db3-d", "Note", Self.rows)
        let ids = { (filter: [String: JSONValue]) in try notes.query(filter).compactMap { $0["id"]?.stringValue }.sorted() }
        let before = (year: try ids(["year": 2001]), tags: try ids(["tags": ["$contains": "sweet"]]))
        let facet = AggregateOptions(groupBy: ["tags"], operations: [AggregateOperation(type: .count)])
        let facetBefore = try RecordLogViewReader(store: binding.store, documents: ["db3-d"]).aggregate("Note", facet, setFields: ["tags"])

        XCTAssertEqual(try binding.store.declineIndex("idx_text_note").status, .declined)
        _ = try binding.store.declineIndex("idx_members_note_tags")
        _ = try binding.store.declineIndex("idx_records_note_year")
        let details: [String: JSONValue] = ["model": "Note", "index": "idx_text_note", "kind": "text"]
        for (label, read) in [
            ("DynamicModel", { _ = try notes.query(["$search": "apple"]) }),
            ("shared", { _ = try fixture.shared(Self.schema).query(["$search": "apple"]) }),
            ("records", { _ = try fixture.records("db3-d").query("Note", ["$search": "apple"]) }),
        ] as [(String, () throws -> Void)] {
            let refused = refusal(read)
            XCTAssertEqual(refused?.code, .db3IndexDeclinedOnDevice, label)
            XCTAssertEqual(refused?.details, details, label)
            XCTAssertTrue(refused?.message.contains("client.db3.indexes.accept") == true, label)
        }
        XCTAssertEqual(try ids(["year": 2001]), before.year)
        XCTAssertEqual(try ids(["tags": ["$contains": "sweet"]]), before.tags)
        XCTAssertNil(try binding.store.readView { try RecordLogIndexes.memberTable($0, documentId: "db3-d", model: "Note", field: "tags") })
        XCTAssertEqual(try RecordLogViewReader(store: binding.store, documents: ["db3-d"]).aggregate("Note", facet, setFields: ["tags"]), facetBefore)

        // Accepted, the search answers again.
        XCTAssertEqual(try binding.store.acceptIndex("idx_text_note").status, .built)
        XCTAssertEqual(Set(try notes.query(["$search": "apple"]).compactMap { $0["id"]?.stringValue }), ["a", "c"])
    }

    func testAMemberReadUnderADefaultThatLeavesMembersOutScans() async throws {
        let world = try await Db3DeviceIndexWorld.make("default-members")
        defer { world.remove() }
        let store = RecordLogStore(host: world.provider, documentId: "db3-n", clientId: "client-1", deviceIndexes: .kinds([.scalar, .text]))
        try store.initialize()
        _ = try store.mintWriter()
        try store.syncIndexes(Self.entries)
        try world.seed("db3-n", "Note", Self.rows)
        XCTAssertNil(try store.readView { try RecordLogIndexes.memberTable($0, documentId: "db3-n", model: "Note", field: "tags") })
        let found = try store.queryView("Note", ["tags": ["$contains": "sweet"]], options: QueryOptions(limit: 100)).data.compactMap { $0["id"]?.stringValue }
        XCTAssertEqual(found.sorted(), ["a", "c"])
        XCTAssertEqual(try store.localIndexes().first { $0.name == "idx_members_note_tags" }?.status, .declined)
    }
}
