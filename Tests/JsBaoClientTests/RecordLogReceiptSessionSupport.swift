import CryptoKit
import XCTest
@testable import JsBaoClient

/// A format-3 session over a real store whose connection fetches artifacts
/// from memory, for the receipt's hermetic suites: the Swift twin of js-bao's
/// `tests/helpers/record-log-receipt-4311.ts`. Chunks are the product's
/// formats: a load's are gzip `⟨id⟩\t⟨patch⟩` lines with an ingest manifest
/// (attempt paths, as the record room writes them), a segment's are gzip
/// `⟨id⟩\t⟨row⟩` lines and a corrections chunk naming each line's model.
enum RecordLogReceiptHarness {
    static let documentId = "01JD4312SESS10NL0ADXXXXXXX"

    static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "slug": FieldDescriptor(type: .string, unique: true),
            "t": FieldDescriptor(type: .number),
        ]
    )

    static let timings = RecordLogSessionTimings(
        tickMs: 1, resultGapMs: 150, drainWaitMs: 300, writerTakenRetryMs: 40, catchUpRetryMs: 40,
        replacementWaitMs: 3_000, replacementPollMs: 20
    )

    /// A gate a held fetch waits on until the test opens it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            for waiter in waiting { waiter.resume() }
        }
    }

    /// What a fetch is answered before it reads the artifacts.
    enum Answer: Sendable {
        case pass
        case status(Int)
        case error
        case hold(Gate)
    }

    /// A socket that keeps every frame it is handed and serves artifacts from memory.
    final class Connection: RecordLogConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [[String: JSONValue]] = []
        private var _open = true
        private var _artifacts: [String: Data] = [:]
        private var _fetched: [String] = []
        private var _intercept: (@Sendable (String) -> Answer)?
        let fetches: Bool

        init(fetches: Bool = true) { self.fetches = fetches }

        var frames: [[String: JSONValue]] { lock.withLock { _frames } }
        var fetched: [String] { lock.withLock { _fetched } }
        var isOpen: Bool {
            get { lock.withLock { _open } }
            set { lock.withLock { _open = newValue } }
        }
        func intercept(_ answer: (@Sendable (String) -> Answer)?) { lock.withLock { _intercept = answer } }
        func put(_ path: String, _ data: Data) { lock.withLock { _artifacts[path] = data } }
        func artifact(_ path: String) -> Data? { lock.withLock { _artifacts[path] } }

        func send(_ frame: [String: JSONValue]) { lock.withLock { _frames.append(frame) } }
        func connected() -> Bool { isOpen }
        var fetchesArtifacts: Bool { fetches }

        func fetchArtifact(_ path: String) async throws -> Data {
            let intercept = lock.withLock { () -> (@Sendable (String) -> Answer)? in
                _fetched.append(path)
                return _intercept
            }
            let answer = intercept?(path) ?? .pass
            switch answer {
            case .pass: break
            case .status(let status): throw RecordLogArtifactError(status: status, path: path)
            case .error: throw URLError(.networkConnectionLost)
            case .hold(let gate): await gate.wait()
            }
            guard let bytes = artifact(path) else { throw RecordLogArtifactError(status: 404, path: path) }
            return bytes
        }

        func all(_ type: String) -> [[String: JSONValue]] { frames.filter { $0["type"]?.stringValue == type } }
    }

    /// Lines the logger's test seam heard about this document.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(level: LogLevel, message: String)] = []
        func append(_ level: LogLevel, _ message: String) { lock.withLock { lines.append((level, message)) } }
        var all: [(level: LogLevel, message: String)] { lock.withLock { lines } }
        func messages(_ level: LogLevel? = nil) -> [String] {
            all.filter { level == nil || $0.level == level }.map(\.message)
        }
        func contains(_ prefix: String, level: LogLevel? = nil) -> Bool {
            messages(level).contains { $0.hasPrefix(prefix) }
        }
    }

    /// One session over a fresh (or given) store, its frames captured.
    final class Fixture: @unchecked Sendable {
        let provider: SQLiteStorageProvider
        let binding: RecordLogDocumentBinding
        let session: RecordLogSession
        let connection: Connection
        let synced = LockedBox(0)
        let progress = LockedBox(0)
        let failed = LockedBox<[String]>([])
        private var grants = 0

        init(provider: SQLiteStorageProvider, clientId: String, fetches: Bool, timings: RecordLogSessionTimings) async throws {
            self.provider = provider
            binding = try RecordLogDocumentBinding(
                host: provider, documentId: RecordLogReceiptHarness.documentId, clientId: clientId,
                engine: BaoModelQueryEngine(host: provider), logger: Logger(level: .none)
            )
            try binding.registerModel(RecordLogReceiptHarness.schema)
            let connection = Connection(fetches: fetches)
            self.connection = connection
            let synced = self.synced
            let progress = self.progress
            let failed = self.failed
            session = RecordLogSession(
                documentId: RecordLogReceiptHarness.documentId, binding: binding,
                host: RecordLogSessionHost(
                    connection: { connection },
                    declarations: { [:] },
                    synced: { _ in synced.withValue { $0 += 1 } },
                    syncFailed: { _, reason in failed.withValue { $0.append(reason) } },
                    progress: { _ in progress.withValue { $0 += 1 } }
                ),
                timings: timings, logger: Logger(level: .verbose)
            )
            await session.attach()
        }

        func feed(_ frame: [String: JSONValue]) async {
            var frame = frame
            frame["documentId"] = .string(RecordLogReceiptHarness.documentId)
            await session.receive(frame)
        }

        func of(_ type: String) -> [[String: JSONValue]] { connection.all(type) }

        /// A load's second chunk has been asked for `times` times. Chunks are
        /// fetched one after another, so the first one is applied by then;
        /// progress counts cannot say so, since every step of a chunk reports it.
        func secondChunkHeld(times: Int = 1) -> Bool {
            connection.fetched.filter { $0.hasSuffix("/Note/1.ATTEMPT1") }.count >= times
        }

        var marks: RecordLogMarks { (try? binding.refreshMarks())! }

        func read(_ id: String, _ model: String = "Note") throws -> RecordLogRow? {
            try binding.store.read(model: model, id: id)
        }

        @discardableResult
        func save(_ id: String, _ fields: [String: JSONValue]) throws -> Int {
            let entry = try binding.commit([RecordLogWrite(mutations: [
                RecordLogMutation(model: "Note", id: id, kind: .create, fields: fields),
            ])])[0]
            try binding.store.flush()
            return entry.seq
        }

        /// Publish a load's manifest and chunks behind a grant; answers its
        /// `record.load complete` fields. `chunks` are in manifest order.
        func publishLoad(
            sessionId: String, chunks: [(model: String, lines: [(String, [String: JSONValue])])],
            firstLsn: Int?, lastLsn: Int?, mode: String = "merge", models: [String]? = nil, epoch: Int = 4, k: Int = 0,
            refusedRows: Int = 0
        ) -> [String: JSONValue] {
            grants += 1
            let base = "/doc-artifact/grant\(grants)"
            var listed: [JSONValue] = []
            var rows = 0
            for (ordinal, chunk) in chunks.enumerated() {
                let text = chunk.lines.map { "\($0.0)\t\(RecordLogJSON.text(.object($0.1)))\n" }.joined()
                let raw = Data(text.utf8)
                let body = GzipFixture.gzip(raw)
                let path = "\(chunk.model)/\(ordinal).ATTEMPT\(ordinal)"
                connection.put("\(base)/\(path)", body)
                rows += chunk.lines.count
                listed.append(.object([
                    "ordinal": .number(Double(ordinal)), "model": .string(chunk.model), "index": .number(Double(ordinal)),
                    "rows": .number(Double(chunk.lines.count)), "bytes": .number(Double(body.count)),
                    "rawBytes": .number(Double(raw.count)), "sha256": .string(RecordLogReceiptHarness.sha256(body)),
                    "firstId": .string(chunk.lines.first?.0 ?? ""), "lastId": .string(chunk.lines.last?.0 ?? ""),
                    "path": .string(path), "key": .string("k/\(path)"),
                ]))
            }
            let manifest: JSONValue = .object([
                "kind": "ingest", "version": 1, "sessionId": .string(sessionId),
                "documentId": .string(RecordLogReceiptHarness.documentId), "chunks": .array(listed),
                "totals": .object(["rows": .number(Double(rows))]),
            ])
            connection.put(base, Data(RecordLogJSON.text(manifest).utf8))
            let named = models ?? Array(Set(chunks.map(\.model))).sorted()
            return [
                "sessionId": .string(sessionId), "mode": .string(mode), "models": .array(named.map { .string($0) }),
                "epoch": .number(Double(epoch)), "k": .number(Double(k)),
                "firstLsn": firstLsn.map { .number(Double($0)) } ?? .null,
                "lastLsn": lastLsn.map { .number(Double($0)) } ?? .null,
                "rows": .number(Double(rows)), "refusedRows": .number(Double(refusedRows)),
                "download": .object(["path": .string(base), "expiresAt": 9_999_999_999_999]),
                "chunkCount": .number(Double(chunks.count)),
            ]
        }

        /// Publish a segment's row chunk and corrections behind a grant; answers its pointer.
        func publishSegment(
            segmentId: String, lsn: Int, completedLsn: Int, rows: [[String: JSONValue]],
            corrections: [(String, [String: JSONValue])]
        ) -> JSONValue {
            grants += 1
            let base = "/doc-artifact/grant\(grants)"
            let text = rows.map { "\($0["id"]?.stringValue ?? "")\t\(RecordLogJSON.text(.object($0)))\n" }.joined()
            let raw = Data(text.utf8)
            let body = GzipFixture.gzip(raw)
            connection.put("\(base)/Note/0", body)
            let correctionsText = corrections.map { "\($0.0)\t\(RecordLogJSON.text(.object($0.1)))\n" }.joined()
            let correctionsRaw = Data(correctionsText.utf8)
            let correctionsBody = GzipFixture.gzip(correctionsRaw)
            connection.put("\(base)/corrections", correctionsBody)
            return .object([
                "segmentId": .string(segmentId), "lsn": .number(Double(lsn)), "completedLsn": .number(Double(completedLsn)),
                "rows": .number(Double(rows.count)),
                "download": .object(["path": .string(base), "expiresAt": 9_999_999_999_999]),
                "chunks": .array([.object([
                    "model": "Note", "index": 0, "path": "Note/0", "rows": .number(Double(rows.count)),
                    "bytes": .number(Double(body.count)), "rawBytes": .number(Double(raw.count)),
                    "sha256": .string(RecordLogReceiptHarness.sha256(body)),
                    "firstId": rows.first?["id"] ?? "", "lastId": rows.last?["id"] ?? "",
                ])]),
                "corrections": .object([
                    "rows": .number(Double(corrections.count)), "bytes": .number(Double(correctionsBody.count)),
                    "rawBytes": .number(Double(correctionsRaw.count)),
                    "sha256": .string(RecordLogReceiptHarness.sha256(correctionsBody)), "path": "corrections",
                ]),
            ])
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A `record.opened` frame.
    static func opened(
        lsn: Int = 0, current: Int = 1, high: Int? = nil, catchUp: JSONValue? = nil
    ) -> [String: JSONValue] {
        [
            "type": "record.opened", "lsn": .number(Double(lsn)), "lastSeq": 0,
            "epochs": .object([
                "current": .number(Double(current)), "next": .number(Double(current + 1)), "floor": 0, "entries": 10_000,
                "high": .number(Double(high ?? current)),
            ]),
            "cursorFloor": 0, "constraints": [],
            "catchUp": catchUp ?? .object(["mode": "inline", "rows": [], "gone": [], "lsn": .number(Double(lsn)), "upTo": .number(Double(lsn))]),
        ]
    }

    static func page(rows: [JSONValue] = [], gone: [JSONValue] = [], lsn: Int, next: JSONValue? = nil, restart: Bool = false) -> [String: JSONValue] {
        var frame: [String: JSONValue] = ["type": "record.catchUpPage", "rows": .array(rows), "gone": .array(gone), "lsn": .number(Double(lsn))]
        if let next { frame["next"] = next }
        if restart { frame = ["type": "record.catchUpPage", "restart": true] }
        return frame
    }

    static func row(_ id: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var row = fields
        row["id"] = .string(id)
        return .object(["model": "Note", "id": .string(id), "row": .object(row)])
    }

    static func gone(_ id: String) -> JSONValue { .object(["model": "Note", "id": .string(id)]) }

    static func results(_ items: [JSONValue]) -> [String: JSONValue] {
        ["type": "record.results", "results": .array(items)]
    }

    static func result(_ l: Int, _ id: String, _ fields: [String: JSONValue] = [:], e: Int = 1, w: String? = nil, seq: Int? = nil) -> JSONValue {
        var row = fields
        row["id"] = .string(id)
        var object: [String: JSONValue] = [
            "l": .number(Double(l)), "e": .number(Double(e)),
            "changes": [.object(["model": "Note", "id": .string(id), "row": .object(row)])],
        ]
        if let w { object["w"] = .string(w) }
        if let seq { object["seq"] = .number(Double(seq)) }
        return .object(object)
    }

    static func load(_ phase: String, _ fields: [String: JSONValue]) -> [String: JSONValue] {
        var frame = fields
        frame["type"] = "record.load"
        frame["phase"] = .string(phase)
        return frame
    }

    static func started(_ sessionId: String) -> [String: JSONValue] {
        load("started", ["sessionId": .string(sessionId), "mode": "merge", "models": ["Note"], "epoch": 4, "k": 0])
    }
}
