import Foundation
import JsBaoSQLite
import XCTest
import YSwift
@testable import JsBaoClient

/// #5221 behaviors 17, 18 and 20 (relationships), edge cases 26 and 31–35 in
/// Swift — the twin of js-bao's `record-log-client-drift-5221` and
/// `db3-drift-model-5221` suites.
///
/// - 17: `record_log_state` gains `known_head` and `known_head_at` at storage
///   version 7; a version-5 or version-6 store reads no head until one is heard; the
///   session declares wire version 3, stamps each frame on arrival and
///   records the head from `record.opened`, `record.results` (held ones with
///   their own stamps) and `record.catchUpPage`, never lowering it.
/// - 18: a device page answers `drift`, `QueryOptions.maxDrift` refuses
///   `DB3_DRIFT_EXCEEDED`, `Db3State.drift` reports the same; the rows, the
///   include legs and the sync state are read in one read transaction.
/// - 20, 35: a `hasManyThrough` page answers the drift of both its reads.
/// - 34: `db3.records(id)` carries `drift` and takes `maxDrift`.
final class RecordLogDriftHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private var directories: [String] = []
    private var fixture: RecordLogViewFixture?

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        fixture?.remove()
        fixture = nil
        try await super.tearDown()
    }

    private static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "n": FieldDescriptor(type: .number),
    ])

    private func harness() async throws -> H.Fixture {
        let directory = NSTemporaryDirectory() + "/record-log-drift-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return try await H.Fixture(provider: provider, clientId: "client-a", fetches: false, timings: H.timings)
    }

    private func views() async throws -> RecordLogViewFixture {
        let made = try await RecordLogViewFixture.make("drift")
        fixture = made
        return made
    }

    private func until(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    private func heads(_ marks: RecordLogMarks) -> [Int?] { [marks.knownHead, marks.knownHeadAt.map(Int.init), marks.cursor] }

    private static func result(_ l: Int, _ id: String? = nil) -> RecordLogResultItem {
        let id = id ?? "r\(l)"
        return .result(RecordLogResult(l: l, e: 1, changes: [RecordLogChange(model: "Note", id: id, row: ["id": .string(id), "n": .number(Double(l))])]))
    }

    private func columns(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withRecordLogConnection { connection in
            try connection.query("SELECT name FROM pragma_table_info('record_log_state')").compactMap { $0["name"].stringValue }
        }
    }

    private func refusal(_ body: () throws -> Any) -> JsBaoError? {
        do {
            _ = try body()
        } catch {
            return error as? JsBaoError
        }
        return nil
    }

    // MARK: - Behavior 17: the head columns at storage version 7

    func testStorageVersionSevenAddsTheHeadColumnsAndAStoreHoldsNoHeadBeforeOneIsHeard() async throws {
        XCTAssertGreaterThanOrEqual(RecordLogSchema.storageVersion, 7)
        let h = try await harness()
        XCTAssertTrue(Set(try columns(h.provider)).isSuperset(of: ["known_head", "known_head_at"]))
        XCTAssertNil(h.marks.knownHead)
        XCTAssertNil(h.marks.knownHeadAt)
        XCTAssertNil(try h.binding.store.storedState().knownHead)
    }

    func testAVersionFiveStoreMigratesAndReadsNoHeadUntilOneIsHeard() async throws {
        try await assertMigratesWithNoHead(from: "5")
    }

    /// A store #5223's build left at version 6 (its index cache keyed by
    /// kind, no head columns) migrates as a version-5 store does.
    func testAVersionSixStoreMigratesAndReadsNoHeadUntilOneIsHeard() async throws {
        try await assertMigratesWithNoHead(from: "6")
    }

    private func assertMigratesWithNoHead(from planted: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let h = try await harness()
        _ = try h.binding.store.receive(writer: h.binding.writer, items: [Self.result(1)])
        // Planted as that version left it.
        try h.provider.withRecordLogConnection { connection in
            let present = try connection.query("SELECT name FROM pragma_table_info('record_log_state')").compactMap { $0["name"].stringValue }
            for column in ["known_head", "known_head_at"] where present.contains(column) {
                try connection.executeScript("ALTER TABLE record_log_state DROP COLUMN \(column)")
            }
            try connection.executeScript("UPDATE record_log_meta SET value = '\(planted)' WHERE key = 'storage_version'")
        }
        let reopened = RecordLogStore(host: h.provider, documentId: H.documentId, clientId: "client-a")
        try reopened.initialize()
        let version = try h.provider.withRecordLogConnection { connection in
            try connection.query("SELECT value FROM record_log_meta WHERE key = 'storage_version'").first?["value"].stringValue
        }
        XCTAssertEqual(version, String(RecordLogSchema.storageVersion), file: file, line: line)
        XCTAssertTrue(Set(try columns(h.provider)).isSuperset(of: ["known_head", "known_head_at"]), file: file, line: line)
        XCTAssertEqual(heads(try reopened.marks()), [nil, nil, 1], file: file, line: line)
        _ = try reopened.receive(writer: h.binding.writer, items: [Self.result(2)], heard: RecordLogHeard(head: 4, receivedAt: 1_000))
        XCTAssertEqual(heads(try reopened.marks()), [4, 1_000, 2], file: file, line: line)
    }

    func testTheMemoryTablesKeepTheHeadAsTheStoreDoes() throws {
        let memory = RecordLogMemoryTables()
        let rules = RecordLogRules(tables: memory, writer: "w")
        _ = try rules.receive(Self.result(1))
        try rules.noteHead(RecordLogHeard(head: 3, receivedAt: 500))
        XCTAssertEqual(memory.knownHead(), RecordLogKnownHead(head: 3, at: 500))
        try rules.noteHead(RecordLogHeard(head: 2, receivedAt: 900))
        XCTAssertEqual(memory.knownHead(), RecordLogKnownHead(head: 3, at: 500))
    }

    // MARK: - Behavior 17: recording the head (edge cases 25 and 31)

    func testTheStoreRecordsTheHeadRaisedOrConfirmedAndNeverLowered() async throws {
        let h = try await harness()
        let store = h.binding.store
        let writer = h.binding.writer
        try store.setState(writer: writer, heard: RecordLogHeard(head: 10, receivedAt: 1_000))
        XCTAssertEqual(heads(try store.marks()), [10, 1_000, 0])
        _ = try store.receive(writer: writer, items: [Self.result(1)], heard: RecordLogHeard(head: 12, receivedAt: 2_000))
        XCTAssertEqual(heads(try store.marks()), [12, 2_000, 1])
        _ = try store.receive(writer: writer, items: [Self.result(2)], heard: RecordLogHeard(head: 11, receivedAt: 3_000))
        XCTAssertEqual(heads(try store.marks()), [12, 2_000, 2], "a lower head changes neither column")
        _ = try store.receive(writer: writer, items: [Self.result(3)], heard: RecordLogHeard(head: 12, receivedAt: 4_000))
        XCTAssertEqual(heads(try store.marks()), [12, 4_000, 3], "an equal head is a fresh confirmation")
        _ = try store.receive(writer: writer, items: (4...13).map { Self.result($0) }, heard: RecordLogHeard(receivedAt: 5_000))
        XCTAssertEqual(heads(try store.marks()), [13, 5_000, 13], "a frame without a head raises the bound to the cursor")
        try store.beginCatchUp(writer: writer, full: false)
        _ = try store.applyCatchUpPage(writer: writer, rows: [], lsn: 13, heard: RecordLogHeard(head: 20, receivedAt: 6_000))
        XCTAssertEqual(heads(try store.marks()), [20, 6_000, 13])
        _ = try store.completeCatchUp(writer: writer, lsn: 14, heard: RecordLogHeard(head: 21, receivedAt: 7_000))
        XCTAssertEqual(heads(try store.marks()), [21, 7_000, 14])
    }

    func testAFrameWithoutAHeadRecordsNothingBeforeAHeadIsHeard() async throws {
        let h = try await harness()
        _ = try h.binding.store.receive(writer: h.binding.writer, items: [Self.result(1)], heard: RecordLogHeard(receivedAt: 100))
        XCTAssertEqual(heads(h.marks), [nil, nil, 1])
    }

    func testALowerHeadFromAnotherSessionNeverLowersTheStoredHead() async throws {
        let h = try await harness()
        let store = h.binding.store
        try store.beginCatchUp(writer: h.binding.writer, full: false)
        _ = try store.completeCatchUp(writer: h.binding.writer, lsn: 50, heard: RecordLogHeard(head: 100, receivedAt: 1_000))
        let sibling = RecordLogStore(host: h.provider, documentId: H.documentId, clientId: "client-b")
        try sibling.initialize()
        _ = try sibling.receive(writer: try sibling.mintWriter(), items: [Self.result(51)], heard: RecordLogHeard(head: 60, receivedAt: 2_000))
        XCTAssertEqual(heads(try store.marks()), [100, 1_000, 51])
        let sync = try XCTUnwrap(try store.queryView("Note").drift?[H.documentId])
        XCTAssertEqual(sync.entriesBehind, 49)
        XCTAssertEqual(
            refusal { try store.queryView("Note", options: QueryOptions(maxDrift: Db3MaxDrift(entries: 40))) }?.code,
            .db3DriftExceeded
        )
    }

    // MARK: - Behavior 17: receipt stamps through the session (edge cases 24 and 32)

    func testTheSessionDeclaresWireVersionThreeAndStampsFramesWhenTheyArrive() async throws {
        XCTAssertEqual(recordLogWireVersion, 3)
        let h = try await harness()
        await h.session.start()
        XCTAssertEqual(h.of("record.open").first?["wireVersion"], 3)
        h.clock.value = 1_000
        var opened = H.opened(lsn: 0)
        opened["wireVersion"] = 3
        opened["head"] = 0
        await h.feed(opened)
        await until("open") { h.synced.value == 1 }
        XCTAssertEqual(heads(h.marks), [0, 1_000, 0])
        h.clock.value = 2_000
        var results = H.results([H.result(1, "r1")])
        results["head"] = 1
        await h.feed(results)
        XCTAssertEqual(heads(h.marks), [1, 2_000, 1])
    }

    private func heldThroughCatchUp(pageHead: Int) async throws -> H.Fixture {
        let h = try await harness()
        await h.session.start()
        h.clock.value = 1_000
        var opened = H.opened(lsn: 2, catchUp: .object(["mode": "paged", "cursor": 0, "upTo": 2]))
        opened["wireVersion"] = 3
        opened["head"] = 2
        await h.feed(opened)
        await until("the catch-up's start") { !h.of("record.catchUp").isEmpty }
        let stream = h.of("record.catchUp").first?["stream"]
        // Heard at T0 = 5,000 and held: the catch-up is in progress.
        h.clock.value = 5_000
        var held = H.results([H.result(3, "r3")])
        held["head"] = 3
        await h.feed(held)
        // The catch-up's last page at T0 + 2 s.
        h.clock.value = 7_000
        var page = H.page(rows: [H.row("r1"), H.row("r2")], lsn: 2)
        if let stream { page["stream"] = stream }
        page["head"] = .number(Double(pageHead))
        await h.feed(page)
        await until("caught up") { h.synced.value == 1 }
        return h
    }

    func testAHeldResultAppliesWithItsOwnReceiptStampNotTheApplyTime() async throws {
        let h = try await heldThroughCatchUp(pageHead: 2)
        XCTAssertEqual(heads(h.marks), [3, 5_000, 3])
    }

    func testTheCompletedCatchUpsHeadHeardLaterAndAsHighKeepsItsOwnTime() async throws {
        let h = try await heldThroughCatchUp(pageHead: 3)
        XCTAssertEqual(heads(h.marks), [3, 7_000, 3])
    }

    func testARestartRepliesHeadIsKeptThoughNoRowsApplyAndTheReopenNeverAnswers() async throws {
        let h = try await harness()
        await h.session.start()
        h.clock.value = 1_000
        var opened = H.opened(lsn: 2, catchUp: .object(["mode": "paged", "cursor": 0, "upTo": 2]))
        opened["wireVersion"] = 3
        opened["head"] = 2
        await h.feed(opened)
        await until("the catch-up's start") { !h.of("record.catchUp").isEmpty }
        // The room's floor passed the cursor; by now its head is 9.
        h.clock.value = 5_000
        var restart: [String: JSONValue] = ["type": "record.catchUpPage", "documentId": .string(H.documentId), "restart": true, "head": 9]
        if let stream = h.of("record.catchUp").first?["stream"] { restart["stream"] = stream }
        await h.feed(restart)
        await until("the reopen") { h.of("record.open").count == 2 }
        // The connection drops before the reopen answers.
        h.clock.value = 6_000
        await h.session.disconnected()
        XCTAssertEqual(heads(try h.binding.store.marks()), [9, 5_000, 0])
    }

    func testAFrameIsStampedBeforeItWaitsForABusySession() async throws {
        let h = try await harness()
        await h.session.start()
        h.clock.value = 1_000
        // The session's synced callback holds the actor until released.
        let hold = DispatchSemaphore(value: 0)
        h.holdSynced.value = hold
        var opened = H.opened(lsn: 0)
        opened["wireVersion"] = 3
        opened["head"] = 0
        let busy = Task { await h.feed(opened) }
        await until("the session busy") { h.synced.value == 1 }
        // Heard at 5,000 while the session is busy; applied once it is free, at 9,000.
        h.clock.value = 5_000
        let reads = h.clockReads.value
        var results = H.results([H.result(1, "r1")])
        results["head"] = 4
        results["documentId"] = .string(RecordLogReceiptHarness.documentId)
        let heard = Task { await h.session.deliver(results) }
        await until("the frame stamped") { h.clockReads.value > reads }
        h.clock.value = 9_000
        h.holdSynced.value = nil
        hold.signal()
        await busy.value
        await heard.value
        XCTAssertEqual(heads(h.marks), [4, 5_000, 1])
    }

    func testAResultsFrameThatChangesNoRowStillTellsThePendingListeners() async throws {
        let h = try await harness()
        let told = LockedBox(0)
        h.binding.onPendingChanged { told.withValue { $0 += 1 } }
        await h.session.start()
        h.clock.value = 1_000
        var opened = H.opened(lsn: 0)
        opened["wireVersion"] = 3
        opened["head"] = 0
        await h.feed(opened)
        await until("open") { h.synced.value == 1 }
        var results = H.results([H.result(1, "r1")])
        results["head"] = 1
        h.clock.value = 2_000
        await h.feed(results)
        let before = told.value
        // The same result again, heard later with a higher head: no row changes.
        results["head"] = 4
        h.clock.value = 3_000
        await h.feed(results)
        XCTAssertEqual(heads(h.marks), [4, 3_000, 1])
        XCTAssertEqual(told.value, before + 1)
    }

    func testTheBindingIsLiveExactlyWhileItsSessionIs() async throws {
        let h = try await harness()
        XCTAssertFalse(h.binding.isLive)
        await h.session.start()
        XCTAssertFalse(h.binding.isLive)
        await h.feed(H.opened(lsn: 0))
        await until("open") { h.synced.value == 1 }
        XCTAssertTrue(h.binding.isLive)
        await h.session.disconnected()
        XCTAssertFalse(h.binding.isLive)
    }

    // MARK: - Behavior 18: drift on a page, and maxDrift (edge cases 22, 23 and 26)

    /// db3s A (5 behind, heard 10 s ago), B (current, heard 1 s ago), N (no head) and L (local-only).
    private func seeded() async throws -> (RecordLogViewFixture, MultiDocModel, Date) {
        let f = try await views()
        let now = Date()
        let at = { (seconds: Double) in Int64((now.timeIntervalSince1970 - seconds) * 1000) }
        for (doc, rows) in [("db3-a", 3), ("db3-b", 2), ("db3-n", 1), ("db3-l", 1)] {
            try f.seed(doc, "Note", (1...rows).map { n in .object(["id": .string("\(doc)-\(n)"), "n": .number(Double(n))]) })
            try f.member(Self.note, doc)
        }
        let a = try f.open("db3-a")
        try a.setState(heard: RecordLogHeard(head: 8, receivedAt: at(10)))
        let b = try f.open("db3-b")
        try b.setState(heard: RecordLogHeard(head: 2, receivedAt: at(1)))
        try f.open("db3-l").setState(localOnly: true)
        return (f, f.shared(Self.note), now)
    }

    func testAPageAnswersDriftKeyedByDb3IdOverTheSyncedDb3sWhoseHeadIsKnown() async throws {
        let (f, shared, now) = try await seeded()
        let page = try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a", "db3-b", "db3-n", "db3-l"]))
        XCTAssertEqual(page.data.count, 7)
        let drift = try XCTUnwrap(page.drift)
        XCTAssertEqual(Set(drift.keys), ["db3-a", "db3-b"])
        XCTAssertEqual(drift["db3-a"]?.entriesBehind, 5)
        XCTAssertEqual(drift["db3-a"]?.live, false)
        XCTAssertEqual(drift["db3-a"]?.pendingWrites, 0)
        XCTAssertEqual(drift["db3-a"]?.asOf.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970 - 10, accuracy: 0.01)
        XCTAssertEqual(drift["db3-b"]?.entriesBehind, 0)
        // Live while the binding is.
        try f.open("db3-a").setLive(true)
        XCTAssertEqual(try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a"])).drift?["db3-a"]?.live, true)
        // The include variant and a single member's page answer it too.
        XCTAssertEqual(try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-b"]), include: []).drift?["db3-b"]?.entriesBehind, 0)
        XCTAssertEqual(try f.member(Self.note, "db3-a").queryPaged(nil).drift?["db3-a"]?.entriesBehind, 5)
        XCTAssertEqual(try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-l"])).drift, [:])
    }

    func testAPageIsNotLiveWhileTheRoomCannotReachTheClientThoughItsSessionStaysOpen() async throws {
        let (f, shared, _) = try await seeded()
        try f.open("db3-a").setLive(true)
        // Offline mode can leave the socket, and so the session, open.
        let reachable = LockedBox(true)
        RecordLogLiveness.connect(f.provider) { reachable.value }
        let live = { try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a"])).drift?["db3-a"] }
        XCTAssertEqual(try live()?.live, true)
        reachable.value = false
        let offline = try XCTUnwrap(try live())
        XCTAssertEqual(offline.live, false)
        XCTAssertEqual(offline.entriesBehind, 5)
        XCTAssertFalse(try f.open("db3-a").isLive)
        reachable.value = true
        XCTAssertEqual(try live()?.asOf, offline.asOf)
        XCTAssertEqual(try live()?.live, true)
    }

    func testMaxDriftRefusesPastABoundWithTheDriftInDetailsAndPassesAtIt() async throws {
        let (_, shared, _) = try await seeded()
        let refused = refusal { try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a"], maxDrift: Db3MaxDrift(entries: 4))) }
        XCTAssertEqual(refused?.code, .db3DriftExceeded)
        XCTAssertEqual(refused?.details?["db3Id"], "db3-a")
        XCTAssertEqual(refused?.details?["drift"]?.objectValue?["entriesBehind"], 5)
        XCTAssertEqual(refused?.details?["maxDrift"]?.objectValue?["entries"], 4)
        XCTAssertTrue(refused?.message.contains("5 entries behind") == true, refused?.message ?? "")
        XCTAssertEqual(try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a"], maxDrift: Db3MaxDrift(entries: 5))).data.count, 3)
        XCTAssertEqual(refusal { try shared.query(nil, options: QueryOptions(db3: ["db3-a"], maxDrift: Db3MaxDrift(age: 5))) }?.code, .db3DriftExceeded)
        XCTAssertEqual(try shared.query(nil, options: QueryOptions(db3: ["db3-a"], maxDrift: Db3MaxDrift(age: 600))).count, 3)
        XCTAssertEqual(refusal { try shared.count(nil, options: QueryOptions(db3: ["db3-a"], maxDrift: Db3MaxDrift(entries: 0))) }?.code, .db3DriftExceeded)
        XCTAssertEqual(try shared.count(nil, options: QueryOptions(db3: ["db3-b"], maxDrift: Db3MaxDrift(entries: 0))), 2)
        // {} passes a synced db3 with a known head (edge case 22).
        XCTAssertEqual(try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a"], maxDrift: Db3MaxDrift())).data.count, 3)
    }

    func testNoHeadHeardRefusesEveryMaxDriftAndALocalOnlyDb3PassesEveryOne() async throws {
        let (_, shared, _) = try await seeded()
        for bound in [Db3MaxDrift(), Db3MaxDrift(entries: 1_000), Db3MaxDrift(age: 1e9)] {
            let refused = refusal { try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-n"], maxDrift: bound)) }
            XCTAssertEqual(refused?.code, .db3DriftExceeded)
            XCTAssertEqual(refused?.details?["db3Id"], "db3-n")
            XCTAssertEqual(refused?.details?["drift"], .null)
        }
        for bound in [Db3MaxDrift(), Db3MaxDrift(entries: 0, age: 0)] {
            XCTAssertEqual(try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-l"], maxDrift: bound)).data.count, 1)
        }
    }

    func testTheRefusalNamesTheFirstDb3InScopeOrderThatExceeds() async throws {
        let (f, shared, _) = try await seeded()
        XCTAssertEqual(
            refusal { try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a", "db3-b"], maxDrift: Db3MaxDrift(age: 0))) }?.details?["db3Id"],
            "db3-a"
        )
        try f.open("db3-b").setState(heard: RecordLogHeard(head: 9, receivedAt: Int64(Date().timeIntervalSince1970 * 1000)))
        XCTAssertEqual(
            refusal { try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a", "db3-b"], maxDrift: Db3MaxDrift(entries: 6))) }?.details?["db3Id"],
            "db3-b"
        )
    }

    func testABadBoundIsRefusedAsAnInvalidArgumentBeforeAnyRead() async throws {
        let (f, shared, _) = try await seeded()
        let trace = try f.trace(self)
        for bound in [Db3MaxDrift(entries: -1), Db3MaxDrift(age: -1), Db3MaxDrift(age: .nan), Db3MaxDrift(age: .infinity)] {
            XCTAssertEqual(refusal { try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a"], maxDrift: bound)) }?.code, .invalidArgument)
            XCTAssertEqual(refusal { try shared.count(nil, options: QueryOptions(db3: ["db3-a"], maxDrift: bound)) }?.code, .invalidArgument)
            XCTAssertEqual(refusal { try f.records("db3-a").count("Note", maxDrift: bound) }?.code, .invalidArgument)
        }
        XCTAssertEqual(trace.viewReads, [], "nothing read")
    }

    func testAModelsPublicCountTakesMaxDrift() async throws {
        let (f, _, _) = try await seeded()
        let member = try f.member(Self.note, "db3-a")
        let refused = refusal { try member.count(nil, options: QueryOptions(maxDrift: Db3MaxDrift(entries: 4))) }
        XCTAssertEqual(refused?.code, .db3DriftExceeded)
        XCTAssertEqual(refused?.details?["db3Id"], "db3-a")
        XCTAssertEqual(try member.count(nil, options: QueryOptions(maxDrift: Db3MaxDrift(entries: 5))), 3)
        XCTAssertEqual(try member.count(), 3)
        XCTAssertEqual(refusal { try member.count(nil, options: QueryOptions(maxDrift: Db3MaxDrift(age: -1))) }?.code, .invalidArgument)
    }

    func testAPendingWriteShowsInTheDrift() async throws {
        let (f, shared, _) = try await seeded()
        _ = try f.member(Self.note, "db3-a").save(id: "mine", values: ["n": .number(9)])
        XCTAssertEqual(try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a"])).drift?["db3-a"]?.pendingWrites, 1)
    }

    // MARK: - Edge case 34: the model-free records

    func testTheModelFreeRecordsCarryDriftAndTakeMaxDrift() async throws {
        let (f, _, _) = try await seeded()
        let page = try f.records("db3-a").query("Note")
        XCTAssertEqual(page.drift?["db3-a"]?.entriesBehind, 5)
        XCTAssertEqual(refusal { try f.records("db3-a").query("Note", options: QueryOptions(maxDrift: Db3MaxDrift(entries: 4))) }?.code, .db3DriftExceeded)
        XCTAssertEqual(refusal { try f.records("db3-a").count("Note", maxDrift: Db3MaxDrift(entries: 4)) }?.details?["db3Id"], "db3-a")
        XCTAssertEqual(try f.records("db3-a").count("Note", maxDrift: Db3MaxDrift(entries: 5)), 3)
        XCTAssertEqual(try f.records("db3-l").query("Note", options: QueryOptions(maxDrift: Db3MaxDrift(entries: 0))).drift, [:])
        XCTAssertEqual(try f.records("db3-l").count("Note", maxDrift: Db3MaxDrift(age: 0)), 1)
    }

    // MARK: - Edge case 35: a hasManyThrough page

    func testAHasManyThroughPageAnswersTheDriftOfBothReads() async throws {
        let f = try await views()
        let source = PrimitiveSchema(
            name: "Post", fields: ["id": FieldDescriptor(type: .id)],
            relationships: ["tags": RelationshipDescriptor(properties: [
                "type": "hasManyThrough", "model": "Tag", "joinModel": "PostTag",
                "joinModelLocalField": "postId", "joinModelRelatedField": "tagId",
            ])]
        )
        let join = PrimitiveSchema(name: "PostTag", fields: [
            "id": FieldDescriptor(type: .id), "postId": FieldDescriptor(type: .string), "tagId": FieldDescriptor(type: .string),
        ])
        let target = PrimitiveSchema(name: "Tag", fields: ["id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string)])
        try f.seed("db3-a", "Post", [["id": "p1"]])
        try f.seed("db3-a", "PostTag", [["id": "j1", "postId": "p1", "tagId": "t1"]])
        try f.seed("db3-b", "Tag", [["id": "t1", "label": "x"]])
        try f.open("db3-a").setState(heard: RecordLogHeard(head: 9, receivedAt: 1_000))
        try f.open("db3-b").setState(heard: RecordLogHeard(head: 1, receivedAt: 2_000))
        let posts = try f.member(source, "db3-a")
        let joins = try f.member(join, "db3-a")
        let tags = try f.member(target, "db3-b")
        let record = PrimitiveRecord(modelName: "Post", id: "p1", model: posts)
        let page = try record.hasManyThrough(relationship: "tags", joinModel: joins, target: tags, limit: 10)
        XCTAssertEqual(page.data.map(\.id), ["t1"])
        XCTAssertEqual(page.drift?["db3-a"]?.entriesBehind, 7)
        XCTAssertEqual(page.drift?["db3-b"]?.entriesBehind, 0)
    }

    // MARK: - Edge case 33: the read snapshot

    func testThePageReadsItsRowsLegsAndSyncStateInOneReadTransaction() async throws {
        let (f, shared, _) = try await seeded()
        let trace = try f.trace(self)
        _ = try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a"]), include: [])
        let statements = trace.statements.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let begin = try XCTUnwrap(statements.firstIndex { $0.hasPrefix("BEGIN") }, "\(statements)")
        let commit = try XCTUnwrap(statements.lastIndex { $0.hasPrefix("COMMIT") }, "\(statements)")
        let reads = statements.indices.filter { statements[$0].contains("record_log_view") || statements[$0].contains("record_log_state") }
        XCTAssertFalse(reads.isEmpty)
        XCTAssertTrue(reads.allSatisfy { $0 > begin && $0 < commit }, "\(statements)")
        XCTAssertEqual(statements.filter { $0.hasPrefix("BEGIN") }.count, 1, "one transaction: \(statements)")
    }

    /// A second connection on the store's file that commits a write once, when the page's legs start.
    private final class Injection {
        var other: OpaquePointer?
        var viewReads = 0
        var result: Int32 = -1
    }

    func testAWriteAnotherConnectionCommitsAfterTheRowsIsSeenByNeitherTheLegsNorTheSyncState() async throws {
        let (f, shared, _) = try await seeded()
        let kid = PrimitiveSchema(name: "Kid", fields: ["id": FieldDescriptor(type: .id), "parentId": FieldDescriptor(type: .string)])
        try f.seed("db3-a", "Kid", [["id": "k1", "parentId": "db3-a-1"]])
        try f.member(kid, "db3-a")
        let injection = Injection()
        XCTAssertEqual(sqlite3_open(f.directory + "/store.sqlite", &injection.other), SQLITE_OK)
        defer { sqlite3_close(injection.other) }
        let context = Unmanaged.passRetained(injection).toOpaque()
        defer { Unmanaged<Injection>.fromOpaque(context).release() }
        _ = try f.provider.withRecordLogConnection { connection in
            sqlite3_trace_v2(connection.rawHandle, UInt32(SQLITE_TRACE_STMT), { _, context, _, text in
                guard let context, let text else { return 0 }
                let sql = String(cString: text.assumingMemoryBound(to: CChar.self))
                let injection = Unmanaged<Injection>.fromOpaque(context).takeUnretainedValue()
                guard sql.contains("record_log_view"), sql.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("SELECT") else { return 0 }
                injection.viewReads += 1
                // The rows were read; the include leg is about to be.
                if injection.viewReads == 2 {
                    injection.result = sqlite3_exec(
                        injection.other,
                        "INSERT INTO record_log_view (doc_id, _type, _id, _data) VALUES ('db3-a', 'Kid', 'k2', '{\"parentId\":\"db3-a-1\"}');"
                            + "UPDATE record_log_state SET known_head = 99 WHERE doc_id = 'db3-a'",
                        nil, nil, nil
                    )
                }
                return 0
            }, context)
        }
        let include = [Include(type: .hasMany, target: f.shared(kid), foreignKey: "parentId", resultKey: "kids")]
        let page = try shared.queryPaged(nil, options: QueryOptions(sortOrder: [("n", 1)], limit: 1, db3: ["db3-a"]), include: include)
        _ = try f.provider.withRecordLogConnection { sqlite3_trace_v2($0.rawHandle, 0, nil, nil) }
        XCTAssertEqual(injection.result, SQLITE_OK, "the other connection committed while the page was read")
        let kids = page.data.first?.raw["_related"]?.objectValue?["kids"]?.arrayValue?.compactMap { $0["id"]?.stringValue }
        XCTAssertEqual(kids, ["k1"], "the legs read the rows' snapshot")
        XCTAssertEqual(page.drift?["db3-a"]?.entriesBehind, 4, "the sync state is the rows' snapshot's (head 8, cursor 4)")
        let after = try shared.queryPaged(nil, options: QueryOptions(sortOrder: [("n", 1)], limit: 1, db3: ["db3-a"]), include: include)
        XCTAssertEqual(after.data.first?.raw["_related"]?.objectValue?["kids"]?.arrayValue?.count, 2)
        XCTAssertEqual(after.drift?["db3-a"]?.entriesBehind, 95)
    }

    func testAReadWhileASaveGroupIsOpenJoinsItAndCommitsNothingOfItsOwn() async throws {
        let (f, shared, _) = try await seeded()
        let binding = try f.open("db3-a")
        binding.store.groupCommitForTest.commitAfterMs = 60_000
        _ = try f.member(Self.note, "db3-a").save(id: "held", values: ["n": .number(1)])
        XCTAssertTrue(try f.provider.withRecordLogConnection { _ in binding.store.groupCommitForTest.isGroupOpen })
        let trace = try f.trace(self)
        let page = try shared.queryPaged(nil, options: QueryOptions(db3: ["db3-a"]))
        XCTAssertTrue(page.data.contains { $0.raw["id"]?.stringValue == "held" }, "it sees the open group's write")
        let statements = trace.statements.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertFalse(statements.contains { $0.hasPrefix("BEGIN") || $0.hasPrefix("COMMIT") }, "\(statements)")
        XCTAssertTrue(try f.provider.withRecordLogConnection { _ in binding.store.groupCommitForTest.isGroupOpen })
        try binding.store.flush()
    }

    // MARK: - Behavior 18: Db3State.drift

    private func lifecycle(_ stored: RecordLogStoredState) -> Db3Lifecycle {
        Db3Lifecycle(deps: Db3LifecycleDeps(
            emit: { _ in },
            socketUp: { true },
            resolveFormat: { _ in 3 },
            isBound: { _ in true },
            syncMarks: { _ in Db3SyncMarks(cursor: stored.cursor, lastCatchUpAt: 1, replacing: false, staged: false) },
            storedState: { _ in stored }
        ))
    }

    func testDb3StateReportsTheDriftOfASyncedDb3OnceAHeadIsHeard() async throws {
        let id = "01JD5221DR1FTSTATESWIFTXXX"
        var stored = RecordLogStoredState(
            cursor: 4, rows: 1, writers: [.init(writer: "w", clientId: "c", nextSeq: 2, lowestPending: 1, pending: 1)], replacing: false,
            lastCatchUpAt: 1
        )
        stored.knownHead = 9
        stored.knownHeadAt = 1_234
        let state = try await lifecycle(stored).state(id)
        XCTAssertEqual(state.drift, Db3Drift(entriesBehind: 5, asOf: Date(timeIntervalSince1970: 1.234), live: false, pendingWrites: 1))
        XCTAssertEqual(state.with(phase: .live).drift?.live, true, "live with the phase")
        stored.cursor = 12
        let clamped = try await lifecycle(stored).state(id)
        XCTAssertEqual(clamped.drift?.entriesBehind, 0, "clamped at 0")
        stored.knownHead = nil
        stored.knownHeadAt = nil
        let unheard = try await lifecycle(stored).state(id)
        XCTAssertNil(unheard.drift, "no head heard")
        stored.knownHead = 3
        stored.knownHeadAt = 1
        stored.localOnly = true
        let local = try await lifecycle(stored).state(id)
        XCTAssertNil(local.drift, "local-only")
    }

    func testTheRefusalCodeIsTheJsClients() {
        XCTAssertEqual(JsBaoErrorCode.db3DriftExceeded.rawValue, "DB3_DRIFT_EXCEEDED")
    }
}
