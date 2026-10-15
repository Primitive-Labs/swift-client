import XCTest
@testable import JsBaoClient

/// Compact own acknowledgements in the Swift client (#4473): the twin of
/// js-bao's `record-log-client-compact-ack-4473` and
/// `record-log-client-session-compact-ack-4473` suites.
///
/// - Every `record.open` declares `acks: "compact"`: with artifact fetching,
///   without it, and after two failed receipts; the frame is the one recorded
///   in `fixtures/compact-ack-forward-compat-4473.json`, which the merge-base
///   room accepts.
/// - `{l, e, w, seq}` with no `changes` is applied, when the cursor reaches
///   `l - 1`, by the pending entry's mutations as plain row operations, giving
///   the rows and touched records of the full item; ahead of the cursor it
///   waits, through the store's buffer; with no unwithdrawn pending entry it
///   stays buffered, the cursor does not pass it, and the session logs and
///   opens again from the cursor.
/// - The full acknowledgement the room before #4473 answers (recorded in the
///   fixture) confirms the row.
final class RecordLogCompactAckHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private static let writer = "01JW4473SW1FTRV1ESWR1TER01"
    private static let other = "01JW4473SW1FT0THERWR1TER01"

    private var directories: [String] = []
    private var lines = H.Lines()

    override func setUp() {
        super.setUp()
        let lines = H.Lines()
        self.lines = lines
        Logger.lineForTest = { level, _, message in
            if message.contains(H.documentId) { lines.append(level, message) }
        }
    }

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Harness

    private func harness(fetches: Bool = true) async throws -> H.Fixture {
        let directory = NSTemporaryDirectory() + "/record-log-compact-ack-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return try await H.Fixture(provider: provider, clientId: "client-a", fetches: fetches, timings: H.timings)
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

    private func loadForm(_ pointer: [String: JSONValue], cursor: Int, upTo: Int) -> JSONValue {
        .object(["mode": "load", "load": .object(pointer), "count": 0, "cursor": .number(Double(cursor)), "upTo": .number(Double(upTo))])
    }

    private static func fixture() throws -> JSONValue {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // JsBaoClientTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-client
            .deletingLastPathComponent()  // the repository
        let data = try Data(contentsOf: root.appendingPathComponent("tests/perf/overlay-layouts/fixtures/compact-ack-forward-compat-4473.json"))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func key(_ id: String) -> RecordLogRecordKey { RecordLogRecordKey(model: "Note", id: id) }

    private func client(writers: [String] = [writer]) -> (tables: RecordLogMemoryTables, rules: RecordLogRules) {
        let tables = RecordLogMemoryTables(writers: writers)
        return (tables, RecordLogRules(tables: tables, writer: writers[0]))
    }

    private func item(_ json: JSONValue) throws -> RecordLogResultItem {
        try XCTUnwrap(RecordLogResultItem(json: json))
    }

    private func compact(_ l: Int, seq: Int, writer: String = writer) throws -> RecordLogResultItem {
        try item(.object(["l": .number(Double(l)), "e": 1, "w": .string(writer), "seq": .number(Double(seq))]))
    }

    private func full(_ l: Int, _ changes: [JSONValue], writer: String? = nil, seq: Int? = nil) throws -> RecordLogResultItem {
        var object: [String: JSONValue] = ["l": .number(Double(l)), "e": 1, "changes": .array(changes)]
        if let writer { object["w"] = .string(writer) }
        if let seq { object["seq"] = .number(Double(seq)) }
        return try item(.object(object))
    }

    /// The confirmed rows, in table order.
    private func confirmed(_ tables: RecordLogMemoryTables) -> [RecordLogRow] {
        tables.rows.orderedRows.map(\.row)
    }

    // MARK: - Every open declares compact acknowledgements (behavior 11)

    func testEveryOpenDeclaresCompactAcknowledgementsWithAndWithoutArtifactFetching() async throws {
        let able = try await harness()
        await able.session.start()
        XCTAssertEqual(able.of("record.open").first?["acks"], "compact")
        XCTAssertEqual(able.of("record.open").first?["accepts"], ["load", "segment", "building"])
        let unable = try await harness(fetches: false)
        await unable.session.start()
        XCTAssertEqual(unable.of("record.open").first?["acks"], "compact")
        XCTAssertNil(unable.of("record.open").first?["accepts"])
    }

    func testEveryOpenDeclaresCompactAcknowledgementsAfterTwoFailedReceiptsToo() async throws {
        let h = try await harness()
        let pointer = h.publishLoad(
            sessionId: "01JS4473SESS10NC0MPACTXX01", chunks: [("Note", [("n1", ["t": 1])]), ("Note", [("n2", ["t": 2])])],
            firstLsn: 1, lastLsn: 2
        )
        await h.session.start()
        h.connection.intercept { $0.hasSuffix("/Note/1.ATTEMPT1") ? .status(404) : .pass }
        await h.feed(H.opened(lsn: 2, catchUp: loadForm(pointer, cursor: 0, upTo: 2)))
        await until("the first reopen") { h.of("record.open").count == 2 }
        h.connection.intercept { _ in .status(403) }
        await h.feed(H.opened(lsn: 2, catchUp: loadForm(pointer, cursor: 0, upTo: 2)))
        await until("the second reopen") { h.of("record.open").count == 3 }
        let opens = h.of("record.open")
        XCTAssertEqual(opens.dropFirst(2).first?["accepts"], [])
        XCTAssertEqual(opens.map { $0["acks"]?.stringValue }, ["compact", "compact", "compact"])
    }

    func testTheOpenFrameIsTheOneRecordedForTheMergeBaseRoom() async throws {
        let h = try await harness()
        await h.session.start()
        var frame = try XCTUnwrap(h.of("record.open").first)
        let recorded = try XCTUnwrap(Self.fixture()["swiftOpen"]?.objectValue)
        frame["writer"] = recorded["writer"]
        XCTAssertEqual(JSONValue.object(frame), JSONValue.object(recorded))
    }

    // MARK: - Deriving a compact acknowledgement (behavior 12)

    func testACompactAcknowledgementGivesTheRowsAndTouchedRecordsOfTheFullItem() throws {
        let a = client()
        let b = client()
        let steps: [(RecordLogMutation, [JSONValue])] = [
            (
                RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["title": "one", "slug": "s1"], stringSetDeltas: ["tags": ["b": true, "a": true]]),
                [.object(["model": "Note", "id": "n1", "row": ["id": "n1", "slug": "s1", "tags": ["a", "b"], "title": "one"]])]
            ),
            (
                RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["title": .null], stringSetDeltas: ["tags": ["a": false, "c": true]]),
                [.object(["model": "Note", "id": "n1", "set": ["tags": ["b", "c"], "title": .null]])]
            ),
            (
                RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["slug": "again"]),
                [.object(["model": "Note", "id": "n1", "set": ["slug": "again"], "unset": ["tags", "title"]])]
            ),
            (
                RecordLogMutation(model: "Note", id: "n1", kind: .delete),
                [.object(["model": "Note", "id": "n1", "gone": true])]
            ),
        ]
        for (l, (mutation, changes)) in steps.enumerated().map({ ($0.offset + 1, $0.element) }) {
            let entry = try a.rules.write(mutation)
            _ = try b.rules.write(mutation)
            let fromFull = try a.rules.receive(full(l, changes, writer: Self.writer, seq: entry.seq))
            let fromCompact = try b.rules.receive(compact(l, seq: entry.seq))
            XCTAssertEqual(b.tables.cursor(), l)
            XCTAssertEqual(confirmed(b.tables), confirmed(a.tables), "after \(mutation.kind)")
            XCTAssertEqual(Set(fromCompact.touched), Set(fromFull.touched))
            XCTAssertEqual(fromCompact.settled, fromFull.settled)
            XCTAssertEqual(fromCompact.acknowledged, fromFull.acknowledged)
        }
        XCTAssertTrue(try b.rules.pending().isEmpty)
        XCTAssertTrue(b.tables.rows.orderedRows.isEmpty)
    }

    func testACompactAcknowledgementWaitsAheadOfTheCursorAndIsDerivedAtItsTurn() throws {
        let (tables, rules) = client()
        let entry = try rules.write(RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["title": "mine"]))
        _ = try rules.receive(compact(2, seq: entry.seq))
        XCTAssertEqual(tables.cursor(), 0)
        XCTAssertEqual(try rules.pending().count, 1)
        _ = try rules.receive(full(1, [.object(["model": "Note", "id": "o1", "row": ["id": "o1", "title": "theirs"]])]))
        XCTAssertEqual(tables.cursor(), 2)
        XCTAssertTrue(try rules.pending().isEmpty)
        XCTAssertEqual(confirmed(tables), [["id": "o1", "title": "theirs"], ["id": "n1", "title": "mine"]])
    }

    func testAtOrBelowTheCursorACompactAcknowledgementOnlySettles() throws {
        let tables = RecordLogMemoryTables(writers: [Self.writer, Self.other])
        let sibling = RecordLogRules(tables: tables, writer: Self.other)
        let current = RecordLogRules(tables: tables, writer: Self.writer)
        let entry = try sibling.write(RecordLogMutation(model: "Note", id: "s1", kind: .create, fields: ["title": "sibling's"]))
        _ = try current.receive(full(1, [.object(["model": "Note", "id": "s1", "row": ["id": "s1", "title": "sibling's"]])]))
        let rows = confirmed(tables)
        let out = try sibling.receive(compact(1, seq: entry.seq, writer: Self.other))
        XCTAssertEqual(out.settled, [RecordLogEntryRef(writer: Self.other, seq: entry.seq)])
        XCTAssertTrue(try sibling.pending().isEmpty)
        XCTAssertEqual(confirmed(tables), rows)
        let again = try sibling.receive(compact(1, seq: entry.seq, writer: Self.other))
        XCTAssertTrue(again.settled.isEmpty)
        XCTAssertEqual(confirmed(tables), rows)
    }

    func testAFullItemWithNoChangesIsAppliedAsNothingChanged() throws {
        let tables = RecordLogMemoryTables(rows: [(key("n1"), ["id": "n1", "title": "x"])], writers: [Self.writer])
        let rules = RecordLogRules(tables: tables, writer: Self.writer)
        let entry = try rules.write(RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["title": "x"]))
        _ = try rules.receive(full(1, [], writer: Self.writer, seq: entry.seq))
        XCTAssertEqual(tables.cursor(), 1)
        XCTAssertTrue(try rules.pending().isEmpty)
        XCTAssertEqual(confirmed(tables), [["id": "n1", "title": "x"]])
    }

    func testACompactAcknowledgementWithNoPendingEntryStaysBufferedAndHoldsTheCursor() throws {
        let (tables, rules) = client()
        _ = try rules.receive(compact(1, seq: 4))
        XCTAssertEqual(tables.cursor(), 0)
        _ = try rules.receive(full(2, [.object(["model": "Note", "id": "o", "row": ["id": "o"]])]))
        XCTAssertEqual(tables.cursor(), 0)
        let withdrawn = client()
        var entry = try withdrawn.rules.write(RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["title": "x"]))
        entry.isVoid = true
        withdrawn.tables.putPending(Self.writer, entry)
        _ = try withdrawn.rules.receive(compact(1, seq: entry.seq))
        XCTAssertEqual(withdrawn.tables.cursor(), 0)
        XCTAssertTrue(withdrawn.tables.rows.orderedRows.isEmpty)
    }

    func testABufferedCompactAcknowledgementIsDerivedThroughTheStore() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(H.opened())
        await until("synced") { h.synced.value == 1 }
        let seq = try h.save("n1", ["title": "mine"])
        let writer = h.binding.writer
        await h.feed(H.results([.object(["l": 2, "e": 1, "w": .string(writer), "seq": .number(Double(seq))])]))
        XCTAssertEqual(h.marks.cursor, 0)
        await h.feed(H.results([H.result(1, "o1", ["title": "theirs"])]))
        await until("the cursor passes the compact acknowledgement") { h.marks.cursor == 2 }
        XCTAssertEqual(try h.read("n1"), ["id": "n1", "title": "mine"])
        XCTAssertEqual(try h.read("o1"), ["id": "o1", "title": "theirs"])
        XCTAssertTrue(try h.binding.store.pendingOf(writer).isEmpty)
    }

    func testACompactAcknowledgementTheStoreCannotDeriveIsLoggedAndOpensAgainFromTheCursor() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(H.opened())
        await until("synced") { h.synced.value == 1 }
        let writer = h.binding.writer
        await h.feed(H.results([.object(["l": 1, "e": 1, "w": .string(writer), "seq": 7])]))
        await until("the reopen") { h.of("record.open").count == 2 }
        XCTAssertEqual(h.of("record.open").dropFirst().first?["cursor"], 0)
        XCTAssertEqual(h.of("record.open").dropFirst().first?["acks"], "compact")
        XCTAssertEqual(h.marks.cursor, 0)
        XCTAssertTrue(lines.messages(.warn).contains {
            $0.contains(H.documentId) && $0.contains(writer) && $0.contains("seq 7") && $0.contains("opening again from the cursor")
        })
        await h.feed(H.opened(lsn: 1, catchUp: .object(["mode": "inline", "rows": [H.row("n1", ["title": "from the room"])], "gone": [], "lsn": 1, "upTo": 1])))
        await until("the catch-up") { h.marks.cursor == 1 }
        XCTAssertEqual(try h.read("n1"), ["id": "n1", "title": "from the room"])
    }

    // MARK: - The room before the change (behavior 18, Swift fixture)

    func testTheFullAcknowledgementOfTheRoomBeforeTheChangeConfirmsTheRow() throws {
        let fixture = try Self.fixture()
        let writer = try XCTUnwrap(fixture["swiftOpen"]?["writer"]?.stringValue)
        let mutation = try XCTUnwrap(RecordLogMutation(json: fixture["create"]?["m"]))
        let (tables, rules) = client(writers: [writer])
        let entry = try rules.write(mutation)
        XCTAssertEqual(entry.seq, fixture["create"]?["seq"]?.wholeNumber)
        let out = try rules.receive(item(try XCTUnwrap(fixture["oldRoomAck"])))
        XCTAssertEqual(out.settled, [RecordLogEntryRef(writer: writer, seq: entry.seq)])
        XCTAssertTrue(try rules.pending().isEmpty)
        XCTAssertEqual(tables.cursor(), 1)
        XCTAssertEqual(tables.rows.row(mutation.key), ["id": .string(mutation.id), "title": "x"])
    }
}
