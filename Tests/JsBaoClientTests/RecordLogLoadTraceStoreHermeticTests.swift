import XCTest
@testable import JsBaoClient

/// The receipt traces (`tests/perf/overlay-layouts/fixtures/load-traces.json`)
/// replayed through the record-log STORE: a `RecordLogStore` over a real
/// `SQLiteStorageProvider`, driven through `beginReceipt`, `applyLoadChunk`,
/// `completeLoad`, `beginFencedCatchUp`, `applySegmentChunk`,
/// `applySegmentCorrections`, `applyCatchUpPage` and `completeCatchUp` with
/// their generation and receipt, as js-bao's `replayLoadTraceThroughStore`
/// drives its store. After every event the store's state must equal the
/// trace's `after`, and the projected `Note` rows the view.
final class RecordLogLoadTraceStoreHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-load-traces-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    func testEveryReceiptTraceReplaysThroughTheStoreWithItsProjectionEqualToTheView() async throws {
        let provider = try await makeProvider()
        let engine = BaoModelQueryEngine(host: provider)
        let schema = RecordLogStoreLoadTraceReplay.schema
        try RecordLogQueryProjection.prepare(schema: schema, engine: engine, host: provider)
        let traceSpec = RecordLogProjectionSpec(schema: schema)
        let traces = try RecordLogTraceFixture.loadReceiptSchedules().flatMap(\.clients)
        var bad = 0
        var projectedBad = 0
        var events = 0
        var first = ""
        for trace in traces {
            let result = try RecordLogStoreLoadTraceReplay.replayLoadTrace(trace, provider: provider, spec: traceSpec)
            bad += result.bad
            projectedBad += result.checkedBad
            events += trace.events.count
            if first.isEmpty { first = result.first }
        }
        XCTAssertGreaterThan(events, 700)
        XCTAssertEqual(bad, 0, first)
        XCTAssertEqual(projectedBad, 0, first)
    }
}

/// The receipt traces through the store: the Swift twin of js-bao's
/// `replayLoadTraceThroughStore`. Each trace starts from a fresh document whose
/// store is seeded at its `init`; after every event the projected `Note` rows
/// must equal the view.
enum RecordLogStoreLoadTraceReplay {
    typealias F = RecordLogTraceFixture

    static let scalars = ["a", "b", "c", "u", "v"]
    static let schema = PrimitiveSchema(
        name: F.model,
        fields: [
            "id": FieldDescriptor(type: .id),
            "a": FieldDescriptor(type: .string), "b": FieldDescriptor(type: .string),
            "c": FieldDescriptor(type: .string), "u": FieldDescriptor(type: .string),
            "v": FieldDescriptor(type: .string), "t": FieldDescriptor(type: .stringset),
        ]
    )

    static func replayLoadTrace(
        _ trace: F.Trace, provider: SQLiteStorageProvider, spec: RecordLogProjectionSpec
    ) throws -> RecordLogLoadTraceReplay.Result {
        let documentId = "trace-\(trace.id)-\(UUID().uuidString)"
        let writer = trace.id
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: "trace-client")
        try store.initialize()
        let project = [spec]
        let initial = trace.initial
        try provider.withConnection { connection in
            try connection.execute("INSERT OR IGNORE INTO record_log_state (doc_id) VALUES (?)", [.text(documentId)])
            try connection.execute(
                "INSERT INTO record_log_writers (doc_id, client_id, writer, next_seq, resumed_at) VALUES (?, ?, ?, ?, 0)",
                [.text(documentId), .text("trace-client"), .text(writer), .integer(Int64(initial["nextSeq"]?.numberValue ?? 1))]
            )
        }
        let seed = try store.beginFencedCatchUp(writer: writer, full: true)
        _ = try store.applyCatchUpPage(
            writer: writer,
            rows: (initial["confirmed"]?.arrayValue ?? []).map { row in
                RecordLogCatchUpRow(model: F.model, id: row["id"]?.stringValue ?? "", row: row.objectValue ?? [:])
            },
            generation: seed, project: project
        )
        _ = try store.completeCatchUp(
            writer: writer, lsn: Int(initial["cursor"]?.numberValue ?? 0), full: true, generation: seed, project: project
        )
        try store.setState(
            writer: writer,
            notice: (current: Int(initial["open"]?.numberValue ?? 1), next: Int(initial["grant"]?.numberValue ?? 2), entries: nil),
            constraints: F.constraints(initial["constraints"])
        )
        func fresh(_ stale: Bool, _ what: String) throws {
            if stale { throw JsBaoError(code: .unavailable, message: "\(what) of \(trace.id) answered stale") }
        }
        // The query tables as the view projects: a column per scalar (a nested
        // object as its JSON), the string set's members in its junction.
        func projected() throws -> JSONValue {
            try provider.withConnection { connection in
                .array(try connection.query(
                    "SELECT * FROM \"\(spec.table)\" WHERE _meta_doc_id = ? ORDER BY id", [.text(documentId)]
                ).map { row in
                    var object: [String: JSONValue] = ["id": .string(row["id"].stringValue ?? "")]
                    for field in scalars { object[field] = row[field].stringValue.map { .string($0) } ?? .null }
                    let members = try connection.query(
                        "SELECT value FROM \"\(spec.table)__t\" WHERE parent_id = ? AND _meta_doc_id = ? ORDER BY value",
                        [row["id"], .text(documentId)]
                    ).compactMap { $0["value"].stringValue }
                    object["t"] = .array(members.map { .string($0) })
                    return .object(object)
                })
            }
        }
        func viewed() throws -> JSONValue {
            .array(try store.readRowsAfter(model: F.model, after: nil, limit: 1_000_000).map { row in
                var object: [String: JSONValue] = ["id": row["id"] ?? .null]
                for field in scalars {
                    switch row[field] {
                    case .some(.object(let value)): object[field] = .string(RecordLogJSON.text(.object(value)))
                    case .some(.array(let value)): object[field] = .string(RecordLogJSON.text(.array(value)))
                    case .some(.null), .none: object[field] = .null
                    case .some(let value): object[field] = value
                    }
                }
                object["t"] = .array((row["t"]?.arrayValue ?? []).compactMap(\.stringValue).sorted().map { .string($0) })
                return .object(object)
            })
        }
        return try RecordLogLoadTraceReplay.replay(trace, RecordLogLoadTraceReplay.Ops(
            cursor: { try store.marks().cursor },
            pending: { try store.pendingOf(writer) },
            write: { mutations, upsertOn in
                try store.commitEntries(
                    writer: writer, writes: [RecordLogWrite(mutations: mutations, upsertOn: upsertOn)], project: project
                ).entries[0]
            },
            receive: { items in _ = try store.receive(writer: writer, items: items, project: project) },
            refused: { refusal in
                let reply = try store.refused(writer: writer, refusal: refusal, project: project)
                return (reply.handedBack, reply.frames)
            },
            settled: { seq in try store.settled(writer: writer, seq: seq) },
            spill: { try store.spill(writer: writer) },
            notice: { current in try store.setState(writer: writer, notice: (current: current, next: nil, entries: nil)) },
            constraints: { names in try store.setState(writer: writer, constraints: F.constraints(names)) },
            beginCatchUp: { full in try store.beginFencedCatchUp(writer: writer, full: full) },
            page: { rows, gone, generation in
                try fresh(try store.applyCatchUpPage(
                    writer: writer, rows: rows, gone: gone, generation: generation, project: project
                ).stale, "a page")
            },
            complete: { lsn, high, full, generation, receipt in
                try fresh(try store.completeCatchUp(
                    writer: writer, lsn: lsn, high: high, full: full, generation: generation, receipt: receipt, project: project
                ).stale, "a completion")
            },
            beginReceipt: { kind, id in try store.beginReceipt(writer: writer, kind: kind, id: id).attempt },
            loadLines: { attempt, model, lines in
                try fresh(try store.applyLoadChunk(
                    writer: writer, sessionId: "trace", attempt: attempt, model: model, lines: lines, project: project
                ).stale, "a load chunk")
            },
            completeLoad: { attempt, mode, models in
                try fresh(try store.completeLoad(
                    writer: writer, sessionId: "trace", attempt: attempt, mode: mode, models: models, project: project
                ).stale, "a load completion")
            },
            segmentRows: { generation, attempt, rows in
                try fresh(try store.applySegmentChunk(
                    writer: writer, generation: generation, attempt: attempt, rows: rows, project: project
                ).stale, "a segment chunk")
            },
            segmentCorrections: { generation, attempt, lines in
                try fresh(try store.applySegmentCorrections(
                    writer: writer, generation: generation, attempt: attempt, lines: lines, project: project
                ).stale, "the corrections")
            },
            snapshot: { handedBack in
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
        ), check: { _, _ in
            let projectedRows = try projected()
            let viewRows = try viewed()
            return projectedRows == viewRows
                ? nil : "query tables \(F.text(projectedRows)) != view \(F.text(viewRows))"
        })
    }
}
