import Foundation
import JsBaoSQLite

/// One training run's answer (#5230): vec1's model bytes, and vec1's version
/// (`0.8`), which the model's envelope names.
struct RecordLogVec1Trained: Sendable {
    var model: Data
    var vec1: String
}

/// What trains a device vector index's model off the store's queue (#5230):
/// vec1's `vec1_train` over a sample, on a detached task with its own
/// in-memory connection to the bundled SQLite, so the provider's serial queue
/// answers the store's queries while a model trains (seconds to minutes on a
/// large index). js-bao's `Vec1Trainer` (a `worker_threads` worker on Node).
/// The connection is closed however the run ends; a training vec1 refuses
/// throws with its message.
///
/// One run at a time: a client's trainer holds one permit, and a run asked
/// for while another trains waits its turn (vec1 trains on several threads
/// and over a sample of up to 100 vectors per bucket, so two at once would
/// contend for the cores and the memory the app answers with).
///
/// `@unchecked Sendable`: `count`, `started`, `holding` and `waiting` are
/// read and written under `lock` only.
final class RecordLogVec1Trainer: @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0
    private var started = 0
    /// Whether a run holds the permit, and the runs waiting for it, first come first.
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// How many runs are under way.
    var running: Int { lock.withLock { count } }

    /// How many runs began since this trainer was made.
    var runs: Int { lock.withLock { started } }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// How many runs wait for the one under way (a test's view).
    var queued: Int { lock.withLock { waiting.count } }

    /// Why a run that waited its turn did not train: its caller no longer wants it.
    static let unwanted = "the training is no longer wanted"

    /// Train a model over `sample`'s vectors with its params, once no other
    /// run of this trainer is under way. `wanted` is asked when the run's
    /// turn comes: a run no longer wanted then throws ``unwanted`` and trains
    /// nothing.
    func train(_ sample: RecordLogVectorSample, wanted: @Sendable () -> Bool = { true }) async throws -> RecordLogVec1Trained {
        await acquire()
        defer { release() }
        guard wanted() else { throw Failure(message: Self.unwanted) }
        lock.withLock {
            count += 1
            started += 1
        }
        defer { lock.withLock { count -= 1 } }
        let config = RecordLogVectorIndex.trainConfig(distance: sample.distance, sample.params)
        return try await Task.detached(priority: .utility) {
            try Self.run(vectors: sample.vectors, count: sample.count, dims: sample.dims, config: config)
        }.value
    }

    private func acquire() async {
        await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if holding {
                    waiting.append(turn)
                    return false
                }
                holding = true
                return true
            }
            if now { turn.resume() }
        }
    }

    /// The permit passes to the first run waiting, or is free.
    private func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiting.isEmpty {
                holding = false
                return nil
            }
            return waiting.removeFirst()
        }
        next?.resume()
    }

    /// The run itself, on the calling thread: open, insert the sample, train, answer.
    static func run(vectors: Data, count: Int, dims: Int, config: String) throws -> RecordLogVec1Trained {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw Failure(message: "vec1 did not train the model: the trainer's connection could not be opened")
        }
        defer { sqlite3_close_v2(db) }
        let fail = { (what: String) in Failure(message: "vec1 did not train the model: \(what): \(String(cString: sqlite3_errmsg(db)))") }
        guard sqlite3_exec(db, "CREATE TEMP TABLE sample (vector BLOB)", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK
        else { throw fail("the sample table") }
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO sample (vector) VALUES (?)", -1, &insert, nil) == SQLITE_OK else { throw fail("the sample's insert") }
        defer { sqlite3_finalize(insert) }
        let width = dims * 4
        try vectors.withUnsafeBytes { raw in
            for index in 0..<count {
                guard let base = raw.baseAddress, (index + 1) * width <= raw.count else { break }
                sqlite3_bind_blob(insert, 1, base + index * width, Int32(width), transient)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw fail("the sample's insert") }
                sqlite3_reset(insert)
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw fail("the sample") }
        var train: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT vec1_train(vector, ?) AS m, vec1_info() AS info FROM sample", -1, &train, nil) == SQLITE_OK else {
            throw fail("vec1_train")
        }
        defer { sqlite3_finalize(train) }
        _ = config.withCString { sqlite3_bind_text(train, 1, $0, -1, transient) }
        guard sqlite3_step(train) == SQLITE_ROW else { throw fail("vec1_train") }
        let length = Int(sqlite3_column_bytes(train, 0))
        guard sqlite3_column_type(train, 0) == SQLITE_BLOB, length > 0, let bytes = sqlite3_column_blob(train, 0) else {
            throw Failure(message: "vec1 did not train the model: no model")
        }
        let model = Data(bytes: bytes, count: length)
        let info = sqlite3_column_text(train, 1).map { String(cString: $0) } ?? ""
        return RecordLogVec1Trained(model: model, vec1: RecordLogVectorIndex.vec1Version(of: info))
    }
}
