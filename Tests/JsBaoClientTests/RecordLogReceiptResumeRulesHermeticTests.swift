import XCTest
@testable import JsBaoClient

/// #5267 behaviors 1–4 (Swift rules, over memory tables): the twin of js-bao's
/// `record-log-client-rules-resume-5267.test.ts`.
///
/// 1: `resumeReceipt` adopts the latest attempt of a kind, id and fingerprint
///    under a new id, in its place, with its progress and load keys; it
///    answers `nil` and changes nothing for another id, kind or fingerprint,
///    an attempt without one, a load whose generation moved, a segment
///    whose generation another replacement superseded, a segment whose own
///    replacement never began (5267-C2-01), a segment beside an attempt
///    that changed a row since its replacement began (5267-C2-02), and a
///    segment whose generation anything else wrote into, a receipt since
///    completed, a page or a result (5267-C2-04); its own pages leave it
///    resumable.
/// 2: chunks, kept chunks, `completeLoad` and corrections record progress;
///    `beginReceipt` records the fingerprint, `done: 0` and, for a load, the
///    generation (a segment has none until its replacement begins).
/// 3: a page or completion carrying a displaced attempt is refused before
///    anything changes; one carrying the attempt in progress does not count
///    as its change; a settled attempt's completion behaves as before.
/// 4: `beginFencedCatchUp(full: true, attempt:)` records its generation on
///    the attempt.
final class RecordLogReceiptResumeRulesHermeticTests: XCTestCase {

    private let writer = "01JW5267RESUMEWR1TER000001"
    private let s = "01JS5267RESUMELOAD00000001"
    private let g = "01JG5267RESUMESEGMENT00001"
    private let f = String(repeating: "f", count: 64)

    private func client(cursor: Int = 1) -> (tables: RecordLogMemoryTables, rules: RecordLogRules) {
        let tables = RecordLogMemoryTables(cursor: cursor, writers: [writer])
        return (tables, RecordLogRules(tables: tables, writer: writer))
    }

    private func load(_ id: String? = nil) -> RecordLogReceipt { RecordLogReceipt(kind: .load, id: id ?? s) }
    private func segment(_ id: String? = nil) -> RecordLogReceipt { RecordLogReceipt(kind: .segment, id: id ?? g) }
    private func line(_ id: String) -> RecordLogLoadLine { RecordLogLoadLine(id: id, patch: ["title": .string("l-\(id)")]) }
    private func note(_ id: String, _ title: String? = nil) -> RecordLogCatchUpRow {
        RecordLogCatchUpRow(model: "Note", id: id, row: ["id": .string(id), "title": .string(title ?? "t-\(id)")])
    }
    private func attempts(_ tables: RecordLogMemoryTables) -> [RecordLogReceiptAttempt] { tables.receipts()?.attempts ?? [] }
    private func ids(_ tables: RecordLogMemoryTables) -> [String] { tables.rows.orderedRows.map { $0.0.id }.sorted() }

    private func apply(_ rules: RecordLogRules, _ attempt: String, _ id: String) throws {
        _ = try rules.applyLoadLines(attempt: attempt, model: "Note", lines: [line(id)])
    }

    // MARK: - resumeReceipt (behavior 1)

    func testResumeAdoptsTheLatestMatchingAttemptUnderANewIdInItsPlaceWithItsLoadKeys() throws {
        let (tables, rules) = client()
        let before = try rules.beginReceipt(load("S0"))
        let old = try rules.beginReceipt(load(), fingerprint: f)
        try apply(rules, old, "n1")
        try apply(rules, old, "n2")
        let after = try rules.beginReceipt(segment())
        let n = try XCTUnwrap(tables.receipts()).n

        let resumed = try XCTUnwrap(try rules.resumeReceipt(load(), fingerprint: f))
        XCTAssertEqual(resumed.done, 2)
        XCTAssertFalse(resumed.completed)
        XCTAssertEqual(resumed.generation, 0)
        XCTAssertNotEqual(resumed.attempt, old)
        XCTAssertTrue(resumed.attempt.hasPrefix("\(n + 1)."))
        let state = try XCTUnwrap(tables.receipts())
        XCTAssertEqual(state.n, n + 1)
        XCTAssertEqual(state.attempts.map(\.attempt), [before, resumed.attempt, after])
        XCTAssertEqual(state.attempts[1], RecordLogReceiptAttempt(
            kind: .load, id: s, attempt: resumed.attempt, last: n + 1, fingerprint: f, done: 2, generation: 0, replaced: [old]
        ))
        XCTAssertFalse(try rules.receiptInProgress(old))
        XCTAssertThrowsError(try apply(rules, old, "n3")) { XCTAssertTrue($0 is RecordLogStaleReceiptError) }
        XCTAssertEqual(tables.loadKeyAttempts, [resumed.attempt])
        _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [note("stale")]))
        try apply(rules, resumed.attempt, "n3")
        XCTAssertEqual(
            try rules.completeLoad(attempt: resumed.attempt, mode: .refresh, models: ["Note"]),
            [RecordLogRecordKey(model: "Note", id: "stale")]
        )
        XCTAssertEqual(ids(tables), ["n1", "n2", "n3"])
    }

    func testAnAdoptedAttemptAdoptedAgainListsEveryIdItTookOver() throws {
        let (tables, rules) = client()
        let first = try rules.beginReceipt(load(), fingerprint: f)
        let second = try XCTUnwrap(try rules.resumeReceipt(load(), fingerprint: f)).attempt
        let third = try XCTUnwrap(try rules.resumeReceipt(load(), fingerprint: f)).attempt
        XCTAssertEqual(attempts(tables).map(\.attempt), [third])
        XCTAssertEqual(attempts(tables).first?.replaced, [first, second])
    }

    func testResumeAnswersNilAndChangesNothingWhenNoAttemptMatchesOrItsGenerationMoved() throws {
        let cases: [(String, (RecordLogRules) throws -> Void, RecordLogReceipt, String)] = [
            ("another id", { _ = try $0.beginReceipt(self.load("S-other"), fingerprint: self.f) }, load(), f),
            ("another kind", { _ = try $0.beginReceipt(self.segment(self.s), fingerprint: self.f) }, load(), f),
            ("another fingerprint", { _ = try $0.beginReceipt(self.load(), fingerprint: self.f) }, load(), String(repeating: "0", count: 64)),
            ("no fingerprint", { _ = try $0.beginReceipt(self.load()) }, load(), f),
            ("a load whose generation a replacement moved", { rules in
                let a = try rules.beginReceipt(self.load(), fingerprint: self.f)
                try self.apply(rules, a, "n1")
                _ = try rules.beginFencedCatchUp(full: true)
            }, load(), f),
            ("a load whose generation a completed replacement moved", { rules in
                let a = try rules.beginReceipt(self.load(), fingerprint: self.f)
                try self.apply(rules, a, "n1")
                let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
                try self.apply(rules, a, "n2")
                _ = try rules.completeCatchUp(lsn: 5, high: nil, full: true, generation: generation)
                XCTAssertTrue(try rules.receiptInProgress(a))
            }, load(), f),
            ("a segment whose generation another replacement superseded", { rules in
                let a = try rules.beginReceipt(self.segment(), fingerprint: self.f)
                let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
                _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [self.note("n1")])
                _ = try rules.beginFencedCatchUp(full: true)
            }, segment(), f),
            // 5267-C2-01: stopped between beginReceipt and its replacement, while
            // an older replacement was unfinished: its generation is not this one's.
            ("a segment whose own replacement never began", { rules in
                _ = try rules.beginFencedCatchUp(full: true)
                _ = try rules.beginReceipt(self.segment(), fingerprint: self.f)
            }, segment(), f),
            // 5267-C2-02: another receipt's chunk wrote under the segment's
            // generation; completing the segment would keep its rows uncorrected.
            ("a segment beside an attempt that changed a row since its replacement began", { rules in
                let a = try rules.beginReceipt(self.segment(), fingerprint: self.f)
                let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
                _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [self.note("n1")])
                let l = try rules.beginReceipt(self.load(), fingerprint: self.f)
                try self.apply(rules, l, "refused")
            }, segment(), f),
            // 5267-C2-04: a receipt that wrote under the segment's generation and
            // completed leaves no attempt behind, but its rows would still be kept.
            ("a segment whose generation a receipt that completed since wrote into", { rules in
                let a = try rules.beginReceipt(self.segment(), fingerprint: self.f)
                let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
                _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [self.note("n1")])
                let l = try rules.beginReceipt(self.load(), fingerprint: self.f)
                try self.apply(rules, l, "later-deleted")
                _ = try rules.completeLoad(attempt: l, mode: .merge, models: ["Note"])
                _ = try rules.completeCatchUp(lsn: 5, high: nil, full: false, receipt: l)
                XCTAssertFalse(try rules.receiptInProgress(l))
            }, segment(), f),
            // 5267-C2-04: a remainder page carries no change of its attempt.
            ("a segment whose generation another load's remainder page wrote into", { rules in
                let l = try rules.beginReceipt(self.load(), fingerprint: self.f)
                try self.apply(rules, l, "n0")
                _ = try rules.completeLoad(attempt: l, mode: .merge, models: ["Note"])
                let a = try rules.beginReceipt(self.segment(), fingerprint: self.f)
                let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
                _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [self.note("n1")])
                _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [self.note("w")]), receipt: l)
                _ = try rules.completeCatchUp(lsn: 5, high: nil, full: false, receipt: l)
            }, segment(), f),
            ("a segment whose generation another catch-up's page wrote into", { rules in
                let a = try rules.beginReceipt(self.segment(), fingerprint: self.f)
                let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
                _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [self.note("n1")])
                _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [], gone: [RecordLogRecordKey(model: "Note", id: "n1")]))
                _ = try rules.completeCatchUp(lsn: 5, high: nil, full: false)
            }, segment(), f),
            ("a segment whose generation a result applied into", { rules in
                let a = try rules.beginReceipt(self.segment(), fingerprint: self.f)
                let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
                _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [self.note("n1")])
                _ = try rules.receive(RecordLogResultItem(json: .object([
                    "l": 2, "e": 1, "changes": .array([.object(["model": "Note", "id": "r", "row": .object(["id": "r"])])]),
                ]))!)
            }, segment(), f),
        ]
        for (name, setup, offer, fingerprint) in cases {
            let (tables, rules) = client()
            try setup(rules)
            let state = tables.receipts()
            let keys = tables.loadKeyAttempts
            XCTAssertNil(try rules.resumeReceipt(offer, fingerprint: fingerprint), name)
            XCTAssertEqual(tables.receipts(), state, name)
            XCTAssertEqual(tables.loadKeyAttempts, keys, name)
        }
        let (_, rules) = client()
        XCTAssertNil(try rules.resumeReceipt(load(), fingerprint: f))
    }

    func testResumeAdoptsTheLatestOfSeveralAttemptsWithTheFingerprint() throws {
        let (tables, rules) = client()
        let older = try rules.beginReceipt(load(), fingerprint: f)
        try apply(rules, older, "n1")
        let newer = try rules.beginReceipt(load(), fingerprint: f)
        let resumed = try XCTUnwrap(try rules.resumeReceipt(load(), fingerprint: f))
        XCTAssertEqual(resumed.done, 0)
        XCTAssertEqual(attempts(tables).map(\.attempt), [older, resumed.attempt])
        XCTAssertEqual(attempts(tables)[1].replaced, [newer])
    }

    func testASegmentResumesUnderItsReplacementKeepingSinceAndTheReplacement() throws {
        let (tables, rules) = client()
        let a = try rules.beginReceipt(segment(), fingerprint: f)
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
        _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [note("n1")])
        let since = try XCTUnwrap(tables.receipts()).since
        XCTAssertNotNil(since)
        let resumed = try XCTUnwrap(try rules.resumeReceipt(segment(), fingerprint: f))
        XCTAssertEqual(resumed.done, 1)
        XCTAssertFalse(resumed.completed)
        XCTAssertEqual(resumed.generation, generation)
        XCTAssertEqual(tables.replacing(), generation)
        XCTAssertEqual(tables.receipts()?.since, since)
        _ = try rules.applySegmentRows(generation: generation, attempt: resumed.attempt, rows: [note("n2")])
        _ = try rules.completeCatchUp(lsn: 9, high: nil, full: true, generation: generation, receipt: resumed.attempt)
        XCTAssertEqual(ids(tables), ["n1", "n2"])
        XCTAssertNil(tables.receipts())
    }

    func testASegmentResumesBesideAnAttemptWhoseLastChangeCameBeforeItsReplacement() throws {
        let (tables, rules) = client()
        let l = try rules.beginReceipt(load(), fingerprint: f)
        try apply(rules, l, "n0")
        let a = try rules.beginReceipt(segment(), fingerprint: f)
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
        _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [note("n1")])
        let resumed = try XCTUnwrap(try rules.resumeReceipt(segment(), fingerprint: f))
        XCTAssertEqual(resumed.done, 1)
        XCTAssertEqual(resumed.generation, generation)
        _ = try rules.completeCatchUp(lsn: 9, high: nil, full: true, generation: generation, receipt: resumed.attempt)
        // The load's row was of the old generation; the replacement settled it.
        XCTAssertEqual(ids(tables), ["n1"])
        XCTAssertNil(tables.receipts())
    }

    func testASegmentResumesAfterItsOwnPagesWhichCarryItsGenerationOrItsAttempt() throws {
        // 5267-C2-04: its own replacement's pages leave it resumable.
        let (tables, rules) = client()
        let a = try rules.beginReceipt(segment(), fingerprint: f)
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
        _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [note("n1")])
        _ = try rules.applySegmentCorrections(generation: generation, attempt: a, lines: [])
        _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [note("p1")]), generation: generation)
        let resumed = try XCTUnwrap(try rules.resumeReceipt(segment(), fingerprint: f))
        XCTAssertEqual(resumed.done, 1)
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(resumed.generation, generation)
        _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [note("p2")]), generation: generation, receipt: resumed.attempt)
        let again = try XCTUnwrap(try rules.resumeReceipt(segment(), fingerprint: f))
        XCTAssertEqual(again.done, 1)
        XCTAssertEqual(again.generation, generation)
        XCTAssertEqual(ids(tables), ["n1", "p1", "p2"])
    }

    func testALoadBegunDuringAnotherReplacementResumesOnceThatCompleted() throws {
        let (tables, rules) = client()
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        let a = try rules.beginReceipt(load(), fingerprint: f)
        XCTAssertEqual(attempts(tables).first?.generation, generation)
        try apply(rules, a, "n1")
        _ = try rules.completeCatchUp(lsn: 5, high: nil, full: true, generation: generation)
        XCTAssertEqual(ids(tables), ["n1"])
        let resumed = try XCTUnwrap(try rules.resumeReceipt(load(), fingerprint: f))
        XCTAssertEqual(resumed.done, 1)
        XCTAssertEqual(resumed.generation, generation)
    }

    func testAReplacementBegunAfterAnAdoptionRefusesTheNextResume() throws {
        let (_, rules) = client()
        let a = try rules.beginReceipt(load(), fingerprint: f)
        try apply(rules, a, "n1")
        let b = try XCTUnwrap(try rules.resumeReceipt(load(), fingerprint: f)).attempt
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        try apply(rules, b, "n2")
        _ = try rules.completeCatchUp(lsn: 5, high: nil, full: true, generation: generation)
        XCTAssertTrue(try rules.receiptInProgress(b))
        XCTAssertNil(try rules.resumeReceipt(load(), fingerprint: f))
    }

    func testResumeRefusesProgressPastTheListOffered() throws {
        let (_, rules) = client()
        let a = try rules.beginReceipt(load(), fingerprint: f)
        try apply(rules, a, "n1")
        try apply(rules, a, "n2")
        XCTAssertNil(try rules.resumeReceipt(load(), fingerprint: f, chunks: 1))
        XCTAssertEqual(try rules.resumeReceipt(load(), fingerprint: f, chunks: 2)?.done, 2)
    }

    // MARK: - Progress (behavior 2)

    func testBeginReceiptRecordsTheFingerprintNoProgressAndTheGeneration() throws {
        let (tables, rules) = client()
        let a = try rules.beginReceipt(load(), fingerprint: f)
        XCTAssertEqual(attempts(tables).first, RecordLogReceiptAttempt(
            kind: .load, id: s, attempt: a, last: 1, fingerprint: f, done: 0, generation: 0
        ))
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.beginReceipt(load("S2"), fingerprint: f)
        XCTAssertEqual(attempts(tables)[1].done, 0)
        XCTAssertEqual(attempts(tables)[1].generation, generation)
        XCTAssertEqual(tables.generation(), generation)
        // A segment has none until its own replacement begins.
        let seg = try rules.beginReceipt(segment(), fingerprint: f)
        XCTAssertEqual(attempts(tables)[2], RecordLogReceiptAttempt(
            kind: .segment, id: g, attempt: seg, last: 3, fingerprint: f, done: 0
        ))
    }

    func testALoadCountsItsChunksAndCompletesAtCompleteLoad() throws {
        let (tables, rules) = client()
        let a = try rules.beginReceipt(load(), fingerprint: f)
        try apply(rules, a, "n1")
        XCTAssertEqual(attempts(tables).first?.done, 1)
        _ = try rules.applyLoadLines(attempt: a, model: "Note", lines: [line("n2"), line("n3")])
        XCTAssertEqual(attempts(tables).first?.done, 2)
        XCTAssertEqual(attempts(tables).first?.completed, false)
        _ = try rules.completeLoad(attempt: a, mode: .merge, models: ["Note"])
        XCTAssertEqual(attempts(tables).first?.done, 2)
        XCTAssertEqual(attempts(tables).first?.completed, true)
    }

    func testASegmentCountsChunksAndKeptChunksNotAMismatchAndCompletesAtItsCorrections() throws {
        let held = RecordLogHeldSegment(segmentId: "G0", chunks: [
            RecordLogHeldSegmentChunk(object: "G0/Note/0", model: "Note", index: 0, firstId: "n1", lastId: "n2", rows: 2, sha256: "sha-a"),
        ])
        let (tables, rules) = client()
        let first = try rules.beginReceipt(segment("G0"))
        let g0 = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: first))
        _ = try rules.applySegmentRows(generation: g0, attempt: first, rows: [note("n1"), note("n2")])
        _ = try rules.completeCatchUp(lsn: 4, high: nil, full: true, generation: g0, receipt: first, segment: held)

        let a = try rules.beginReceipt(segment(), fingerprint: f)
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
        func keep(rows: Int) throws -> RecordLogKeepOutcome {
            try rules.keepSegmentChunk(
                generation: generation, attempt: a, object: "G0/Note/0", sha256: "sha-a", model: "Note", firstId: "n1", lastId: "n2", rows: rows
            )
        }
        XCTAssertEqual(try keep(rows: 3), .mismatch)
        XCTAssertEqual(attempts(tables).first?.done, 0)
        XCTAssertEqual(try keep(rows: 2), .kept(rows: 2, ranges: [RecordLogIdRange(model: "Note", firstId: "n1", lastId: "n2")]))
        XCTAssertEqual(attempts(tables).first?.done, 1)
        _ = try rules.applySegmentRows(generation: generation, attempt: a, rows: [note("n3")])
        XCTAssertEqual(attempts(tables).first?.done, 2)
        _ = try rules.applySegmentRows(generation: generation, attempt: nil, rows: [note("n4")])
        XCTAssertEqual(attempts(tables).first?.done, 2)
        _ = try rules.applySegmentCorrections(generation: generation, attempt: nil, lines: [])
        XCTAssertEqual(attempts(tables).first?.completed, false)
        _ = try rules.applySegmentCorrections(generation: generation, attempt: a, lines: [])
        XCTAssertEqual(attempts(tables).first?.done, 2)
        XCTAssertEqual(attempts(tables).first?.completed, true)
    }

    // MARK: - A displaced attempt's remainder (behavior 3)

    private func adopted() throws -> (tables: RecordLogMemoryTables, rules: RecordLogRules, old: String, adopter: String) {
        let (tables, rules) = client(cursor: 1)
        let old = try rules.beginReceipt(load(), fingerprint: f)
        try apply(rules, old, "n1")
        _ = try rules.completeLoad(attempt: old, mode: .merge, models: ["Note"])
        let resumed = try XCTUnwrap(try rules.resumeReceipt(load(), fingerprint: f))
        XCTAssertTrue(resumed.completed)
        return (tables, rules, old, resumed.attempt)
    }

    func testAPageOrCompletionOfADisplacedAttemptIsRefusedBeforeAnythingChanges() throws {
        let (tables, rules, old, _) = try adopted()
        XCTAssertTrue(try rules.displacedReceipt(old))
        let rows = tables.rows.orderedRows.map { $0.1 }
        let state = tables.receipts()
        XCTAssertThrowsError(try rules.applyCatchUpPage(
            RecordLogCatchUpInput(rows: [note("n1", "older")], gone: [RecordLogRecordKey(model: "Note", id: "n1")]), receipt: old
        )) { XCTAssertTrue($0 is RecordLogStaleReceiptError) }
        XCTAssertThrowsError(try rules.completeCatchUp(lsn: 9, high: nil, full: false, receipt: old)) {
            XCTAssertTrue($0 is RecordLogStaleReceiptError)
        }
        XCTAssertEqual(tables.rows.orderedRows.map { $0.1 }, rows)
        XCTAssertEqual(tables.receipts(), state)
        XCTAssertEqual(tables.cursor(), 1)
    }

    func testAPageOfTheAttemptInProgressAppliesWithoutCountingAsItsChange() throws {
        let (tables, rules, _, adopter) = try adopted()
        let last = attempts(tables).first?.last
        let n = tables.receipts()?.n
        _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [note("n1", "newer")]), receipt: adopter)
        XCTAssertEqual(attempts(tables).first?.last, last)
        XCTAssertEqual(tables.receipts()?.n, n)
        XCTAssertEqual(tables.rows.orderedRows.map { $0.1 }, [["id": "n1", "title": "newer"]])
        _ = try rules.completeCatchUp(lsn: 9, high: nil, full: false, receipt: adopter)
        XCTAssertNil(tables.receipts())
        XCTAssertEqual(tables.cursor(), 9)
        XCTAssertFalse(try rules.displacedReceipt(adopter))
    }

    func testASettledAttemptNoAttemptDisplacedCompletesAsBefore() throws {
        let (tables, rules) = client(cursor: 1)
        let a = try rules.beginReceipt(load(), fingerprint: f)
        try apply(rules, a, "n1")
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [note("n1")]), generation: generation)
        _ = try rules.completeCatchUp(lsn: 5, high: nil, full: true, generation: generation)
        XCTAssertFalse(try rules.receiptInProgress(a))
        XCTAssertFalse(try rules.displacedReceipt(a))
        _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: [note("n2")]), receipt: a)
        _ = try rules.completeCatchUp(lsn: 7, high: nil, full: false, receipt: a)
        XCTAssertEqual(tables.cursor(), 7)
        XCTAssertEqual(ids(tables), ["n1", "n2"])
    }

    func testReceiptsSettleAsBefore() throws {
        let (tables, rules) = client(cursor: 1)
        let failed = try rules.beginReceipt(load(), fingerprint: f)
        try apply(rules, failed, "n1")
        let retry = try rules.beginReceipt(load(), fingerprint: String(repeating: "0", count: 64))
        try apply(rules, retry, "n1")
        _ = try rules.completeCatchUp(lsn: 4, high: nil, full: false, receipt: retry)
        XCTAssertNil(tables.receipts())
        let other = try rules.beginReceipt(segment(), fingerprint: f)
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true))
        _ = try rules.completeCatchUp(lsn: 6, high: nil, full: true, generation: generation)
        XCTAssertFalse(try rules.receiptInProgress(other))
    }

    // MARK: - beginFencedCatchUp with an attempt (behavior 4)

    func testAFullCatchUpBegunForAnAttemptRecordsItsGenerationOnIt() throws {
        let (tables, rules) = client()
        let a = try rules.beginReceipt(segment(), fingerprint: f)
        let other = try rules.beginReceipt(load(), fingerprint: f)
        XCTAssertNil(attempts(tables).first?.generation)
        let generation = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a))
        XCTAssertEqual(generation, 1)
        XCTAssertEqual(attempts(tables).first { $0.attempt == a }?.generation, generation)
        XCTAssertEqual(attempts(tables).first { $0.attempt == other }?.generation, 0)
    }

    func testNothingIsRecordedWithoutAnAttemptOrForACatchUpThatIsNotFull() throws {
        let (tables, rules) = client()
        let a = try rules.beginReceipt(segment(), fingerprint: f)
        _ = try rules.beginFencedCatchUp(full: true)
        XCTAssertNil(attempts(tables).first?.generation)
        XCTAssertNil(try rules.beginFencedCatchUp(full: false, attempt: a))
        XCTAssertNil(attempts(tables).first?.generation)
    }

    // MARK: - What a resume leaves alone (edge cases)

    func testTheAloneRuleIsUnchangedForAResumedSegmentAttempt() throws {
        let held = RecordLogHeldSegment(segmentId: "G0", chunks: [
            RecordLogHeldSegmentChunk(object: "G0/Note/0", model: "Note", index: 0, firstId: "n1", lastId: "n2", rows: 2, sha256: "sha-a"),
        ])
        func setup(beside: Bool = false) throws -> (RecordLogRules, Int) {
            let (_, rules) = client()
            let first = try rules.beginReceipt(segment("G0"))
            let g0 = try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: first))
            _ = try rules.applySegmentRows(generation: g0, attempt: first, rows: [note("n1"), note("n2")])
            _ = try rules.completeCatchUp(lsn: 4, high: nil, full: true, generation: g0, receipt: first, segment: held)
            // An attempt begun before the replacement does not refuse the resume (5267-C2-02).
            if beside { _ = try rules.beginReceipt(load()) }
            let a = try rules.beginReceipt(segment(), fingerprint: f)
            return (rules, try XCTUnwrap(try rules.beginFencedCatchUp(full: true, attempt: a)))
        }
        func keep(_ rules: RecordLogRules, _ generation: Int, _ attempt: String) throws -> RecordLogKeepOutcome {
            try rules.keepSegmentChunk(
                generation: generation, attempt: attempt, object: "G0/Note/0", sha256: "sha-a", model: "Note", firstId: "n1", lastId: "n2", rows: 2
            )
        }
        do {
            let (rules, generation) = try setup()
            let resumed = try XCTUnwrap(try rules.resumeReceipt(segment(), fingerprint: f))
            XCTAssertNotEqual(try keep(rules, generation, resumed.attempt), .mismatch)
        }
        do {
            let (rules, generation) = try setup(beside: true)
            let resumed = try XCTUnwrap(try rules.resumeReceipt(segment(), fingerprint: f))
            XCTAssertEqual(try keep(rules, generation, resumed.attempt), .mismatch)
        }
    }

    func testAResumedAttemptsLastContinuesFromTheStatesCount() throws {
        let (tables, rules) = client()
        let a = try rules.beginReceipt(load(), fingerprint: f)
        for id in ["n1", "n2", "n3"] { try apply(rules, a, id) }
        let last = try XCTUnwrap(attempts(tables).first?.last)
        _ = try rules.resumeReceipt(load(), fingerprint: f)
        XCTAssertEqual(attempts(tables).first?.last, tables.receipts()?.n)
        XCTAssertGreaterThan(try XCTUnwrap(attempts(tables).first?.last), last)
    }
}
