import Foundation
import XCTest
@testable import JsBaoClient

/// What the live receipt suites watch on a Swift client: the record frames it
/// is routed (with when), the frames its sessions send, its artifact reads
/// (held back on demand, every one recorded with its answer), and its rows
/// against the room's. The Swift twin of js-bao's
/// `tests/helpers/record-log-receipt-live-4311.ts`, through the client's test
/// seams.
final class RecordLogClientWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [(at: Date, frame: [String: JSONValue])] = []
    private var _sent: [[String: JSONValue]] = []
    private var _fetched: [(path: String, status: Int)] = []
    private var hold: (match: @Sendable (String) -> Bool, gate: RecordLogReceiptHarness.Gate, reached: RecordLogReceiptHarness.Gate)?
    private var failNext: (match: @Sendable (String) -> Bool, status: Int, times: Int)?

    init(_ client: JsBaoClient) {
        client.recordLogFrameForTest = { [weak self] frame in self?.record(frame) }
        client.recordLogFrameSentForTest = { [weak self] text in
            guard let frame = RecordLogJSON.parse(text)?.objectValue else { return }
            self?.lock.withLock { self?._sent.append(frame) }
        }
        client.recordLogArtifactFetchForTest = { [weak self] path in
            guard let self else { return }
            let held = self.lock.withLock { () -> (RecordLogReceiptHarness.Gate, RecordLogReceiptHarness.Gate)? in
                guard let hold = self.hold, hold.match(path) else { return nil }
                self.hold = nil
                return (hold.gate, hold.reached)
            }
            if let (gate, reached) = held {
                reached.open()
                await gate.wait()
            }
            let failing = self.lock.withLock { () -> Int? in
                guard var fail = self.failNext, fail.match(path), fail.times > 0 else { return nil }
                fail.times -= 1
                self.failNext = fail
                self._fetched.append((path, fail.status))
                return fail.status
            }
            if let failing { throw RecordLogArtifactError(status: failing, path: path) }
            self.lock.withLock { self._fetched.append((path, 0)) }
        }
        client.recordLogArtifactStatusForTest = { [weak self] path, status in
            guard let self else { return }
            self.lock.withLock {
                if let at = self._fetched.lastIndex(where: { $0.path == path && $0.status == 0 }) {
                    self._fetched[at].status = status ?? -1
                }
            }
        }
    }

    /// Keep a frame the client was routed: for a test that hooks the routing itself.
    func record(_ frame: [String: JSONValue]) {
        lock.withLock { _received.append((Date(), frame)) }
    }

    var received: [(at: Date, frame: [String: JSONValue])] { lock.withLock { _received } }
    var sent: [[String: JSONValue]] { lock.withLock { _sent } }
    /// Every artifact read, with the status it was answered (0 while in flight).
    var fetched: [(path: String, status: Int)] { lock.withLock { _fetched } }

    func received(_ type: String, phase: String? = nil) -> [(at: Date, frame: [String: JSONValue])] {
        received.filter { $0.frame["type"]?.stringValue == type && (phase == nil || $0.frame["phase"]?.stringValue == phase) }
    }

    func sent(_ type: String) -> [[String: JSONValue]] { sent.filter { $0["type"]?.stringValue == type } }

    /// Hold the next read whose path matches until the answered gate opens;
    /// answers the gate to open and one that opens when the read is reached.
    func holdNext(_ match: @escaping @Sendable (String) -> Bool) -> (release: RecordLogReceiptHarness.Gate, reached: RecordLogReceiptHarness.Gate) {
        let gate = RecordLogReceiptHarness.Gate()
        let reached = RecordLogReceiptHarness.Gate()
        lock.withLock { hold = (match, gate, reached) }
        return (gate, reached)
    }

    /// Answer the next `times` reads whose path matches with `status`, without sending them.
    func fail(_ match: @escaping @Sendable (String) -> Bool, status: Int, times: Int = 1) {
        lock.withLock { failNext = (match, status, times) }
    }
}

extension RecordLogLiveApp {
    /// The room's live rows of `model`, by id, as it keeps them (`table`).
    func roomTable(_ documentId: String, _ model: String) async throws -> [String: [String: JSONValue]] {
        let table = try await route(documentId, "table")
        var out: [String: [String: JSONValue]] = [:]
        for record in table["records"] as? [[String: Any]] ?? [] {
            guard (record["dead"] as? NSNumber)?.intValue == 0, record["model"] as? String == model,
                  let id = record["id"] as? String, let data = record["data"] as? String
            else { continue }
            out[id] = RecordLogJSON.parse(data)?.objectValue ?? [:]
        }
        return out
    }

    /// The client's rows of `model` as a query answers them, by id.
    func localRows(_ client: JsBaoClient, _ documentId: String, _ model: String) throws -> [String: [String: JSONValue]] {
        let rows = try member(client, documentId, model).query(nil, options: QueryOptions(limit: 1_000_000))
        var out: [String: [String: JSONValue]] = [:]
        for row in rows { if let id = row["id"]?.stringValue { out[id] = row } }
        return out
    }

    /// The first difference between the client's rows and the room's on `fields`, or `nil`.
    func differs(_ client: JsBaoClient, _ documentId: String, _ model: String, _ fields: [String]) async throws -> String? {
        let room = try await roomTable(documentId, model)
        let local = try localRows(client, documentId, model)
        if room.count != local.count { return "room \(room.count) rows, client \(local.count)" }
        for (id, row) in room {
            guard let mine = local[id] else { return "client lacks \(id)" }
            for field in fields {
                let a = row[field] ?? .null
                let b = mine[field] ?? .null
                if a != b { return "\(id).\(field): room \(RecordLogJSON.text(a)), client \(RecordLogJSON.text(b))" }
            }
        }
        return nil
    }

    /// Wait until the client equals the room on `fields`.
    func untilEqual(
        _ client: JsBaoClient, _ documentId: String, _ model: String, _ fields: [String], timeout: TimeInterval = 30,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String? = "never compared"
        while Date() < deadline {
            last = try await differs(client, documentId, model, fields)
            if last == nil { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("the client to equal the room: \(last ?? "")", file: file, line: line)
    }

    /// The room's log number.
    func roomLsn(_ documentId: String) async throws -> Int {
        (try await route(documentId, "state")["lsn"] as? NSNumber)?.intValue ?? -1
    }

    /// A store's marks, read again.
    func marks(_ client: JsBaoClient, _ documentId: String) throws -> RecordLogMarks {
        try binding(client, documentId).refreshMarks()
    }
}
