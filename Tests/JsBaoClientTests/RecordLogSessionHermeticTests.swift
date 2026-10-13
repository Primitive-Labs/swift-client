import XCTest
@testable import JsBaoClient
import YSwift

/// A format-3 document's session, driven by scripted room frames (the JS
/// wire's JSON) through a connection that records what the session sends.
/// The store underneath is real SQLite; only the room is scripted.
final class RecordLogSessionHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, unique: true),
        ]
    )

    /// A socket that keeps every frame it is handed, in order.
    final class RecordingConnection: RecordLogConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [[String: JSONValue]] = []
        private var _open = true
        var frames: [[String: JSONValue]] { lock.withLock { _frames } }
        var isOpen: Bool {
            get { lock.withLock { _open } }
            set { lock.withLock { _open = newValue } }
        }
        func send(_ frame: [String: JSONValue]) { lock.withLock { _frames.append(frame) } }
        func connected() -> Bool { isOpen }
        func types() -> [String] { frames.compactMap { $0["type"]?.stringValue } }
        func clear() { lock.withLock { _frames = [] } }
        func last(_ type: String) -> [String: JSONValue]? { frames.last { $0["type"]?.stringValue == type } }
        func all(_ type: String) -> [[String: JSONValue]] { frames.filter { $0["type"]?.stringValue == type } }
    }

    private struct Fixture {
        let provider: SQLiteStorageProvider
        let binding: RecordLogDocumentBinding
        let session: RecordLogSession
        let connection: RecordingConnection
        let synced: LockedBox<Int>
        let failed: LockedBox<[String]>
        let refusals: LockedBox<[DocumentWriteRefusedEvent]>
        let documentId: String
    }

    private static let timings = RecordLogSessionTimings(
        tickMs: 1, resultGapMs: 150, drainWaitMs: 300, writerTakenRetryMs: 40, catchUpRetryMs: 40
    )

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-session-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeFixture(
        provider existing: SQLiteStorageProvider? = nil, documentId: String = "doc-1", clientId: String = "client-1"
    ) async throws -> Fixture {
        let provider: SQLiteStorageProvider
        if let existing { provider = existing } else { provider = try await makeProvider() }
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: documentId, clientId: clientId,
            engine: BaoModelQueryEngine(host: provider), logger: Logger(level: .none)
        )
        try binding.registerModel(Self.schema)
        let connection = RecordingConnection()
        let synced = LockedBox(0)
        let failed = LockedBox<[String]>([])
        let refusals = LockedBox<[DocumentWriteRefusedEvent]>([])
        binding.setRefusalReporter { event in refusals.withValue { $0.append(event) } }
        let session = RecordLogSession(
            documentId: documentId, binding: binding,
            host: RecordLogSessionHost(
                connection: { connection },
                declarations: { ["Note": .object(["fields": .object(["title": .object(["type": "string"])])])] },
                synced: { _ in synced.withValue { $0 += 1 } },
                syncFailed: { _, reason in failed.withValue { $0.append(reason) } }
            ),
            timings: Self.timings, logger: Logger(level: .none)
        )
        await session.attach()
        return Fixture(
            provider: provider, binding: binding, session: session, connection: connection,
            synced: synced, failed: failed, refusals: refusals, documentId: documentId
        )
    }

    @discardableResult
    private func write(_ binding: RecordLogDocumentBinding, _ id: String, _ fields: [String: JSONValue] = [:]) throws -> RecordLogPendingEntry {
        var all = fields
        if all["title"] == nil { all["title"] = .string(id) }
        let entry = try binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: id, kind: .create, fields: all),
        ])])[0]
        try binding.store.flush()
        return entry
    }

    private func opened(
        lsn: Int = 0, lastSeq: Int = 0, current: Int = 1, entries: Int = 10_000, high: Int? = nil,
        catchUp: JSONValue? = nil, constraints: [JSONValue] = []
    ) -> [String: JSONValue] {
        [
            "type": "record.opened", "documentId": "doc-1", "lsn": .number(Double(lsn)),
            "lastSeq": .number(Double(lastSeq)),
            "epochs": .object([
                "current": .number(Double(current)), "next": .number(Double(current + 1)), "floor": 0,
                "entries": .number(Double(entries)), "high": .number(Double(high ?? current)),
            ]),
            "cursorFloor": 0,
            "constraints": .array(constraints),
            "catchUp": catchUp ?? .object(["mode": "inline", "rows": [], "gone": [], "lsn": .number(Double(lsn)), "upTo": .number(Double(lsn))]),
        ]
    }

    private func row(_ id: String, _ title: String) -> JSONValue {
        .object(["model": "Note", "id": .string(id), "row": .object(["id": .string(id), "title": .string(title)])])
    }

    private func results(_ items: [JSONValue]) -> [String: JSONValue] {
        ["type": "record.results", "documentId": "doc-1", "results": .array(items)]
    }

    private func result(_ l: Int, _ id: String, _ title: String, w: String? = nil, seq: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "l": .number(Double(l)), "e": 1,
            "changes": [.object(["model": "Note", "id": .string(id), "row": .object(["id": .string(id), "title": .string(title)])])],
        ]
        if let w { object["w"] = .string(w) }
        if let seq { object["seq"] = .number(Double(seq)) }
        return .object(object)
    }

    private func error(_ code: String, _ messageType: String = "record.open", extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var frame: [String: JSONValue] = [
            "type": "error", "documentId": "doc-1", "code": .string(code), "messageType": .string(messageType),
            "message": .string(code),
        ]
        for (key, value) in extra { frame[key] = value }
        return frame
    }

    /// Wait until `condition` holds, polling; fails after `timeout` seconds.
    private func eventually(
        _ what: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    private func entrySeqs(_ frame: [String: JSONValue]?) -> [Int] {
        (frame?["entries"]?.arrayValue ?? []).compactMap { $0["seq"]?.wholeNumber }
    }

    // MARK: - Behavior 14: the open

    func testTheOpenCarriesTheWriterAndAppliesTheCatchUpThenDeclaresAndResubmits() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "a")
        try write(binding, "b")
        await fixture.session.start()

        let open = try XCTUnwrap(fixture.connection.last("record.open"))
        XCTAssertEqual(open["writer"]?.stringValue, binding.writer)
        XCTAssertEqual(open["cursor"], 0)
        XCTAssertEqual(open["nextSeq"], 1, "the lowest unacknowledged seq")
        XCTAssertEqual(open["open"], 1)
        XCTAssertEqual(open["formats"], [3])
        XCTAssertEqual(open["documentFormat"], 3)
        XCTAssertEqual(open["documentId"], "doc-1")

        await fixture.session.receive(opened(
            lsn: 4, current: 2, entries: 50, high: 3,
            catchUp: .object(["mode": "inline", "rows": [row("r1", "remote")], "gone": [], "lsn": 4, "upTo": 4]),
            constraints: [.object(["model": "Note", "name": "slug", "fields": ["slug"]])]
        ))
        XCTAssertEqual(fixture.synced.value, 1)
        let marks = try binding.refreshMarks()
        XCTAssertEqual(marks.cursor, 4)
        XCTAssertEqual(marks.open, 3, "the catch-up saw epoch 3")
        XCTAssertEqual(marks.grant, 3)
        XCTAssertEqual(marks.entries, 50)
        XCTAssertEqual(marks.constraints.map(\.name), ["slug"])
        XCTAssertEqual(try binding.store.read(model: "Note", id: "r1")?["title"], "remote")

        await eventually("the declaration and the entries") { fixture.connection.last("record.entries") != nil }
        let types = fixture.connection.types()
        XCTAssertEqual(types.filter { $0 != "record.open" }, ["record.declare", "record.entries"])
        XCTAssertNotNil(fixture.connection.last("record.declare")?["models"]?["Note"])
        XCTAssertEqual(entrySeqs(fixture.connection.last("record.entries")), [1, 2], "every unsent entry, in seq order")
        XCTAssertNil(fixture.connection.last("record.resume"), "no gap behind the first unsent entry")
        let isOpen = await fixture.session.isOpen
        XCTAssertTrue(isOpen)

        // Results acknowledge this writer's entries; a later save goes once its group commits.
        await fixture.session.receive(results([result(5, "a", "a", w: binding.writer, seq: 1)]))
        XCTAssertEqual(binding.syncState(model: "Note", id: "a", lastSeq: 1), .confirmed)
        XCTAssertEqual(binding.syncState(model: "Note", id: "b", lastSeq: 2), .pending)
        fixture.connection.clear()
        try write(binding, "c")
        await eventually("the new entry") { fixture.connection.last("record.entries") != nil }
        XCTAssertEqual(entrySeqs(fixture.connection.last("record.entries")), [3])
    }

    // MARK: - Behavior 15: orphan writers drain first

    func testAnEarlierWritersEntriesAreDrainedBeforeTheOwnWriterOpens() async throws {
        let provider = try await makeProvider()
        let earlier = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "earlier", engine: BaoModelQueryEngine(host: provider)
        )
        try write(earlier, "o1")
        try write(earlier, "o2")
        let fixture = try await makeFixture(provider: provider, clientId: "now")
        XCTAssertNotEqual(fixture.binding.writer, earlier.writer)

        await fixture.session.start()
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, earlier.writer, "the orphan opens first")
        XCTAssertEqual(fixture.connection.last("record.open")?["nextSeq"], 1)
        await fixture.session.receive(opened())
        await eventually("the orphan's entries resubmitted") { fixture.connection.last("record.entries") != nil }
        XCTAssertEqual(entrySeqs(fixture.connection.last("record.entries")), [1, 2])
        XCTAssertEqual(fixture.synced.value, 0, "draining is not the open")

        await fixture.session.receive(results([
            result(1, "o1", "o1", w: earlier.writer, seq: 1),
            .object(["seq": 2, "duplicate": true]),
        ]))
        XCTAssertEqual(fixture.connection.all("record.open").count, 2)
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, fixture.binding.writer,
                       "every entry answered: the own writer opens")
        XCTAssertEqual(try fixture.binding.store.pendingOf(earlier.writer).map(\.seq), [], "the orphan's entries settled")
    }

    func testATakenOrphanIsSkipped() async throws {
        let provider = try await makeProvider()
        let earlier = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "earlier", engine: BaoModelQueryEngine(host: provider)
        )
        try write(earlier, "o1")
        let fixture = try await makeFixture(provider: provider, clientId: "now")
        await fixture.session.start()
        await fixture.session.receive(error("WRITER_ID_TAKEN"))
        XCTAssertEqual(fixture.connection.all("record.open").count, 2)
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, fixture.binding.writer, "the orphan is skipped")
    }

    func testATakenOwnWriterIsRetriedAfterADoublingBackoff() async throws {
        let fixture = try await makeFixture()
        await fixture.session.start()
        let first = Date()
        await fixture.session.receive(error("WRITER_ID_TAKEN"))
        XCTAssertEqual(fixture.connection.all("record.open").count, 1, "not at once")
        await eventually("a retry of the own writer") { fixture.connection.all("record.open").count == 2 }
        let firstWait = Date().timeIntervalSince(first)
        XCTAssertGreaterThanOrEqual(firstWait, 0.035, "after the backoff")
        let second = Date()
        await fixture.session.receive(error("WRITER_ID_TAKEN"))
        await eventually("a second retry") { fixture.connection.all("record.open").count == 3 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(second), 0.075, "the backoff doubled")
        await fixture.session.receive(opened())
        XCTAssertEqual(fixture.synced.value, 1)
    }

    func testADrainTheRoomDoesNotAnswerMovesOnAfterItsWait() async throws {
        let provider = try await makeProvider()
        let earlier = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "earlier", engine: BaoModelQueryEngine(host: provider)
        )
        try write(earlier, "o1")
        let fixture = try await makeFixture(provider: provider, clientId: "now")
        await fixture.session.start()
        await fixture.session.receive(opened())
        await eventually("the own writer opens once the drain's wait is over") {
            fixture.connection.last("record.open")?["writer"]?.stringValue == fixture.binding.writer
        }
        XCTAssertEqual(try fixture.binding.store.pendingOf(earlier.writer).map(\.seq), [1], "kept for the next session")
    }

    // MARK: - Behavior 16 and edge 36: paged catch-up

    func testAPagedCatchUpRequestsEachPageHoldsResultsAndCompletes() async throws {
        let fixture = try await makeFixture()
        await fixture.session.start()
        await fixture.session.receive(opened(lsn: 5, catchUp: .object(["mode": "paged", "full": true, "count": 3, "cursor": 0, "upTo": 5])))
        var request = try XCTUnwrap(fixture.connection.last("record.catchUp"))
        XCTAssertEqual(request["cursor"], 0)
        XCTAssertEqual(request["upTo"], 5)
        XCTAssertEqual(request["full"], true)
        XCTAssertNil(request["after"])

        await fixture.session.receive(results([result(6, "late", "after the read")]))
        let next: JSONValue = .object(["lsn": 2, "model": "Note", "id": "p2"])
        await fixture.session.receive([
            "type": "record.catchUpPage", "documentId": "doc-1", "rows": [row("p1", "one"), row("p2", "two")], "gone": [],
            "next": next, "lsn": 5,
        ])
        request = try XCTUnwrap(fixture.connection.last("record.catchUp"))
        XCTAssertEqual(request["after"], next)
        XCTAssertEqual(fixture.synced.value, 0)
        await fixture.session.receive([
            "type": "record.catchUpPage", "documentId": "doc-1", "rows": [row("p3", "three")], "gone": [], "lsn": 5,
        ])
        XCTAssertEqual(fixture.synced.value, 1)
        XCTAssertEqual(try fixture.binding.refreshMarks().cursor, 6, "the held result applied after the catch-up")
        XCTAssertEqual(try fixture.binding.store.readRowsAfter(model: "Note", after: nil, limit: 10).compactMap { $0["id"]?.stringValue },
                       ["late", "p1", "p2", "p3"])
    }

    func testARestartAnErrorAndAStalePageEachOpenAgain() async throws {
        let fixture = try await makeFixture()
        let paged: JSONValue = .object(["mode": "paged", "count": 3, "cursor": 0, "upTo": 5])
        await fixture.session.start()
        await fixture.session.receive(opened(lsn: 5, catchUp: paged))
        await fixture.session.receive(["type": "record.catchUpPage", "documentId": "doc-1", "restart": true])
        XCTAssertEqual(fixture.connection.all("record.open").count, 2, "restart opens again")

        await fixture.session.receive(opened(lsn: 5, catchUp: paged))
        await fixture.session.receive(error("INTERNAL", "record.catchUp"))
        await eventually("the open goes again after the backoff") { fixture.connection.all("record.open").count == 3 }

        // A page read before the store's cursor passed it: stale.
        await fixture.session.receive(opened(lsn: 5, catchUp: paged))
        let writer = fixture.binding.writer
        _ = try fixture.binding.store.receive(writer: writer, items: [
            .result(RecordLogResult(l: 1, e: 1, changes: [])), .result(RecordLogResult(l: 2, e: 1, changes: [])),
            .result(RecordLogResult(l: 3, e: 1, changes: [])), .result(RecordLogResult(l: 4, e: 1, changes: [])),
            .result(RecordLogResult(l: 5, e: 1, changes: [])), .result(RecordLogResult(l: 6, e: 1, changes: [])),
        ])
        await fixture.session.receive(["type": "record.catchUpPage", "documentId": "doc-1", "rows": [row("s", "stale")], "gone": [], "lsn": 5])
        XCTAssertEqual(fixture.connection.all("record.open").count, 4, "a stale page opens again from the store's cursor")
        XCTAssertEqual(fixture.connection.last("record.open")?["cursor"], 6)
        XCTAssertNil(try fixture.binding.store.read(model: "Note", id: "s"))
    }

    func testAPageAnsweredAfterTheRoomReleasedTheSubscriptionIsDiscarded() async throws {
        let fixture = try await makeFixture()
        await fixture.session.start()
        await fixture.session.receive(opened(lsn: 5, catchUp: .object(["mode": "paged", "full": true, "count": 3, "cursor": 0, "upTo": 5])))
        await fixture.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        XCTAssertEqual(fixture.connection.all("record.open").count, 1, "the page request is still out")
        await fixture.session.receive(["type": "record.catchUpPage", "documentId": "doc-1", "rows": [row("x", "lost")], "gone": [], "lsn": 5])
        XCTAssertEqual(fixture.connection.all("record.open").count, 2, "its answer is discarded and the open goes again")
        XCTAssertNil(try fixture.binding.store.read(model: "Note", id: "x"))
        XCTAssertEqual(fixture.synced.value, 0)
    }

    // MARK: - Behavior 17: released, the result gap, record.gap

    func testReleasedWhileOpenReopensAndAResultGapReopensAfterItsWait() async throws {
        let fixture = try await makeFixture()
        await fixture.session.start()
        await fixture.session.receive(opened())
        await fixture.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        XCTAssertEqual(fixture.connection.all("record.open").count, 2)
        await fixture.session.receive(opened())

        await fixture.session.receive(results([result(3, "far", "ahead")]))
        XCTAssertEqual(try fixture.binding.refreshMarks().cursor, 0, "held behind the missing 1 and 2")
        await eventually("the gap watchdog reopens from the cursor") { fixture.connection.all("record.open").count == 3 }
        XCTAssertEqual(fixture.connection.last("record.open")?["cursor"], 0)
    }

    func testAGapFrameResendsTheEntriesInFlightFromExpected() async throws {
        let fixture = try await makeFixture()
        for id in ["a", "b", "c"] { try write(fixture.binding, id) }
        await fixture.session.start()
        await fixture.session.receive(opened())
        await eventually("the entries") { fixture.connection.last("record.entries") != nil }
        XCTAssertEqual(entrySeqs(fixture.connection.last("record.entries")), [1, 2, 3])
        fixture.connection.clear()
        await fixture.session.receive(["type": "record.gap", "documentId": "doc-1", "expected": 2])
        await eventually("the resend") { fixture.connection.last("record.entries") != nil }
        XCTAssertEqual(entrySeqs(fixture.connection.last("record.entries")), [2, 3])
    }

    // MARK: - Behavior 18: re-mint, not-open, write access

    func testWriterUnknownRemintsRenumbersAndMovesWaitersToTheNewNumbers() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "a")
        try write(binding, "b")
        let oldWriter = binding.writer
        let acknowledged = LockedBox(false)
        let waiter = Task {
            try await binding.whenAcknowledged(2)
            acknowledged.withValue { $0 = true }
        }
        await fixture.session.start()
        await fixture.session.receive(error("WRITER_UNKNOWN"))
        XCTAssertNotEqual(binding.writer, oldWriter)
        let open = try XCTUnwrap(fixture.connection.last("record.open"))
        XCTAssertEqual(open["writer"]?.stringValue, binding.writer)
        XCTAssertEqual(open["nextSeq"], 1)
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).map(\.seq), [1, 2], "renumbered from 1")
        await fixture.session.receive(opened())
        await fixture.session.receive(results([
            result(1, "a", "a", w: binding.writer, seq: 1), result(2, "b", "b", w: binding.writer, seq: 2),
        ]))
        try await waiter.value
        XCTAssertTrue(acknowledged.value, "the waiter followed its entry to its new number")
    }

    func testARoomThatJudgedMoreThanTheStoreMintedRemints() async throws {
        let fixture = try await makeFixture()
        try write(fixture.binding, "a")
        let oldWriter = fixture.binding.writer
        await fixture.session.start()
        await fixture.session.receive(opened(lastSeq: 7))
        XCTAssertNotEqual(fixture.binding.writer, oldWriter, "a restored store's writer is re-minted")
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, fixture.binding.writer)
        XCTAssertEqual(fixture.synced.value, 0)
    }

    func testNotOpenReopensAndWriteAccessDeniedHandsPendingBackUntilWriteAccessReturns() async throws {
        let fixture = try await makeFixture()
        await fixture.session.start()
        await fixture.session.receive(opened())
        await fixture.session.receive(error("DOCUMENT_NOT_OPEN", "record.entries"))
        XCTAssertEqual(fixture.connection.all("record.open").count, 2)
        await fixture.session.receive(opened())

        try write(fixture.binding, "a")
        try write(fixture.binding, "b")
        await fixture.session.receive(error("WRITE_ACCESS_DENIED", "record.entries"))
        XCTAssertTrue(fixture.binding.isReadOnly)
        XCTAssertEqual(fixture.refusals.value.count, 1)
        let event = try XCTUnwrap(fixture.refusals.value.first)
        XCTAssertEqual(event.error.code, .writeAccessDenied)
        XCTAssertEqual(event.writes?.map(\.recordId), ["a", "b"])
        XCTAssertNil(try fixture.binding.store.read(model: "Note", id: "a"))
        XCTAssertThrowsError(try fixture.binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: "c", kind: .create, fields: ["title": "c"]),
        ])])) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .accessDenied)
        }
        await fixture.session.adoptWriteAccess()
        XCTAssertFalse(fixture.binding.isReadOnly, "a connect with write access lifts it")
        XCTAssertNoThrow(try write(fixture.binding, "c"))
    }

    // MARK: - Behavior 19: a disconnect mid-open

    func testADisconnectMidOpenAbandonsTheStaleContinuation() async throws {
        let fixture = try await makeFixture()
        try write(fixture.binding, "a")
        await fixture.session.start()
        await fixture.session.disconnected()
        await fixture.session.receive(opened())
        XCTAssertEqual(fixture.synced.value, 0, "a record.opened after the disconnect is ignored")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(fixture.connection.last("record.entries"), "the sender holds nothing from the dead connection")

        await fixture.session.start()
        XCTAssertEqual(fixture.connection.all("record.open").count, 2, "the next connection's open starts from idle")
        await fixture.session.receive(opened())
        XCTAssertEqual(fixture.synced.value, 1)
    }

    // MARK: - Edge 35: a refusal before record.opened

    func testARefusalArrivingBeforeOpenedIsDropped() async throws {
        let fixture = try await makeFixture()
        try write(fixture.binding, "a")
        await fixture.session.start()
        await fixture.session.receive([
            "type": "record.refused", "documentId": "doc-1", "seq": 1, "code": "DOCUMENT_CONSTRAINT_VIOLATED",
            "scope": "record", "from": 1, "records": [.object(["model": "Note", "id": "a", "from": 1])],
        ])
        XCTAssertEqual(fixture.refusals.value.count, 0)
        XCTAssertEqual(try fixture.binding.store.pendingOf(fixture.binding.writer).map(\.seq), [1])
        XCTAssertNotNil(try fixture.binding.store.read(model: "Note", id: "a"))
    }

    // MARK: - A refusal while open

    func testARecordRefusalHandsTheClosureBackOnceWithTheConflictingRecord() async throws {
        let fixture = try await makeFixture()
        try write(fixture.binding, "a", ["slug": "k"])
        try write(fixture.binding, "a2", ["slug": "other"])
        await fixture.session.start()
        await fixture.session.receive(opened())
        await fixture.session.receive([
            "type": "record.refused", "documentId": "doc-1", "seq": 1, "code": "DOCUMENT_CONSTRAINT_VIOLATED",
            "scope": "record", "from": 1, "records": [.object(["model": "Note", "id": "a", "from": 1])],
            "conflicting": .object(["model": "Note", "id": "winner"]), "constraint": "slug",
        ])
        XCTAssertEqual(fixture.refusals.value.count, 1)
        let event = try XCTUnwrap(fixture.refusals.value.first)
        XCTAssertEqual(event.error.code, .documentConstraintViolated)
        XCTAssertEqual(event.conflictingRecord, RecordLogRecordKey(model: "Note", id: "winner"))
        XCTAssertEqual(event.error.details?["constraint"], "slug")
        XCTAssertEqual(event.writes?.map(\.recordId), ["a"])
        XCTAssertEqual(event.writes?.first?.fields?["slug"], "k")
        XCTAssertNil(try fixture.binding.store.read(model: "Note", id: "a"))
        XCTAssertNotNil(try fixture.binding.store.read(model: "Note", id: "a2"), "a record outside the closure is untouched")
        XCTAssertEqual(fixture.binding.syncState(model: "Note", id: "a", lastSeq: 1), .refused)
        await eventually("the resume") { fixture.connection.last("record.resume") != nil }
        XCTAssertEqual(fixture.connection.last("record.resume")?["records"], [.object(["model": "Note", "id": "a", "from": 1])])
    }

    // MARK: - A model registered on an open document (4309-C2-02)

    func testAModelRegisteredOnAnOpenDocumentIsDeclaredBeforeItsEntries() async throws {
        let provider = try await makeProvider()
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "client-1",
            engine: BaoModelQueryEngine(host: provider), logger: Logger(level: .none)
        )
        try binding.registerModel(Self.schema)
        let connection = RecordingConnection()
        let declared = LockedBox<[String]>(["Note"])
        let session = RecordLogSession(
            documentId: "doc-1", binding: binding,
            host: RecordLogSessionHost(
                connection: { connection },
                declarations: {
                    Dictionary(uniqueKeysWithValues: declared.value.map { ($0, JSONValue.object(["fields": .object([:])])) })
                },
                synced: { _ in }, syncFailed: { _, _ in }
            ),
            timings: Self.timings, logger: Logger(level: .none)
        )
        await session.attach()
        await session.start()
        await session.receive(opened())
        await eventually("the open's declaration") { connection.last("record.declare") != nil }
        XCTAssertEqual(connection.all("record.declare").count, 1)
        connection.clear()

        // A model registered now, and saved at once: its declaration goes
        // first, even when the save reaches the session before the client's
        // `declare()` call does.
        let late = PrimitiveSchema(
            name: "Late", fields: ["id": FieldDescriptor(type: .id), "code": FieldDescriptor(type: .string, unique: true)]
        )
        try binding.registerModel(late)
        declared.withValue { $0.append("Late") }
        try binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: "Late", id: "l1", kind: .create, fields: ["code": "k"]),
        ])])
        try binding.store.flush()
        await eventually("the late model's entry") { connection.last("record.entries") != nil }
        XCTAssertEqual(connection.types(), ["record.declare", "record.entries"], "declared before its first entry")
        XCTAssertNotNil(connection.last("record.declare")?["models"]?["Late"])

        // The client's call after the registration declares nothing twice.
        await session.declare()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(connection.all("record.declare").count, 1)

        // A model registered with no save after it is declared by that call.
        let other = PrimitiveSchema(name: "Other", fields: ["id": FieldDescriptor(type: .id)])
        try binding.registerModel(other)
        declared.withValue { $0.append("Other") }
        await session.declare()
        await eventually("the second declaration") { connection.all("record.declare").count == 2 }
        XCTAssertNotNil(connection.last("record.declare")?["models"]?["Other"])
    }

    // MARK: - A re-mint on an open connection (4309-C2-03)

    func testARemintOnAnOpenConnectionSendsOnlyTheRenumberedEntries() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        for index in 1...5 { try write(binding, "a\(index)") }
        await fixture.session.start()
        await fixture.session.receive(opened())
        await eventually("the first entries") { fixture.connection.last("record.entries") != nil }
        let oldWriter = binding.writer
        await fixture.session.receive(results((1...5).map { result($0, "a\($0)", "a\($0)", w: oldWriter, seq: $0) }))
        XCTAssertEqual(try binding.store.pendingOf(oldWriter).filter { $0.acked == nil }, [])

        // Ten more: eight in flight (the window), two queued.
        for index in 1...10 { try write(binding, "b\(index)") }
        await eventually("the window full") {
            fixture.connection.all("record.entries").flatMap { entrySeqs($0) }.filter { $0 > 5 }.count == 8
        }
        fixture.connection.clear()

        // The room drops the subscription and no longer knows the writer.
        await fixture.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
        await fixture.session.receive(error("WRITER_UNKNOWN"))
        XCTAssertNotEqual(binding.writer, oldWriter)
        let renumbered = try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }
        XCTAssertEqual(renumbered.map(\.seq), Array(1...10), "renumbered from 1")
        await fixture.session.receive(opened(lsn: 5))
        await eventually("the renumbered entries") { fixture.connection.last("record.entries") != nil }
        try await Task.sleep(nanoseconds: 20_000_000)

        let sent = fixture.connection.all("record.entries").flatMap { $0["entries"]?.arrayValue ?? [] }
        XCTAssertEqual(sent.compactMap { $0["seq"]?.wholeNumber }, Array(1...8),
                       "the new writer's numbers from 1, in order, up to the window")
        for entry in sent {
            let seq = try XCTUnwrap(entry["seq"]?.wholeNumber)
            XCTAssertEqual(entry["m"]?["id"]?.stringValue, "b\(seq)", "entry \(seq) carries its own write")
        }
    }

    // MARK: - Edge 41: a constraint the room keeps out of force

    func testADeclaredRefusalTakesTheConstraintOutOfTheLocalPreCheck() async throws {
        let fixture = try await makeFixture()
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: fixture.documentId, doc: YDocument())
        try model.bindRecordLog(fixture.binding)
        _ = try model.create(id: "a", values: ["slug": .string("same")])
        XCTAssertThrowsError(try model.create(id: "b", values: ["slug": .string("same")]))
        let constraint = try XCTUnwrap(Self.schema.resolvedUniqueConstraints.first?.name)
        await fixture.session.receive(["type": "record.declared", "documentId": "doc-1", "refused": [.string(constraint)]])
        XCTAssertFalse(fixture.binding.constraintInForce(constraint))
        XCTAssertNoThrow(try model.create(id: "b", values: ["slug": .string("same")]),
                         "the save is sent and judged by the room")
    }
}
