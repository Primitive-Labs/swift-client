import XCTest
@testable import JsBaoClient
import YSwift

/// Whether this device can hold this document, decided BEFORE the first chunk
/// is fetched (#3437, behaviors 32, 33 and 34, edge E8).
///
/// The failure this exists to prevent is the quiet one. Without the check a
/// load starts, writes for minutes, and throws on the chunk that crosses the
/// quota — leaving a `records` table holding SOME of the document, which the
/// client will nonetheless answer queries from, because on format 2 the merged
/// view IS the document. A partial merged view is not a slower document, it is
/// a wrong one.
///
/// The intent's Swift rule is that the check CAPS the models loaded rather
/// than refusing the document: a device that can hold the hot models is more
/// useful than one that holds nothing. It refuses only when not even the
/// models the app named will fit.
final class Format2StorageCapabilityHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDirectory() -> String {
        let directory = NSTemporaryDirectory() + "/f2-cap-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory
    }

    /// A manifest whose chunk sizes are the input to the plan. `rawBytes` is
    /// what a current builder records; a chunk without one is the older form.
    private func manifest(
        _ chunks: [(model: String, ordinal: Int, bytes: Int, rawBytes: Int?)]
    ) -> SnapshotManifest {
        SnapshotManifest(
            version: 3,
            epoch: 5,
            buildId: "b5",
            createdAt: 0,
            chunks: chunks.map {
                SnapshotChunkEntry(
                    key: "app/doc/5-b5/\($0.model)/\($0.ordinal).ndjson.gz",
                    path: "\($0.model)/\($0.ordinal)",
                    ordinal: $0.ordinal,
                    model: $0.model,
                    bytes: $0.bytes,
                    rawBytes: $0.rawBytes,
                    rows: 1,
                    firstId: "a",
                    lastId: "z",
                    sha256: String(repeating: "0", count: 64)
                )
            },
            totalRows: chunks.count,
            totalBytes: chunks.reduce(0) { $0 + $1.bytes }
        )
    }

    /// `Note` costs 200 materialized bytes, `Task` 800.
    private var twoModels: SnapshotManifest {
        manifest([
            (model: "Note", ordinal: 0, bytes: 10, rawBytes: 100),
            (model: "Task", ordinal: 1, bytes: 40, rawBytes: 400),
        ])
    }

    // MARK: - Behavior 32 — the estimate and the plan

    func testTheEstimateUsesTheRecordedRawLengthAndFallsBackToTheCompressedOne() {
        let recorded = SnapshotChunkEntry(
            key: "k", path: "Note/0", ordinal: 0, model: "Note",
            bytes: 10, rawBytes: 100, rows: 1, firstId: "a", lastId: "z", sha256: ""
        )
        XCTAssertEqual(
            Format2StorageCapability.estimateMaterializedBytes(recorded), 200,
            "the uncompressed length times the storage expansion: the rows "
                + "land as SQLite rows plus their indexes"
        )
        let older = SnapshotChunkEntry(
            key: "k", path: "Note/0", ordinal: 0, model: "Note",
            bytes: 10, rawBytes: nil, rows: 1, firstId: "a", lastId: "z", sha256: ""
        )
        XCTAssertEqual(
            Format2StorageCapability.estimateMaterializedBytes(older), 160,
            "and a manifest that does not say is guessed at PESSIMISTICALLY — "
                + "gzipped ndjson of repetitive records compresses by an order "
                + "of magnitude, and treating the compressed size as a proxy "
                + "is how a device approves a document it cannot hold"
        )
    }

    func testEverythingThatFitsIsTakenWhole() throws {
        let plan = try Format2StorageCapability.planSnapshotHydration(
            manifest: twoModels,
            capability: StorageCapability(persistent: true, quotaBytes: 10_000),
            models: ["Note"]
        )
        XCTAssertEqual(plan.kind, .full)
        XCTAssertEqual(plan.models, ["Note", "Task"])
        XCTAssertEqual(plan.skipped, [])
        XCTAssertEqual(plan.bytes, 1_000)
    }

    func testNoQuotaReportedIsNotARefusal() throws {
        let plan = try Format2StorageCapability.planSnapshotHydration(
            manifest: twoModels,
            capability: StorageCapability(persistent: true, quotaBytes: nil),
            models: []
        )
        XCTAssertEqual(
            plan.kind, .full,
            "refusing on ignorance would take large documents away from every "
                + "platform without a quota API, and those are the ones with room"
        )
    }

    func testAQuotaThatHoldsTheConfiguredModelsCapsRatherThanRefusing() throws {
        let plan = try Format2StorageCapability.planSnapshotHydration(
            manifest: twoModels,
            capability: StorageCapability(persistent: true, quotaBytes: 500),
            models: ["Note"]
        )
        XCTAssertEqual(plan.kind, .capped)
        XCTAssertEqual(plan.models, ["Note"])
        XCTAssertEqual(plan.skipped, ["Task"])
        XCTAssertEqual(plan.bytes, 200)
    }

    func testAModelTheSnapshotDoesNotCarryCostsNothingAndSkipsNothing() throws {
        let plan = try Format2StorageCapability.planSnapshotHydration(
            manifest: twoModels,
            capability: StorageCapability(persistent: true, quotaBytes: 500),
            models: ["Note", "Renamed"]
        )
        XCTAssertEqual(plan.models, ["Note"])
        XCTAssertEqual(plan.skipped, ["Task"])
    }

    func testNotEvenTheConfiguredModelsFitIsARefusalBeforeAnyChunkIsFetched() {
        XCTAssertThrowsError(
            try Format2StorageCapability.planSnapshotHydration(
                manifest: twoModels,
                capability: StorageCapability(persistent: true, quotaBytes: 100),
                models: ["Note"]
            )
        ) { error in
            let refusal = error as? JsBaoError
            XCTAssertEqual(refusal?.code, .format2StorageUnavailable)
            XCTAssertEqual(refusal?.details?["reason"], .string("over-quota"))
            XCTAssertEqual(refusal?.details?["requiredBytes"], .number(200))
            XCTAssertEqual(refusal?.details?["availableBytes"], .number(100))
            XCTAssertEqual(refusal?.details?["models"], .array([.string("Note")]))
        }
    }

    func testWithNoConfiguredModelsAtAllTheRefusalNamesTheWholeDocument() {
        XCTAssertThrowsError(
            try Format2StorageCapability.planSnapshotHydration(
                manifest: twoModels,
                capability: StorageCapability(persistent: true, quotaBytes: 100),
                models: []
            )
        ) { error in
            XCTAssertEqual(
                (error as? JsBaoError)?.details?["requiredBytes"], .number(1_000),
                "nothing was named worth keeping, so what did not fit is the "
                    + "whole document"
            )
        }
    }

    // MARK: - Edge E8 — a resumed capped load

    func testAChunkAlreadyCommittedCostsNothingMore() throws {
        let plan = try Format2StorageCapability.planSnapshotHydration(
            manifest: twoModels,
            capability: StorageCapability(persistent: true, quotaBytes: 900),
            models: ["Note"],
            completedChunks: [1]
        )
        XCTAssertEqual(
            plan.kind, .full,
            "`Task`'s rows are already on the device, so they are counted in "
                + "what the origin reports as USED — adding them to what is "
                + "still needed would count them twice and refuse a resumed "
                + "load the closer it got to finishing"
        )
        XCTAssertEqual(plan.bytes, 200)
    }

    func testADeviceWhoseFreeSpaceShrankBelowTheRemainingNeedStillRefuses() {
        XCTAssertThrowsError(
            try Format2StorageCapability.planSnapshotHydration(
                manifest: twoModels,
                capability: StorageCapability(
                    persistent: true, quotaBytes: 1_000, usedBytes: 950
                ),
                models: [],
                completedChunks: [1]
            )
        ) { error in
            XCTAssertEqual(
                (error as? JsBaoError)?.details?["availableBytes"], .number(50)
            )
        }
    }

    func testAStoreThatDoesNotPersistIsRefusedWhateverItsSize() {
        XCTAssertThrowsError(
            try Format2StorageCapability.planSnapshotHydration(
                manifest: twoModels,
                capability: StorageCapability(persistent: false, quotaBytes: nil),
                models: []
            )
        ) { error in
            XCTAssertEqual(
                (error as? JsBaoError)?.details?["reason"], .string("not-persistent")
            )
        }
    }

    // MARK: - Behavior 33 — the probe

    func testTheProbeReadsTheVolumeCapacityOfTheDatabaseDirectory() {
        let capability = Format2StorageCapability.probe(directory: newDirectory())
        XCTAssertTrue(capability.persistent)
        XCTAssertTrue(capability.probed)
        XCTAssertEqual(capability.usedBytes, 0)
        XCTAssertNotNil(
            capability.quotaBytes,
            "a real directory on a real volume answers: this is the iPadOS "
                + "quota check's replacement, and it reads the capacity the "
                + "system is willing to give important data"
        )
        XCTAssertGreaterThan(try XCTUnwrap(capability.quotaBytes), 0)
    }

    func testADirectoryThatCannotBeProbedReadsAsNoQuota() {
        let capability = Format2StorageCapability.probe(
            directory: "/definitely/not/a/path/\(UUID().uuidString)"
        )
        XCTAssertNil(
            capability.quotaBytes,
            "an unreadable key is an UNKNOWN quota, never zero: zero would "
                + "refuse the document on every platform that guards the API"
        )
        XCTAssertTrue(capability.persistent)
    }

    // MARK: - Behavior 34 — the cap applied to a real load

    /// A base load plans hydration FIRST, and what the plan leaves out is
    /// never fetched, never folded and never answered from.
    func testACappedLoadFetchesOnlyTheConfiguredModelsAndSaysSo() async throws {
        let directory = newDirectory()
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let document = YDocument()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        // `Note` costs 200 materialized bytes and `Task` 800; the device has
        // room for one of them.
        coordinator.storageOptions = LargeDocumentStorageOptions(
            capability: StorageCapability(persistent: true, quotaBytes: 500),
            models: ["Note"]
        )
        let binding = try coordinator.bind(
            documentId: "d", models: ["Note", "Task"], document: document
        )
        let note = MultiDocModel(schema: PrimitiveSchema(
            name: "Note",
            fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
        )).connect(docId: "d", doc: document)
        note.bindFormat2(binding)
        let task = MultiDocModel(schema: PrimitiveSchema(
            name: "Task",
            fields: ["id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string)]
        )).connect(docId: "d", doc: document)
        task.bindFormat2(binding)

        let base = try buildBase()
        let fetched = LockedBox<[String]>([])
        let outcome = try coordinator.runBaseLoad(
            documentId: "d",
            base: Format2Coordinator.BaseToLoad(
                epoch: 5, grantPath: base.grantPath, rows: 2
            ),
            source: source(base, onRead: { path in
                fetched.withValue { $0.append(path) }
            }),
            now: Int(Date().timeIntervalSince1970 * 1000)
        )
        XCTAssertEqual(outcome.plan, .join)
        XCTAssertFalse(
            fetched.value.contains { $0.contains("Task") },
            "the cap is enforced by not asking for the skipped model's chunks "
                + "at all — bytes not transferred, not only bytes not stored"
        )
        XCTAssertTrue(fetched.value.contains { $0.contains("Note") })

        XCTAssertEqual(
            try binding.store.hydrationScope(), ["Note"],
            "and the scope is DURABLE: a restart reconnects and starts folding "
                + "the epoch overlay again, which without it would quietly "
                + "repopulate the skipped model with whatever that epoch touched"
        )
        XCTAssertThrowsError(try task.count()) { error in
            XCTAssertEqual(
                (error as? JsBaoError)?.code, .format2ModelNotHydrated,
                "a query on a model this device does not hold is refused by "
                    + "name rather than answered from a fragment"
            )
        }
        XCTAssertEqual(try note.count(), 1)
        // A later overlay entry for the skipped model is not folded either.
        try binding.writePath.withOperation {
            _ = binding.overlay.applyRawEntries(
                [(OverlayKeys.fieldKey(recordId: "t9", field: "label"), .string("late"))],
                model: "Task"
            )
        }
        binding.settleFolds()
        XCTAssertThrowsError(try binding.store.read(model: "Task", recordId: "t9"))

        // And the scope survives a discard: a rebuild plans against the same
        // cap rather than taking the document whole on a device that has not
        // grown.
        try binding.store.discardMergedView()
        XCTAssertEqual(try binding.store.hydrationScope(), ["Note"])
    }

    /// One line names what was left behind (principle 8).
    ///
    /// Read off the method's OWN body rather than from a captured sink: the
    /// client's logger writes to the console and has no test seam, and a pin
    /// measured in characters from a landmark is the trap this project has
    /// paid for six times. The body is bounded by its own closing brace.
    func testTheCapLogsWhatItLeftBehind() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/JsBaoClient/LargeDocuments/Format2Coordinator.swift"
                ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "private func hydrationModels(")
        )
        let body = source[start.lowerBound...].prefix(while: { _ in true })
        let end = try XCTUnwrap(body.range(of: "\n    }\n"))
        let method = String(body[..<end.upperBound])
        XCTAssertTrue(
            method.contains("does not fit on this device"),
            "the grep-able line #3437 declares, in the method that caps the load"
        )
        XCTAssertTrue(
            method.contains("plan.skipped"),
            "and it names the models that were skipped, not only that some were"
        )
    }

    private struct LoadBase {
        let manifest: [String: Any]
        let bodies: [String: Data]
        let grantPath = "/artifact/base-5"
    }

    /// One `Note` chunk and one `Task` chunk, written by the real encoder.
    private func buildBase() throws -> LoadBase {
        let response = try Format2Harness.run([
            "command": "encode-chunk",
            "chunks": [
                [
                    "key": "app/doc/5-b5/Note/0.ndjson.gz", "path": "Note/0",
                    "ordinal": 0, "model": "Note",
                    "rows": [["id": "n1", "data": #"{"title":"from the base"}"#]],
                ],
                [
                    "key": "app/doc/5-b5/Task/1.ndjson.gz", "path": "Task/1",
                    "ordinal": 1, "model": "Task",
                    "rows": [["id": "t1", "data": #"{"label":"from the base"}"#]],
                ],
            ],
        ])
        let encoded = try XCTUnwrap(response["chunks"] as? [[String: Any]])
        var entries: [[String: Any]] = []
        var bodies: [String: Data] = [:]
        var rows = 0
        var bytes = 0
        for chunk in encoded {
            var entry = try XCTUnwrap(chunk["entry"] as? [String: Any])
            // The sizes the plan is taken over: `Note` 200 bytes, `Task` 800.
            entry["rawBytes"] = (entry["model"] as? String) == "Note" ? 100 : 400
            rows += entry["rows"] as? Int ?? 0
            bytes += entry["bytes"] as? Int ?? 0
            entries.append(entry)
            bodies[try XCTUnwrap(entry["path"] as? String)] =
                Data(base64Encoded: try XCTUnwrap(chunk["body"] as? String))
        }
        return LoadBase(
            manifest: [
                "version": 3, "epoch": 5, "buildId": "b5", "createdAt": 0,
                "schema": [
                    "Note": ["stringSetFields": []],
                    "Task": ["stringSetFields": []],
                ],
                "chunks": entries,
                "totals": ["rows": rows, "bytes": bytes],
            ],
            bodies: bodies
        )
    }

    private func source(
        _ base: LoadBase, onRead: @escaping @Sendable (String) -> Void
    ) -> Format2SnapshotSource {
        Format2SnapshotSource(
            apiUrl: "https://api.example.test",
            documentId: "d",
            grantPath: base.grantPath,
            read: { url in
                onRead(url.path)
                if url.path == base.grantPath {
                    return Format2SnapshotSource.Answer(
                        status: 200,
                        body: try JSONSerialization.data(withJSONObject: base.manifest)
                    )
                }
                let suffix = String(url.path.dropFirst(base.grantPath.count + 1))
                guard let body = base.bodies[suffix] else {
                    return Format2SnapshotSource.Answer(status: 404, body: Data())
                }
                return Format2SnapshotSource.Answer(status: 200, body: body)
            }
        )
    }

    // MARK: - Parity with js-bao

    func testThePlanAgreesWithJsBaoOverTheSameInputs() throws {
        let cases: [(quota: Int?, used: Int, models: [String], completed: [Int])] = [
            (quota: 10_000, used: 0, models: ["Note"], completed: []),
            (quota: nil, used: 0, models: [], completed: []),
            (quota: 500, used: 0, models: ["Note"], completed: []),
            (quota: 900, used: 0, models: ["Note"], completed: [1]),
            (quota: 1_200, used: 400, models: ["Task"], completed: []),
        ]
        for (index, input) in cases.enumerated() {
            let response = try Format2Harness.run([
                "command": "plan-hydration",
                "manifest": manifestJSON,
                "capability": [
                    "persistent": true,
                    "quotaBytes": input.quota as Any,
                    "usedBytes": input.used,
                ] as [String: Any],
                "models": input.models,
                "completedChunks": input.completed,
            ])
            let plan = try Format2StorageCapability.planSnapshotHydration(
                manifest: twoModels,
                capability: StorageCapability(
                    persistent: true, quotaBytes: input.quota, usedBytes: input.used
                ),
                models: input.models,
                completedChunks: Set(input.completed)
            )
            XCTAssertEqual(
                response["kind"] as? String, plan.kind.rawValue,
                "case \(index)"
            )
            XCTAssertEqual(
                response["models"] as? [String], plan.models, "case \(index)"
            )
            XCTAssertEqual(
                response["skipped"] as? [String], plan.skipped, "case \(index)"
            )
            XCTAssertEqual(response["bytes"] as? Int, plan.bytes, "case \(index)")
        }
    }

    func testARefusalAgreesWithJsBaoToo() throws {
        let response = try Format2Harness.run([
            "command": "plan-hydration",
            "manifest": manifestJSON,
            "capability": ["persistent": true, "quotaBytes": 100, "usedBytes": 0],
            "models": ["Note"],
        ])
        XCTAssertEqual(response["refused"] as? String, "over-quota")
        XCTAssertEqual(response["requiredBytes"] as? Int, 200)
        XCTAssertEqual(response["availableBytes"] as? Int, 100)
        XCTAssertThrowsError(
            try Format2StorageCapability.planSnapshotHydration(
                manifest: twoModels,
                capability: StorageCapability(persistent: true, quotaBytes: 100),
                models: ["Note"]
            )
        )
    }

    /// The same manifest the Swift fixture describes, in the shape js-bao
    /// reads it.
    private var manifestJSON: [String: Any] { [
        "version": 3, "epoch": 5, "buildId": "b5", "createdAt": 0,
        "schema": [
            "Note": ["stringSetFields": []],
            "Task": ["stringSetFields": []],
        ],
        "chunks": [
            [
                "key": "app/doc/5-b5/Note/0.ndjson.gz", "path": "Note/0",
                "ordinal": 0, "model": "Note", "rows": 1, "bytes": 10,
                "rawBytes": 100, "sha256": String(repeating: "0", count: 64),
                "firstId": "a", "lastId": "z",
            ],
            [
                "key": "app/doc/5-b5/Task/1.ndjson.gz", "path": "Task/1",
                "ordinal": 1, "model": "Task", "rows": 1, "bytes": 40,
                "rawBytes": 400, "sha256": String(repeating: "0", count: 64),
                "firstId": "a", "lastId": "z",
            ],
        ],
        "totals": ["rows": 2, "bytes": 50],
    ] }
}
