import Foundation

/// What a store wants for one `ann` entry (#5230): its room's model fetched,
/// or one trained here. js-bao's `RecordLogVectorWant`.
struct RecordLogVectorWant: Equatable, Sendable {
    enum Kind: String, Sendable { case fetch, train }

    var name: String
    var want: Kind
    /// The index's generation and revision a claim and an upload name, or
    /// the listed model's a fetch is for; `nil` on a local-only db3.
    var generation: Int?
    var revision: Int?
    /// The buckets the model is trained with (a `train` want).
    var nbucket: Int?
    /// The live rows the device holds (a `train` want).
    var rows: Int?
    /// A local-only db3's model is trained and installed here, with no request.
    var localOnly: Bool = false

    /// The want with its rows left out: a want is the same want however many rows its device holds since.
    var identity: RecordLogVectorWant {
        var out = self
        out.rows = nil
        return out
    }
}

/// What an install did (#5230): its fill began, the model was refused (with
/// why), the entry is not the one it was for, or the device failed it (a
/// full disk, a locked or unwritable file), when the same model is installed
/// again later. js-bao's `RecordLogVectorInstall`.
struct RecordLogVectorInstall: Equatable, Sendable {
    enum Outcome: String, Sendable { case building, refused, stale, failed }

    var name: String
    var outcome: Outcome
    var reason: String?
}

/// A training run's input (#5230): the index's identity, the params it trains
/// with, and its sample, `count` vectors of `dims` binary32 numbers one after
/// another. js-bao's `RecordLogVectorSample`.
struct RecordLogVectorSample: Sendable {
    var name: String
    var generation: Int?
    var revision: Int?
    var dims: Int
    var distance: String
    /// The live rows the device holds.
    var rows: Int
    var params: RecordLogVectorTrainingParams
    var vectors: Data
    var count: Int
}

/// A db3's device vector indexes' shared ANN models in the store (#5230), the
/// Swift port of js-bao's `vectorModels.ts`: what each `ann` entry wants (a
/// model to fetch, or one to train), the sample a training run reads, the
/// install of a model the envelope check admits, the fill of its ANN table
/// from the flat table in slices, and its invalidation.
///
/// The flat table is never dropped while the index exists, so a `$near`
/// always has an exact answer: an install creates the ANN table empty, has
/// vec1 rebuild it with the model, writes the triggers so they keep both
/// tables, and leaves the copy of the flat table's rows to
/// ``continueVectorFill()``, a slice at a time in a command of its own,
/// between which the store answers its queries exactly. Once the copy ends
/// the entry's mode is `ann`. An invalidation drops the ANN table and rewrites
/// the triggers in one transaction: the next query answers exactly.
extension RecordLogStore {

    /// SQLite's messages for a failure of the device's storage rather than of
    /// the bytes (js-bao's `isVectorStorageFailure`): such a failure says
    /// nothing of the model, so the model is not refused.
    static func isVectorStorageFailure(_ error: Error) -> Bool {
        let message = RecordLogIndexes.message(error)
        return message.range(
            of: #"database or disk is full|disk I/O error|database is locked|database table is locked|readonly database|unable to open database file|^interrupted$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func entryNamed(_ sql: RecordLogSql, _ name: String) throws -> Format2SqlRow? {
        try RecordLogIndexes.cachedVectorRows(sql, documentId: documentId).first { $0["room_name"].stringValue == name }
    }

    /// How many records of the entry's model the device holds.
    private func liveRows(_ sql: RecordLogSql, _ row: Format2SqlRow) throws -> Int {
        try sql.first("SELECT COUNT(*) AS n FROM record_log_view WHERE doc_id = ? AND _type = ?", [row["doc_id"], row["model"]])?["n"].intValue ?? 0
    }

    /// Write the entry's triggers to keep `tables`.
    private func writeTriggers(_ sql: RecordLogSql, _ row: Format2SqlRow, _ options: [String: JSONValue], _ tables: [String]) throws {
        guard let vector = RecordLogVectorOptions(cached: options["vector"]) else { return }
        for suffix in RecordLogVectorIndex.triggerSuffixes {
            try sql.connection.executeScript("DROP TRIGGER IF EXISTS \(RecordLogVectorIndex.quoted("\(tables[0])\(suffix)"))")
        }
        for statement in RecordLogVectorIndex.triggersDDL(tables, RecordLogIndexes.vectorTarget(row, vector)) {
            try sql.connection.executeScript(statement)
        }
    }

    /// Whether a training run of the entry's revision is under way, its mark younger than a claim's life.
    private static func trainingHeld(_ options: [String: JSONValue], now: Int64) -> Bool {
        guard let training = options["training"]?.objectValue, let at = training["at"]?.numberValue else { return false }
        return Double(now) - at < RecordLogVectorIndex.claimSeconds * 1000 && training["revision"] == options["revision"]
    }

    /// When the earliest training mark among the db3's `ann` entries lapses
    /// (epoch ms), `nil` with none held. A mark outlives the run that took it
    /// when its client closed or crashed mid-run, and no command may come to
    /// evaluate the wants again once it lapses, so the jobs wake then.
    func vectorTrainingLapse(now: Int64? = nil) throws -> Int64? {
        let now = now ?? Self.now()
        return try reading { sql in
            try RecordLogIndexes.cachedVectorRows(sql, documentId: documentId).compactMap { row -> Int64? in
                let options = RecordLogIndexes.optionsOf(row)
                guard Self.trainingHeld(options, now: now), let at = options["training"]?["at"]?.numberValue else { return nil }
                return Int64(at) + Int64(RecordLogVectorIndex.claimSeconds * 1000)
            }.min()
        }
    }

    /// What the db3 wants for each of its `ann` vector entries, in name
    /// order (js-bao's `vectorModelWants`). Nothing for an entry that is
    /// `exact`, declined, not built, being filled, or whose model is installed
    /// and current; nothing either while a training run of it is marked here,
    /// unless the room lists a model; then on a synced db3 `fetch` when the
    /// room lists a model this device neither holds nor refused, and `train`
    /// when it lists none, none was refused at the index's revision, and the
    /// device holds at least `max(4·nbucket, 1000)` live rows; on a
    /// local-only db3 `train` likewise when no model is installed or refused.
    func vectorModelWants(now: Int64? = nil) throws -> [RecordLogVectorWant] {
        let now = now ?? Self.now()
        return try reading { sql in
            var wants: [RecordLogVectorWant] = []
            for row in try RecordLogIndexes.cachedVectorRows(sql, documentId: documentId) {
                guard !row["vector"].isNull, RecordLogIndexes.disposition(row, deviceIndexes) != .decline else { continue }
                let options = RecordLogIndexes.optionsOf(row)
                guard let vector = RecordLogVectorOptions(cached: options["vector"]), vector.isAnn, options["unbuilt"] == nil, options["fill"] == nil
                else { continue }
                let held = Self.trainingHeld(options, now: now)
                let name = row["room_name"].stringValue ?? ""
                let localOnly = row["local_only"].intValue == 1
                let generation = RecordLogVectorIndex.integer(options["generation"])
                let revision = RecordLogVectorIndex.integer(options["revision"])
                if localOnly {
                    if held || options["ann"] != nil || options["refused"] != nil { continue }
                } else {
                    guard let generation, let revision else { continue }
                    if let listed = options["annModel"]?.objectValue {
                        let listedRevision = RecordLogVectorIndex.integer(listed["revision"])
                        if let ann = options["ann"]?.objectValue, RecordLogVectorIndex.integer(ann["generation"]) == generation,
                           RecordLogVectorIndex.integer(ann["revision"]) == listedRevision { continue }
                        if let refused = options["refused"]?.objectValue, RecordLogVectorIndex.integer(refused["generation"]) == generation,
                           RecordLogVectorIndex.integer(refused["revision"]) == listedRevision { continue }
                        wants.append(RecordLogVectorWant(name: name, want: .fetch, generation: generation, revision: listedRevision))
                        continue
                    }
                    if held || options["ann"] != nil { continue }
                    if let refused = options["refused"]?.objectValue, RecordLogVectorIndex.integer(refused["generation"]) == generation,
                       RecordLogVectorIndex.integer(refused["revision"]) == revision { continue }
                }
                let rows = try liveRows(sql, row)
                let nbucket = RecordLogVectorIndex.wantedNbucket(vector.index, rows: rows)
                if rows < RecordLogVectorIndex.minRows(nbucket: nbucket) { continue }
                wants.append(RecordLogVectorWant(
                    name: name, want: .train, generation: localOnly ? nil : generation, revision: localOnly ? nil : revision,
                    nbucket: nbucket, rows: rows, localOnly: localOnly
                ))
            }
            return wants.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
        }
    }

    /// Whether the db3 holds an `ann` vector entry whose want can change with its rows: one with no model installed or being filled.
    func vectorModelsAwaited() throws -> Bool {
        try reading { sql in
            try RecordLogIndexes.cachedVectorRows(sql, documentId: documentId).contains { row in
                let options = RecordLogIndexes.optionsOf(row)
                return !row["vector"].isNull && RecordLogVectorOptions(cached: options["vector"])?.isAnn == true && options["ann"] == nil
            }
        }
    }

    /// The sample a training run of `name` reads: up to 100 vectors per bucket
    /// of the params it trains with, as binary32, chosen at random among the
    /// flat table's rows. The entry is marked as training here, so the store
    /// wants nothing more of it until the run installs its model, fails
    /// (``releaseVectorTraining(_:)``) or a claim's life passes; `nil` while
    /// another run's mark holds (a second client of the file heard the same
    /// want), so one store trains once.
    ///
    /// - Throws: `JsBaoError(.invalidArgument)` when `name` is no built `ann` vector entry of the db3.
    func vectorTrainingSample(_ name: String, now: Int64? = nil) throws -> RecordLogVectorSample? {
        let now = now ?? Self.now()
        return try command { sql in
            guard let row = try entryNamed(sql, name), let flat = row["vector"].stringValue,
                  let vector = RecordLogVectorOptions(cached: RecordLogIndexes.optionsOf(row)["vector"]), vector.isAnn
            else {
                throw JsBaoError(code: .invalidArgument, message: "[record-log] \(documentId): \(name) is no built ann vector index to train")
            }
            var options = RecordLogIndexes.optionsOf(row)
            if Self.trainingHeld(options, now: now) { return nil }
            let rows = try liveRows(sql, row)
            let params = RecordLogVectorIndex.trainingParams(vector.index, dims: vector.dims, rows: rows)
            let wanted = min(rows, RecordLogVectorIndex.samplePerBucket * params.nbucket)
            var vectors = Data()
            var count = 0
            for picked in try sql.rows("SELECT vector FROM \(RecordLogVectorIndex.quoted(flat)) ORDER BY random() LIMIT ?", [.integer(Int64(wanted))]) {
                guard case .blob(let bytes) = picked["vector"], bytes.count == vector.dims * 4 else { continue }
                vectors.append(bytes)
                count += 1
            }
            var training: [String: JSONValue] = ["at": .number(Double(now))]
            if let generation = options["generation"] { training["generation"] = generation }
            if let revision = options["revision"] { training["revision"] = revision }
            options["training"] = .object(training)
            try RecordLogIndexes.writeVectorOptions(sql, row, options, flat)
            return RecordLogVectorSample(
                name: name, generation: RecordLogVectorIndex.integer(options["generation"]), revision: RecordLogVectorIndex.integer(options["revision"]),
                dims: vector.dims, distance: vector.distance, rows: rows, params: params, vectors: vectors, count: count
            )
        }
    }

    /// A training run of `name` ended without a model: its want comes back.
    func releaseVectorTraining(_ name: String) throws {
        try command { sql in
            guard let row = try entryNamed(sql, name) else { return }
            let options = RecordLogIndexes.optionsOf(row)
            guard options["training"] != nil else { return }
            try RecordLogIndexes.writeVectorOptions(sql, row, RecordLogIndexes.removing(options, "training"), row["vector"].stringValue)
        }
    }

    /// Why a model of `generation` and `revision` is not for the entry
    /// (js-bao's `installVectorModel`'s stale answers), or `nil` when it is.
    private static func installStaleness(_ row: Format2SqlRow, _ options: [String: JSONValue], generation: Int?, revision: Int?) -> String? {
        guard RecordLogVectorOptions(cached: options["vector"])?.isAnn == true else { return "not an ann vector index" }
        if row["vector"].isNull || options["unbuilt"] != nil { return "the vector index is not built on this device" }
        guard row["local_only"].intValue != 1 else { return nil }
        let current = RecordLogVectorIndex.integer(options["generation"])
        if generation != current {
            return "the model is for generation \(generation.map(String.init) ?? "undefined"), the index is at \(current.map(String.init) ?? "undefined")"
        }
        let at = RecordLogVectorIndex.integer(options["revision"])
        if revision == nil || (at != nil && revision! < at!) {
            return "the model is for revision \(revision.map(String.init) ?? "undefined"), the index is at \(at.map(String.init) ?? "undefined")"
        }
        return nil
    }

    /// `name`'s entry as it stands now, read in the caller's transaction,
    /// when it is still the one `row` and `options` were read as: the same
    /// flat table and vector options, and `still` holding of it now. `nil`
    /// once an index list or another command moved it on, so a write made
    /// for the entry as it was read writes nothing over what it is now.
    private func currentVectorEntry(
        _ sql: RecordLogSql, _ name: String, as row: Format2SqlRow, _ options: [String: JSONValue],
        still: (Format2SqlRow, [String: JSONValue]) -> Bool
    ) throws -> (row: Format2SqlRow, options: [String: JSONValue])? {
        guard let now = try entryNamed(sql, name) else { return nil }
        let nowOptions = RecordLogIndexes.optionsOf(now)
        guard now["vector"] == row["vector"], nowOptions["vector"] == options["vector"], still(now, nowOptions) else { return nil }
        return (now, nowOptions)
    }

    /// Install a model for `name` (js-bao's `installVectorModel`). Answered
    /// `stale` for an entry that is not a built `ann` vector index of the
    /// model's generation (or one whose revision the room has moved past);
    /// `refused` with why, recorded so it is not fetched again at that
    /// revision and warned about once, when ``RecordLogVectorModelCheck`` or
    /// vec1 refuses the body; `failed`, with nothing recorded, when the
    /// device's storage fails the install, so the same model is wanted again;
    /// otherwise the entry's ANN table (an earlier one dropped) is rebuilt
    /// with the model, its triggers keep both tables, and its fill begins
    /// (`building`). `generation` and `revision` are the ones the bytes were
    /// fetched under (the `GET` answer's headers) or trained under.
    func installVectorModel(_ name: String, generation: Int?, revision: Int?, bytes: Data, source: String) throws -> RecordLogVectorInstall {
        let stale = { (reason: String) in RecordLogVectorInstall(name: name, outcome: .stale, reason: reason) }
        // The entry as the check judges the bytes against it. Each write below
        // reads it again in its own transaction and goes ahead only while it
        // still is this entry (``currentVectorEntry``): an index list applied
        // between them (a delete, a re-registration) is never written over.
        let read = try reading { sql -> (row: Format2SqlRow, options: [String: JSONValue])? in
            guard let row = try entryNamed(sql, name) else { return nil }
            return (row, RecordLogIndexes.optionsOf(row))
        }
        guard let (row, options) = read else { return stale("no such vector index") }
        if let reason = Self.installStaleness(row, options, generation: generation, revision: revision) { return stale(reason) }
        guard let vector = RecordLogVectorOptions(cached: options["vector"]) else { return stale("not an ann vector index") }
        let vec1 = try reading { try RecordLogVectorIndex.engineVec1Version($0) }
        let outcome = RecordLogVectorModelCheck.check(
            bytes, RecordLogVectorModelCheck.Expectation(vec1: vec1, dims: vector.dims, distance: vector.distance, index: vector.index)
        )
        let current = { (sql: RecordLogSql) throws -> (row: Format2SqlRow, options: [String: JSONValue])? in
            try self.currentVectorEntry(sql, name, as: row, options) { Self.installStaleness($0, $1, generation: generation, revision: revision) == nil }
        }
        try vectorEntryReadForTest?()
        let moved = "the vector index changed while its model was checked"
        let refuse = { (reason: String) throws -> RecordLogVectorInstall in
            let recorded = try self.command { sql -> Bool in
                guard let (row, options) = try current(sql) else { return false }
                var refused: [String: JSONValue] = ["reason": .string(reason)]
                if let generation { refused["generation"] = .number(Double(generation)) }
                if let revision { refused["revision"] = .number(Double(revision)) }
                var next = RecordLogIndexes.removing(options, "training")
                next["refused"] = .object(refused)
                try RecordLogIndexes.writeVectorOptions(sql, row, next, row["vector"].stringValue)
                return true
            }
            guard recorded else { return stale(moved) }
            self.logger?.warn(
                "[record-log] \(self.documentId): the model for vector index \(name)\(revision.map { " (revision \($0))" } ?? "") was refused: \(reason); $near on it answers exactly."
            )
            return RecordLogVectorInstall(name: name, outcome: .refused, reason: reason)
        }
        guard case .ok(let params, let model) = outcome else {
            if case .refused(let reason) = outcome { return try refuse(reason) }
            return try refuse("the model was refused")
        }
        let flat = row["vector"].stringValue ?? ""
        let ann = RecordLogVectorIndex.annTable(flat)
        do {
            // One command, one transaction: a failure leaves nothing of the install.
            let installed = try command { sql -> Bool in
                    guard let (row, options) = try current(sql) else { return false }
                    try sql.connection.executeScript("DROP TABLE IF EXISTS \(RecordLogVectorIndex.quoted(ann))")
                    try sql.connection.executeScript(RecordLogVectorIndex.tableDDL(ann))
                    try sql.exec("INSERT INTO \(RecordLogVectorIndex.quoted(ann)) (cmd, arg) VALUES ('rebuild', ?)", [.blob(model)])
                    try writeTriggers(sql, row, options, [flat, ann])
                    var installed: [String: JSONValue] = [
                        "source": .string(source),
                        "params": ["nbucket": .number(Double(params.nbucket)), "codesize": .number(Double(params.codesize)), "quantizer": .string(params.quantizer)],
                        "rows": .number(Double(params.rows)), "trainedAt": .string(params.trainedAt), "vec1": .string(params.vec1),
                    ]
                    if let generation { installed["generation"] = .number(Double(generation)) }
                    if let revision { installed["revision"] = .number(Double(revision)) }
                    var next = RecordLogIndexes.removing(options, "refused", "training")
                    next["ann"] = .object(installed)
                    next["fill"] = ["rowid": 0]
                    try RecordLogIndexes.writeVectorOptions(sql, row, next, flat)
                    return true
            }
            if !installed { return stale(moved) }
        } catch {
            let reason = RecordLogIndexes.message(error)
            if !Self.isVectorStorageFailure(error) { return try refuse("vec1 refused the model: \(reason)") }
            // The device failed, not the bytes: nothing is recorded against the model, and a training run's mark goes so its want comes back.
            try? command { sql in
                guard let (row, options) = try current(sql), options["training"] != nil else { return }
                try RecordLogIndexes.writeVectorOptions(sql, row, RecordLogIndexes.removing(options, "training"), row["vector"].stringValue)
            }
            logger?.warn(
                "[record-log] \(documentId): the model for vector index \(name) was not installed: \(reason); $near on it answers exactly, and it is installed again later."
            )
            return RecordLogVectorInstall(name: name, outcome: .failed, reason: reason)
        }
        logger?.log("[record-log] \(documentId): vector index \(name) installed a \(source) model; its ANN table fills in the background.")
        return RecordLogVectorInstall(name: name, outcome: .building)
    }

    /// One slice of the db3's ANN fills, a command of its own: the first
    /// entry being filled copies the next rows of its flat table its ANN
    /// table lacks, at most ``RecordLogVectorIndex/fillSliceRows`` in one
    /// statement, skipping a row its triggers already wrote. A slice that
    /// lists fewer rows than it may ends the fill: the entry answers from its
    /// ANN table from then. A slice that fails (a full disk) drops the ANN
    /// table, keeps the flat one serving and lets the store want the model
    /// again.
    ///
    /// - Returns: How many rows the slice copied, its time, and the entries still being filled after it.
    @discardableResult
    func continueVectorFill() throws -> (filled: Int, ms: Double, building: [String]) {
        let filling = { (sql: RecordLogSql) throws -> [Format2SqlRow] in
            try RecordLogIndexes.cachedVectorRows(sql, documentId: self.documentId).filter { row in
                let options = RecordLogIndexes.optionsOf(row)
                return !row["vector"].isNull && options["fill"] != nil && options["ann"] != nil
            }
        }
        guard let first = try reading({ try filling($0).first }) else { return (0, 0, []) }
        let firstOptions = RecordLogIndexes.optionsOf(first)
        let flat = first["vector"].stringValue ?? ""
        let ann = RecordLogVectorIndex.annTable(flat)
        let name = first["room_name"].stringValue ?? ""
        // The model the slice fills for: an index list applied since the read
        // above (a delete, a newer model) leaves the entry another's, and the
        // slice then writes nothing.
        let model = firstOptions["ann"]
        let current = { (sql: RecordLogSql) throws -> (row: Format2SqlRow, options: [String: JSONValue])? in
            try self.currentVectorEntry(sql, name, as: first, firstOptions) { $1["ann"] == model && $1["fill"] != nil }
        }
        try vectorEntryReadForTest?()
        let started = Date()
        var filled = 0
        var applied = false
        do {
            try command { sql in
                    guard let (row, options) = try current(sql) else { return }
                    applied = true
                    let from = Int64(options["fill"]?["rowid"]?.numberValue ?? 0)
                    let listed = try sql.rows(
                        "SELECT rowid FROM \(RecordLogVectorIndex.quoted(flat)) WHERE rowid > ? ORDER BY rowid LIMIT ?",
                        [.integer(from), .integer(Int64(RecordLogVectorIndex.fillSliceRows))]
                    ).compactMap { $0["rowid"].intValue }
                    if let last = listed.last {
                        let missing = """
                            FROM \(RecordLogVectorIndex.quoted(flat)) f WHERE f.rowid > ? AND f.rowid <= ? \
                            AND NOT EXISTS (SELECT 1 FROM \(RecordLogVectorIndex.quoted(ann)) a WHERE a.rowid = f.rowid)
                            """
                        filled = try sql.first("SELECT COUNT(*) AS n \(missing)", [.integer(from), .integer(Int64(last))])?["n"].intValue ?? 0
                        try sql.exec(
                            """
                            INSERT INTO \(RecordLogVectorIndex.quoted(ann)) (rowid, vector) SELECT f.rowid, f.vector FROM \(RecordLogVectorIndex.quoted(flat)) f \
                            WHERE f.rowid > ? AND f.rowid <= ? AND NOT EXISTS (SELECT 1 FROM \(RecordLogVectorIndex.quoted(ann)) a WHERE a.rowid = f.rowid) ORDER BY f.rowid
                            """,
                            [.integer(from), .integer(Int64(last))]
                        )
                    }
                    let done = listed.count < RecordLogVectorIndex.fillSliceRows
                    var next = RecordLogIndexes.removing(options, "fill")
                    if !done { next["fill"] = ["rowid": .number(Double(listed.last ?? Int(from)))] }
                    try RecordLogIndexes.writeVectorOptions(sql, row, next, flat)
            }
        } catch {
            let reason = RecordLogIndexes.message(error)
            do {
                try command { sql in
                    guard let (row, options) = try current(sql) else { return }
                    try sql.connection.executeScript("DROP TABLE IF EXISTS \(RecordLogVectorIndex.quoted(ann))")
                    try writeTriggers(sql, row, options, [flat])
                    try RecordLogIndexes.writeVectorOptions(sql, row, RecordLogIndexes.removing(options, "ann", "fill"), flat)
                }
            } catch {
                logger?.warn("[record-log] \(documentId): vector index \(name)'s partial ANN table could not be dropped: \(RecordLogIndexes.message(error))")
            }
            logger?.warn(
                "[record-log] \(documentId): vector index \(name)'s ANN table could not be filled: \(reason); $near on it answers exactly, and the model is installed again later."
            )
            return (0, Date().timeIntervalSince(started) * 1000, try reading { try filling($0).compactMap { $0["room_name"].stringValue } })
        }
        let ms = Date().timeIntervalSince(started) * 1000
        logger?.debug("[record-log] \(documentId): vector index \(name) filled \(filled) rows of its ANN table in \(String(format: "%.1f", ms)) ms.")
        let building = try reading { try filling($0).compactMap { $0["room_name"].stringValue } }
        if applied && !building.contains(name) { logger?.log("[record-log] \(documentId): vector index \(name) answers from its ANN table.") }
        return (filled, ms, building)
    }

    /// Whether any vector entry of the db3 is being filled.
    func vectorFillPending() throws -> Bool {
        try reading { sql in
            try RecordLogIndexes.cachedVectorRows(sql, documentId: documentId).contains { !$0["vector"].isNull && RecordLogIndexes.optionsOf($0)["fill"] != nil }
        }
    }

    /// Drop `name`'s installed model: its ANN table goes and its triggers keep
    /// the flat table alone, in one transaction, so the next `$near` answers
    /// exactly. Answers whether there was one.
    @discardableResult
    func invalidateVectorModel(_ name: String) throws -> Bool {
        let dropped = try command { sql -> Bool in
            guard let row = try entryNamed(sql, name) else { return false }
            let options = RecordLogIndexes.optionsOf(row)
            guard options["ann"] != nil || options["fill"] != nil, let flat = row["vector"].stringValue else { return false }
            try sql.connection.executeScript("DROP TABLE IF EXISTS \(RecordLogVectorIndex.quoted(RecordLogVectorIndex.annTable(flat)))")
            try writeTriggers(sql, row, options, [flat])
            try RecordLogIndexes.writeVectorOptions(sql, row, RecordLogIndexes.removing(options, "ann", "fill"), flat)
            return true
        }
        if dropped { logger?.log("[record-log] \(documentId): vector index \(name)'s model was dropped; $near on it answers exactly.") }
        return dropped
    }
}
