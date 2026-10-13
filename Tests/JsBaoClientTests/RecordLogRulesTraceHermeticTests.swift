import XCTest
@testable import JsBaoClient

/// The record-log rules (`RecordLogRules` over `RecordLogMemoryTables`) against
/// the model's plain-rows client, event for event over the golden traces: the
/// Swift twin of js-bao's `record-log-client-traces-4307.test.ts`.
///
/// Each trace is replayed from the fixture alone. After every event the
/// client's cursor, epochs, constraints, next seq, pending entries, confirmed
/// rows, view and handed-back seqs, the resume frames it asks the room for, and
/// a write's `{seq, e, k}`, must equal what the model recorded.
final class RecordLogRulesTraceHermeticTests: XCTestCase {

    func testTheTracesHoldEveryEventKindTheModelRecords() throws {
        let traces = try RecordLogTraceFixture.load()
        let kinds = Set(traces.flatMap { $0.events.map(\.t) })
        XCTAssertEqual(kinds.sorted(), ["catchUp", "notice", "receive", "refused", "settled", "spill", "write"])
    }

    func testEveryClientOfEveryScheduleReplaysEqualToTheModel() throws {
        let traces = try RecordLogTraceFixture.load()
        var bad = 0
        var events = 0
        var first = ""
        for trace in traces {
            let result = try replay(trace)
            bad += result.bad
            events += trace.events.count
            if first.isEmpty { first = result.first }
        }
        XCTAssertGreaterThan(events, 2000)
        XCTAssertEqual(bad, 0, first)
    }

    private func replay(_ trace: RecordLogTraceFixture.Trace) throws -> (bad: Int, first: String) {
        typealias F = RecordLogTraceFixture
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
        var handedBack: [Int] = []

        func refuse(_ out: JSONValue, _ seq: Int, _ calls: inout [JSONValue]) throws {
            let outcome = try rules.refused(F.refusal(out, seq: seq))
            handedBack.append(contentsOf: outcome.handedBack.map(\.seq))
            calls.append(contentsOf: F.calls(outcome.frames))
        }

        func snapshot() throws -> JSONValue {
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

        var bad = 0
        var first = ""
        for (n, event) in trace.events.enumerated() {
            let input = event.input
            var calls: [JSONValue] = []
            var ret: JSONValue?
            switch event.t {
            case "write":
                let entry = try rules.write(
                    F.mutation(input["m"]),
                    also: (input["also"]?.arrayValue ?? []).map { F.mutation($0) },
                    upsertOn: input["upsertOn"]?.stringValue
                )
                ret = .object(["seq": .number(Double(entry.seq)), "e": .number(Double(entry.e)), "k": .number(Double(entry.k))])
            case "receive":
                _ = try rules.receive(F.resultItem(input))
            case "refused":
                try refuse(input["out"] ?? .null, Int(input["seq"]?.numberValue ?? 0), &calls)
            case "settled":
                try rules.settled(Int(input["seq"]?.numberValue ?? 0))
            case "spill":
                try rules.spill()
            case "notice":
                try rules.notice(current: Int(input["current"]?.numberValue ?? 0))
            case "catchUp":
                let outcomes = input["outcomes"]?.objectValue ?? [:]
                // What the room accepted of this writer's pending entries is a
                // duplicate when it is resubmitted: settled, its row from the catch-up.
                for entry in try rules.pending() where outcomes[String(entry.seq)]?["status"]?.stringValue == "accepted" {
                    _ = try rules.receive(.duplicate(seq: entry.seq))
                }
                let lsn = Int(input["lsn"]?.numberValue ?? 0)
                let high = input["high"]?.numberValue.map { Int($0) }
                var catchUp = RecordLogCatchUpInput()
                if input["reload"]?.boolValue == true {
                    catchUp.full = true
                    catchUp.rows = (input["rows"]?.arrayValue ?? []).map { row in
                        RecordLogCatchUpRow(model: F.model, id: row["id"]?.stringValue ?? "", row: row.objectValue ?? [:])
                    }
                } else {
                    for pair in input["changed"]?.arrayValue ?? [] {
                        let id = pair.arrayValue?.first?.stringValue ?? ""
                        if let row = pair.arrayValue?.dropFirst().first?.objectValue {
                            catchUp.rows.append(RecordLogCatchUpRow(model: F.model, id: id, row: row))
                        } else {
                            catchUp.gone.append(RecordLogRecordKey(model: F.model, id: id))
                        }
                    }
                }
                _ = try rules.catchUp(
                    catchUp, lsn: lsn, high: high,
                    notice: (current: Int(input["current"]?.numberValue ?? 0), next: nil, entries: nil),
                    constraints: F.constraints(input["constraints"])
                )
                // The rest is answered by resubmission: a withdrawn entry's number
                // is settled, a refusal the room replays is acted on.
                for entry in try rules.pending() {
                    guard let out = outcomes[String(entry.seq)],
                          let now = try rules.pending().first(where: { $0.seq == entry.seq })
                    else { continue }
                    if now.isVoid {
                        try rules.settled(entry.seq)
                    } else if out["status"]?.stringValue == "refused" {
                        try refuse(out, entry.seq, &calls)
                    }
                }
            default:
                XCTFail("unknown event \(event.t)")
            }
            let got = try snapshot()
            let want = F.comparable(event.after)
            let same = got == want && JSONValue.array(calls) == event.calls && ret == event.ret
            if !same {
                bad += 1
                if first.isEmpty {
                    first = "client \(trace.id) event \(n) (\(event.t)): got \(F.text(got)) want \(F.text(want)) "
                        + "calls \(F.text(.array(calls))) want \(F.text(event.calls)) ret \(ret.map(F.text) ?? "-") want \(event.ret.map(F.text) ?? "-")"
                }
            }
        }
        return (bad, first)
    }
}
