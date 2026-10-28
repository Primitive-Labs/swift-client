import XCTest
@testable import JsBaoClient

/// #4701 behaviours 5–7 and edges 47–48: what a db3's session tells its host
/// about where it is (the status a `Db3State.phase` is read from), its
/// `release()` (the conversation stopped without a socket loss, startable
/// again), and the room's access refusal (the store marked `refused`, nothing
/// more sent, the mark lifted by the own writer's next `record.opened`). Rule
/// for rule js-bao's `session.ts` `status()`, `release()` and
/// `accessRefused`, driven by scripted room frames over a real store through
/// the receipt harness's in-memory connection.
final class RecordLogSessionStatusHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private static let session1 = "01JS4701SESS10NL0ADXXXXX01"

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-status-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func harness(provider: SQLiteStorageProvider? = nil, clientId: String = "client-a") async throws -> H.Fixture {
        let store: SQLiteStorageProvider
        if let provider { store = provider } else { store = try await makeProvider() }
        return try await H.Fixture(provider: store, clientId: clientId, fetches: true, timings: H.timings)
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

    private func pause(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

    private func status(_ phase: RecordLogSessionPhase, _ progress: (Int, Int, RecordLogSessionProgress.Unit)? = nil) -> RecordLogSessionStatus {
        RecordLogSessionStatus(phase: phase, progress: progress.map { RecordLogSessionProgress(done: $0.0, total: $0.1, unit: $0.2) })
    }

    private func paged(cursor: Int, upTo: Int, count: Int, full: Bool = false) -> JSONValue {
        var form: [String: JSONValue] = [
            "mode": "paged", "cursor": .number(Double(cursor)), "upTo": .number(Double(upTo)), "count": .number(Double(count)),
        ]
        if full { form["full"] = true }
        return .object(form)
    }

    private func noRepeats(_ statuses: [RecordLogSessionStatus], file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(statuses, statuses.dropFirst()) {
            XCTAssertNotEqual(a, b, "the same status was reported twice in a row: \(statuses)", file: file, line: line)
        }
    }

    private func accessError(_ messageType: String?, code: String?, message: String = "Access denied to document") -> [String: JSONValue] {
        var frame: [String: JSONValue] = ["type": "error", "message": .string(message)]
        if let messageType { frame["messageType"] = .string(messageType) }
        if let code { frame["code"] = .string(code) }
        return frame
    }

    // MARK: - Behaviour 5: the status

    func testAFullWalkReportsOpeningThenLoadingWithEntriesThenLiveThenIdleOnRelease() async throws {
        let h = try await harness()
        await h.session.start()
        XCTAssertEqual(h.statuses.value, [status(.opening)])
        await h.feed(H.opened(lsn: 5, catchUp: paged(cursor: 0, upTo: 5, count: 3, full: true)))
        XCTAssertEqual(h.statuses.value.last, status(.loading, (0, 3, .entries)))
        await h.feed(H.page(rows: [H.row("p1"), H.row("p2")], lsn: 5, next: .object(["lsn": 2, "model": "Note", "id": "p2"])))
        XCTAssertEqual(h.statuses.value.last, status(.loading, (2, 3, .entries)))
        await h.feed(H.page(rows: [H.row("p3")], lsn: 5))
        XCTAssertEqual(h.statuses.value.last, status(.live))
        await h.session.release()
        XCTAssertEqual(h.statuses.value, [
            status(.opening), status(.loading, (0, 3, .entries)), status(.loading, (2, 3, .entries)), status(.live), status(.idle),
        ])

        // Paged changes from a cursor the store caught up to are a catch-up.
        await h.session.start()
        XCTAssertEqual(h.of("record.open").last?["cursor"], 5, "the open goes from the stored cursor")
        await h.feed(H.opened(lsn: 8, catchUp: paged(cursor: 5, upTo: 8, count: 2)))
        XCTAssertEqual(h.statuses.value.last, status(.catchingUp, (0, 2, .entries)))
        await h.feed(H.page(rows: [H.row("p4"), H.row("p5")], lsn: 8))
        XCTAssertEqual(h.statuses.value.last, status(.live))
        await h.session.disconnected()
        XCTAssertEqual(h.statuses.value.last, status(.idle), "a disconnect is idle too")
        noRepeats(h.statuses.value)
    }

    func testAStoresFirstLoadByPagesIsLoadingNotCatchingUp() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(H.opened(lsn: 3, catchUp: paged(cursor: 0, upTo: 3, count: 1)))
        XCTAssertEqual(h.statuses.value.last, status(.loading, (0, 1, .entries)), "cursor 0 and never caught up: a load")
        await h.feed(H.page(rows: [H.row("p1")], lsn: 3))
        XCTAssertEqual(h.statuses.value.last, status(.live))
    }

    func testAReceiptReportsLoadingWithChunksAndItsChunkRepliesNotifyRemoteWithTheirModels() async throws {
        let h = try await harness()
        let notices = LockedBox<[RecordLogChangeNotice]>([])
        h.binding.onChange { notice in notices.withValue { $0.append(notice) } }
        await h.session.start()
        let pointer = h.publishLoad(
            sessionId: Self.session1,
            chunks: [("Note", [("n1", ["title": "one"])]), ("Note", [("n2", ["title": "two"])])],
            firstLsn: 1, lastLsn: 2
        )
        let gate = H.Gate()
        h.connection.intercept { path in path.hasSuffix("/Note/1.ATTEMPT1") ? .hold(gate) : .pass }
        await h.feed(H.opened(lsn: 2, catchUp: .object([
            "mode": "load", "load": .object(pointer), "count": 0, "cursor": 0, "upTo": 2,
        ])))
        await until("the first chunk applied") { h.secondChunkHeld() }
        await until("one chunk of two") { h.statuses.value.last == status(.loading, (1, 2, .chunks)) }
        XCTAssertTrue(h.statuses.value.contains(status(.loading, (0, 2, .chunks))), "\(h.statuses.value)")
        let chunk = try XCTUnwrap(notices.value.first { !$0.models.isEmpty })
        XCTAssertEqual(chunk.origin, .remote)
        XCTAssertEqual(chunk.models, ["Note"])
        gate.open()
        await until("the remainder") { h.of("record.catchUp").count == 1 }
        await until("every chunk in, the remainder paging") { h.statuses.value.last == status(.loading, (2, 2, .chunks)) }
        await h.feed(H.page(rows: [], lsn: 2))
        XCTAssertEqual(h.statuses.value.last, status(.live))
        noRepeats(h.statuses.value)

        // A result the room relays is a remote change, with its row.
        await h.feed(H.results([H.result(3, "r1", ["title": "relayed"])]))
        let relayed = try XCTUnwrap(notices.value.last)
        XCTAssertEqual(relayed.origin, .remote)
        XCTAssertEqual(relayed.changes.first { $0.id == "r1" }?.row?["title"], "relayed")
    }

    // MARK: - Behaviour 6: release

    func testReleaseStopsTheConversationDropsHeldAnswersAndLeavesTheSessionStartable() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(H.opened(lsn: 5, catchUp: paged(cursor: 0, upTo: 5, count: 1)))
        // A result arriving while the pages are read is held for the catch-up's end…
        await h.feed(H.results([H.result(6, "late", ["title": "held"])]))
        await h.session.release()
        XCTAssertEqual(h.statuses.value.last, status(.idle))
        let sent = h.connection.frames.count
        _ = try h.save("mine", ["title": "after the release"])
        await h.feed(H.page(rows: [H.row("p1")], lsn: 5))
        await pause(60)
        XCTAssertEqual(h.connection.frames.count, sent, "nothing more is sent: \(h.connection.frames.suffix(2))")
        XCTAssertNil(try h.read("p1"), "a page of the released conversation applies to nothing")

        // …and dropped with it: the next open goes from the cursor and the held answer is gone.
        await h.session.start()
        XCTAssertEqual(h.of("record.open").count, 2)
        XCTAssertEqual(h.of("record.open").last?["cursor"], 0)
        await h.feed(H.opened(lsn: 5))
        XCTAssertEqual(h.synced.value, 1)
        XCTAssertNil(try h.read("late"), "the held result was dropped with the conversation")
        await until("the save made while released goes now") { !h.of("record.entries").isEmpty }

        // close() still ends it for good.
        await h.session.close()
        await h.session.start()
        XCTAssertEqual(h.of("record.open").count, 2)
    }

    // MARK: - Edge 48: release during a receipt

    func testReleaseDuringAReceiptCancelsItAndNothingItFetchedIsApplied() async throws {
        let h = try await harness()
        await h.session.start()
        let pointer = h.publishLoad(
            sessionId: Self.session1, chunks: [("Note", [("n1", ["title": "one"])])], firstLsn: 1, lastLsn: 1
        )
        let gate = H.Gate()
        h.connection.intercept { path in path.hasSuffix("/Note/0.ATTEMPT0") ? .hold(gate) : .pass }
        await h.feed(H.opened(lsn: 1, catchUp: .object([
            "mode": "load", "load": .object(pointer), "count": 0, "cursor": 0, "upTo": 1,
        ])))
        await until("the chunk is asked for") { h.connection.fetched.contains { $0.hasSuffix("/Note/0.ATTEMPT0") } }
        await h.session.release()
        gate.open()
        await pause(150)
        XCTAssertNil(try h.read("n1"), "nothing the cancelled receipt fetched is applied")
        XCTAssertTrue(h.of("record.catchUp").isEmpty, "no remainder is asked for")
        XCTAssertEqual(h.statuses.value.last, status(.idle))
        await h.session.start()
        XCTAssertEqual(h.of("record.open").count, 2, "startable again")
    }

    // MARK: - Behaviour 7: the access refusal

    func testAnAccessRefusalMarksTheStoreRefusedSendsNothingMoreAndTheOwnWritersOpenLiftsIt() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(H.opened())
        _ = try h.save("a", ["title": "queued"])
        await until("the entry") { !h.of("record.entries").isEmpty }

        await h.feed(accessError("record.entries", code: "ACCESS_DENIED"))
        XCTAssertEqual(h.marks.permission, "refused")
        XCTAssertEqual(h.failed.value, ["ACCESS_DENIED"])
        XCTAssertEqual(h.statuses.value.last, status(.idle))
        let sent = h.connection.frames.count
        await h.feed(H.results([H.result(1, "x", ["title": "after"])]))
        await pause(60)
        XCTAssertEqual(h.connection.frames.count, sent, "nothing more is sent")
        XCTAssertEqual(try h.binding.store.pendingOf(h.binding.writer).count, 1, "the unsent write is kept")
        XCTAssertNotNil(try h.read("a"), "the rows stay readable")

        await h.session.start()
        await h.feed(H.opened())
        XCTAssertNil(h.marks.permission, "the own writer's record.opened lifts the mark")
    }

    func testEveryFormOfTheAccessRefusalIsRecognisedAndNoOtherIs() async throws {
        for frame in [
            accessError("record.open", code: "DOC_ACCESS_DENIED"),
            accessError("record.catchUp", code: "ACCESS_DENIED"),
            accessError("record.open", code: nil),
            accessError(nil, code: nil),
        ] {
            let h = try await harness()
            await h.session.start()
            await h.feed(frame)
            XCTAssertEqual(h.marks.permission, "refused", "\(frame)")
            XCTAssertEqual(h.failed.value, ["ACCESS_DENIED"], "\(frame)")
        }
        for frame in [
            accessError("doc.sync", code: "ACCESS_DENIED"),
            accessError("record.open", code: "INTERNAL", message: "Access denied to document"),
            accessError("record.open", code: nil, message: "denied"),
        ] {
            let h = try await harness()
            await h.session.start()
            await h.feed(H.opened())
            await h.feed(frame)
            XCTAssertNil(h.marks.permission, "not an access refusal: \(frame)")
        }
    }

    // MARK: - Edge 47: only the own writer's open lifts the mark

    func testAnOrphanWritersOpenDoesNotLiftTheRefusedMark() async throws {
        let provider = try await makeProvider()
        let earlier = try RecordLogDocumentBinding(host: provider, documentId: H.documentId, clientId: "earlier")
        _ = try earlier.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: "o1", kind: .create, fields: ["title": "orphan"]),
        ])])
        try earlier.store.flush()
        let h = try await harness(provider: provider, clientId: "now")
        await h.session.start()
        XCTAssertEqual(h.of("record.open").last?["writer"]?.stringValue, earlier.writer)
        await h.feed(accessError("record.open", code: "ACCESS_DENIED"))
        XCTAssertEqual(h.marks.permission, "refused")

        await h.session.start()
        XCTAssertEqual(h.of("record.open").last?["writer"]?.stringValue, earlier.writer, "the orphan opens first again")
        await h.feed(H.opened())
        XCTAssertEqual(h.marks.permission, "refused", "an orphan writer's record.opened does not lift it")
        await until("the orphan's entry") { !h.of("record.entries").isEmpty }
        await h.feed(H.results([.object(["seq": 1, "duplicate": true])]))
        await until("the own writer's open") { h.of("record.open").last?["writer"]?.stringValue == h.binding.writer }
        XCTAssertEqual(h.marks.permission, "refused")
        await h.feed(H.opened())
        XCTAssertNil(h.marks.permission, "the own writer's record.opened lifts it")
    }
}
