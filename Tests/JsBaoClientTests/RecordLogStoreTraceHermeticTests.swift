import XCTest
@testable import JsBaoClient

/// The golden traces replayed through the record-log STORE: a `RecordLogStore`
/// over a real `SQLiteStorageProvider` on a temp file, driven through the
/// commands a session drives it with. The Swift twin of js-bao's
/// `record-log-traces-4308.test.ts`.
///
/// Each trace starts from a fresh database whose store is seeded so its first
/// snapshot is the trace's `init`. After every event the store's state must
/// equal the trace's `after`, its `record.resume` frames the trace's `calls`,
/// and a write's `{seq, e, k}` its `ret`. (Until #4700 the projected `Note`
/// rows were compared with the view too; a db3's rows live in the view only.)
final class RecordLogStoreTraceHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-traces-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    func testEveryClientReplaysThroughTheStore() async throws {
        let provider = try await makeProvider()
        let traces = try RecordLogTraceFixture.load()
        var bad = 0
        var initBad = 0
        var events = 0
        var first = ""
        var sawNull = false
        var sawObject = false
        for trace in traces {
            let result = try replay(trace, provider: provider)
            bad += result.bad
            initBad += result.initSame ? 0 : 1
            events += trace.events.count
            sawNull = sawNull || result.sawNull
            sawObject = sawObject || result.sawObject
            if first.isEmpty { first = result.first }
        }
        XCTAssertGreaterThan(events, 2000)
        XCTAssertEqual(initBad, 0, "every seeded store starts at its trace's init")
        XCTAssertEqual(bad, 0, first)
        XCTAssertTrue(sawNull, "the traces write a present null")
        XCTAssertTrue(sawObject, "the traces write a nested object")
    }

    private struct Replay {
        var bad = 0
        var initSame = false
        var first = ""
        var sawNull = false
        var sawObject = false
    }

    private func replay(
        _ trace: RecordLogTraceFixture.Trace, provider: SQLiteStorageProvider
    ) throws -> Replay {
        typealias F = RecordLogTraceFixture
        let documentId = "trace-\(trace.id)-\(UUID().uuidString)"
        let writer = trace.id
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: "trace-client")
        try store.initialize()
        let initial = trace.initial

        // The trace's starting state: its writer, its rows at its cursor, its epochs and constraints.
        try provider.withConnection { connection in
            try connection.execute("INSERT OR IGNORE INTO record_log_state (doc_id) VALUES (?)", [.text(documentId)])
            try connection.execute(
                "INSERT INTO record_log_writers (doc_id, client_id, writer, next_seq, resumed_at) VALUES (?, ?, ?, ?, 0)",
                [.text(documentId), .text("trace-client"), .text(writer), .integer(Int64(initial["nextSeq"]?.numberValue ?? 1))]
            )
        }
        try store.beginCatchUp(writer: writer, full: true)
        _ = try store.applyCatchUpPage(
            writer: writer,
            rows: (initial["confirmed"]?.arrayValue ?? []).map { row in
                RecordLogCatchUpRow(model: F.model, id: row["id"]?.stringValue ?? "", row: row.objectValue ?? [:])
            }
        )
        _ = try store.completeCatchUp(writer: writer, lsn: Int(initial["cursor"]?.numberValue ?? 0), full: true)
        try store.setState(
            writer: writer,
            notice: (current: Int(initial["open"]?.numberValue ?? 1), next: Int(initial["grant"]?.numberValue ?? 2), entries: nil),
            constraints: F.constraints(initial["constraints"])
        )

        var handedBack: [Int] = []
        func snapshot() throws -> JSONValue {
            let marks = try store.marks()
            return F.comparable(.object([
                "cursor": .number(Double(marks.cursor)),
                "open": .number(Double(marks.open)),
                "grant": .number(Double(marks.grant)),
                "constraints": .array(marks.constraints.map { .string($0.name) }),
                "nextSeq": .number(Double(marks.nextSeq)),
                "pending": .array(try store.pendingOf(writer).map { F.modelPending(writer, $0) }),
                "confirmed": F.rows(try store.confirmedRows()),
                "view": F.rows(try store.readRowsAfter(model: F.model, after: nil, limit: 1_000_000)),
                "handedBack": .array(handedBack.map { .number(Double($0)) }),
            ]))
        }
        func refuse(_ out: JSONValue, _ seq: Int, _ calls: inout [JSONValue]) throws {
            let reply = try store.refused(writer: writer, refusal: F.refusal(out, seq: seq))
            handedBack.append(contentsOf: reply.handedBack.map(\.seq))
            calls.append(contentsOf: F.calls(reply.frames))
        }

        var result = Replay()
        result.initSame = try snapshot() == F.comparable(initial)
        for (n, event) in trace.events.enumerated() {
            let input = event.input
            var calls: [JSONValue] = []
            var ret: JSONValue?
            switch event.t {
            case "write":
                let m = F.mutation(input["m"])
                for value in (m.fields ?? [:]).values {
                    if value == .null { result.sawNull = true }
                    if case .object = value { result.sawObject = true }
                }
                let reply = try store.commitEntries(
                    writer: writer,
                    writes: [RecordLogWrite(
                        mutations: [m] + (input["also"]?.arrayValue ?? []).map { F.mutation($0) },
                        upsertOn: input["upsertOn"]?.stringValue
                    )]
                )
                let entry = reply.entries[0]
                ret = .object(["seq": .number(Double(entry.seq)), "e": .number(Double(entry.e)), "k": .number(Double(entry.k))])
            case "receive":
                _ = try store.receive(writer: writer, items: [F.resultItem(input)])
            case "refused":
                try refuse(input["out"] ?? .null, Int(input["seq"]?.numberValue ?? 0), &calls)
            case "settled":
                try store.settled(writer: writer, seq: Int(input["seq"]?.numberValue ?? 0))
            case "spill":
                try store.spill(writer: writer)
            case "notice":
                try store.setState(writer: writer, notice: (current: Int(input["current"]?.numberValue ?? 0), next: nil, entries: nil))
            case "catchUp":
                let outcomes = input["outcomes"]?.objectValue ?? [:]
                // What the room accepted of this writer's pending entries is a
                // duplicate when it is resubmitted: settled, its row from the catch-up.
                let duplicates = try store.pendingOf(writer)
                    .filter { outcomes[String($0.seq)]?["status"]?.stringValue == "accepted" }
                    .map { RecordLogResultItem.duplicate(seq: $0.seq) }
                if !duplicates.isEmpty { _ = try store.receive(writer: writer, items: duplicates) }
                let reload = input["reload"]?.boolValue == true
                try store.beginCatchUp(writer: writer, full: reload)
                if reload {
                    _ = try store.applyCatchUpPage(
                        writer: writer,
                        rows: (input["rows"]?.arrayValue ?? []).map { row in
                            RecordLogCatchUpRow(model: F.model, id: row["id"]?.stringValue ?? "", row: row.objectValue ?? [:])
                        }
                    )
                } else {
                    var rows: [RecordLogCatchUpRow] = []
                    var gone: [RecordLogRecordKey] = []
                    for pair in input["changed"]?.arrayValue ?? [] {
                        let id = pair.arrayValue?.first?.stringValue ?? ""
                        if let row = pair.arrayValue?.dropFirst().first?.objectValue {
                            rows.append(RecordLogCatchUpRow(model: F.model, id: id, row: row))
                        } else {
                            gone.append(RecordLogRecordKey(model: F.model, id: id))
                        }
                    }
                    _ = try store.applyCatchUpPage(writer: writer, rows: rows, gone: gone)
                }
                _ = try store.completeCatchUp(
                    writer: writer, lsn: Int(input["lsn"]?.numberValue ?? 0),
                    high: input["high"]?.numberValue.map { Int($0) }, full: reload
                )
                try store.setState(
                    writer: writer, notice: (current: Int(input["current"]?.numberValue ?? 0), next: nil, entries: nil),
                    constraints: F.constraints(input["constraints"])
                )
                // The rest is answered by resubmission: a withdrawn entry's number
                // is settled, a refusal the room replays is acted on.
                for entry in try store.pendingOf(writer) {
                    guard let out = outcomes[String(entry.seq)],
                          let now = try store.pendingOf(writer).first(where: { $0.seq == entry.seq })
                    else { continue }
                    if now.isVoid {
                        try store.settled(writer: writer, seq: entry.seq)
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
                result.bad += 1
                if result.first.isEmpty {
                    result.first = "client \(trace.id) event \(n) (\(event.t)): got \(F.text(got)) want \(F.text(want)) "
                        + "calls \(F.text(.array(calls))) want \(F.text(event.calls))"
                }
            }
        }
        return result
    }
}
