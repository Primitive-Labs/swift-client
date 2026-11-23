import XCTest
@testable import JsBaoClient

/// The receipt traces (`tests/perf/overlay-layouts/fixtures/load-traces.json`)
/// replayed through the record-log rules (`RecordLogRules` over
/// `RecordLogMemoryTables`), event for event: the Swift twin of js-bao's
/// `replayLoadTraceInMemory` (`tests/helpers/record-log-load-trace-replay-4311.ts`).
///
/// Per kind, the calls a session makes:
/// - `load`: a completed load past the cursor begins a receipt, applies each
///   chunk's lines by key and completes the load; an aborted or failed one
///   asks to open again.
/// - `loadRemainder`: its rows and gone records as a catch-up page, completed
///   at its log number as the receipt; on a reconnect the outcomes are settled
///   and the epochs and constraints recorded, as a catch-up's are.
/// - `segment`: a replacement under its generation: the chunks' rows (a chunk
///   the model kept is kept through `keepSegmentChunk` instead, #4394), the
///   corrections, the rows changed since `C`, completed at `upTo`.
/// - the seven kinds of the golden traces, as their replay drives them.
final class RecordLogLoadTraceRulesHermeticTests: XCTestCase {

    static let receiptCases = [
        "aborted", "failed", "held", "live", "reconnect", "recreated", "refresh", "refused-gone", "segment", "segment-kept",
        "segment-tombstone-rewrite",
    ]

    func testTheFileHoldsEveryKindAndEveryReceiptCase() throws {
        let schedules = try RecordLogTraceFixture.loadReceiptSchedules()
        let kinds = Set(schedules.flatMap { $0.clients.flatMap { $0.events.map(\.t) } })
        XCTAssertEqual(
            kinds.sorted(), ["catchUp", "load", "loadRemainder", "notice", "receive", "refused", "segment", "settled", "spill", "write"]
        )
        XCTAssertEqual(Set(schedules.flatMap(\.cases)).sorted(), Self.receiptCases)
    }

    func testEveryClientOfEveryScheduleReplaysEqualToTheModel() throws {
        let traces = try RecordLogTraceFixture.loadReceiptSchedules().flatMap(\.clients)
        var bad = 0
        var events = 0
        var first = ""
        var leaked = 0
        var kept = 0
        var mismatched = 0
        for trace in traces {
            let result = try RecordLogLoadTraceReplay.inMemory(trace)
            bad += result.bad
            leaked += result.leakedLoadKeys
            kept += result.kept
            mismatched += result.mismatched
            events += trace.events.count
            if first.isEmpty { first = result.first }
        }
        XCTAssertGreaterThan(events, 700)
        XCTAssertEqual(bad, 0, first)
        XCTAssertEqual(leaked, 0, "no receipt's load keys outlive it")
        // Every chunk the model kept is kept by the rules (#4394).
        XCTAssertGreaterThan(kept, 0)
        XCTAssertEqual(mismatched, 0, first)
    }
}

/// The replay of one receipt trace, through the calls a session makes; shared
/// by the rules' replay (memory tables) and the store's (SQLite).
enum RecordLogLoadTraceReplay {
    typealias F = RecordLogTraceFixture

    /// What a replay needs of the client under test.
    struct Ops {
        var cursor: () throws -> Int
        var pending: () throws -> [RecordLogPendingEntry]
        var write: (_ mutations: [RecordLogMutation], _ upsertOn: String?) throws -> RecordLogPendingEntry
        var receive: (_ items: [RecordLogResultItem]) throws -> Void
        var refused: (_ refusal: RecordLogRefusal) throws -> (handedBack: [RecordLogPendingEntry], frames: [RecordLogUpFrame])
        var settled: (_ seq: Int) throws -> Void
        var spill: () throws -> Void
        var notice: (_ current: Int) throws -> Void
        var constraints: (_ names: JSONValue?) throws -> Void
        var beginCatchUp: (_ full: Bool) throws -> Int?
        var page: (_ rows: [RecordLogCatchUpRow], _ gone: [RecordLogRecordKey], _ generation: Int?) throws -> Void
        var complete: (
            _ lsn: Int, _ high: Int?, _ full: Bool, _ generation: Int?, _ receipt: String?, _ segment: RecordLogHeldSegment?
        ) throws -> Void
        var beginReceipt: (_ kind: RecordLogReceiptKind, _ id: String) throws -> String
        var loadLines: (_ attempt: String, _ model: String, _ lines: [RecordLogLoadLine]) throws -> Void
        var completeLoad: (_ attempt: String, _ mode: RecordLogLoadMode, _ models: [String]) throws -> Void
        var segmentRows: (_ generation: Int, _ attempt: String, _ rows: [RecordLogCatchUpRow]) throws -> Void
        var segmentCorrections: (_ generation: Int, _ attempt: String, _ lines: [RecordLogCorrection]) throws -> Void
        /// Keep a held chunk (#4394); answers whether the client kept it (`false`: it answered mismatch).
        var keep: (_ generation: Int, _ attempt: String, _ segmentId: String, _ chunk: RecordLogHeldSegmentChunk) throws -> Bool
        /// The client's state as the model records it, `handedBack` included.
        var snapshot: (_ handedBack: [Int]) throws -> JSONValue
    }

    struct Result {
        var bad = 0
        /// Events after which `check` found a difference (the store's projection).
        var checkedBad = 0
        var first = ""
        var leakedLoadKeys = 0
        /// Segment chunks kept through the keep command (#4394).
        var kept = 0
        /// Kept chunks the client answered mismatch for, where the model kept them.
        var mismatched = 0
    }

    /// Replay `trace`; `check` runs after every event and answers a difference to report, or `nil`.
    static func replay(
        _ trace: F.Trace, _ ops: Ops, check: ((_ n: Int, _ event: F.Event) throws -> String?)? = nil
    ) throws -> Result {
        var handedBack: [Int] = []
        func refuse(_ out: JSONValue, _ seq: Int, _ calls: inout [JSONValue]) throws {
            let reply = try ops.refused(F.refusal(out, seq: seq))
            handedBack.append(contentsOf: reply.handedBack.map(\.seq))
            calls.append(contentsOf: F.calls(reply.frames))
        }
        // What the room accepted of the pending entries is a duplicate when resubmitted.
        func duplicates(_ outcomes: [String: JSONValue]) throws {
            let items = try ops.pending()
                .filter { outcomes[String($0.seq)]?["status"]?.stringValue == "accepted" }
                .map { RecordLogResultItem.duplicate(seq: $0.seq) }
            if !items.isEmpty { try ops.receive(items) }
        }
        // The rest is answered by resubmission: a withdrawn entry's number
        // settles, a replayed refusal is acted on.
        func resolve(_ outcomes: [String: JSONValue], _ calls: inout [JSONValue]) throws {
            for entry in try ops.pending() {
                guard let out = outcomes[String(entry.seq)],
                      let now = try ops.pending().first(where: { $0.seq == entry.seq })
                else { continue }
                if now.isVoid {
                    try ops.settled(entry.seq)
                } else if out["status"]?.stringValue == "refused" {
                    try refuse(out, entry.seq, &calls)
                }
            }
        }
        func learn(_ input: JSONValue, _ calls: inout [JSONValue]) throws {
            try ops.notice(Int(input["current"]?.numberValue ?? 0))
            try ops.constraints(input["constraints"])
            try resolve(input["outcomes"]?.objectValue ?? [:], &calls)
        }

        var result = Result()
        // The receipt attempt of the load whose remainder comes next.
        var attempt: String?
        for (n, event) in trace.events.enumerated() {
            let input = event.input
            var calls: [JSONValue] = []
            var ret: JSONValue?
            switch event.t {
            case "write":
                let entry = try ops.write(
                    [F.mutation(input["m"])] + (input["also"]?.arrayValue ?? []).map { F.mutation($0) },
                    input["upsertOn"]?.stringValue
                )
                ret = .object(["seq": .number(Double(entry.seq)), "e": .number(Double(entry.e)), "k": .number(Double(entry.k))])
            case "receive":
                try ops.receive([F.resultItem(input)])
            case "refused":
                try refuse(input["out"] ?? .null, Int(input["seq"]?.numberValue ?? 0), &calls)
            case "settled":
                try ops.settled(Int(input["seq"]?.numberValue ?? 0))
            case "spill":
                try ops.spill()
            case "notice":
                try ops.notice(Int(input["current"]?.numberValue ?? 0))
            case "catchUp":
                try duplicates(input["outcomes"]?.objectValue ?? [:])
                let full = input["reload"]?.boolValue == true
                let generation = try ops.beginCatchUp(full)
                if full {
                    try ops.page(
                        (input["rows"]?.arrayValue ?? []).map { row in
                            RecordLogCatchUpRow(model: F.model, id: row["id"]?.stringValue ?? "", row: row.objectValue ?? [:])
                        },
                        [], generation
                    )
                } else {
                    try ops.page(F.rowsOf(input["changed"]), F.goneOf(input["changed"]), generation)
                }
                try ops.complete(
                    Int(input["lsn"]?.numberValue ?? 0), input["high"]?.numberValue.map { Int($0) }, full, generation, nil, nil
                )
                try learn(input, &calls)
            case "load":
                guard input["phase"]?.stringValue == "complete" else {
                    calls.append(.object(["reopen": .bool(true)]))
                    break
                }
                guard let lastLsn = input["lastLsn"]?.wholeNumber, try ops.cursor() < lastLsn else { break }
                let begun = try ops.beginReceipt(.load, input["sessionId"]?.stringValue ?? "")
                attempt = begun
                for chunk in F.loadChunks(input) { try ops.loadLines(begun, chunk.model, chunk.lines) }
                try ops.completeLoad(
                    begun, RecordLogLoadMode(rawValue: input["mode"]?.stringValue ?? "") ?? .merge,
                    (input["models"]?.arrayValue ?? []).compactMap(\.stringValue)
                )
            case "loadRemainder":
                let reconnect = input["outcomes"] != nil
                if reconnect { try duplicates(input["outcomes"]?.objectValue ?? [:]) }
                try ops.page(F.rowsOf(input["rows"]), (input["gone"]?.arrayValue ?? []).compactMap(\.stringValue).map {
                    RecordLogRecordKey(model: F.model, id: $0)
                }, nil)
                try ops.complete(
                    Int(input["lsn"]?.numberValue ?? 0), input["high"]?.numberValue.map { Int($0) }, false, nil, attempt, nil
                )
                attempt = nil
                if reconnect { try learn(input, &calls) }
            case "segment":
                try duplicates(input["outcomes"]?.objectValue ?? [:])
                let segmentAttempt = try ops.beginReceipt(.segment, input["segmentId"]?.stringValue ?? "")
                guard let generation = try ops.beginCatchUp(true) else {
                    throw JsBaoError(code: .unavailable, message: "a full catch-up answered no generation")
                }
                // A chunk the model kept from the rows it held is kept here too (#4394).
                let segmentId = input["segmentId"]?.stringValue ?? ""
                let held = F.heldSegment(input)
                for (at, chunk) in (input["chunks"]?.arrayValue ?? []).enumerated() {
                    if chunk["kept"]?.boolValue == true {
                        result.kept += 1
                        if try !ops.keep(generation, segmentAttempt, segmentId, held.chunks[at]) {
                            result.mismatched += 1
                            if result.first.isEmpty {
                                result.first = "client \(trace.id) event \(n) (segment): the client would not keep \(held.chunks[at].object)"
                            }
                        }
                        continue
                    }
                    try ops.segmentRows(generation, segmentAttempt, F.chunkRows(chunk))
                }
                try ops.segmentCorrections(generation, segmentAttempt, F.corrections(input))
                try ops.page(F.rowsOf(input["changed"]), F.goneOf(input["changed"]), generation)
                try ops.complete(
                    Int(input["upTo"]?.numberValue ?? 0), input["high"]?.numberValue.map { Int($0) }, true, generation,
                    segmentAttempt, held
                )
                try learn(input, &calls)
            default:
                throw JsBaoError(code: .unavailable, message: "unknown event \(event.t)")
            }
            let got = try ops.snapshot(handedBack)
            let want = F.comparable(event.after)
            let same = got == want && JSONValue.array(calls) == event.calls && ret == event.ret
            if let difference = try check?(n, event) {
                result.checkedBad += 1
                if result.first.isEmpty { result.first = "client \(trace.id) event \(n) (\(event.t)): \(difference)" }
            }
            if !same {
                result.bad += 1
                if result.first.isEmpty {
                    result.first = "client \(trace.id) event \(n) (\(event.t)): got \(F.text(got)) want \(F.text(want)) "
                        + "calls \(F.text(.array(calls))) want \(F.text(event.calls)) ret \(ret.map(F.text) ?? "-") "
                        + "want \(event.ret.map(F.text) ?? "-")"
                }
            }
        }
        return result
    }

    /// Replay one trace through `RecordLogRules` over memory tables.
    static func inMemory(_ trace: F.Trace) throws -> Result {
        let initial = trace.initial
        let tables = RecordLogMemoryTables(
            rows: (initial["confirmed"]?.arrayValue ?? []).map { row in
                (RecordLogRecordKey(model: F.model, id: row["id"]?.stringValue ?? ""), row.objectValue ?? [:])
            },
            cursor: Int(initial["cursor"]?.numberValue ?? 0),
            open: Int(initial["open"]?.numberValue ?? 1),
            grant: Int(initial["grant"]?.numberValue ?? 2),
            writers: [trace.id]
        )
        tables.setConstraints(F.constraints(initial["constraints"]))
        tables.setWriterState(trace.id, RecordLogWriterState(nextSeq: Int(initial["nextSeq"]?.numberValue ?? 1), resumedAt: 0))
        let rules = RecordLogRules(tables: tables, writer: trace.id)
        var result = try replay(trace, Ops(
            cursor: { tables.cursor() },
            pending: { try rules.pending() },
            write: { mutations, upsertOn in
                try rules.write(mutations[0], also: Array(mutations.dropFirst()), upsertOn: upsertOn)
            },
            receive: { items in for item in items { _ = try rules.receive(item) } },
            refused: { refusal in
                let out = try rules.refused(refusal)
                return (out.handedBack, out.frames)
            },
            settled: { seq in try rules.settled(seq) },
            spill: { try rules.spill() },
            notice: { current in try rules.notice(current: current) },
            constraints: { names in tables.setConstraints(F.constraints(names)) },
            beginCatchUp: { full in try rules.beginFencedCatchUp(full: full) },
            page: { rows, gone, generation in
                _ = try rules.applyCatchUpPage(RecordLogCatchUpInput(rows: rows, gone: gone), generation: generation)
            },
            complete: { lsn, high, full, generation, receipt, segment in
                _ = try rules.completeCatchUp(
                    lsn: lsn, high: high, full: full, generation: generation, receipt: receipt, segment: segment
                )
            },
            beginReceipt: { kind, id in try rules.beginReceipt(RecordLogReceipt(kind: kind, id: id)) },
            loadLines: { attempt, model, lines in _ = try rules.applyLoadLines(attempt: attempt, model: model, lines: lines) },
            completeLoad: { attempt, mode, models in _ = try rules.completeLoad(attempt: attempt, mode: mode, models: models) },
            segmentRows: { generation, attempt, rows in
                _ = try rules.applySegmentRows(generation: generation, attempt: attempt, rows: rows)
            },
            segmentCorrections: { generation, attempt, lines in
                _ = try rules.applySegmentCorrections(generation: generation, attempt: attempt, lines: lines)
            },
            keep: { generation, attempt, _, chunk in
                try rules.keepSegmentChunk(
                    generation: generation, attempt: attempt, object: chunk.object, sha256: chunk.sha256, model: chunk.model,
                    firstId: chunk.firstId, lastId: chunk.lastId, rows: chunk.rows
                ) != .mismatch
            },
            snapshot: { handedBack in
                let epochs = tables.epochs()
                return F.comparable(.object([
                    "cursor": .number(Double(tables.cursor())),
                    "open": .number(Double(epochs.open)),
                    "grant": .number(Double(epochs.grant)),
                    "constraints": .array(tables.constraints().map { .string($0.name) }),
                    "nextSeq": .number(Double(try rules.nextSeq())),
                    "pending": .array(try rules.pending().map { F.modelPending(trace.id, $0) }),
                    "confirmed": F.rows(tables.rows.orderedRows.map(\.row)),
                    "view": F.rows(try tables.view().orderedRows.map(\.row)),
                    "handedBack": .array(handedBack.map { .number(Double($0)) }),
                ]))
            }
        ))
        let live = Set(tables.receipts()?.attempts.map(\.attempt) ?? [])
        result.leakedLoadKeys = tables.loadKeyAttempts.filter { !live.contains($0) }.count
        return result
    }
}
