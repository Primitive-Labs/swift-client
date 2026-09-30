import Foundation

/// The cold load of a large document (#3436, behavior 24).
///
/// A port of `packages/js-bao/src/models/format2SnapshotLoader.ts`, without
/// the convergence inputs #3435 added for a client crossing a bulk load —
/// those belong to #3437 along with everything else that needs the sealed
/// chain. A new client does not replay a large document's history; there is
/// none to replay. It streams the chunks of the latest base into its own
/// `records` table.
///
/// What makes that usable on a device rather than only in principle:
///
/// - **Resumable.** Each chunk's rows and its `_snapshot_load` mark are
///   written in ONE commit by the store, so an interrupted load has no
///   half-applied chunk and a resume downloads only what is missing. On a
///   multi-hundred-megabyte base that is the difference between a load that
///   eventually finishes and one that starts over every time the connection
///   drops.
/// - **Verified.** A chunk goes straight into the authoritative table, so a
///   truncated or swapped one would write records the server never had, with
///   no whole-document comparison left to notice. The digest is checked before
///   anything is applied and a bad chunk is re-fetched once; a chunk that
///   stays bad ends the load rather than completing a wrong one.
/// - **Progressive.** A model is answerable as soon as ITS chunks are in, and
///   progress is reported per chunk — a load that reports only at the end is
///   indistinguishable from a hang.
/// - **Bounded by the device.** A load may be capped to the models this device
///   has room for; a capped-out model's chunks are never fetched, so the cap
///   is bandwidth saved as well as space.
///
/// Materialization goes through the same fold an overlay entry takes, so a
/// snapshot cannot come to mean something an overlay does not.
public enum Format2SnapshotLoader {

    /// How far a load has got.
    public struct Progress: Sendable, Equatable {
        /// Rows materialized so far, including a resumed run's earlier ones.
        public let rows: Int
        public let totalRows: Int
        public let chunks: Int
        public let totalChunks: Int
        /// The model the chunk just applied belongs to.
        public let model: String
    }

    /// What a finished load did.
    public struct Result: Sendable, Equatable {
        public let rows: Int
        public let chunks: Int
        /// Chunks a previous attempt had already committed.
        public let resumed: Int
        /// Chunks that had to be fetched twice because the first copy was wrong.
        public let refetched: Int
        public let models: [String]
        /// Models the snapshot carries that this load left behind, because the
        /// device could not hold them.
        public let skipped: [String]
        /// Models a completion pass had to re-apply chunks of. Their rows
        /// landed AFTER the model was reported ready, so anything the caller
        /// derived from them when it announced the model is one discard out of
        /// date and has to be rebuilt.
        public let repaired: [String]
    }

    /// A chunk that did not become the bytes the manifest describes, twice.
    public struct IntegrityError: Error, CustomStringConvertible {
        public let chunk: SnapshotChunkEntry
        public let cause: SnapshotChunkIntegrityError

        public var description: String {
            "Snapshot chunk \(chunk.key) could not be loaded: \(cause.reason)"
        }
    }

    /// Extra passes a load takes over the chunks whose marks vanished under
    /// it. One per discard observed is what the design asks for; three is room
    /// for a couple of them and a bound a runaway cannot escape.
    public static let maximumCompletionPasses = 3

    /// A load that could not be made complete.
    ///
    /// The marks a load reads at the end are the marks as they stand THEN, not
    /// as they stood when it started: another holder of this store may have
    /// discarded its merged view mid-pass, which deletes the rows and the
    /// marks for both. Reporting success on a captured set would hand back a
    /// merged view missing whatever vanished, and the query-table projection
    /// that follows would vouch for it. Marks that keep vanishing mean
    /// something is discarding continuously, and failing typed is the only
    /// honest end.
    public static func incomplete(
        buildId: String, missing: [String], passes: Int
    ) -> JsBaoError {
        let named = missing.prefix(3).joined(separator: ", ")
        return JsBaoError(
            code: .format2SnapshotLoadIncomplete,
            message: "Snapshot build \(buildId) could not be loaded completely: "
                + "\(missing.count) chunk(s) were still unmarked after \(passes) "
                + "pass(es) (\(named)\(missing.count > 3 ? ", …" : "")). Another "
                + "holder of this store is discarding its merged view while the "
                + "load runs.",
            details: [
                "buildId": .string(buildId),
                "missing": .number(Double(missing.count)),
                "passes": .number(Double(passes)),
            ]
        )
    }

    /// Load a snapshot's chunks into the client's merged view.
    ///
    /// Chunks are applied in MANIFEST order, which is `(model, id)` order — so
    /// a model's chunks are contiguous and it can be reported ready as soon as
    /// its last one lands.
    ///
    /// - Parameters:
    ///   - fetchChunk: read one chunk's bytes; the caller owns the transport
    ///     and the grant.
    ///   - onModelReady: a model whose last chunk has landed. "Ready" has to
    ///     mean QUERYABLE, and the caller may have derived tables to project
    ///     before it can honestly say so, so it is called before the load
    ///     moves on.
    ///   - retries: re-fetches allowed for a chunk that arrives corrupt.
    ///   - models: the models to hydrate, or `nil` for the whole snapshot. A
    ///     model outside the cap is not fetched at all.
    @discardableResult
    public static func load(
        store: Format2RecordStore,
        manifest: SnapshotManifest,
        fetchChunk: (SnapshotChunkEntry) throws -> Data,
        onProgress: ((Progress) -> Void)? = nil,
        onModelReady: ((String) throws -> Void)? = nil,
        retries: Int = 1,
        models: [String]? = nil
    ) throws -> Result {
        // Before a single byte is fetched (#3432, principle 6). A manifest
        // arrives from the server over a network: a version this client cannot
        // read, or two entries sharing the ordinal a resume keys on, has to
        // stop the load here rather than produce one that reports success
        // while missing a chunk.
        try manifest.validate()
        // Every path it will read, before it reads any of them (edge E7): an
        // entry this client cannot address is a chunk that would be discovered
        // missing halfway through a load of everything before it.
        for chunk in manifest.chunks where models?.contains(chunk.model) ?? true {
            _ = try snapshotChunkPath(chunk)
        }

        // This view is being made into `manifest.buildId`, and is not a
        // complete baseline until the load says so. Recorded FIRST: an
        // interrupted load must read as incomplete, or a later convergence
        // would keep chunks over rows that were never all there.
        try store.beginBase(buildId: manifest.buildId, epoch: manifest.epoch)
        let already = Set(try store.completedChunks(buildId: manifest.buildId))

        // What this load takes is what this device holds, from here on.
        // Recorded BEFORE the first chunk and durably, because the cap has to
        // outlive the load: the epoch overlay this client goes on to follow
        // carries every model's changes, and folding a skipped model's share
        // of them would turn a model this device declined into one holding a
        // few recent records.
        try store.setHydrationScope(models)

        let ordinals = Dictionary(
            uniqueKeysWithValues: manifest.chunks.enumerated().map { index, chunk in
                (index, resolveChunkOrdinal(chunk, at: index))
            }
        )
        func wanted(_ model: String) -> Bool { models?.contains(model) ?? true }

        var selected: [Int] = []
        var modelsLoaded: [String] = []
        var skipped: [String] = []
        var remainingPerModel: [String: Int] = [:]
        for (index, chunk) in manifest.chunks.enumerated() {
            guard wanted(chunk.model) else {
                if !skipped.contains(chunk.model) { skipped.append(chunk.model) }
                continue
            }
            selected.append(index)
            remainingPerModel[chunk.model, default: 0] += 1
            if !modelsLoaded.contains(chunk.model) { modelsLoaded.append(chunk.model) }
        }

        let totalChunks = selected.count
        let totalRows = selected.reduce(0) { $0 + manifest.chunks[$1].rows }
        var rows = 0
        var chunks = 0
        var resumed = 0
        var refetched = 0

        func applyOne(_ index: Int, outstanding: Int) throws {
            let chunk = manifest.chunks[index]
            let ordinal = ordinals[index]!
            var decoded: [SnapshotChunkReader.Row]?
            var lastError: SnapshotChunkIntegrityError?
            for attempt in 0...max(0, retries) {
                let body = try fetchChunk(chunk)
                do {
                    decoded = try SnapshotChunkReader.read(
                        body: body, entry: chunk, ordinal: ordinal
                    )
                    break
                } catch let error as SnapshotChunkIntegrityError {
                    lastError = error
                    if attempt < retries { refetched += 1 }
                }
            }
            guard let decoded else {
                // Every attempt allowed came back as bytes the entry does not
                // describe. A chunk that stays bad ends the load rather than
                // completing a wrong one.
                throw IntegrityError(
                    chunk: chunk,
                    cause: lastError ?? SnapshotChunkIntegrityError(
                        key: chunk.key, model: chunk.model, ordinal: ordinal,
                        reason: "it could not be read"
                    )
                )
            }
            try commit(decoded, chunk: chunk, ordinal: ordinal, outstanding: outstanding)
        }

        func commit(
            _ decoded: [SnapshotChunkReader.Row],
            chunk: SnapshotChunkEntry,
            ordinal: Int,
            outstanding: Int
        ) throws {
            let stringSetFields = manifest.stringSetFields(for: chunk.model)
            let entries = try decoded.map { row in
                SnapshotChunkReader.overlayEntry(
                    id: row.id,
                    data: try SnapshotChunkReader.decodeData(
                        row.data, entry: chunk, ordinal: ordinal, id: row.id
                    ),
                    stringSetFields: stringSetFields
                )
            }
            // The rows and the mark that says "this chunk is loaded" commit
            // together: a mark that could outlive its rows would make a resume
            // skip records that are not there.
            try store.applyChunk(
                model: chunk.model, entries: entries,
                buildId: manifest.buildId, ordinal: ordinal
            )
            chunks += 1
            rows += decoded.count
            onProgress?(Progress(
                rows: rows, totalRows: totalRows,
                chunks: chunks, totalChunks: totalChunks, model: chunk.model
            ))
            if outstanding == 0 { try onModelReady?(chunk.model) }
        }

        for index in selected {
            let chunk = manifest.chunks[index]
            let outstanding = (remainingPerModel[chunk.model] ?? 1) - 1
            remainingPerModel[chunk.model] = outstanding

            if already.contains(ordinals[index]!) {
                resumed += 1
                chunks += 1
                rows += chunk.rows
                if outstanding == 0 { try onModelReady?(chunk.model) }
                continue
            }
            try applyOne(index, outstanding: outstanding)
        }

        // A load is complete when every chunk of the manifest is MARKED — as
        // the marks stand now, not as they stood when this started.
        var repaired: [String] = []
        var pass = 1
        while true {
            let marked = Set(try store.completedChunks(buildId: manifest.buildId))
            let missing = selected.filter { !marked.contains(ordinals[$0]!) }
            if missing.isEmpty { break }
            if pass > maximumCompletionPasses {
                throw incomplete(
                    buildId: manifest.buildId,
                    missing: missing.map { manifest.chunks[$0].key },
                    passes: pass - 1
                )
            }
            for index in missing {
                // `-1`, so the model is not announced ready a second time: it
                // was announced when its last chunk first landed. What it DOES
                // owe the caller is a fresh projection of the rows this pass
                // put back, which travels in `repaired`.
                try applyOne(index, outstanding: -1)
                let model = manifest.chunks[index].model
                if !repaired.contains(model) { repaired.append(model) }
            }
            pass += 1
        }

        // The load finished: this view IS a complete baseline of `buildId`.
        try store.completeBase(buildId: manifest.buildId)

        return Result(
            rows: rows, chunks: chunks, resumed: resumed, refetched: refetched,
            models: modelsLoaded, skipped: skipped, repaired: repaired
        )
    }
}
