import XCTest
@testable import JsBaoClient

/// The rules a client runs over a bulk load and a segment, over memory tables:
/// the Swift twin of js-bao's `record-log-client-rules-load-4311.test.ts`.
///
/// - `applyLoadLines` merges each line over the row by key: `_deleted: true`
///   removes it (an absent record is a no-op), `null` stays a present null, the
///   line's own `id` field is ignored, nested values are opaque and a string
///   set's array replaces its members.
/// - `completeLoad` of a refresh removes every confirmed row of the covered
///   models no line of the receipt attempt named; a merge removes nothing. Two
///   attempts of one refresh keep their named keys apart.
/// - A receipt's marker is set by `beginReceipt` and ended only by its own
///   completion, or by a full replacement begun after its last change; an
///   attempt so ended refuses a later chunk, and its load keys are forgotten.
/// - A segment is a replacement: its rows and corrections are applied under the
///   generation `beginFencedCatchUp(full: true)` handed out; a later
///   replacement makes the earlier generation stale.
final class RecordLogReceiptRulesHermeticTests: XCTestCase {

    private let writer = "01JW4312RV1ESWR1TER0000001"

    private func key(_ id: String, _ model: String = "Note") -> RecordLogRecordKey {
        RecordLogRecordKey(model: model, id: id)
    }

    private func client(
        _ rows: [(String, RecordLogRow, String)] = [], cursor: Int = 0
    ) -> (tables: RecordLogMemoryTables, rules: RecordLogRules) {
        let tables = RecordLogMemoryTables(
            rows: rows.map { id, row, model in
                var row = row
                row["id"] = .string(id)
                return (key(id, model), row)
            },
            cursor: cursor,
            writers: [writer]
        )
        return (tables, RecordLogRules(tables: tables, writer: writer))
    }

    private func load(_ rules: RecordLogRules, _ id: String = "S1") throws -> String {
        try rules.beginReceipt(RecordLogReceipt(kind: .load, id: id))
    }

    private func line(_ id: String, _ patch: RecordLogRow) -> RecordLogLoadLine {
        RecordLogLoadLine(id: id, patch: patch)
    }

    private func confirmed(_ tables: RecordLogMemoryTables) -> [String: RecordLogRow] {
        var out: [String: RecordLogRow] = [:]
        for (key, row) in tables.rows.orderedRows { out[key.id] = row }
        return out
    }

    // MARK: - applyLoadLines (behavior 3)

    func testALoadLineMergesOverItsRowKeepingAPresentNullAndIgnoringItsIdField() throws {
        let (tables, rules) = client([("n1", ["title": "a", "body": "b", "n": 1], "Note")])
        let nested: JSONValue = .object(["deep": .object(["list": .array([1, .object(["z": 2])])])])
        let touched = try rules.applyLoadLines(attempt: try load(rules), model: "Note", lines: [
            line("n1", ["id": "other", "title": "x", "n": .null, "meta": nested]),
            line("n2", ["title": "new"]),
        ])
        XCTAssertEqual(touched, [key("n1"), key("n2")])
        XCTAssertEqual(confirmed(tables), [
            "n1": ["id": "n1", "title": "x", "body": "b", "n": .null, "meta": nested],
            "n2": ["id": "n2", "title": "new"],
        ])
    }

    func testALoadLineDeletesOnDeletedTrueAndChangesNothingForAnAbsentRecord() throws {
        let (tables, rules) = client([("n1", ["title": "a"], "Note")])
        let touched = try rules.applyLoadLines(attempt: try load(rules), model: "Note", lines: [
            line("n1", ["_deleted": true]),
            line("gone", ["_deleted": true]),
        ])
        XCTAssertEqual(confirmed(tables), [:])
        XCTAssertEqual(touched, [key("n1")])
    }

    func testALoadLineReplacesAStringSetsMembersWithItsArray() throws {
        let (tables, rules) = client([("n1", ["tags": ["a", "b"]], "Note")])
        _ = try rules.applyLoadLines(attempt: try load(rules), model: "Note", lines: [line("n1", ["tags": ["c"]])])
        XCTAssertEqual(confirmed(tables)["n1"], ["id": "n1", "tags": ["c"]])
    }

    func testAPendingGuessStaysOnTopOfTheLoadedRow() throws {
        let (tables, rules) = client([("n1", ["title": "a", "n": 1], "Note")])
        _ = try rules.write(RecordLogMutation(json: .object([
            "model": "Note", "id": "n1", "kind": "patch", "fields": .object(["title": "mine"]),
        ]))!)
        _ = try rules.applyLoadLines(attempt: try load(rules), model: "Note", lines: [line("n1", ["title": "loaded", "n": 2])])
        XCTAssertEqual(try tables.view().row(key("n1")), ["id": "n1", "title": "mine", "n": 2])
    }

    func testTheKeysAChunkNamesAreNotedUnderItsAttempt() throws {
        let (tables, rules) = client()
        let attempt = try load(rules)
        _ = try rules.applyLoadLines(attempt: attempt, model: "Note", lines: [line("n1", ["t": 1])])
        XCTAssertEqual(tables.loadKeyAttempts, [attempt])
    }

    // MARK: - completeLoad (behavior 3)

    func testARefreshRemovesItsCoveredRowsNoLineNamedAndKeepsOtherModels() throws {
        let (tables, rules) = client([
            ("n1", ["title": "a"], "Note"), ("n2", ["title": "b"], "Note"), ("t1", ["title": "t"], "Task"),
        ])
        let attempt = try load(rules)
        _ = try rules.applyLoadLines(attempt: attempt, model: "Note", lines: [line("n1", ["title": "kept"])])
        XCTAssertEqual(try rules.completeLoad(attempt: attempt, mode: .refresh, models: ["Note"]), [key("n2")])
        XCTAssertEqual(confirmed(tables).keys.sorted(), ["n1", "t1"])
        // A record another writer created during the load comes back with the remainder.
        _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [
            RecordLogCatchUpRow(model: "Note", id: "n9", row: ["id": "n9", "title": "during"]),
        ]))
        XCTAssertEqual(confirmed(tables)["n9"], ["id": "n9", "title": "during"])
    }

    func testAMergeRemovesNothingAndTheAttemptsKeysAreForgottenEitherWay() throws {
        let (tables, rules) = client([("n1", ["title": "a"], "Note"), ("n2", ["title": "b"], "Note")])
        let attempt = try load(rules)
        _ = try rules.applyLoadLines(attempt: attempt, model: "Note", lines: [line("n1", ["title": "x"])])
        XCTAssertEqual(try rules.completeLoad(attempt: attempt, mode: .merge, models: ["Note"]), [])
        XCTAssertEqual(confirmed(tables).keys.sorted(), ["n1", "n2"])
        // The keys were forgotten: a refresh completed again names none of them.
        XCTAssertEqual(
            try rules.completeLoad(attempt: attempt, mode: .refresh, models: ["Note"]).map(\.id).sorted(), ["n1", "n2"]
        )
        XCTAssertEqual(tables.loadKeyAttempts, [])
    }

    func testTwoAttemptsOfOneRefreshKeepTheirKeysApart() throws {
        let (tables, rules) = client([("old", ["title": "before"], "Note")], cursor: 1)
        let a = try load(rules)
        let b = try load(rules)
        for attempt in [a, b] {
            _ = try rules.applyLoadLines(attempt: attempt, model: "Note", lines: [line("n1", ["title": "loaded"])])
        }
        XCTAssertEqual(try rules.completeLoad(attempt: a, mode: .refresh, models: ["Note"]), [key("old")])
        // B completes after A forgot its own keys: B's are still B's.
        XCTAssertEqual(try rules.completeLoad(attempt: b, mode: .refresh, models: ["Note"]), [])
        XCTAssertEqual(confirmed(tables), ["n1": ["id": "n1", "title": "loaded"]])
        for attempt in [a, b] { _ = try rules.completeCatchUp(lsn: 4, high: nil, full: false, receipt: attempt) }
        XCTAssertNil(try rules.incompleteReceipt())
        XCTAssertEqual(tables.loadKeyAttempts, [])
    }

    func testResultsHeldDuringALoadReplayPastTheRemainderAndThoseBelowItAreDropped() throws {
        let (tables, rules) = client([("n1", ["title": "a"], "Note")], cursor: 5)
        let attempt = try load(rules)
        // The load took 6..10; results 11 and 12 arrive while the chunks apply.
        _ = try rules.receive(RecordLogResultItem(json: .object([
            "l": 11, "e": 9, "changes": .array([.object(["model": "Note", "id": "n1", "set": .object(["title": "eleven"])])]),
        ]))!)
        _ = try rules.receive(RecordLogResultItem(json: .object([
            "l": 12, "e": 9,
            "changes": .array([.object(["model": "Note", "id": "n2", "row": .object(["id": "n2", "title": "twelve"])])]),
        ]))!)
        XCTAssertEqual(tables.cursor(), 5)
        _ = try rules.applyLoadLines(attempt: attempt, model: "Note", lines: [line("n1", ["title": "loaded"])])
        // The remainder was read at 11 and carries n1 as of then.
        _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [
            RecordLogCatchUpRow(model: "Note", id: "n1", row: ["id": "n1", "title": "eleven"]),
        ]))
        _ = try rules.completeCatchUp(lsn: 11, high: 9, full: false, receipt: attempt)
        XCTAssertEqual(tables.cursor(), 12)
        XCTAssertEqual(confirmed(tables), ["n1": ["id": "n1", "title": "eleven"], "n2": ["id": "n2", "title": "twelve"]])
        XCTAssertNil(try rules.incompleteReceipt())
    }

    // MARK: - The receipt marker (behavior 4)

    func testTheMarkerStaysAcrossARowsCompletionAndClearsOnAReceiptsOrAFullReplacements() throws {
        let (_, rules) = client()
        XCTAssertNil(try rules.incompleteReceipt())
        let a = try load(rules)
        XCTAssertEqual(try rules.incompleteReceipt(), RecordLogReceipt(kind: .load, id: "S1"))
        try rules.beginCatchUp(full: false)
        _ = try rules.completeCatchUp(lsn: 3, high: nil, full: false)
        XCTAssertEqual(try rules.incompleteReceipt(), RecordLogReceipt(kind: .load, id: "S1"))
        _ = try rules.completeCatchUp(lsn: 4, high: nil, full: false, receipt: a)
        XCTAssertNil(try rules.incompleteReceipt())
        let g1 = try rules.beginReceipt(RecordLogReceipt(kind: .segment, id: "G1"))
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.completeCatchUp(lsn: 5, high: nil, full: true, generation: generation, receipt: g1)
        XCTAssertNil(try rules.incompleteReceipt())
    }

    func testAFullReplacementBegunAfterAnAttemptsLastChangeEndsItAndItsLaterChunksAreRefused() throws {
        let (tables, rules) = client(cursor: 1)
        let old = try load(rules)
        _ = try rules.applyLoadLines(attempt: old, model: "Note", lines: [line("refused", ["t": 1])])
        // The recovery: a full replacement walks the room's table, which has no "refused".
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.applyCatchUpPage(
            RecordLogCatchUpInput(rows: [RecordLogCatchUpRow(model: "Note", id: "kept", row: ["id": "kept"])]),
            generation: generation
        )
        _ = try rules.completeCatchUp(lsn: 5, high: nil, full: true, generation: generation)
        XCTAssertNil(try rules.incompleteReceipt())
        XCTAssertFalse(try rules.receiptInProgress(old))
        // The old attempt's chunk arrives late: refused before anything changes.
        XCTAssertThrowsError(try rules.applyLoadLines(attempt: old, model: "Note", lines: [line("refused", ["t": 1])])) {
            XCTAssertEqual($0 as? RecordLogStaleReceiptError, RecordLogStaleReceiptError(attempt: old))
        }
        XCTAssertThrowsError(try rules.completeLoad(attempt: old, mode: .refresh, models: ["Note"])) {
            XCTAssertTrue($0 is RecordLogStaleReceiptError)
        }
        XCTAssertEqual(confirmed(tables), ["kept": ["id": "kept"]])
    }

    func testAnAttemptThatChangedRowsAfterTheReplacementBeganStaysUntilItsOwnCompletion() throws {
        let (_, rules) = client(cursor: 1)
        let other = try load(rules)
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.applyLoadLines(attempt: other, model: "Note", lines: [line("late", ["t": 1])])
        _ = try rules.completeCatchUp(lsn: 5, high: nil, full: true, generation: generation)
        XCTAssertEqual(try rules.incompleteReceipt(), RecordLogReceipt(kind: .load, id: "S1"))
        XCTAssertTrue(try rules.receiptInProgress(other))
        _ = try rules.completeCatchUp(lsn: 6, high: nil, full: false, receipt: other)
        XCTAssertNil(try rules.incompleteReceipt())
    }

    func testARetrysCompletionEndsAnEarlierAttemptOfTheSameLoadAndKeepsAnotherLoads() throws {
        let (_, rules) = client(cursor: 1)
        let failed = try load(rules)
        _ = try rules.applyLoadLines(attempt: failed, model: "Note", lines: [line("n1", ["t": 1])])
        let other = try load(rules, "S2")
        _ = try rules.applyLoadLines(attempt: other, model: "Note", lines: [line("m1", ["t": 1])])
        let retry = try load(rules)
        _ = try rules.applyLoadLines(attempt: retry, model: "Note", lines: [line("n1", ["t": 1])])
        _ = try rules.completeLoad(attempt: retry, mode: .merge, models: ["Note"])
        _ = try rules.completeCatchUp(lsn: 4, high: nil, full: false, receipt: retry)
        XCTAssertFalse(try rules.receiptInProgress(failed))
        XCTAssertTrue(try rules.receiptInProgress(other))
        XCTAssertEqual(try rules.incompleteReceipt(), RecordLogReceipt(kind: .load, id: "S2"))
    }

    func testTheLoadKeysOfAnAttemptAFullReplacementEndedAreForgotten() throws {
        let (tables, rules) = client(cursor: 1)
        let failed = try load(rules)
        _ = try rules.applyLoadLines(attempt: failed, model: "Note", lines: [line("n1", ["t": 1])])
        XCTAssertEqual(tables.loadKeyAttempts, [failed])
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.completeCatchUp(lsn: 5, high: nil, full: true, generation: generation)
        XCTAssertEqual(tables.loadKeyAttempts, [])
    }

    // MARK: - The generation fence (behavior 5)

    func testASegmentUnderItsGenerationReplacesTheTableWithItsRowsAndCorrections() throws {
        let (tables, rules) = client([
            ("n1", ["title": "old"], "Note"), ("x1", ["title": "only here"], "Note"), ("t1", ["title": "task"], "Task"),
        ])
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.applySegmentRows(generation: generation, attempt: nil, rows: [
            RecordLogCatchUpRow(model: "Note", id: "n1", row: ["id": "n1", "title": "at B"]),
            RecordLogCatchUpRow(model: "Note", id: "n2", row: ["id": "n2", "title": "at B"]),
            RecordLogCatchUpRow(model: "Note", id: "n3", row: ["id": "n3", "title": "at B"]),
        ])
        _ = try rules.applySegmentCorrections(generation: generation, attempt: nil, lines: [
            RecordLogCorrection(model: "Note", id: "n2", row: ["id": "n2", "title": "after B"]),
            RecordLogCorrection(model: "Note", id: "n3", row: nil),
            RecordLogCorrection(model: "Note", id: "never", row: nil),
            RecordLogCorrection(model: "Task", id: "n2", row: ["id": "n2", "title": "a task named n2"]),
        ])
        let out = try rules.completeCatchUp(lsn: 20, high: 4, full: true, generation: generation)
        XCTAssertEqual(out.touched.map(\.description).sorted(), ["Note/x1", "Task/t1"])
        XCTAssertEqual(tables.rows.orderedRows.map(\.row), [
            ["id": "n1", "title": "at B"], ["id": "n2", "title": "after B"], ["id": "n2", "title": "a task named n2"],
        ])
        XCTAssertEqual(tables.cursor(), 20)
    }

    func testEveryCommandUnderAGenerationALaterReplacementReplacedIsRefusedAndChangesNothing() throws {
        let (tables, rules) = client([("n1", ["title": "a"], "Note")])
        let first = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        let second = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        XCTAssertNotEqual(first, second)
        let stale = RecordLogStaleReplacementError(generation: first, current: second)
        XCTAssertThrowsError(try rules.applySegmentRows(generation: first, attempt: nil, rows: [
            RecordLogCatchUpRow(model: "Note", id: "n1", row: ["id": "n1", "title": "stale"]),
        ])) { XCTAssertEqual($0 as? RecordLogStaleReplacementError, stale) }
        XCTAssertThrowsError(try rules.applySegmentCorrections(generation: first, attempt: nil, lines: [
            RecordLogCorrection(model: "Note", id: "n1", row: nil),
        ])) { XCTAssertEqual($0 as? RecordLogStaleReplacementError, stale) }
        XCTAssertThrowsError(try rules.completeCatchUp(lsn: 3, high: nil, full: true, generation: first)) {
            XCTAssertEqual($0 as? RecordLogStaleReplacementError, stale)
        }
        XCTAssertThrowsError(try rules.applyCatchUpPage(RecordLogCatchUpInput(gone: [key("n1")]), generation: first)) {
            XCTAssertEqual($0 as? RecordLogStaleReplacementError, stale)
        }
        XCTAssertEqual(confirmed(tables), ["n1": ["id": "n1", "title": "a"]])
        XCTAssertEqual(tables.cursor(), 0)
        _ = try rules.completeCatchUp(lsn: 3, high: nil, full: true, generation: second)
        XCTAssertNil(tables.replacing())
    }

    func testARowsCatchUpAnswersNoGenerationAndTablesWithoutReceiptsCannotReceive() throws {
        let (_, rules) = client()
        XCTAssertNil(try rules.beginFencedCatchUp(full: false))
        let plain = RecordLogRules(tables: PlainTables(), writer: writer)
        XCTAssertNil(try plain.beginFencedCatchUp(full: true))
        XCTAssertThrowsError(try plain.beginReceipt(RecordLogReceipt(kind: .load, id: "S1")))
    }

    // MARK: - The stored receipt state (edge 014)

    func testTheReceiptStateRoundTripsItsJSONAndAnEarlierBuildsBareMarkerIsOneAttempt() {
        let state = RecordLogReceiptState(n: 3, since: 2, attempts: [
            RecordLogReceiptAttempt(kind: .segment, id: "G1", attempt: "3.abcdefgh", last: 3),
        ])
        XCTAssertEqual(RecordLogReceiptState(json: state.json), state)
        XCTAssertEqual(
            RecordLogReceiptState(json: .object(["kind": "load", "id": "S1"])),
            RecordLogReceiptState(n: 0, since: nil, attempts: [RecordLogReceiptAttempt(kind: .load, id: "S1", attempt: "", last: 0)])
        )
        XCTAssertNil(RecordLogReceiptState(json: .object(["kind": "load"])))
        XCTAssertNil(RecordLogReceiptState(json: .null))
    }

    /// Tables that keep no receipt state: a format-3 store before receipts.
    private final class PlainTables: RecordLogTables {
        private let inner = RecordLogMemoryTables()
        func cursor() -> Int { inner.cursor() }
        func setCursor(_ cursor: Int) { inner.setCursor(cursor) }
        func epochs() -> RecordLogEpochs { inner.epochs() }
        func setEpochs(_ epochs: RecordLogEpochs) { inner.setEpochs(epochs) }
        func constraints() -> [RecordLogConstraint] { inner.constraints() }
        func setConstraints(_ constraints: [RecordLogConstraint]) { inner.setConstraints(constraints) }
        func confirmed() -> RecordLogRowTable { inner.confirmed() }
        func beginReplace() { inner.beginReplace() }
        func completeReplace() -> [RecordLogRecordKey] { inner.completeReplace() }
        func buffered(_ l: Int) -> RecordLogResult? { inner.buffered(l) }
        func buffer(_ item: RecordLogResult) { inner.buffer(item) }
        func dropBufferedThrough(_ l: Int) { inner.dropBufferedThrough(l) }
        func isWriter(_ writer: String) -> Bool { inner.isWriter(writer) }
        func writerState(_ writer: String) -> RecordLogWriterState { inner.writerState(writer) }
        func setWriterState(_ writer: String, _ state: RecordLogWriterState) { inner.setWriterState(writer, state) }
        func pending(_ writer: String) -> [RecordLogPendingEntry] { inner.pending(writer) }
        func putPending(_ writer: String, _ entry: RecordLogPendingEntry) { inner.putPending(writer, entry) }
        func deletePending(_ writer: String, _ seq: Int) { inner.deletePending(writer, seq) }
        func acknowledgedThrough(_ l: Int) -> [RecordLogEntryRef] { inner.acknowledgedThrough(l) }
        func handled(_ writer: String, _ key: RecordLogRecordKey) -> [Int: Int] { inner.handled(writer, key) }
        func setHandled(_ writer: String, _ key: RecordLogRecordKey, from: Int, until: Int) {
            inner.setHandled(writer, key, from: from, until: until)
        }
        func epochCount(_ e: Int) -> Int { inner.epochCount(e) }
        func countEpoch(_ e: Int) { inner.countEpoch(e) }
        func pendingInEpoch(_ e: Int) -> Int { inner.pendingInEpoch(e) }
    }
}
