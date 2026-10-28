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

    private static let noteDeclarations: [String: JSONValue] = [
        "Note": .object(["fields": .object(["title": .object(["type": "string"])])]),
    ]

    private func makeFixture(
        provider existing: SQLiteStorageProvider? = nil, documentId: String = "doc-1", clientId: String = "client-1",
        declarations: @escaping @Sendable () -> [String: JSONValue] = { RecordLogSessionHermeticTests.noteDeclarations },
        history: RecordLogWriterHistory = RecordLogWriterHistory()
    ) async throws -> Fixture {
        let provider: SQLiteStorageProvider
        if let existing { provider = existing } else { provider = try await makeProvider() }
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: documentId, clientId: clientId,
            logger: Logger(level: .none)
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
                declarations: declarations,
                synced: { _ in synced.withValue { $0 += 1 } },
                syncFailed: { _, reason in failed.withValue { $0.append(reason) } }
            ),
            timings: Self.timings, logger: Logger(level: .none), history: history
        )
        await session.attach()
        return Fixture(
            provider: provider, binding: binding, session: session, connection: connection,
            synced: synced, failed: failed, refusals: refusals, documentId: documentId
        )
    }

    /// The fixture's document closed and opened again: a new session on its
    /// binding and connection, given what the closed one left.
    private func reopened(_ fixture: Fixture, history: RecordLogWriterHistory) async -> RecordLogSession {
        await fixture.session.close()
        let connection = fixture.connection
        let synced = fixture.synced
        let failed = fixture.failed
        let session = RecordLogSession(
            documentId: fixture.documentId, binding: fixture.binding,
            host: RecordLogSessionHost(
                connection: { connection },
                declarations: { RecordLogSessionHermeticTests.noteDeclarations },
                synced: { _ in synced.withValue { $0 += 1 } },
                syncFailed: { _, reason in failed.withValue { $0.append(reason) } }
            ),
            timings: Self.timings, logger: Logger(level: .none), history: history
        )
        await session.attach()
        return session
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
            host: provider, documentId: "doc-1", clientId: "earlier"
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
            host: provider, documentId: "doc-1", clientId: "earlier"
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
            host: provider, documentId: "doc-1", clientId: "earlier"
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
        // The connection's first open sent the old id's entry with it (#4489):
        // the re-minted writer opens once the room answered it.
        XCTAssertEqual(fixture.connection.all("record.open").count, 1)
        await fixture.session.receive(results([.object(["seq": 1, "duplicate": true])]))
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
        // The connection's first open sent its entries with it (#4489); nothing
        // more of them leaves once the connection is gone.
        XCTAssertEqual(fixture.connection.all("record.entries").count, 1)
        await fixture.session.receive(opened())
        XCTAssertEqual(fixture.synced.value, 0, "a record.opened after the disconnect is ignored")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fixture.connection.all("record.entries").count, 1, "the sender holds nothing from the dead connection")

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

    // MARK: - A refusal of the writer's last pending entry (#4497)

    private func constraintRefusal(_ seq: Int, _ id: String) -> [String: JSONValue] {
        [
            "type": "record.refused", "documentId": "doc-1", "seq": .number(Double(seq)), "code": "DOCUMENT_CONSTRAINT_VIOLATED",
            "scope": "record", "from": .number(Double(seq)),
            "records": [.object(["model": "Note", "id": .string(id), "from": .number(Double(seq))])],
            "conflicting": .object(["model": "Note", "id": "winner"]),
        ]
    }

    private func sentSeqs(_ connection: RecordingConnection) -> [Int] {
        connection.all("record.entries").flatMap { entrySeqs($0) }
    }

    func testARefusalOfTheOnlyEntryInFlightLeavesNothingPending() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "loser", ["slug": "k"])
        let outcome = LockedBox<Error?>(nil)
        let waiter = Task {
            do { try await binding.whenAcknowledged(1) } catch { outcome.withValue { $0 = error } }
        }
        await fixture.session.start()
        await fixture.session.receive(opened())
        await eventually("the entry") { sentSeqs(fixture.connection) == [1] }

        await fixture.session.receive(constraintRefusal(1, "loser"))

        XCTAssertEqual(try binding.store.pendingOf(binding.writer).map(\.seq), [], "the refused entry's marker settles")
        await waiter.value
        XCTAssertEqual((outcome.value as? JsBaoError)?.code, .documentConstraintViolated)
        XCTAssertEqual(fixture.refusals.value.count, 1)
        XCTAssertEqual(fixture.refusals.value.first?.writes?.map(\.recordId), ["loser"])
        XCTAssertNil(try binding.store.read(model: "Note", id: "loser"))
        await eventually("the resume") { fixture.connection.last("record.resume") != nil }
        XCTAssertEqual(sentSeqs(fixture.connection), [1], "the marker is not sent")

        try write(binding, "after", ["slug": "k2"])
        await eventually("the next save") { sentSeqs(fixture.connection) == [1, 2] }
    }

    func testARefusalOfTheLastOfSeveralEntriesLeavesNothingPending() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "kept", ["slug": "other"])
        try write(binding, "loser", ["slug": "k"])
        await fixture.session.start()
        await fixture.session.receive(opened())
        await eventually("the entries") { sentSeqs(fixture.connection) == [1, 2] }

        await fixture.session.receive(results([result(1, "kept", "kept", w: binding.writer, seq: 1)]))
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).map(\.seq), [2])
        await fixture.session.receive(constraintRefusal(2, "loser"))

        XCTAssertEqual(try binding.store.pendingOf(binding.writer).map(\.seq), [], "the refused entry's marker settles")
        XCTAssertEqual(fixture.refusals.value.count, 1)
        XCTAssertNil(try binding.store.read(model: "Note", id: "loser"))
        XCTAssertNotNil(try binding.store.read(model: "Note", id: "kept"))
        XCTAssertEqual(sentSeqs(fixture.connection), [1, 2])
    }

    // MARK: - A model registered on an open document (4309-C2-02)

    func testAModelRegisteredOnAnOpenDocumentIsDeclaredBeforeItsEntries() async throws {
        let provider = try await makeProvider()
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "client-1",
            logger: Logger(level: .none)
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

        // Ten more, written with nothing in flight: they leave together, in one frame.
        fixture.connection.isOpen = false
        for index in 1...10 { try write(binding, "b\(index)") }
        try await Task.sleep(nanoseconds: 20_000_000)
        fixture.connection.isOpen = true
        await fixture.session.kick()
        await eventually("the ten in flight") { entrySeqs(fixture.connection.last("record.entries")) == Array(6...15) }
        XCTAssertEqual(fixture.connection.all("record.entries").map { entrySeqs($0) }, [Array(1...5), Array(6...15)])
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

        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.open", "record.declare", "record.entries"])
        let sent = fixture.connection.all("record.entries").flatMap { $0["entries"]?.arrayValue ?? [] }
        XCTAssertEqual(sent.compactMap { $0["seq"]?.wholeNumber }, Array(1...10),
                       "the new writer's numbers from 1, in order, in one frame")
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

    // MARK: - #4489: the connection's first open sends its pending entries with it

    private func pagedOpened(_ upTo: Int, lastSeq: Int = 0) -> [String: JSONValue] {
        opened(lsn: upTo, lastSeq: lastSeq, catchUp: .object(["mode": "paged", "count": 500, "cursor": 0, "upTo": .number(Double(upTo))]))
    }

    private func lastPage(_ lsn: Int) -> [String: JSONValue] {
        ["type": "record.catchUpPage", "documentId": "doc-1", "rows": [], "gone": [], "lsn": .number(Double(lsn))]
    }

    private func writerRefusal(_ seq: Int, from: Int? = nil) -> [String: JSONValue] {
        [
            "type": "record.refused", "documentId": "doc-1", "seq": .number(Double(seq)), "code": "DOCUMENT_OFFLINE_WINDOW_EXPIRED",
            "scope": "writer", "from": .number(Double(from ?? seq)), "records": [],
        ]
    }

    /// The writer's acknowledgements of `seqs` (records `r<seq>`), at log numbers from `lsn`.
    private func acks(_ seqs: [Int], from lsn: Int, writer: String) -> [String: JSONValue] {
        results(seqs.enumerated().map { index, seq in result(lsn + index, "r\(seq)", "r\(seq)", w: writer, seq: seq) })
    }

    private func entryFrames(_ connection: RecordingConnection) -> [[Int]] {
        connection.all("record.entries").map { entrySeqs($0) }
    }

    func testTheFirstOpenSendsTheDeclarationAndEveryUnacknowledgedEntryAheadOfOpened() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        await fixture.session.start()
        await fixture.session.receive(opened())
        fixture.connection.isOpen = false
        try write(binding, "r1", ["slug": "k"])
        try binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: "r1", kind: .patch, fields: ["title": "withdrawn with it"]),
        ])])
        try binding.store.flush()
        try write(binding, "r2")
        // A record-scoped refusal while the socket is away: 2 stays as a void marker.
        await fixture.session.receive([
            "type": "record.refused", "documentId": "doc-1", "seq": 1, "code": "DOCUMENT_CONSTRAINT_VIOLATED",
            "scope": "record", "from": 1, "records": [.object(["model": "Note", "id": "r1", "from": 1])],
        ])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).map { [$0.seq, $0.isVoid ? 1 : 0] }, [[2, 1], [3, 0]])
        await fixture.session.disconnected()
        fixture.connection.isOpen = true
        fixture.connection.clear()

        await fixture.session.start()
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.declare", "record.entries"], "before any room frame")
        XCTAssertEqual(fixture.connection.last("record.open")?["nextSeq"], 2)
        XCTAssertNotNil(fixture.connection.last("record.declare")?["models"]?["Note"])
        let sent = fixture.connection.last("record.entries")?["entries"]?.arrayValue ?? []
        XCTAssertEqual(sent.compactMap { $0["seq"]?.wholeNumber }, [2, 3], "every unacknowledged entry, in seq order")
        XCTAssertEqual(sent.first?["void"], true, "the void marker goes too")

        await fixture.session.receive(opened(lsn: 1, lastSeq: 1))
        XCTAssertEqual(fixture.synced.value, 2)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.declare", "record.entries"], "nothing is sent again")
    }

    func testResultsForTheEntriesSentAheadDuringAPagedCatchUpAreHeldUntilItCompletes() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "r1")
        try write(binding, "r2")
        await fixture.session.start()
        XCTAssertEqual(entryFrames(fixture.connection), [[1, 2]])
        await fixture.session.receive(pagedOpened(9))
        await fixture.session.receive(acks([1, 2], from: 10, writer: binding.writer))
        XCTAssertEqual(try binding.refreshMarks().cursor, 0, "held while the pages are read")
        await fixture.session.receive(lastPage(9))
        XCTAssertEqual(fixture.synced.value, 1)
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).map(\.seq), [])
        XCTAssertEqual(try binding.refreshMarks().cursor, 11)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(entryFrames(fixture.connection), [[1, 2]], "nothing is resent")
    }

    func testARefusalOfAnEntrySentAheadDuringTheCatchUpIsAppliedAfterIt() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        for id in ["r1", "r2", "r3"] { try write(binding, id) }
        await fixture.session.start()
        await fixture.session.receive(pagedOpened(9))
        await fixture.session.receive(acks([1], from: 10, writer: binding.writer))
        await fixture.session.receive(writerRefusal(2))
        await fixture.session.receive(writerRefusal(3, from: 2))
        XCTAssertEqual(fixture.refusals.value.count, 0, "held with the results")
        XCTAssertNil(fixture.connection.last("record.resume"))
        await fixture.session.receive(lastPage(9))
        XCTAssertEqual(fixture.refusals.value.count, 1, "handed back once")
        XCTAssertEqual(fixture.refusals.value.first?.error.code, .documentOfflineWindowExpired)
        XCTAssertEqual(fixture.refusals.value.first?.writes?.map(\.recordId), ["r2", "r3"])
        await eventually("the resume") { fixture.connection.last("record.resume") != nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.connection.all("record.resume").count, 1)
        XCTAssertEqual(fixture.connection.last("record.resume")?["nextSeq"], 4)
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).map(\.seq), [])
        XCTAssertNotNil(try binding.store.read(model: "Note", id: "r1"))
        XCTAssertNil(try binding.store.read(model: "Note", id: "r2"))
        XCTAssertEqual(entryFrames(fixture.connection), [[1, 2, 3]])
    }

    func testWithNothingPendingTheFirstOpenSendsTheOpenAndTheDeclarationOnly() async throws {
        let fixture = try await makeFixture()
        await fixture.session.start()
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.declare"])
        XCTAssertEqual(fixture.synced.value, 0)
        await fixture.session.receive(opened())
        XCTAssertEqual(fixture.synced.value, 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.declare"])
    }

    func testAHandBackTheRoomMayNotHaveHeardKeepsTheResumeDeclareEntriesOrder() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        await fixture.session.start()
        await fixture.session.receive(opened())
        fixture.connection.isOpen = false
        try write(binding, "r1")
        await fixture.session.receive(writerRefusal(1))
        XCTAssertEqual(fixture.refusals.value.count, 1)
        try write(binding, "r2")
        await fixture.session.disconnected()
        fixture.connection.isOpen = true
        fixture.connection.clear()

        await fixture.session.start()
        XCTAssertEqual(fixture.connection.types(), ["record.open"], "a resume may be owed: nothing goes ahead")
        await fixture.session.receive(opened())
        await eventually("the entries") { fixture.connection.last("record.entries") != nil }
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.resume", "record.declare", "record.entries"])
        XCTAssertEqual(fixture.connection.last("record.resume")?["nextSeq"], 2)
        XCTAssertEqual(entrySeqs(fixture.connection.last("record.entries")), [2])
    }

    func testDocumentNotOpenForTheFramesSentAheadFallsBackToDeclaringAndResendingAfterTheCatchUp() async throws {
        for refusedAfterOpened in [false, true] {
            let fixture = try await makeFixture()
            let binding = fixture.binding
            try write(binding, "r1")
            try write(binding, "r2")
            await fixture.session.start()
            let refuse = {
                await fixture.session.receive(self.error("DOCUMENT_NOT_OPEN", "record.declare"))
                await fixture.session.receive(self.error("DOCUMENT_NOT_OPEN", "record.entries"))
            }
            if !refusedAfterOpened { await refuse() }
            await fixture.session.receive(pagedOpened(4))
            if refusedAfterOpened { await refuse() }
            fixture.connection.clear()
            await fixture.session.receive(lastPage(4))
            await eventually("the resend") { fixture.connection.last("record.entries") != nil }
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertEqual(fixture.connection.types(), ["record.declare", "record.entries"], "after: \(refusedAfterOpened)")
            XCTAssertEqual(entryFrames(fixture.connection), [[1, 2]], "each sent again once")
            XCTAssertEqual(fixture.synced.value, 1)
        }
    }

    func testAnswersToTheFramesSentAheadThatArriveBeforeOpenedAreHeldNotDropped() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        for id in ["r1", "r2", "r3"] { try write(binding, id) }
        await fixture.session.start()
        // Today's worker can post the entries under a surviving subscription
        // and answer them before the open.
        await fixture.session.receive(acks([1], from: 1, writer: binding.writer))
        await fixture.session.receive([
            "type": "record.refused", "documentId": "doc-1", "seq": 2, "code": "DOCUMENT_ENTRY_INVALID",
            "scope": "entry", "from": 2, "records": [],
        ])
        await fixture.session.receive(acks([3], from: 2, writer: binding.writer))
        XCTAssertEqual(fixture.refusals.value.count, 0)
        await fixture.session.receive(opened(
            lsn: 2, lastSeq: 3,
            catchUp: .object(["mode": "inline", "rows": [row("r1", "r1"), row("r3", "r3")], "gone": [], "lsn": 2, "upTo": 2])
        ))
        XCTAssertEqual(fixture.synced.value, 1)
        XCTAssertEqual(fixture.refusals.value.count, 1)
        XCTAssertEqual(fixture.refusals.value.first?.writes?.map(\.recordId), ["r2"])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).map(\.seq), [])
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(entryFrames(fixture.connection), [[1, 2, 3]], "nothing is resent")
    }

    func testTheOwnWriterOpenedAfterAnOrphanDrainSendsItsOpenAlone() async throws {
        let provider = try await makeProvider()
        let earlier = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "earlier"
        )
        try write(earlier, "o1")
        let fixture = try await makeFixture(provider: provider, clientId: "now")
        try write(fixture.binding, "mine")
        await fixture.session.start()
        XCTAssertEqual(fixture.connection.types(), ["record.open"], "the orphan's open goes alone")
        await fixture.session.receive(opened())
        await eventually("the orphan's entries") { fixture.connection.last("record.entries") != nil }
        await fixture.session.receive(results([.object(["seq": 1, "duplicate": true])]))
        await eventually("the own writer's open") { fixture.connection.all("record.open").count == 2 }
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.entries", "record.open"], "the own writer's open goes alone")
        await fixture.session.receive(opened())
        await eventually("the own entries") { fixture.connection.all("record.entries").count == 2 }
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.entries", "record.open", "record.declare", "record.entries"])
        XCTAssertEqual(fixture.synced.value, 1)
    }

    func testAWriterUnknownOnTheFirstOpenRemintsAndTheNewOpenSendsNothingAhead() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        for id in ["r1", "r2", "r3"] { try write(binding, id) }
        let oldWriter = binding.writer
        await fixture.session.start()
        XCTAssertEqual(entryFrames(fixture.connection), [[1, 2, 3]])
        await fixture.session.receive(error("WRITER_UNKNOWN"))
        XCTAssertNotEqual(binding.writer, oldWriter)
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.declare", "record.entries", "record.open"])
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, binding.writer)
        XCTAssertEqual(fixture.connection.last("record.open")?["nextSeq"], 1)
        // The answers to the frames sent under the old id.
        await fixture.session.receive(error("DOCUMENT_NOT_OPEN", "record.declare"))
        await fixture.session.receive(error("DOCUMENT_NOT_OPEN", "record.entries"))
        await fixture.session.receive(results([.object(["seq": 1, "duplicate": true])]))
        fixture.connection.clear()
        await fixture.session.receive(opened())
        await eventually("the renumbered entries") { fixture.connection.last("record.entries") != nil }
        XCTAssertEqual(fixture.connection.types(), ["record.declare", "record.entries"])
        XCTAssertEqual(entryFrames(fixture.connection), [[1, 2, 3]])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }.map(\.seq), [1, 2, 3],
                       "no new number was acknowledged by an old answer")
    }

    func testARestoredStoresRemintedWriterOpensOnceTheOldIdsAnswersAreInAndNoneSettlesItsNumbers() async throws {
        // The room queues the old id's answers on the old subscription's
        // stream; the new id's open is sent only once they are in, so none can
        // arrive after its numbers went.
        let fixture = try await makeFixture()
        let binding = fixture.binding
        for id in ["r1", "r2", "r3"] { try write(binding, id) }
        let oldWriter = binding.writer
        await fixture.session.start()
        // One answer before the open (a server answering ahead of it): held, then dropped with the old id.
        await fixture.session.receive(results([.object(["seq": 1, "duplicate": true])]))
        await fixture.session.receive(opened(lastSeq: 7))
        XCTAssertNotEqual(binding.writer, oldWriter)
        XCTAssertEqual(fixture.connection.all("record.open").count, 1, "the room still owes the old id 2 and 3")
        await fixture.session.receive([
            "type": "record.refused", "documentId": "doc-1", "seq": 2, "code": "DOCUMENT_ENTRY_INVALID",
            "scope": "entry", "from": 2, "records": [],
        ])
        XCTAssertEqual(fixture.connection.all("record.open").count, 1)
        await fixture.session.receive(results([.object(["seq": 3, "duplicate": true])]))
        XCTAssertEqual(fixture.connection.all("record.open").map { $0["writer"]?.stringValue }, [oldWriter, binding.writer])
        XCTAssertEqual(fixture.connection.last("record.open")?["nextSeq"], 1)
        await fixture.session.receive(pagedOpened(4))
        await fixture.session.receive(lastPage(4))
        await eventually("the renumbered entries") { fixture.connection.all("record.entries").count == 2 }
        XCTAssertEqual(fixture.synced.value, 1)
        XCTAssertEqual(fixture.refusals.value.count, 0)
        XCTAssertEqual(entryFrames(fixture.connection), [[1, 2, 3], [1, 2, 3]])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }.map(\.seq), [1, 2, 3],
                       "no new number was settled by an old answer")
        for id in ["r1", "r2", "r3"] { XCTAssertNotNil(try binding.store.read(model: "Note", id: id)) }
    }

    func testARestoredStoresRemintedWriterOpensOnceTheOldIdsEntriesAreRefusedOrItsSubscriptionReleased() async throws {
        for released in [false, true] {
            let fixture = try await makeFixture()
            let binding = fixture.binding
            try write(binding, "r1")
            try write(binding, "r2")
            await fixture.session.start()
            await fixture.session.receive(opened(lastSeq: 5))
            XCTAssertEqual(fixture.connection.all("record.open").count, 1)
            if released {
                await fixture.session.receive(["type": "record.released", "documentId": "doc-1", "reason": "delivery-failed"])
            } else {
                await fixture.session.receive(error("DOCUMENT_NOT_OPEN", "record.entries"))
            }
            XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, binding.writer)
            XCTAssertEqual(fixture.connection.last("record.open")?["nextSeq"], 1)
            // A late answer of the old id while the new one opens is dropped.
            await fixture.session.receive(results([.object(["seq": 1, "duplicate": true])]))
            fixture.connection.clear()
            await fixture.session.receive(opened())
            await eventually("the renumbered entries") { fixture.connection.last("record.entries") != nil }
            XCTAssertEqual(entryFrames(fixture.connection), [[1, 2]])
            XCTAssertEqual(try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }.map(\.seq), [1, 2])
        }
    }

    func testPastTheDrainWaitARemintedWriterStillWaitsAndOnlyItsOldIdsOpenAgainLetsItOpen() async throws {
        // The room may deliver the old id's answers after the new id's
        // record.opened (separate streams): a wait that simply ran out would let
        // a late duplicate settle the new id's 1.
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "r1")
        try write(binding, "r2")
        let oldWriter = binding.writer
        await fixture.session.start()
        await fixture.session.receive(opened(lastSeq: 5))
        let fresh = binding.writer
        await eventually("the old id opened again") { fixture.connection.all("record.open").count == 2 }
        XCTAssertEqual(fixture.connection.all("record.open").map { $0["writer"]?.stringValue }, [oldWriter, oldWriter])
        XCTAssertEqual(fixture.connection.last("record.open")?["nextSeq"], 6)
        // The old id's late answers, and its gap, do not end the wait; nor does time.
        await fixture.session.receive(results([.object(["seq": 1, "duplicate": true]), .object(["seq": 2, "duplicate": true])]))
        await fixture.session.receive(["type": "record.gap", "documentId": "doc-1", "expected": 1])
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(fixture.connection.all("record.open").count, 2)
        // The old id's open is answered behind everything its stream carried.
        await fixture.session.receive(opened(lastSeq: 5))
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, fresh)
        XCTAssertEqual(fixture.connection.last("record.open")?["nextSeq"], 1)
        fixture.connection.clear()
        await fixture.session.receive(pagedOpened(4))
        await fixture.session.receive(lastPage(4))
        await eventually("the renumbered entries") { fixture.connection.last("record.entries") != nil }
        XCTAssertEqual(fixture.synced.value, 1)
        XCTAssertEqual(fixture.connection.types(), ["record.catchUp", "record.declare", "record.entries"])
        XCTAssertEqual(entryFrames(fixture.connection), [[1, 2]])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }.map(\.seq), [1, 2])
        for id in ["r1", "r2"] { XCTAssertNotNil(try binding.store.read(model: "Note", id: id)) }
    }

    func testTheRemintedWritersOldOpenAnsweredWithAnErrorEndsTheWait() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "r1")
        await fixture.session.start()
        await fixture.session.receive(opened(lastSeq: 5))
        await eventually("the old id opened again") { fixture.connection.all("record.open").count == 2 }
        await fixture.session.receive(error("DOCUMENT_NOT_OPEN", "record.entries"))
        XCTAssertEqual(fixture.connection.all("record.open").count, 2)
        await fixture.session.receive(error("WRITER_ID_TAKEN"))
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, binding.writer)
        XCTAssertEqual(fixture.connection.last("record.open")?["nextSeq"], 1)
    }

    func testARemintedWritersWaitForItsOldIdOutlivesTheConnectionAndTheSession() async throws {
        // The room delivers what the old id's subscription queued to the
        // connection id, which the next socket and the next session share.
        for reopen in [false, true] {
            let history = RecordLogWriterHistory()
            let fixture = try await makeFixture(history: history)
            let binding = fixture.binding
            try write(binding, "r1")
            try write(binding, "r2")
            let oldWriter = binding.writer
            await fixture.session.start()
            await fixture.session.receive(opened(lastSeq: 5))
            let fresh = binding.writer
            await fixture.session.disconnected()
            let session = reopen ? await reopened(fixture, history: history) : fixture.session
            fixture.connection.clear()
            await session.start()
            // The old id is opened first, alone; its answers meanwhile are dropped.
            XCTAssertEqual(fixture.connection.types(), ["record.open"])
            XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, oldWriter)
            await session.receive(results([.object(["seq": 1, "duplicate": true])]))
            XCTAssertEqual(fixture.connection.types(), ["record.open"])
            await session.receive(opened(lastSeq: 5))
            XCTAssertEqual(fixture.connection.types(), ["record.open", "record.open"])
            XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, fresh)
            await session.receive(opened())
            await eventually("the renumbered entries") { fixture.connection.last("record.entries") != nil }
            XCTAssertEqual(fixture.connection.types(), ["record.open", "record.open", "record.declare", "record.entries"])
            XCTAssertEqual(entryFrames(fixture.connection), [[1, 2]])
            XCTAssertEqual(try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }.map(\.seq), [1, 2])
        }
    }

    func testTheDocumentClosedAndOpenedAgainBetweenAnOrphanDrainAndTheOwnOpenedSendsNothingAhead() async throws {
        let provider = try await makeProvider()
        let earlier = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "earlier"
        )
        try write(earlier, "o1")
        let history = RecordLogWriterHistory()
        let fixture = try await makeFixture(provider: provider, clientId: "now", history: history)
        let binding = fixture.binding
        try write(binding, "mine")
        await fixture.session.start()
        await fixture.session.receive(opened())
        await eventually("the orphan's entries") { fixture.connection.last("record.entries") != nil }
        await fixture.session.receive(results([result(1, "o1", "o1", w: earlier.writer, seq: 1)]))
        await eventually("the own writer's open") { fixture.connection.all("record.open").count == 2 }
        await fixture.session.disconnected()
        let session = await reopened(fixture, history: history)

        fixture.connection.clear()
        await session.start()
        XCTAssertEqual(fixture.connection.types(), ["record.open"], "the own writer's open goes alone")
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, binding.writer)
        // The orphan's answer, judged under its surviving subscription: dropped.
        await session.receive(results([.object(["seq": 1, "duplicate": true])]))
        await session.receive(opened(lsn: 1, catchUp: .object(["mode": "inline", "rows": [], "gone": [], "lsn": 1, "upTo": 1])))
        await eventually("the own entries") { fixture.connection.last("record.entries") != nil }
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.declare", "record.entries"])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }.map(\.seq), [1])
        XCTAssertNotNil(try binding.store.read(model: "Note", id: "mine"))
    }

    func testAConnectionLostBetweenAnOrphanDrainAndTheOwnOpenedSendsNothingAheadOnTheNext() async throws {
        // The room may still hold this connection id's subscription for the
        // orphan: a server that judges frames sent ahead under it would answer
        // the own writer's 1 with the orphan's duplicate.
        let provider = try await makeProvider()
        let earlier = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "earlier"
        )
        try write(earlier, "o1")
        let fixture = try await makeFixture(provider: provider, clientId: "now")
        let binding = fixture.binding
        try write(binding, "mine")
        await fixture.session.start()
        await fixture.session.receive(opened())
        await eventually("the orphan's entries") { fixture.connection.last("record.entries") != nil }
        await fixture.session.receive(results([result(1, "o1", "o1", w: earlier.writer, seq: 1)]))
        await eventually("the own writer's open") { fixture.connection.all("record.open").count == 2 }
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, binding.writer)
        await fixture.session.disconnected()

        fixture.connection.clear()
        await fixture.session.start()
        XCTAssertEqual(fixture.connection.types(), ["record.open"], "the own writer's open goes alone")
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, binding.writer)
        // The orphan's answer, judged under its surviving subscription, arrives before the open's: dropped.
        await fixture.session.receive(results([.object(["seq": 1, "duplicate": true])]))
        await fixture.session.receive(opened(lsn: 1, catchUp: .object(["mode": "inline", "rows": [], "gone": [], "lsn": 1, "upTo": 1])))
        await eventually("the own entries") { fixture.connection.last("record.entries") != nil }
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.declare", "record.entries"])
        XCTAssertEqual(entryFrames(fixture.connection), [[1]])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).filter { $0.acked == nil }.map(\.seq), [1])
        XCTAssertNotNil(try binding.store.read(model: "Note", id: "mine"))

        // Once the room answered the own writer's open, a later connection's first open sends ahead again.
        await fixture.session.disconnected()
        fixture.connection.clear()
        await fixture.session.start()
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.declare", "record.entries"])
    }

    func testAConnectionLostBeforeARemintedWritersOpenedSendsNothingAheadOnTheNext() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "r1")
        await fixture.session.start()
        await fixture.session.receive(opened(lastSeq: 4))
        await fixture.session.receive(results([.object(["seq": 1, "duplicate": true])]))
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, binding.writer)
        await fixture.session.disconnected()
        fixture.connection.clear()
        await fixture.session.start()
        XCTAssertEqual(fixture.connection.types(), ["record.open"])
        XCTAssertEqual(fixture.connection.last("record.open")?["writer"]?.stringValue, binding.writer)
    }

    func testAReadersFramesSentAheadAnsweredWriteAccessDeniedHandTheWritesBackOnce() async throws {
        for deniedAfterOpened in [false, true] {
            let fixture = try await makeFixture()
            let binding = fixture.binding
            try write(binding, "r1")
            try write(binding, "r2")
            await fixture.session.start()
            let deny = {
                await fixture.session.receive(self.error("WRITE_ACCESS_DENIED", "record.declare"))
                await fixture.session.receive(self.error("WRITE_ACCESS_DENIED", "record.entries", extra: ["from": 1]))
            }
            if !deniedAfterOpened { await deny() }
            await fixture.session.receive(pagedOpened(3))
            if deniedAfterOpened { await deny() }
            await fixture.session.receive(lastPage(3))
            XCTAssertEqual(fixture.synced.value, 1)
            XCTAssertTrue(binding.isReadOnly)
            XCTAssertEqual(fixture.refusals.value.count, 1, "after: \(deniedAfterOpened)")
            XCTAssertEqual(fixture.refusals.value.first?.error.code, .writeAccessDenied)
            XCTAssertEqual(fixture.refusals.value.first?.writes?.map(\.recordId), ["r1", "r2"])
            XCTAssertEqual(try binding.store.pendingOf(binding.writer).map(\.seq), [])
            XCTAssertEqual(try binding.refreshMarks().cursor, 3)
        }
    }

    func testAnEntryCommittedWhileTheOpenIsUnderWayLeavesOnceInItsOwnFrame() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "r1")
        await fixture.session.start()
        try write(binding, "r2")
        await fixture.session.receive(acks([1], from: 1, writer: binding.writer))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(entryFrames(fixture.connection), [[1]])
        await fixture.session.receive(opened(
            lsn: 1, lastSeq: 1, catchUp: .object(["mode": "inline", "rows": [row("r1", "r1")], "gone": [], "lsn": 1, "upTo": 1])
        ))
        await eventually("the entry committed meanwhile") { fixture.connection.all("record.entries").count == 2 }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(entryFrames(fixture.connection), [[1], [2]])
        XCTAssertEqual(fixture.connection.types(), ["record.open", "record.declare", "record.entries", "record.entries"])
    }

    func testAModelRegisteredDuringTheCatchUpIsDeclaredBeforeItsEntry() async throws {
        let declared = LockedBox<[String]>(["Note"])
        let fixture = try await makeFixture(declarations: {
            Dictionary(uniqueKeysWithValues: declared.value.map { ($0, JSONValue.object(["fields": .object([:])])) })
        })
        let binding = fixture.binding
        try write(binding, "r1")
        await fixture.session.start()
        await fixture.session.receive(pagedOpened(4))
        await fixture.session.receive(acks([1], from: 5, writer: binding.writer))
        let late = PrimitiveSchema(
            name: "Late", fields: ["id": FieldDescriptor(type: .id), "code": FieldDescriptor(type: .string, unique: true)]
        )
        try binding.registerModel(late)
        declared.withValue { $0.append("Late") }
        await fixture.session.declare()
        try binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: "Late", id: "l1", kind: .create, fields: ["code": "k"]),
        ])])
        try binding.store.flush()
        fixture.connection.clear()
        await fixture.session.receive(lastPage(4))
        await eventually("the late model's entry") { fixture.connection.last("record.entries") != nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.connection.types(), ["record.declare", "record.entries"], "declared before its entry")
        XCTAssertNotNil(fixture.connection.last("record.declare")?["models"]?["Late"])
        XCTAssertEqual(entryFrames(fixture.connection), [[2]])
    }

    func testWithNoModelRegisteredSinceTheDeclarationWentAheadNoSecondOneLeaves() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        try write(binding, "r1")
        await fixture.session.start()
        await fixture.session.receive(pagedOpened(4))
        try write(binding, "r2")
        await fixture.session.receive(acks([1], from: 5, writer: binding.writer))
        fixture.connection.clear()
        await fixture.session.receive(lastPage(4))
        await eventually("the entry committed meanwhile") { fixture.connection.last("record.entries") != nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.connection.types(), ["record.entries"])
        XCTAssertEqual(entryFrames(fixture.connection), [[2]])
    }
}
