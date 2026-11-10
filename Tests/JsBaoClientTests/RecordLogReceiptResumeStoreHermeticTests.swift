import XCTest
@testable import JsBaoClient

/// #5267 behaviors 5–8 and 7b (Swift store, over a real `SQLiteStorageProvider`
/// on a temp file): the twin of js-bao's `record-log-client-store-resume-5267.test.ts`.
///
/// 5:  `beginReceipt` with a fingerprint answers the attempt and its progress;
///     a store reopened over the file after two chunks resumes at `done: 2`; a
///     chunk whose transaction fails leaves neither its rows nor its progress;
///     the marks carry `done` and `completed`.
/// 6:  a refresh resumed after chunk 1 of 2 removes exactly the covered rows no
///     chunk of either run named; a completed one is answered so.
/// 7:  a resumed segment continues under its generation; a superseded one
///     starts fresh, as does one stopped before its own replacement began
///     while an older one was unfinished (5267-C2-01) and one beside a receipt
///     that changed a row since its replacement began (5267-C2-02), as does
///     one whose generation a load that completed since or another writer's
///     page wrote into (5267-C2-04); each completes fresh with only the room's
///     rows. Its own replacement's pages leave it resumable.
/// 7b: a load around another writer's replacement starts fresh and completes
///     with every row.
/// 8:  after an adoption every command of the replaced attempt is `stale`.
/// Edge: the adoption renames the load keys in its own transaction. Pin
/// (behavior 20): what an earlier build wrote still reads and is never resumed.
final class RecordLogReceiptResumeStoreHermeticTests: XCTestCase {

    private let s = "01JS5267ST0RERESUMELOAD001"
    private let g1 = "01JG5267ST0RERESUMESEG0001"
    private let g2 = "01JG5267ST0RERESUMESEG0002"
    private let f = String(repeating: "a", count: 64)
    private let f2 = String(repeating: "b", count: 64)
    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/record-log-resume-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func makeProvider(path: String) async throws -> SQLiteStorageProvider {
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// A store over `provider`, its writer the first one `clientId` minted there.
    private func store(_ provider: SQLiteStorageProvider, clientId: String = "client-a") throws -> (store: RecordLogStore, writer: String) {
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: clientId)
        try store.initialize()
        return (store, try store.marks().writer ?? store.mintWriter())
    }

    private func line(_ id: String, _ title: String? = nil) -> RecordLogLoadLine {
        RecordLogLoadLine(id: id, patch: ["title": .string(title ?? "l-\(id)")])
    }

    private func note(_ id: String, _ title: String? = nil) -> RecordLogCatchUpRow {
        RecordLogCatchUpRow(model: "Note", id: id, row: ["id": .string(id), "title": .string(title ?? "t-\(id)")])
    }

    @discardableResult
    private func load(_ store: RecordLogStore, _ writer: String, _ attempt: String, _ lines: [RecordLogLoadLine]) throws -> RecordLogChunkReply {
        try store.applyLoadChunk(writer: writer, sessionId: s, attempt: attempt, model: "Note", lines: lines)
    }

    private func rowIds(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection {
            try $0.query("SELECT _id FROM record_log_rows WHERE doc_id = 'doc-1' ORDER BY _id", []).compactMap { $0["_id"].stringValue }
        }
    }

    private func loadKeys(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection {
            try $0.query("SELECT DISTINCT attempt FROM record_log_load_keys WHERE doc_id = 'doc-1'", []).compactMap { $0["attempt"].stringValue }
        }
    }

    private func receiptText(_ provider: SQLiteStorageProvider) throws -> String? {
        try provider.withConnection {
            try $0.query("SELECT receipt FROM record_log_state WHERE doc_id = 'doc-1'", []).first?["receipt"].stringValue
        }
    }

    private func rowsText(_ provider: SQLiteStorageProvider) throws -> [String] {
        try provider.withConnection {
            try $0.query("SELECT _id, _gen, json(_data) AS d FROM record_log_rows ORDER BY _id", []).map {
                "\($0["_id"].stringValue ?? "")|\($0["_gen"].intValue ?? -1)|\($0["d"].stringValue ?? "")"
            }
        }
    }

    // MARK: - beginReceipt with a fingerprint (behavior 5)

    func testAFreshAttemptStartsAtZeroAndAStoreReopenedOverTheFileResumesItAtTwo() async throws {
        let path = newDatabasePath()
        let provider = try await makeProvider(path: path)
        let (first, writer) = try store(provider)
        let fresh = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 3)
        XCTAssertEqual(fresh, RecordLogReceiptStart(cursor: 0, attempt: fresh.attempt))
        XCTAssertEqual(try first.marks().receipt, RecordLogReceipt(kind: .load, id: s, done: 0, completed: false))
        try load(first, writer, fresh.attempt, [line("n1")])
        try load(first, writer, fresh.attempt, [line("n2")])
        XCTAssertEqual(try first.marks().receipt, RecordLogReceipt(kind: .load, id: s, done: 2, completed: false))
        await provider.close()

        let reopened = try await makeProvider(path: path)
        let (again, againWriter) = try store(reopened, clientId: "client-b")
        let resumed = try again.beginReceipt(writer: againWriter, kind: .load, id: s, fingerprint: f, chunks: 3)
        XCTAssertEqual(resumed, RecordLogReceiptStart(cursor: 0, attempt: resumed.attempt, done: 2))
        XCTAssertNotEqual(resumed.attempt, fresh.attempt)
        XCTAssertEqual(try loadKeys(reopened), [resumed.attempt])
        _ = try again.completeLoad(writer: againWriter, sessionId: s, attempt: resumed.attempt, mode: .merge, models: ["Note"])
        XCTAssertEqual(try again.marks().receipt, RecordLogReceipt(kind: .load, id: s, done: 2, completed: true))
        await reopened.close()
    }

    func testAChunkWhoseTransactionFailsKeepsNeitherItsRowsNorItsProgress() async throws {
        let path = newDatabasePath()
        let provider = try await makeProvider(path: path)
        let (first, writer) = try store(provider)
        let attempt = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 3).attempt
        try load(first, writer, attempt, [line("n1")])
        try provider.withConnection { connection in
            try connection.executeScript("""
                CREATE TRIGGER refuse_n3 BEFORE INSERT ON record_log_view WHEN NEW._id = 'n3'
                BEGIN SELECT RAISE(ABORT, 'the chunk fails mid-way'); END
                """)
        }
        XCTAssertThrowsError(try load(first, writer, attempt, [line("n2"), line("n3")]))
        try provider.withConnection { try $0.executeScript("DROP TRIGGER refuse_n3") }
        XCTAssertEqual(try rowIds(provider), ["n1"])
        await provider.close()
        let reopened = try await makeProvider(path: path)
        let (again, againWriter) = try store(reopened, clientId: "client-b")
        XCTAssertEqual(try again.marks().receipt, RecordLogReceipt(kind: .load, id: s, done: 1, completed: false))
        XCTAssertEqual(try again.beginReceipt(writer: againWriter, kind: .load, id: s, fingerprint: f, chunks: 3).done, 1)
        await reopened.close()
    }

    func testAnotherFingerprintIdOrProgressPastTheListStartsFresh() async throws {
        let provider = try await makeProvider(path: newDatabasePath())
        let (first, writer) = try store(provider)
        let attempt = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 2).attempt
        try load(first, writer, attempt, [line("n1")])
        try load(first, writer, attempt, [line("n2")])
        let before = RecordLogReceiptState(json: RecordLogJSON.parse(try XCTUnwrap(try receiptText(provider))))
        let (other, otherWriter) = try store(provider, clientId: "client-b")
        XCTAssertEqual(try other.beginReceipt(writer: otherWriter, kind: .load, id: s, fingerprint: f, chunks: 1).done, 0)
        XCTAssertEqual(try other.beginReceipt(writer: otherWriter, kind: .load, id: s, fingerprint: f2, chunks: 2).done, 0)
        XCTAssertEqual(try other.beginReceipt(writer: otherWriter, kind: .load, id: "S-other", fingerprint: f, chunks: 2).done, 0)
        let after = RecordLogReceiptState(json: RecordLogJSON.parse(try XCTUnwrap(try receiptText(provider))))
        XCTAssertEqual(after?.attempts.first, before?.attempts.first)
        await provider.close()
    }

    func testTheAdoptionRenamesTheLoadKeysInItsOwnTransaction() async throws {
        let provider = try await makeProvider(path: newDatabasePath())
        let (first, writer) = try store(provider)
        let attempt = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 3).attempt
        try load(first, writer, attempt, [line("n1"), line("n2")])
        let before = try receiptText(provider)
        try provider.withConnection { connection in
            try connection.executeScript("""
                CREATE TRIGGER refuse_receipt BEFORE UPDATE OF receipt ON record_log_state
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }
        let (other, otherWriter) = try store(provider, clientId: "client-b")
        XCTAssertThrowsError(try other.beginReceipt(writer: otherWriter, kind: .load, id: s, fingerprint: f, chunks: 3))
        try provider.withConnection { try $0.executeScript("DROP TRIGGER refuse_receipt") }
        XCTAssertEqual(try loadKeys(provider), [attempt])
        XCTAssertEqual(try receiptText(provider), before)
        await provider.close()
    }

    // MARK: - A refresh resumed (behavior 6)

    private func refreshing(_ provider: SQLiteStorageProvider) throws -> (store: RecordLogStore, writer: String, attempt: String) {
        let (first, writer) = try store(provider)
        _ = try first.applyCatchUpPage(writer: writer, rows: [
            note("a1", "old"), note("gone1"), note("gone2"), note("b2", "old"),
            RecordLogCatchUpRow(model: "Task", id: "t1", row: ["id": "t1"]),
        ])
        let attempt = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 2).attempt
        try load(first, writer, attempt, [line("a1"), line("a2")])
        return (first, writer, attempt)
    }

    func testARefreshResumedInASecondStoreRemovesExactlyTheRowsNoChunkOfEitherRunNamed() async throws {
        let path = newDatabasePath()
        let provider = try await makeProvider(path: path)
        _ = try refreshing(provider)
        await provider.close()
        let reopened = try await makeProvider(path: path)
        let (again, writer) = try store(reopened, clientId: "client-b")
        let resumed = try again.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 2)
        XCTAssertEqual(resumed.done, 1)
        XCTAssertFalse(resumed.completed)
        try load(again, writer, resumed.attempt, [line("b1"), line("b2")])
        let reply = try again.completeLoad(writer: writer, sessionId: s, attempt: resumed.attempt, mode: .refresh, models: ["Note"])
        XCTAssertEqual(reply.removed, 2)
        XCTAssertEqual(try rowIds(reopened), ["a1", "a2", "b1", "b2", "t1"])
        XCTAssertNil(try again.read(model: "Note", id: "gone1"))
        XCTAssertEqual(try again.read(model: "Note", id: "a1"), ["id": "a1", "title": "l-a1"])
        await reopened.close()
    }

    func testACompletedAttemptIsAnsweredSoAndItsRemainderLeavesEveryRowInPlace() async throws {
        let path = newDatabasePath()
        let provider = try await makeProvider(path: path)
        let (first, writer, attempt) = try refreshing(provider)
        try load(first, writer, attempt, [line("b1"), line("b2")])
        _ = try first.completeLoad(writer: writer, sessionId: s, attempt: attempt, mode: .refresh, models: ["Note"])
        _ = try first.applyCatchUpPage(writer: writer, rows: [note("w1", "during")], lsn: 3, receipt: attempt)
        await provider.close()
        let reopened = try await makeProvider(path: path)
        let (again, againWriter) = try store(reopened, clientId: "client-b")
        let resumed = try again.beginReceipt(writer: againWriter, kind: .load, id: s, fingerprint: f, chunks: 2)
        XCTAssertEqual(resumed.done, 2)
        XCTAssertTrue(resumed.completed)
        _ = try again.applyCatchUpPage(writer: againWriter, rows: [note("w1", "during")], lsn: 3, receipt: resumed.attempt)
        _ = try again.completeCatchUp(writer: againWriter, lsn: 3, receipt: resumed.attempt)
        XCTAssertEqual(try rowIds(reopened), ["a1", "a2", "b1", "b2", "t1", "w1"])
        XCTAssertEqual(try again.marks().cursor, 3)
        XCTAssertNil(try again.marks().receipt)
        XCTAssertEqual(try loadKeys(reopened), [])
        await reopened.close()
    }

    // MARK: - A segment resumed (behavior 7)

    private lazy var held = RecordLogHeldSegment(segmentId: g1, chunks: [
        RecordLogHeldSegmentChunk(object: "\(g1)/Note/0", model: "Note", index: 0, firstId: "n1", lastId: "n2", rows: 2, sha256: "sha-a"),
        RecordLogHeldSegmentChunk(object: "\(g1)/Note/1", model: "Note", index: 1, firstId: "n3", lastId: "n4", rows: 2, sha256: "sha-b"),
    ])

    private func holdingG1(_ provider: SQLiteStorageProvider) throws -> (store: RecordLogStore, writer: String) {
        let (first, writer) = try store(provider)
        let attempt = try first.beginReceipt(writer: writer, kind: .segment, id: g1).attempt
        let generation = try XCTUnwrap(try first.beginFencedCatchUp(writer: writer, full: true, attempt: attempt))
        _ = try first.applySegmentChunk(writer: writer, generation: generation, attempt: attempt, rows: ["n1", "n2", "n3", "n4"].map { note($0) })
        _ = try first.completeCatchUp(writer: writer, lsn: 10, full: true, generation: generation, receipt: attempt, segment: held)
        return (first, writer)
    }

    func testAResumedSegmentContinuesUnderItsGenerationKeepsAHeldChunkAndRecordsTheMarker() async throws {
        let path = newDatabasePath()
        let provider = try await makeProvider(path: path)
        let (first, writer) = try holdingG1(provider)
        let attempt = try first.beginReceipt(writer: writer, kind: .segment, id: g2, fingerprint: f, chunks: 2).attempt
        let generation = try XCTUnwrap(try first.beginFencedCatchUp(writer: writer, full: true, attempt: attempt))
        XCTAssertEqual(try first.applySegmentChunk(writer: writer, generation: generation, attempt: attempt, rows: [note("n5"), note("n6")]).applied, 2)
        XCTAssertEqual(try first.marks().receipt, RecordLogReceipt(kind: .segment, id: g2, done: 1, completed: false))
        await provider.close()

        let reopened = try await makeProvider(path: path)
        let (again, againWriter) = try store(reopened, clientId: "client-b")
        let resumed = try again.beginReceipt(writer: againWriter, kind: .segment, id: g2, fingerprint: f, chunks: 2)
        XCTAssertEqual(resumed, RecordLogReceiptStart(cursor: 10, attempt: resumed.attempt, done: 1, generation: generation, held: held))
        XCTAssertEqual(try again.marks().replacement, generation)
        let kept = try again.keepSegmentChunk(
            writer: againWriter, generation: generation, attempt: resumed.attempt, segmentId: g2, object: "\(g1)/Note/0", sha256: "sha-a",
            model: "Note", firstId: "n1", lastId: "n2", rows: 2
        )
        XCTAssertEqual(kept.applied, 2)
        _ = try again.applySegmentCorrections(writer: againWriter, generation: generation, attempt: resumed.attempt, lines: [])
        XCTAssertEqual(try again.marks().receipt, RecordLogReceipt(kind: .segment, id: g2, done: 2, completed: true))
        let marker = RecordLogHeldSegment(segmentId: g2, chunks: [
            RecordLogHeldSegmentChunk(object: "\(g2)/Note/0", model: "Note", index: 0, firstId: "n5", lastId: "n6", rows: 2, sha256: "sha-c"),
            held.chunks[0],
        ])
        let done = try again.completeCatchUp(
            writer: againWriter, lsn: 20, full: true, generation: generation, receipt: resumed.attempt, segment: marker
        )
        XCTAssertFalse(done.stale)
        XCTAssertEqual(try rowIds(reopened), ["n1", "n2", "n5", "n6"])
        let marks = try again.marks()
        XCTAssertEqual(marks.cursor, 20)
        XCTAssertNil(marks.receipt)
        XCTAssertFalse(marks.replacing)
        XCTAssertEqual(marks.segment, marker)
        await reopened.close()
    }

    func testASegmentWhoseGenerationAnotherReplacementSupersededStartsFresh() async throws {
        let provider = try await makeProvider(path: newDatabasePath())
        let (first, writer) = try holdingG1(provider)
        let attempt = try first.beginReceipt(writer: writer, kind: .segment, id: g2, fingerprint: f, chunks: 2).attempt
        let generation = try XCTUnwrap(try first.beginFencedCatchUp(writer: writer, full: true, attempt: attempt))
        _ = try first.applySegmentChunk(writer: writer, generation: generation, attempt: attempt, rows: [note("n5")])
        let (other, otherWriter) = try store(provider, clientId: "client-b")
        _ = try other.beginFencedCatchUp(writer: otherWriter, full: true)
        let again = try other.beginReceipt(writer: otherWriter, kind: .segment, id: g2, fingerprint: f, chunks: 2)
        XCTAssertEqual(again, RecordLogReceiptStart(cursor: 10, attempt: again.attempt))
        await provider.close()
    }

    // MARK: - A segment that must not continue (behavior 7, findings 5267-C2-01 and 5267-C2-02)

    /// Complete g2 as the fresh attempt `attempt` (rows n5, n6) and answer its generation.
    @discardableResult
    private func completeFresh(_ store: RecordLogStore, _ writer: String, _ attempt: String) throws -> Int {
        let generation = try XCTUnwrap(try store.beginFencedCatchUp(writer: writer, full: true, attempt: attempt))
        _ = try store.applySegmentChunk(writer: writer, generation: generation, attempt: attempt, rows: [note("n5")])
        _ = try store.applySegmentChunk(writer: writer, generation: generation, attempt: attempt, rows: [note("n6")])
        _ = try store.applySegmentCorrections(writer: writer, generation: generation, attempt: attempt, lines: [])
        XCTAssertFalse(try store.completeCatchUp(writer: writer, lsn: 20, full: true, generation: generation, receipt: attempt).stale)
        return generation
    }

    func testASegmentStoppedBeforeItsOwnReplacementBeganStartsFresh() async throws {
        let path = newDatabasePath()
        let provider = try await makeProvider(path: path)
        let (first, writer) = try holdingG1(provider)
        // An earlier segment's replacement began and put a row the room no longer has, then stopped.
        let older = try first.beginReceipt(writer: writer, kind: .segment, id: g1, fingerprint: f2, chunks: 1).attempt
        let g0 = try XCTUnwrap(try first.beginFencedCatchUp(writer: writer, full: true, attempt: older))
        _ = try first.applySegmentChunk(writer: writer, generation: g0, attempt: older, rows: [note("gone")])
        // g2's receipt begins; the device stops before its replacement does.
        _ = try first.beginReceipt(writer: writer, kind: .segment, id: g2, fingerprint: f, chunks: 2)
        await provider.close()

        let reopened = try await makeProvider(path: path)
        let (again, againWriter) = try store(reopened, clientId: "client-b")
        let start = try again.beginReceipt(writer: againWriter, kind: .segment, id: g2, fingerprint: f, chunks: 2)
        XCTAssertEqual(start, RecordLogReceiptStart(cursor: 10, attempt: start.attempt))
        XCTAssertNotEqual(try completeFresh(again, againWriter, start.attempt), g0)
        XCTAssertEqual(try rowIds(reopened), ["n5", "n6"])
        XCTAssertNil(try again.marks().receipt)
        await reopened.close()
    }

    func testASegmentBesideAReceiptThatChangedARowSinceItsReplacementBeganStartsFresh() async throws {
        let path = newDatabasePath()
        let provider = try await makeProvider(path: path)
        let (first, writer) = try holdingG1(provider)
        let segment = try first.beginReceipt(writer: writer, kind: .segment, id: g2, fingerprint: f, chunks: 2).attempt
        let generation = try XCTUnwrap(try first.beginFencedCatchUp(writer: writer, full: true, attempt: segment))
        _ = try first.applySegmentChunk(writer: writer, generation: generation, attempt: segment, rows: [note("n5")])
        // A load is received next; its first chunk carries a create the room refused, then it stops too.
        let loading = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 2).attempt
        try load(first, writer, loading, [line("refused")])
        await provider.close()

        let reopened = try await makeProvider(path: path)
        let (again, againWriter) = try store(reopened, clientId: "client-b")
        let start = try again.beginReceipt(writer: againWriter, kind: .segment, id: g2, fingerprint: f, chunks: 2)
        XCTAssertEqual(start, RecordLogReceiptStart(cursor: 10, attempt: start.attempt))
        try completeFresh(again, againWriter, start.attempt)
        XCTAssertEqual(try rowIds(reopened), ["n5", "n6"])
        XCTAssertNil(try again.marks().receipt)
        await reopened.close()
    }

    // 5267-C2-04: the writer that changed a row under the segment's generation
    // completed before the reopen, leaving no attempt behind.
    func testASegmentWhoseGenerationALoadThatCompletedWroteIntoStartsFresh() async throws {
        let path = newDatabasePath()
        let provider = try await makeProvider(path: path)
        let (first, writer) = try holdingG1(provider)
        let segment = try first.beginReceipt(writer: writer, kind: .segment, id: g2, fingerprint: f, chunks: 2).attempt
        let generation = try XCTUnwrap(try first.beginFencedCatchUp(writer: writer, full: true, attempt: segment))
        _ = try first.applySegmentChunk(writer: writer, generation: generation, attempt: segment, rows: [note("n5")])
        // A load writes a row the room deletes before the segment's snapshot, and completes.
        let loading = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 1).attempt
        try load(first, writer, loading, [line("deleted")])
        _ = try first.completeLoad(writer: writer, sessionId: s, attempt: loading, mode: .merge, models: ["Note"])
        _ = try first.completeCatchUp(writer: writer, lsn: 15, receipt: loading)
        XCTAssertEqual(try first.marks().receipt?.id, g2)
        await provider.close()

        let reopened = try await makeProvider(path: path)
        let (again, againWriter) = try store(reopened, clientId: "client-b")
        let start = try again.beginReceipt(writer: againWriter, kind: .segment, id: g2, fingerprint: f, chunks: 2)
        XCTAssertEqual(start, RecordLogReceiptStart(cursor: 15, attempt: start.attempt))
        try completeFresh(again, againWriter, start.attempt)
        XCTAssertEqual(try rowIds(reopened), ["n5", "n6"])
        XCTAssertNil(try again.marks().receipt)
        await reopened.close()
    }

    func testASegmentWhoseGenerationAnotherWritersPageWroteIntoStartsFresh() async throws {
        let provider = try await makeProvider(path: newDatabasePath())
        let (first, writer) = try holdingG1(provider)
        let segment = try first.beginReceipt(writer: writer, kind: .segment, id: g2, fingerprint: f, chunks: 2).attempt
        let generation = try XCTUnwrap(try first.beginFencedCatchUp(writer: writer, full: true, attempt: segment))
        _ = try first.applySegmentChunk(writer: writer, generation: generation, attempt: segment, rows: [note("n5")])
        let (other, otherWriter) = try store(provider, clientId: "client-b")
        _ = try other.applyCatchUpPage(writer: otherWriter, rows: [note("deleted")], lsn: 15)
        _ = try other.completeCatchUp(writer: otherWriter, lsn: 15)

        let (again, againWriter) = try store(provider, clientId: "client-c")
        let start = try again.beginReceipt(writer: againWriter, kind: .segment, id: g2, fingerprint: f, chunks: 2)
        XCTAssertEqual(start, RecordLogReceiptStart(cursor: 15, attempt: start.attempt))
        try completeFresh(again, againWriter, start.attempt)
        XCTAssertEqual(try rowIds(provider), ["n5", "n6"])
        await provider.close()
    }

    func testASegmentStillContinuesAfterItsOwnReplacementsPages() async throws {
        let provider = try await makeProvider(path: newDatabasePath())
        let (first, writer) = try holdingG1(provider)
        let segment = try first.beginReceipt(writer: writer, kind: .segment, id: g2, fingerprint: f, chunks: 1).attempt
        let generation = try XCTUnwrap(try first.beginFencedCatchUp(writer: writer, full: true, attempt: segment))
        _ = try first.applySegmentChunk(writer: writer, generation: generation, attempt: segment, rows: [note("n5")])
        _ = try first.applySegmentCorrections(writer: writer, generation: generation, attempt: segment, lines: [])
        _ = try first.applyCatchUpPage(writer: writer, rows: [note("p1")], lsn: 20, generation: generation, receipt: segment)

        let (again, againWriter) = try store(provider, clientId: "client-b")
        let start = try again.beginReceipt(writer: againWriter, kind: .segment, id: g2, fingerprint: f, chunks: 1)
        XCTAssertEqual(start.done, 1)
        XCTAssertTrue(start.completed)
        XCTAssertEqual(start.generation, generation)
        XCTAssertFalse(try again.completeCatchUp(writer: againWriter, lsn: 20, full: true, generation: generation, receipt: start.attempt).stale)
        XCTAssertEqual(try rowIds(provider), ["n5", "p1"])
        await provider.close()
    }

    // MARK: - A load around another writer's replacement (behavior 7b)

    func testALoadAroundAnotherWritersReplacementStartsFreshAndCompletesWithEveryRow() async throws {
        for completed in [false, true] {
            let provider = try await makeProvider(path: newDatabasePath())
            let (first, writer) = try store(provider)
            let attempt = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 3).attempt
            try load(first, writer, attempt, [line("L1")])
            let (other, otherWriter) = try store(provider, clientId: "client-b")
            let generation = try XCTUnwrap(try other.beginFencedCatchUp(writer: otherWriter, full: true))
            try load(first, writer, attempt, [line("L2")])
            func replace() throws {
                _ = try other.applyCatchUpPage(writer: otherWriter, rows: [note("x")], generation: generation)
                _ = try other.completeCatchUp(writer: otherWriter, lsn: 5, full: true, generation: generation)
            }
            if completed {
                try replace()
                XCTAssertEqual(try rowIds(provider), ["L2", "x"])
                XCTAssertEqual(try first.marks().receipt?.done, 2)
            }
            let (reopened, reopenedWriter) = try store(provider, clientId: "client-c")
            let fresh = try reopened.beginReceipt(writer: reopenedWriter, kind: .load, id: s, fingerprint: f, chunks: 3)
            XCTAssertEqual(fresh.done, 0, "completed: \(completed)")
            XCTAssertFalse(fresh.completed)
            if !completed {
                try replace()
                XCTAssertFalse(try rowIds(provider).contains("L1"))
            }
            for id in ["L1", "L2", "L3"] { XCTAssertFalse(try load(reopened, reopenedWriter, fresh.attempt, [line(id)]).stale) }
            _ = try reopened.completeLoad(writer: reopenedWriter, sessionId: s, attempt: fresh.attempt, mode: .merge, models: ["Note"])
            _ = try reopened.completeCatchUp(writer: reopenedWriter, lsn: 6, receipt: fresh.attempt)
            XCTAssertEqual(try rowIds(provider), ["L1", "L2", "L3", "x"], "completed: \(completed)")
            await provider.close()
        }
    }

    // MARK: - The replaced attempt (behavior 8)

    func testEveryLoadCommandOfTheReplacedIdIsStaleAndChangesNothing() async throws {
        let provider = try await makeProvider(path: newDatabasePath())
        let (first, writer) = try store(provider)
        let old = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 2).attempt
        try load(first, writer, old, [line("n1")])
        let (adopter, adopterWriter) = try store(provider, clientId: "client-b")
        let attempt = try adopter.beginReceipt(writer: adopterWriter, kind: .load, id: s, fingerprint: f, chunks: 2).attempt
        try load(adopter, adopterWriter, attempt, [line("n2")])
        _ = try adopter.applyCatchUpPage(writer: adopterWriter, rows: [note("n1", "newer")], lsn: 4, receipt: attempt)
        let rows = try rowsText(provider)
        let state = try receiptText(provider)
        XCTAssertTrue(try load(first, writer, old, [line("n3")]).stale)
        XCTAssertTrue(try first.completeLoad(writer: writer, sessionId: s, attempt: old, mode: .refresh, models: ["Note"]).stale)
        XCTAssertTrue(try first.applyCatchUpPage(writer: writer, rows: [note("n1", "older")], lsn: 4, receipt: old).stale)
        XCTAssertTrue(try first.completeCatchUp(writer: writer, lsn: 4, receipt: old).stale)
        XCTAssertEqual(try rowsText(provider), rows)
        XCTAssertEqual(try receiptText(provider), state)
        XCTAssertEqual(try first.marks().cursor, 0)
        XCTAssertEqual(try first.read(model: "Note", id: "n1"), ["id": "n1", "title": "newer"])
        await provider.close()
    }

    func testEverySegmentCommandOfTheReplacedIdIsStaleAndChangesNothing() async throws {
        let provider = try await makeProvider(path: newDatabasePath())
        let (first, writer) = try holdingG1(provider)
        let old = try first.beginReceipt(writer: writer, kind: .segment, id: g2, fingerprint: f, chunks: 2).attempt
        let generation = try XCTUnwrap(try first.beginFencedCatchUp(writer: writer, full: true, attempt: old))
        _ = try first.applySegmentChunk(writer: writer, generation: generation, attempt: old, rows: [note("n5")])
        let (adopter, adopterWriter) = try store(provider, clientId: "client-b")
        XCTAssertEqual(try adopter.beginReceipt(writer: adopterWriter, kind: .segment, id: g2, fingerprint: f, chunks: 2).done, 1)
        let rows = try rowsText(provider)
        let state = try receiptText(provider)
        XCTAssertTrue(try first.applySegmentChunk(writer: writer, generation: generation, attempt: old, rows: [note("n6")]).stale)
        XCTAssertTrue(try first.keepSegmentChunk(
            writer: writer, generation: generation, attempt: old, segmentId: g2, object: "\(g1)/Note/0", sha256: "sha-a",
            model: "Note", firstId: "n1", lastId: "n2", rows: 2
        ).stale)
        XCTAssertTrue(try first.applySegmentCorrections(
            writer: writer, generation: generation, attempt: old, lines: [RecordLogCorrection(model: "Note", id: "n5", row: nil)]
        ).stale)
        XCTAssertTrue(try first.applyCatchUpPage(writer: writer, rows: [note("n7")], lsn: 12, generation: generation, receipt: old).stale)
        XCTAssertTrue(try first.completeCatchUp(
            writer: writer, lsn: 20, full: true, generation: generation, receipt: old, segment: held
        ).stale)
        XCTAssertEqual(try rowsText(provider), rows)
        XCTAssertEqual(try receiptText(provider), state)
        let marks = try first.marks()
        XCTAssertEqual(marks.cursor, 10)
        XCTAssertTrue(marks.replacing)
        XCTAssertEqual(marks.replacement, generation)
        XCTAssertEqual(marks.segment, held)
        await provider.close()
    }

    // MARK: - What an earlier build wrote (behavior 20, pin)

    func testABareMarkerAndAnAttemptWithoutProgressStillReadAndAreNeverResumed() async throws {
        let provider = try await makeProvider(path: newDatabasePath())
        let (first, writer) = try store(provider)
        func write(_ json: String) throws {
            try provider.withConnection {
                try $0.execute("UPDATE record_log_state SET receipt = ? WHERE doc_id = ?", [.text(json), .text("doc-1")])
            }
        }
        try write("{\"kind\":\"load\",\"id\":\"\(s)\"}")
        XCTAssertEqual(try first.marks().receipt, RecordLogReceipt(kind: .load, id: s))
        XCTAssertEqual(try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 1).done, 0)
        try write("{\"n\":3,\"since\":null,\"attempts\":[{\"kind\":\"load\",\"id\":\"\(s)\",\"attempt\":\"3.older\",\"last\":3}]}")
        XCTAssertEqual(try first.marks().receipt, RecordLogReceipt(kind: .load, id: s))
        XCTAssertFalse(try load(first, writer, "3.older", [line("n1")]).stale)
        let fresh = try first.beginReceipt(writer: writer, kind: .load, id: s, fingerprint: f, chunks: 1)
        XCTAssertEqual(fresh.done, 0)
        XCTAssertNotEqual(fresh.attempt, "3.older")
        _ = try first.completeCatchUp(writer: writer, lsn: 2, receipt: fresh.attempt)
        XCTAssertNil(try first.marks().receipt)
        await provider.close()
    }
}
