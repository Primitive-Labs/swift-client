import XCTest
@testable import JsBaoClient

/// The cold load of a large document (#3436, behavior 24, edges E7 and E9).
///
/// The store is a real `SQLiteStorageProvider` on a temp file and the chunk
/// bytes are the bytes the REAL platform encoder wrote, handed over by the
/// parity harness. What is stubbed is the transport, which is the one part a
/// hermetic test has no business owning: everything else — the digest checks,
/// the per-chunk commit, the resume, the completion re-check — is the product.
final class Format2SnapshotLoaderHermeticTests: XCTestCase {

    // MARK: - Fixtures

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-load-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(
        _ provider: SQLiteStorageProvider, documentId: String = "doc-load"
    ) throws -> Format2RecordStore {
        let store = Format2RecordStore(
            host: provider, documentId: documentId, clientId: "loader-client"
        )
        try store.initialize()
        return store
    }

    /// A base built by the real encoder: `Note` over two chunks, `Task` over
    /// one, with a declared stringset field so the fold has something to split.
    private struct Base {
        let manifest: SnapshotManifest
        let bodies: [String: Data]  // keyed by chunk key
    }

    private func buildBase(
        epoch: Int = 7,
        buildId: String = "b1",
        notes: [[(id: String, data: String)]] = [
            [(id: "n1", data: #"{"title":"one","tags":["a","b"]}"#),
             (id: "n2", data: #"{"title":"two","tags":[]}"#)],
            [(id: "n3", data: #"{"title":"three"}"#)],
        ],
        tasks: [[(id: String, data: String)]] = [
            [(id: "t1", data: #"{"done":true}"#)],
        ],
        sourcedFrom: (epoch: Int, buildId: String)? = nil
    ) throws -> Base {
        var requests: [[String: Any]] = []
        var ordinal = 0
        var plan: [(model: String, ordinal: Int, index: Int)] = []
        for (index, rows) in notes.enumerated() {
            requests.append(request(
                model: "Note", ordinal: ordinal, index: index, rows: rows,
                epoch: epoch, buildId: buildId,
                // The sourced form on exactly one chunk, which is what makes
                // this a version-3 manifest (#3432's chunk reuse).
                sourcedFrom: index == 1 ? sourcedFrom : nil
            ))
            plan.append((model: "Note", ordinal: ordinal, index: index))
            ordinal += 1
        }
        for (index, rows) in tasks.enumerated() {
            requests.append(request(
                model: "Task", ordinal: ordinal, index: index, rows: rows,
                epoch: epoch, buildId: buildId, sourcedFrom: nil
            ))
            plan.append((model: "Task", ordinal: ordinal, index: index))
            ordinal += 1
        }

        let response = try Format2Harness.run([
            "command": "encode-chunk", "chunks": requests,
        ])
        let encoded = try XCTUnwrap(response["chunks"] as? [[String: Any]])

        var entries: [SnapshotChunkEntry] = []
        var bodies: [String: Data] = [:]
        for each in encoded {
            let raw = try XCTUnwrap(each["entry"] as? [String: Any])
            let entry = SnapshotChunkEntry(
                key: try XCTUnwrap(raw["key"] as? String),
                path: raw["path"] as? String,
                ordinal: raw["ordinal"] as? Int,
                model: try XCTUnwrap(raw["model"] as? String),
                bytes: try XCTUnwrap(raw["bytes"] as? Int),
                rawBytes: raw["rawBytes"] as? Int,
                rows: try XCTUnwrap(raw["rows"] as? Int),
                firstId: try XCTUnwrap(raw["firstId"] as? String),
                lastId: try XCTUnwrap(raw["lastId"] as? String),
                sha256: try XCTUnwrap(raw["sha256"] as? String)
            )
            entries.append(entry)
            bodies[entry.key] = try XCTUnwrap(
                Data(base64Encoded: try XCTUnwrap(each["body"] as? String))
            )
        }

        let manifest = SnapshotManifest(
            version: sourcedFrom == nil ? 2 : 3,
            epoch: epoch,
            buildId: buildId,
            schema: ["Note": .object(["stringSetFields": .array([.string("tags")])])],
            chunks: entries,
            totalRows: entries.reduce(0) { $0 + $1.rows },
            totalBytes: entries.reduce(0) { $0 + $1.bytes }
        )
        try manifest.validate()
        return Base(manifest: manifest, bodies: bodies)
    }

    private func request(
        model: String, ordinal: Int, index: Int,
        rows: [(id: String, data: String)],
        epoch: Int, buildId: String,
        sourcedFrom: (epoch: Int, buildId: String)?
    ) -> [String: Any] {
        let prefix = sourcedFrom.map { "\($0.epoch)-\($0.buildId)/" } ?? ""
        return [
            "key": "app/doc/\(sourcedFrom.map { "\($0.epoch)-\($0.buildId)" } ?? "\(epoch)-\(buildId)")/\(model)/\(index).ndjson.gz",
            "path": "\(prefix)\(model)/\(index)",
            "ordinal": ordinal,
            "model": model,
            "rows": rows.map { ["id": $0.id, "data": $0.data] },
        ]
    }

    // MARK: - Behavior 24 — the load

    func testALoadInstallsEveryChunkAndMarksTheBaseComplete() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase()

        var fetched: [String] = []
        var progress: [Format2SnapshotLoader.Progress] = []
        var ready: [String] = []
        let result = try Format2SnapshotLoader.load(
            store: store,
            manifest: base.manifest,
            fetchChunk: { chunk in
                fetched.append(try snapshotChunkPath(chunk))
                return base.bodies[chunk.key]!
            },
            onProgress: { progress.append($0) },
            onModelReady: { ready.append($0) }
        )

        XCTAssertEqual(result.rows, 4)
        XCTAssertEqual(result.chunks, 3)
        XCTAssertEqual(result.resumed, 0)
        XCTAssertEqual(result.refetched, 0)
        XCTAssertEqual(result.models, ["Note", "Task"])
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(result.repaired, [])

        // Manifest order, which is `(model, id)` order — so a model's chunks
        // are contiguous and it can be reported ready as soon as its last one
        // lands, rather than at the end of the whole load.
        XCTAssertEqual(fetched, ["Note/0", "Note/1", "Task/0"])
        XCTAssertEqual(ready, ["Note", "Task"])
        XCTAssertEqual(progress.map(\.model), ["Note", "Note", "Task"])
        XCTAssertEqual(progress.map(\.chunks), [1, 2, 3])
        XCTAssertEqual(progress.map(\.rows), [2, 3, 4])
        XCTAssertEqual(Set(progress.map(\.totalRows)), [4])
        XCTAssertEqual(Set(progress.map(\.totalChunks)), [3])

        // Every row is in the merged view, and a declared stringset field
        // became MEMBERS rather than an array value.
        XCTAssertEqual(try store.recordIds(model: "Note"), ["n1", "n2", "n3"])
        XCTAssertEqual(try store.recordIds(model: "Task"), ["t1"])
        XCTAssertEqual(
            try store.read(model: "Note", recordId: "n1")?["title"], .string("one")
        )
        XCTAssertEqual(try store.members(model: "Note", recordId: "n1", field: "tags"), ["a", "b"])

        let state = try XCTUnwrap(try store.baseState())
        XCTAssertEqual(state.buildId, "b1")
        XCTAssertEqual(state.epoch, 7)
        XCTAssertTrue(state.complete, "the base is a complete baseline")
        XCTAssertEqual(try store.completedChunks(buildId: "b1"), [0, 1, 2])
    }

    /// `_snapshot_base` is written BEFORE the first chunk and is incomplete
    /// until the last one lands: an interrupted load must read as incomplete,
    /// or a later convergence would keep chunks over rows that were never all
    /// there.
    func testTheBaseIsRecordedIncompleteBeforeTheFirstChunkIsFetched() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase()

        var stateAtFirstFetch: (buildId: String, epoch: Int, complete: Bool)?
        _ = try Format2SnapshotLoader.load(
            store: store, manifest: base.manifest,
            fetchChunk: { chunk in
                if stateAtFirstFetch == nil { stateAtFirstFetch = try store.baseState() }
                return base.bodies[chunk.key]!
            }
        )
        XCTAssertEqual(stateAtFirstFetch?.buildId, "b1")
        XCTAssertFalse(stateAtFirstFetch?.complete ?? true)
    }

    /// A chunk that arrives corrupt is re-fetched ONCE; a second copy that is
    /// still wrong ends the load rather than completing a wrong one.
    func testACorruptChunkIsRefetchedOnceAndThenEndsTheLoad() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase()

        var attempts = 0
        let repaired = try Format2SnapshotLoader.load(
            store: store, manifest: base.manifest,
            fetchChunk: { chunk in
                let body = base.bodies[chunk.key]!
                guard chunk.model == "Task" else { return body }
                attempts += 1
                return attempts == 1 ? body.dropLast(3) : body
            }
        )
        XCTAssertEqual(repaired.refetched, 1)
        XCTAssertEqual(repaired.chunks, 3)
        XCTAssertEqual(try store.recordIds(model: "Task"), ["t1"])

        let second = try makeStore(try await makeProvider(), documentId: "doc-bad")
        XCTAssertThrowsError(
            try Format2SnapshotLoader.load(
                store: second, manifest: base.manifest,
                fetchChunk: { chunk in
                    chunk.model == "Task"
                        ? base.bodies[chunk.key]!.dropLast(3)
                        : base.bodies[chunk.key]!
                }
            )
        ) { error in
            let failure = error as? Format2SnapshotLoader.IntegrityError
            XCTAssertEqual(failure?.chunk.model, "Task")
            XCTAssertEqual(failure?.cause.ordinal, 2)
        }
        // And the base it was installing is still INCOMPLETE, so nothing that
        // reads the mark takes those rows for a baseline.
        XCTAssertFalse(try XCTUnwrap(second.baseState()).complete)
    }

    /// A load interrupted part-way resumes without re-fetching a committed
    /// chunk — the difference, on a multi-hundred-megabyte base, between a
    /// load that eventually finishes and one that starts over every time the
    /// connection drops.
    func testAnInterruptedLoadResumesWithoutRefetchingACommittedChunk() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase()

        struct Dropped: Error {}
        var firstPass: [String] = []
        XCTAssertThrowsError(
            try Format2SnapshotLoader.load(
                store: store, manifest: base.manifest,
                fetchChunk: { chunk in
                    if chunk.model == "Task" { throw Dropped() }
                    firstPass.append(chunk.key)
                    return base.bodies[chunk.key]!
                }
            )
        )
        XCTAssertEqual(firstPass.count, 2)
        XCTAssertEqual(try store.completedChunks(buildId: "b1"), [0, 1])

        var secondPass: [String] = []
        let result = try Format2SnapshotLoader.load(
            store: store, manifest: base.manifest,
            fetchChunk: { chunk in
                secondPass.append(chunk.key)
                return base.bodies[chunk.key]!
            }
        )
        XCTAssertEqual(secondPass.count, 1, "only the chunk that never landed")
        XCTAssertEqual(secondPass.first, base.manifest.chunks[2].key)
        XCTAssertEqual(result.resumed, 2)
        XCTAssertEqual(result.chunks, 3)
        // The resumed chunks still count towards the rows the caller is told
        // about, or a resumed load would report a document smaller than it is.
        XCTAssertEqual(result.rows, 4)
        XCTAssertTrue(try XCTUnwrap(store.baseState()).complete)
        XCTAssertEqual(try store.recordIds(model: "Note"), ["n1", "n2", "n3"])
    }

    /// Edge E9 — `applyChunk` on an already-marked ordinal is a no-op inside
    /// the transaction. A snapshot row REPLACES the merged row, and by the
    /// time a second attempt reaches one an overlay fold may have changed it:
    /// re-applying would put the base's older value back over the current one
    /// with nothing to notice.
    func testApplyingAnAlreadyMarkedChunkChangesNothing() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        try store.beginBase(buildId: "b1", epoch: 7)

        let applied = try store.applyChunk(
            model: "Note",
            entries: [OverlayRecordEntry(id: "n1", fields: ["title": .string("base")], replace: true)],
            buildId: "b1", ordinal: 0
        )
        XCTAssertEqual(applied, 1)

        // A later overlay fold moves the record on.
        try store.applyRemote(
            model: "Note",
            entry: OverlayRecordEntry(id: "n1", fields: ["title": .string("edited")])
        )

        let again = try store.applyChunk(
            model: "Note",
            entries: [OverlayRecordEntry(id: "n1", fields: ["title": .string("base")], replace: true)],
            buildId: "b1", ordinal: 0
        )
        XCTAssertEqual(again, 0, "an already-marked chunk applies nothing")
        XCTAssertEqual(
            try store.read(model: "Note", recordId: "n1")?["title"], .string("edited")
        )
        XCTAssertEqual(try store.completedChunks(buildId: "b1"), [0])
    }

    /// A load whose marks keep vanishing under it — another holder of the same
    /// database discarding its merged view — is re-applied, bounded, and then
    /// fails typed. A silent success would hand back exactly the half-loaded
    /// document the re-check exists to prevent.
    func testAMarkThatKeepsVanishingEndsTheLoadTyped() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase()

        var fetches = 0
        XCTAssertThrowsError(
            try Format2SnapshotLoader.load(
                store: store, manifest: base.manifest,
                fetchChunk: { chunk in
                    fetches += 1
                    defer {
                        // Somebody else discards the view the instant this
                        // chunk's mark is written.
                        try? store.discardMergedView()
                    }
                    return base.bodies[chunk.key]!
                }
            )
        ) { error in
            let failure = error as? JsBaoError
            XCTAssertEqual(failure?.code, .format2SnapshotLoadIncomplete)
            XCTAssertEqual(failure?.details?["passes"], .number(3))
        }
        XCTAssertGreaterThan(fetches, 3, "the passes really re-applied")
    }

    /// The device cap: a model outside it is not fetched at all, so the cap is
    /// bandwidth saved as well as space — and it is recorded durably, because
    /// the epoch overlay this client goes on to follow carries every model's
    /// changes.
    func testAModelOutsideTheCapIsNeverFetchedAndTheScopeIsDurable() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase()

        var fetched: [String] = []
        let result = try Format2SnapshotLoader.load(
            store: store, manifest: base.manifest,
            fetchChunk: { chunk in
                fetched.append(chunk.model)
                return base.bodies[chunk.key]!
            },
            models: ["Note"]
        )
        XCTAssertEqual(Set(fetched), ["Note"])
        XCTAssertEqual(result.models, ["Note"])
        XCTAssertEqual(result.skipped, ["Task"])
        XCTAssertEqual(try store.hydrationScope(), ["Note"])
        XCTAssertFalse(try store.isHydrated("Task"))
        XCTAssertEqual(try store.recordIds(model: "Note"), ["n1", "n2", "n3"])
    }

    // MARK: - Behavior 24 — what stops a load before it starts

    /// Before a single byte is fetched (#3432, principle 6): a manifest this
    /// client cannot read, or one two of whose entries share the ordinal a
    /// resume keys on, stops the load here rather than producing one that
    /// reports success while missing a chunk.
    func testAnInvalidManifestStopsTheLoadBeforeTheFirstFetch() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase()

        let collided = SnapshotManifest(
            version: base.manifest.version, epoch: 7, buildId: "b1",
            schema: base.manifest.schema,
            chunks: base.manifest.chunks.map {
                SnapshotChunkEntry(
                    key: $0.key, path: $0.path, ordinal: 0, model: $0.model,
                    bytes: $0.bytes, rows: $0.rows, firstId: $0.firstId,
                    lastId: $0.lastId, sha256: $0.sha256
                )
            },
            totalRows: base.manifest.totalRows, totalBytes: base.manifest.totalBytes
        )
        var fetched = 0
        XCTAssertThrowsError(
            try Format2SnapshotLoader.load(
                store: store, manifest: collided,
                fetchChunk: { chunk in fetched += 1; return base.bodies[chunk.key]! }
            )
        ) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .snapshotManifestInvalid)
        }
        XCTAssertEqual(fetched, 0)
        XCTAssertNil(try store.baseState(), "nothing was begun")
    }

    /// Edge E7's other half — an entry this client cannot ADDRESS is refused
    /// before any fetch, not discovered missing halfway through a load of
    /// everything before it.
    func testAnUnaddressableEntryIsRefusedBeforeAnyFetch() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase()

        var chunks = base.manifest.chunks
        chunks[2] = SnapshotChunkEntry(
            key: "app/doc/whatever", path: nil, ordinal: 2, model: "Task",
            bytes: chunks[2].bytes, rows: chunks[2].rows,
            firstId: chunks[2].firstId, lastId: chunks[2].lastId,
            sha256: chunks[2].sha256
        )
        let unaddressable = SnapshotManifest(
            version: 2, epoch: 7, buildId: "b1", schema: base.manifest.schema,
            chunks: chunks,
            totalRows: base.manifest.totalRows, totalBytes: base.manifest.totalBytes
        )
        var fetched = 0
        XCTAssertThrowsError(
            try Format2SnapshotLoader.load(
                store: store, manifest: unaddressable,
                fetchChunk: { chunk in fetched += 1; return base.bodies[chunk.key]! }
            )
        ) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .snapshotManifestInvalid)
        }
        XCTAssertEqual(fetched, 0)
    }

    // MARK: - Behavior 29's hermetic half — manifest version 3

    /// A manifest `version: 3` carrying a chunk in the SOURCED path form —
    /// one an earlier build wrote and this one carried forward by reference —
    /// loads, and the sourced chunk is addressed by its own path.
    func testAVersion3ManifestWithASourcedPathLoads() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase(sourcedFrom: (epoch: 4, buildId: "older-build"))

        XCTAssertEqual(base.manifest.version, 3)
        XCTAssertEqual(base.manifest.chunks[1].path, "4-older-build/Note/1")
        let address = try XCTUnwrap(parseSnapshotChunkPath(base.manifest.chunks[1].path))
        XCTAssertEqual(address.source?.epoch, 4)
        XCTAssertEqual(address.source?.buildId, "older-build")

        var paths: [String] = []
        let result = try Format2SnapshotLoader.load(
            store: store, manifest: base.manifest,
            fetchChunk: { chunk in
                paths.append(try snapshotChunkPath(chunk))
                return base.bodies[chunk.key]!
            }
        )
        XCTAssertEqual(paths, ["Note/0", "4-older-build/Note/1", "Task/0"])
        XCTAssertEqual(result.chunks, 3)
        XCTAssertEqual(try store.recordIds(model: "Note"), ["n1", "n2", "n3"])
        XCTAssertTrue(try XCTUnwrap(store.baseState()).complete)
    }

    // MARK: - discardMergedView

    func testDiscardingTheViewKeepsTheWritesThisClientStillOwes() async throws {
        let provider = try await makeProvider()
        let store = try makeStore(provider)
        let base = try buildBase()
        _ = try Format2SnapshotLoader.load(
            store: store, manifest: base.manifest,
            fetchChunk: { base.bodies[$0.key]! }
        )
        try store.commitLocalWrite(
            model: "Note",
            mutation: OverlayMutation(id: "n9", kind: .create, fields: ["title": .string("mine")]),
            pending: PendingOpInput(
                model: "Note", recordId: "n9", op: .create,
                fields: ["title"], baseEpoch: 7, ts: 1_700_000_000_000
            )
        )
        try store.noteDiscontinuity(epoch: 4)

        try store.discardMergedView()

        XCTAssertEqual(try store.recordIds(model: "Note"), [])
        XCTAssertEqual(try store.completedChunks(buildId: "b1"), [])
        XCTAssertNil(try store.baseState())
        // What a broken view does not make less owed:
        XCTAssertEqual(try store.pendingOps().count, 1)
        XCTAssertEqual(try store.discontinuityEpochs(), [4])
    }
}
