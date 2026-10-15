import Foundation
@testable import JsBaoClient

/// The golden traces of the record-log client
/// (`tests/perf/overlay-layouts/fixtures/log-traces.json`), read by repository
/// path, and the vocabulary both Swift replays share with the JS ones
/// (`record-log-client-traces-4307.test.ts`, `record-log-trace-replay-4308.ts`).
///
/// The traces were recorded from the model's one-model client: mutations carry
/// no model, writers are strings, and `after` is the client's whole state after
/// each event. Rows are compared sorted by id; objects compare by content.
enum RecordLogTraceFixture {
    /// The one model the traces write.
    static let model = "Note"

    struct Event {
        let t: String
        let input: JSONValue
        let ret: JSONValue?
        let calls: JSONValue
        let after: JSONValue
    }

    struct Trace {
        let id: String
        let initial: JSONValue
        let events: [Event]
    }

    static func load() throws -> [Trace] {
        try schedules(of: "log-traces.json").flatMap(\.clients)
    }

    /// One schedule of a trace file: its clients, and the receipt cases it covers
    /// (`load-traces.json` only).
    struct Schedule {
        let cases: [String]
        let clients: [Trace]
    }

    /// The receipt traces (`tests/perf/overlay-layouts/fixtures/load-traces.json`),
    /// which #4311 recorded with the model in its pointer mode: the golden
    /// traces' kinds and `load`, `loadRemainder` and `segment`.
    static func loadReceiptSchedules() throws -> [Schedule] {
        try schedules(of: "load-traces.json")
    }

    private static func schedules(of file: String) throws -> [Schedule] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // JsBaoClientTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-client
            .deletingLastPathComponent()  // the repository
        let data = try Data(contentsOf: root.appendingPathComponent("tests/perf/overlay-layouts/fixtures/\(file)"))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        return (decoded.arrayValue ?? []).map { schedule in
            Schedule(
                cases: (schedule["cases"]?.arrayValue ?? []).compactMap(\.stringValue),
                clients: (schedule["clients"]?.arrayValue ?? []).map { client in
                    Trace(
                        id: client["id"]?.stringValue ?? "",
                        initial: client["init"] ?? .null,
                        events: (client["events"]?.arrayValue ?? []).map { event in
                            Event(
                                t: event["t"]?.stringValue ?? "",
                                input: event["in"] ?? .null,
                                ret: event["ret"],
                                calls: event["calls"] ?? .array([]),
                                after: event["after"] ?? .null
                            )
                        }
                    )
                }
            )
        }
    }

    // MARK: - The receipt kinds' inputs

    /// The `[id, row]` pairs of a remainder or a segment: rows where a row is given.
    static func rowsOf(_ pairs: JSONValue?) -> [RecordLogCatchUpRow] {
        (pairs?.arrayValue ?? []).compactMap { pair -> RecordLogCatchUpRow? in
            guard let items = pair.arrayValue, let id = items.first?.stringValue,
                  let row = items.dropFirst().first?.objectValue
            else { return nil }
            return RecordLogCatchUpRow(model: model, id: id, row: row)
        }
    }

    /// The `[id, row]` pairs whose row is `null`: records gone.
    static func goneOf(_ pairs: JSONValue?) -> [RecordLogRecordKey] {
        (pairs?.arrayValue ?? []).compactMap { pair -> RecordLogRecordKey? in
            guard let items = pair.arrayValue, let id = items.first?.stringValue,
                  items.dropFirst().first?.objectValue == nil
            else { return nil }
            return RecordLogRecordKey(model: model, id: id)
        }
    }

    /// A load event's chunks, each a model and its `[id, patch]` lines.
    static func loadChunks(_ input: JSONValue) -> [(model: String, lines: [RecordLogLoadLine])] {
        (input["chunks"]?.arrayValue ?? []).map { chunk in
            (
                chunk["model"]?.stringValue ?? model,
                (chunk["lines"]?.arrayValue ?? []).map { line in
                    RecordLogLoadLine(
                        id: line.arrayValue?.first?.stringValue ?? "",
                        patch: line.arrayValue?.dropFirst().first?.objectValue ?? [:]
                    )
                }
            )
        }
    }

    /// One segment chunk's rows, in order.
    static func chunkRows(_ chunk: JSONValue) -> [RecordLogCatchUpRow] {
        (chunk["rows"]?.arrayValue ?? []).map { row in
            RecordLogCatchUpRow(model: chunk["model"]?.stringValue ?? model, id: row["id"]?.stringValue ?? "", row: row.objectValue ?? [:])
        }
    }

    /// A segment event's chunks as the store holds them once it completes
    /// (#4394): each chunk's object, range and row count; the object's name
    /// stands for its digest.
    static func heldSegment(_ input: JSONValue) -> RecordLogHeldSegment {
        let segmentId = input["segmentId"]?.stringValue ?? ""
        return RecordLogHeldSegment(
            segmentId: segmentId,
            chunks: (input["chunks"]?.arrayValue ?? []).enumerated().map { at, chunk in
                let rows = chunk["rows"]?.arrayValue ?? []
                let chunkModel = chunk["model"]?.stringValue ?? model
                let object = chunk["object"]?.stringValue ?? "\(segmentId)/\(chunkModel)/\(at)"
                return RecordLogHeldSegmentChunk(
                    object: object, model: chunkModel, index: chunk["index"]?.wholeNumber ?? at,
                    firstId: chunk["firstId"]?.stringValue ?? rows.first?["id"]?.stringValue ?? "",
                    lastId: chunk["lastId"]?.stringValue ?? rows.last?["id"]?.stringValue ?? "",
                    rows: rows.count, sha256: object
                )
            }
        )
    }

    /// A segment event's chunk rows, every chunk's, in order.
    static func segmentRows(_ input: JSONValue) -> [RecordLogCatchUpRow] {
        (input["chunks"]?.arrayValue ?? []).flatMap { chunk in
            (chunk["rows"]?.arrayValue ?? []).map { row in
                RecordLogCatchUpRow(
                    model: chunk["model"]?.stringValue ?? model, id: row["id"]?.stringValue ?? "", row: row.objectValue ?? [:]
                )
            }
        }
    }

    /// A segment event's corrections: a row, or `nil` for a record deleted.
    static func corrections(_ input: JSONValue) -> [RecordLogCorrection] {
        (input["corrections"]?.arrayValue ?? []).map { pair in
            RecordLogCorrection(
                model: model, id: pair.arrayValue?.first?.stringValue ?? "",
                row: pair.arrayValue?.dropFirst().first?.objectValue
            )
        }
    }

    // MARK: - The model's vocabulary to the product's

    static func mutation(_ json: JSONValue?) -> RecordLogMutation {
        var object = json?.objectValue ?? [:]
        object["model"] = .string(model)
        return RecordLogMutation(json: .object(object))!
    }

    static func modelMutation(_ m: RecordLogMutation) -> JSONValue {
        var object = m.json.objectValue ?? [:]
        object.removeValue(forKey: "model")
        return .object(object)
    }

    /// The model's pending entry, from the product's.
    static func modelPending(_ writer: String, _ entry: RecordLogPendingEntry) -> JSONValue {
        var object: [String: JSONValue] = [
            "w": .string(writer), "seq": .number(Double(entry.seq)), "e": .number(Double(entry.e)),
            "k": .number(Double(entry.k)), "m": modelMutation(entry.m),
        ]
        if let also = entry.also { object["also"] = .array(also.map(modelMutation)) }
        if let upsertOn = entry.upsertOn { object["upsertOn"] = .string(upsertOn) }
        if entry.isVoid { object["void"] = .bool(true) }
        return .object(object)
    }

    static func resultItem(_ input: JSONValue) -> RecordLogResultItem {
        var object = input.objectValue ?? [:]
        // A compact own acknowledgement (#4473) carries no changes.
        if let changes = input["changes"]?.arrayValue {
            object["changes"] = .array(changes.map { change in
                var c = change.objectValue ?? [:]
                c["model"] = .string(model)
                return .object(c)
            })
        }
        if var alias = input["alias"]?.objectValue {
            alias["model"] = .string(model)
            object["alias"] = .object(alias)
        }
        return RecordLogResultItem(json: .object(object))!
    }

    static func refusal(_ out: JSONValue, seq: Int) -> RecordLogRefusal {
        RecordLogRefusal(
            seq: seq,
            code: out["reason"]?.stringValue ?? "",
            scope: RecordLogRefusalScope(rawValue: out["scope"]?.stringValue ?? "") ?? .entry,
            from: Int(out["from"]?.numberValue ?? Double(seq)),
            records: (out["records"]?.arrayValue ?? []).map { record in
                RecordLogRefusedRecord(
                    model: model, id: record["id"]?.stringValue ?? "", from: Int(record["from"]?.numberValue ?? 0)
                )
            }
        )
    }

    static func constraints(_ json: JSONValue?) -> [RecordLogConstraint] {
        (json?.arrayValue ?? []).compactMap(\.stringValue).map { RecordLogConstraint(model: model, name: $0, fields: []) }
    }

    /// The model's resume calls, from the frames a refusal answered.
    static func calls(_ frames: [RecordLogUpFrame]) -> [JSONValue] {
        var calls: [JSONValue] = []
        for frame in frames {
            guard case .resume(let nextSeq, let records) = frame else { continue }
            guard let records else {
                calls.append(.object(["resume": .number(Double(nextSeq))]))
                continue
            }
            for record in records {
                calls.append(.object([
                    "resumeRecord": .string(record.id), "from": .number(Double(record.from)),
                    "nextSeq": .number(Double(nextSeq)),
                ]))
            }
        }
        return calls
    }

    static func rows(_ rows: [RecordLogRow]) -> JSONValue { .array(rows.map { .object($0) }) }

    /// A state as both sides compare it: rows sorted by id, each string set's
    /// members sorted.
    static func comparable(_ state: JSONValue) -> JSONValue {
        guard var object = state.objectValue else { return state }
        for key in ["confirmed", "view"] {
            let rows = (object[key]?.arrayValue ?? []).map { row -> JSONValue in
                guard var fields = row.objectValue else { return row }
                if let members = fields["t"]?.arrayValue {
                    fields["t"] = .array(members.compactMap(\.stringValue).sorted().map { .string($0) })
                }
                return .object(fields)
            }
            object[key] = .array(rows.sorted { ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") })
        }
        return .object(object)
    }

    static func text(_ value: JSONValue) -> String { RecordLogJSON.text(value) }
}
