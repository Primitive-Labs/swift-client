import XCTest
@testable import JsBaoClient

/// #5230 behaviors 7 (the ANN table's half), 18 to 22 and edge cases 37 to
/// 39 and 41 — a device vector index's shared ANN model in the Swift store,
/// the port of js-bao's (#5229):
///
/// - 18: an install refuses a body the check refuses (recorded, warned once,
///   exact kept, not wanted again at that revision), installs a genuine one
///   (the ANN table rebuilt from it, triggers for both tables, `ann` and
///   `fill` recorded, one info line), answers `stale` for another generation,
///   a revision moved past, an exact or an unbuilt entry, and `failed` with
///   nothing refused when the disk is full.
/// - 7, 19: the fill copies the flat rows the ANN table lacks in slices of at
///   most 256, each a command of its own, a `$near` between them answering
///   exactly, the triggers keeping both tables meanwhile; the oracle finds the
///   ANN table's rowids and vectors the flat table's; a slice the disk refuses
///   drops the partial table and the model is wanted again.
/// - 20: an invalidation drops the ANN table at once; a newer revision's model
///   replaces the installed one.
/// - 21: the wants, the training sample and its mark, told to the client only
///   when they change.
/// - 22: the trainer trains on a task of its own while the store answers.
/// - 37: two stores of one file fill and train once between them.
/// - 38: a training mark left by an ended run wakes the wants at its lapse.
/// - 39, 41: an install for an entry made exact is stale; a model deleted mid-fill is dropped by the next list.
final class Db3VectorModelStoreHermeticTests: XCTestCase {

    private typealias F = Db3VectorFixture
    private typealias Support = Db3VectorTestSupport

    private static let dims = 16
    private static let encoding = VectorEncoding(dims: dims, element: .f32)
    private static let name = "idx_vec_note_embedding"

    private var worlds: [Db3DeviceIndexWorld] = []
    private var rows: [(id: String, vector: [Float])] = []

    override func tearDown() {
        Logger.lineForTest = nil
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    /// A synced db3 of `count` clustered 16-d notes, its `embedding` indexed as `index`.
    private func world(count: Int = 1200, index: JSONValue = F.ann(), generation: Int = 3, revision: Int = 2, annModel: JSONValue? = nil,
                       localOnly: Bool = false) async throws -> (Db3DeviceIndexWorld, RecordLogStore) {
        let world = try await Db3DeviceIndexWorld.make("vector-model", logger: Logger(level: .debug))
        worlds.append(world)
        let store = try world.store("db3-a", localOnly: localOnly)
        let vectors = Support.clusteredVectors(count, Self.dims, clusters: 12)
        rows = vectors.enumerated().map { (String(format: "n%05d", $0.offset), $0.element) }
        let seeded: [JSONValue] = try rows.map { ["id": .string($0.id), "embedding": .string(try VectorCodec.encode($0.vector, encoding: Self.encoding))] }
        if localOnly {
            try world.commit("db3-a", seeded.map { RecordLogMutation(model: "Note", id: $0["id"]?.stringValue ?? "", kind: .create, fields: ($0.objectValue ?? [:]).filter { $0.key != "id" }) })
        } else {
            try world.seed("db3-a", "Note", seeded)
        }
        try store.syncIndexes([entry(index: index, generation: generation, revision: revision, annModel: annModel)])
        return (world, store)
    }

    private func entry(index: JSONValue = F.ann(), generation: Int? = 3, revision: Int? = 2, annModel: JSONValue? = nil) -> RecordLogIndexEntry {
        Support.vectorEntry("Note", "embedding", Self.encoding, index: index, generation: generation, revision: revision, annModel: annModel)
    }

    /// A genuine model over the rows, in its envelope.
    private func model(nbucket: Int = 20, codesize: Int = 8, quantizer: String = "opq") throws -> Data {
        let params = RecordLogVectorModelParams(
            vec1: try Support.vec1Version(), dims: Self.dims, distance: "cos", nbucket: nbucket, codesize: codesize, quantizer: quantizer,
            rows: rows.count, trainedAt: "2026-11-05T00:00:00.000Z"
        )
        return RecordLogVectorModelCheck.encode(params, model: try Support.trainModel(rows.map(\.vector), distance: "cos", nbucket: nbucket, codesize: codesize, quantizer: quantizer))
    }

    private func near(_ store: RecordLogStore, _ vector: [Float], k: Int = 10) throws -> [RecordLogRow] {
        try store.queryView("Note", ["$near": ["field": "embedding", "vector": .array(vector.map { .number(Double($0)) }), "k": .number(Double(k))]],
                            options: QueryOptions(limit: 100)).data
    }

    private func options(_ world: Db3DeviceIndexWorld) throws -> [String: JSONValue] {
        try F.options(world, "db3-a")?.objectValue ?? [:]
    }

    private func annTable() -> String { RecordLogVectorIndex.annTable(F.flat("db3-a")) }

    private func fillAll(_ store: RecordLogStore) throws -> Int {
        var slices = 0
        while try store.vectorFillPending() {
            try store.continueVectorFill()
            slices += 1
        }
        return slices
    }

    private func triggers(_ world: Db3DeviceIndexWorld) throws -> [String] {
        let flat = F.flat("db3-a")
        return try world.rows("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name IN (?, ?, ?) ORDER BY name = ?, name = ?, name",
                              [.text("\(flat)__i"), .text("\(flat)__u"), .text("\(flat)__d"), .text("\(flat)__d"), .text("\(flat)__u")])
            .compactMap { $0["sql"].stringValue }
    }

    private var target: RecordLogVectorIndex.Target {
        RecordLogVectorIndex.Target(documentId: "db3-a", model: "Note", field: "embedding", element: "f32", dims: Self.dims)
    }

    // MARK: - 18: install

    func testARefusedBodyIsRecordedAtItsRevisionWarnedOnceAndTheIndexStaysExact() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        XCTAssertEqual(try store.vectorModelWants().map(\.want), [.fetch])
        var bad = try model()
        bad[bad.startIndex] = 0x58
        let lines = try Db3TextIndexFixture.logged {
            let outcome = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: bad, source: "shared")
            XCTAssertEqual(outcome, RecordLogVectorInstall(name: Self.name, outcome: .refused, reason: "the body is not a pvm1 model (no PVM1 magic)"))
        }
        XCTAssertEqual(try options(world)["refused"], ["generation": 3, "revision": 2, "reason": "the body is not a pvm1 model (no PVM1 magic)"])
        XCTAssertFalse(try F.objects(world).contains("table:\(annTable())"))
        XCTAssertEqual(try store.localIndexes().first?.mode, .exact)
        XCTAssertEqual(lines.filter { $0.message.contains("was refused") }.map(\.level), [.warn])
        XCTAssertEqual(
            lines.first { $0.message.contains("was refused") }?.message,
            "[record-log] db3-a: the model for vector index \(Self.name) (revision 2) was refused: the body is not a pvm1 model (no PVM1 magic); $near on it answers exactly."
        )
        // Not wanted again at that revision; wanted at the next.
        XCTAssertEqual(try store.vectorModelWants(), [])
        try store.syncIndexes([entry(revision: 3, annModel: F.annModel(revision: 3))])
        XCTAssertEqual(try store.vectorModelWants().map { [$0.want.rawValue, String($0.revision ?? -1)] }, [["fetch", "3"]])
        // A model with a NaN coefficient, refused before vec1 reads it.
        var nan = try model()
        nan.replaceSubrange((nan.count - 4)..<nan.count, with: [0x00, 0x00, 0xc0, 0x7f])
        XCTAssertEqual(try store.installVectorModel(Self.name, generation: 3, revision: 3, bytes: nan, source: "shared").outcome, .refused)
        XCTAssertTrue(try options(world)["refused"]?["reason"]?.stringValue?.contains("not finite") == true)
    }

    func testAGenuineModelBuildsTheAnnTableWritesBothTablesTriggersAndRecordsItsFill() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        let lines = try Db3TextIndexFixture.logged {
            XCTAssertEqual(try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared"),
                           RecordLogVectorInstall(name: Self.name, outcome: .building))
        }
        XCTAssertTrue(try F.objects(world).contains("table:\(annTable())"))
        XCTAssertEqual(try triggers(world), RecordLogVectorIndex.triggersDDL([F.flat("db3-a"), annTable()], target))
        let recorded = try options(world)
        XCTAssertEqual(recorded["ann"], [
            "generation": 3, "revision": 2, "source": "shared", "params": ["nbucket": 20, "codesize": 8, "quantizer": "opq"],
            "rows": .number(Double(rows.count)), "trainedAt": "2026-11-05T00:00:00.000Z", "vec1": .string(try Support.vec1Version()),
        ])
        XCTAssertEqual(recorded["fill"], ["rowid": 0])
        XCTAssertEqual(try store.localIndexes().map { [$0.status.rawValue, $0.mode?.rawValue ?? "-"] }, [["building", "exact"]])
        XCTAssertEqual(lines.filter { $0.message.contains("installed a shared model") }.map(\.level), [.info])
        XCTAssertEqual(try store.vectorModelWants(), [], "an entry being filled wants nothing")
    }

    func testAnInstallForAnotherGenerationAMovedRevisionOrAnEntryNotAnnAndBuiltIsStale() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        let genuine = try model()
        XCTAssertEqual(try store.installVectorModel(Self.name, generation: 4, revision: 2, bytes: genuine, source: "shared"),
                       RecordLogVectorInstall(name: Self.name, outcome: .stale, reason: "the model is for generation 4, the index is at 3"))
        XCTAssertEqual(try store.installVectorModel(Self.name, generation: 3, revision: 1, bytes: genuine, source: "shared"),
                       RecordLogVectorInstall(name: Self.name, outcome: .stale, reason: "the model is for revision 1, the index is at 2"))
        XCTAssertEqual(try store.installVectorModel("idx_vec_note_other", generation: 3, revision: 2, bytes: genuine, source: "shared").outcome, .stale)
        // 39: re-registered exact.
        try store.syncIndexes([entry(index: "exact", annModel: F.annModel(revision: 2))])
        XCTAssertEqual(try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: genuine, source: "shared"),
                       RecordLogVectorInstall(name: Self.name, outcome: .stale, reason: "not an ann vector index"))
        // Unbuilt: the list gives no options.
        try store.syncIndexes([RecordLogIndexEntry(name: Self.name, model: "Note", fields: ["embedding"], unique: false, kind: .vector, generation: 3, revision: 2)])
        XCTAssertEqual(try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: genuine, source: "shared").outcome, .stale)
        XCTAssertNil(try options(world)["refused"])
        XCTAssertNil(try options(world)["ann"])
    }

    func testAStorageFailureIsFailedRecordsNoRefusalAndDropsATrainingMark() async throws {
        let (world, store) = try await world()
        XCTAssertNotNil(try store.vectorTrainingSample(Self.name))
        XCTAssertNotNil(try options(world)["training"])
        let genuine = try model()
        let restore = try F.limitPages(world, headroom: 1)
        let outcome = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: genuine, source: "shared")
        try restore()
        XCTAssertEqual(outcome.outcome, .failed, "\(outcome)")
        XCTAssertTrue(outcome.reason?.contains("disk is full") == true, outcome.reason ?? "")
        XCTAssertNil(try options(world)["refused"])
        XCTAssertNil(try options(world)["training"])
        XCTAssertFalse(try F.objects(world).contains("table:\(annTable())"))
        XCTAssertEqual(try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: genuine, source: "shared").outcome, .building)
    }

    // MARK: - 7, 19: the fill

    func testTheFillCopiesTheFlatRowsInSlicesBetweenWhichNearAnswersExactly() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        _ = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared")
        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        var marks: [Int] = []
        var patched = false
        while try store.vectorFillPending() {
            let slice = try store.continueVectorFill()
            XCTAssertLessThanOrEqual(slice.filled, 256)
            if let mark = try options(world)["fill"]?["rowid"]?.numberValue { marks.append(Int(mark)) }
            // A `$near` between slices answers from the flat table, exactly. The slice
            // that ends the fill hands `$near` to the ANN table, whose candidates
            // depend on vec1's random seeding, so only a pending fill is compared.
            trace.clear()
            let query = rows[100].vector
            let answered = try near(store, query)
            if try store.vectorFillPending() {
                XCTAssertEqual(answered.compactMap { $0["id"]?.stringValue }, Support.bruteForce(rows, query, k: 10).map(\.id))
                XCTAssertFalse(trace.viewReads.contains { $0.contains("_ann\"(") }, "\(trace.viewReads.filter { $0.contains("_ann") })")
            }
            // A patch while the fill runs: its trigger writes both tables, and the fill skips the row.
            if !patched, let mark = marks.last, mark > 300 {
                let moved = Support.randomVectors(2, Self.dims, seed: 41)
                try world.seed("db3-a", "Note", [
                    ["id": "n00010", "embedding": .string(try VectorCodec.encode(moved[0], encoding: Self.encoding))],
                    ["id": "n01100", "embedding": .string(try VectorCodec.encode(moved[1], encoding: Self.encoding))],
                ])
                rows[10].vector = moved[0]
                rows[1100].vector = moved[1]
                patched = true
            }
        }
        XCTAssertTrue(patched)
        XCTAssertEqual(marks, marks.sorted(), "fill.rowid advances")
        XCTAssertEqual(marks.count, 4, "1,200 rows: four slices of 256 leave a mark, the fifth ends the fill")
        XCTAssertNil(try options(world)["fill"])
        XCTAssertNotNil(try options(world)["ann"])
        XCTAssertEqual(try store.localIndexes().map { [$0.status.rawValue, $0.mode?.rawValue ?? "-"] }, [["built", "ann"]])
        XCTAssertEqual(try world.drift(), [], "the ANN table holds the flat table's rowids and vectors")
        XCTAssertEqual(try F.held(world, annTable()).count, 1200)
        // The triggers keep both tables: a create, a patch, a null and a delete.
        let fresh = Support.randomVectors(2, Self.dims, seed: 43)
        try world.seed("db3-a", "Note", [
            ["id": "x1", "embedding": .string(try VectorCodec.encode(fresh[0], encoding: Self.encoding))],
            ["id": "n00020", "embedding": .string(try VectorCodec.encode(fresh[1], encoding: Self.encoding))],
            ["id": "n00030", "embedding": .null],
        ])
        try world.seedDeletes("db3-a", "Note", ["n00040"])
        XCTAssertEqual(try world.drift(), [])
        XCTAssertEqual(try F.held(world, annTable()).count, 1199)
        // From the ANN table now.
        trace.clear()
        _ = try near(store, rows[500].vector)
        XCTAssertTrue(trace.viewReads.contains { $0.contains("\(annTable())\"(?, ?) AS a") })
    }

    func testASliceTheDiskRefusesDropsThePartialAnnTableAndTheModelIsWantedAgain() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        _ = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared")
        try store.continueVectorFill()
        let restore = try F.limitPages(world, headroom: 0)
        let lines = try Db3TextIndexFixture.logged { try store.continueVectorFill() }
        try restore()
        XCTAssertFalse(try F.objects(world).contains("table:\(annTable())"))
        XCTAssertEqual(try triggers(world), RecordLogVectorIndex.triggersDDL([F.flat("db3-a")], target))
        XCTAssertNil(try options(world)["ann"])
        XCTAssertNil(try options(world)["fill"])
        XCTAssertTrue(lines.contains { $0.level == .warn && $0.message.contains("could not be filled") })
        XCTAssertEqual(try store.vectorModelWants().map(\.want), [.fetch])
        XCTAssertEqual(try near(store, rows[3].vector).first?["id"], "n00003")
        XCTAssertEqual(try world.drift(), [])
    }

    // MARK: - 20, 41: invalidation

    func testAnInvalidationDropsTheAnnTableAndANewerRevisionReplacesTheModel() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        _ = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared")
        _ = try fillAll(store)
        XCTAssertTrue(try store.invalidateVectorModel(Self.name))
        XCTAssertFalse(try store.invalidateVectorModel(Self.name))
        XCTAssertFalse(try F.objects(world).contains("table:\(annTable())"))
        XCTAssertEqual(try triggers(world), RecordLogVectorIndex.triggersDDL([F.flat("db3-a")], target))
        XCTAssertEqual(try store.localIndexes().first?.mode, .exact)
        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        XCTAssertEqual(try near(store, rows[9].vector).first?["id"], "n00009")
        XCTAssertFalse(trace.statements.contains { $0.contains("rebuild") || $0.contains("CREATE VIRTUAL") }, "no build")
        // A newer revision's model is installed and filled again from the flat table.
        _ = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared")
        _ = try fillAll(store)
        try store.syncIndexes([entry(revision: 3, annModel: F.annModel(revision: 3))])
        XCTAssertFalse(try F.objects(world).contains("table:\(annTable())"), "the listing moved past the installed model")
        XCTAssertEqual(try store.installVectorModel(Self.name, generation: 3, revision: 3, bytes: try model(nbucket: 24), source: "shared").outcome, .building)
        XCTAssertEqual(try fillAll(store), 5)
        XCTAssertEqual(try options(world)["ann"]?["params"]?["nbucket"], 24)
        XCTAssertEqual(try world.drift(), [])
    }

    func testAModelDeletedMidFillIsDroppedByTheNextListAndNearIsExact() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        _ = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared")
        try store.continueVectorFill()
        XCTAssertNotNil(try options(world)["fill"])
        // The owner deleted the model: the revision moved, no model listed.
        try store.syncIndexes([entry(revision: 3, annModel: nil)])
        XCTAssertFalse(try F.objects(world).contains("table:\(annTable())"))
        XCTAssertNil(try options(world)["fill"])
        XCTAssertFalse(try store.vectorFillPending())
        XCTAssertEqual(try near(store, rows[4].vector).first?["id"], "n00004")
        XCTAssertEqual(try world.drift(), [])
    }

    /// F-5230-CODE-003: an index list applied between an install's check and
    /// its write (the index dropped and registered again) is never written
    /// over: the install is `stale`, the new generation stands, and nothing of
    /// the old model is left.
    func testAnIndexListAppliedDuringAnInstallIsNeverWrittenOver() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        let genuine = try model()
        store.vectorEntryReadForTest = { try store.syncIndexes([self.entry(generation: 4, revision: 1, annModel: nil)]) }
        let outcome = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: genuine, source: "shared")
        store.vectorEntryReadForTest = nil
        XCTAssertEqual(outcome.outcome, .stale)
        let after = try options(world)
        XCTAssertEqual(after["generation"], 4)
        XCTAssertEqual(after["revision"], 1)
        XCTAssertNil(after["annModel"])
        XCTAssertNil(after["ann"])
        XCTAssertNil(after["fill"])
        XCTAssertFalse(try F.objects(world).contains("table:\(annTable())"))
        XCTAssertEqual(try triggers(world), RecordLogVectorIndex.triggersDDL([F.flat("db3-a")], target))
        // The new generation is trained afresh, as nothing installed stands in its way.
        XCTAssertEqual(try store.vectorModelWants().map(\.want), [.train])

        // A refusal judged before the move records nothing against the new generation either.
        store.vectorEntryReadForTest = { try store.syncIndexes([self.entry(generation: 5, revision: 1, annModel: F.annModel(revision: 1))]) }
        XCTAssertEqual(try store.installVectorModel(Self.name, generation: 4, revision: 1, bytes: Data("not a model".utf8), source: "shared").outcome, .stale)
        store.vectorEntryReadForTest = nil
        XCTAssertNil(try options(world)["refused"])
        XCTAssertEqual(try store.vectorModelWants().map(\.want), [.fetch])
        XCTAssertEqual(try world.drift(), [])
    }

    /// F-5230-CODE-003: a list that drops the model between a fill slice's
    /// read and its write leaves the slice nothing to write: the new listing
    /// stands, no ANN table is left, and the new revision's model is wanted.
    func testAnIndexListAppliedDuringAFillSliceIsNeverWrittenOver() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        _ = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared")
        try store.continueVectorFill()
        XCTAssertNotNil(try options(world)["fill"])
        store.vectorEntryReadForTest = { try store.syncIndexes([self.entry(revision: 3, annModel: F.annModel(revision: 3))]) }
        let slice = try store.continueVectorFill()
        store.vectorEntryReadForTest = nil
        XCTAssertEqual(slice.filled, 0)
        XCTAssertEqual(slice.building, [])
        let after = try options(world)
        XCTAssertEqual(after["revision"], 3)
        XCTAssertEqual(after["annModel"]?["revision"], 3)
        XCTAssertNil(after["ann"])
        XCTAssertNil(after["fill"])
        XCTAssertFalse(try F.objects(world).contains("table:\(annTable())"))
        XCTAssertEqual(try store.vectorModelWants(), [RecordLogVectorWant(name: Self.name, want: .fetch, generation: 3, revision: 3)])
        XCTAssertEqual(try near(store, rows[4].vector).first?["id"], "n00004")
        XCTAssertEqual(try world.drift(), [])
    }

    // MARK: - 21: wants and the sample

    func testWantsFollowJsBaosRules() async throws {
        // An exact entry, and too few rows, want nothing.
        var (world, store) = try await world(count: 900, index: "exact")
        XCTAssertEqual(try store.vectorModelWants(), [])
        XCTAssertFalse(try store.vectorModelsAwaited())
        try store.syncIndexes([entry()])
        XCTAssertTrue(try store.vectorModelsAwaited())
        XCTAssertEqual(try store.vectorModelWants(), [], "900 rows are under max(4·nbucket, 1000)")
        // A registration's own nbucket: 300 × 4 = 1,200 rows needed.
        (world, store) = try await self.world(count: 1100, index: F.ann(nbucket: 300))
        XCTAssertEqual(try store.vectorModelWants(), [])
        (world, store) = try await self.world()
        XCTAssertEqual(try store.vectorModelWants(), [
            RecordLogVectorWant(name: Self.name, want: .train, generation: 3, revision: 2, nbucket: 35, rows: 1200),
        ])
        // A listed model is fetched; once installed and current, nothing; refused at its revision, nothing.
        try store.syncIndexes([entry(annModel: F.annModel(revision: 2))])
        XCTAssertEqual(try store.vectorModelWants(), [RecordLogVectorWant(name: Self.name, want: .fetch, generation: 3, revision: 2)])
        _ = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared")
        _ = try fillAll(store)
        XCTAssertEqual(try store.vectorModelWants(), [])
        XCTAssertFalse(try store.vectorModelsAwaited())
        // Declined: nothing.
        _ = try store.declineIndex(Self.name)
        XCTAssertEqual(try store.vectorModelWants(), [])
        _ = world
    }

    func testTheSampleMarksTrainingAndASecondSampleWhileMarkedIsNil() async throws {
        let (world, store) = try await world()
        let sample = try XCTUnwrap(store.vectorTrainingSample(Self.name))
        XCTAssertEqual(sample.params, RecordLogVectorTrainingParams(nbucket: 35, codesize: 16, quantizer: "opq"))
        XCTAssertEqual(sample.count, 1200, "min(rows, 100 · nbucket)")
        XCTAssertEqual(sample.vectors.count, 1200 * Self.dims * 4)
        XCTAssertEqual(sample.generation, 3)
        XCTAssertEqual(sample.revision, 2)
        XCTAssertEqual(sample.rows, 1200)
        XCTAssertEqual(Set(stride(from: 0, to: sample.vectors.count, by: Self.dims * 4).map { sample.vectors.subdata(in: $0..<($0 + Self.dims * 4)) }),
                       Set(rows.map { Support.bytes($0.vector) }), "the flat table's vectors, in random order")
        XCTAssertEqual(try options(world)["training"]?["revision"], 2)
        XCTAssertNil(try store.vectorTrainingSample(Self.name), "a second run waits for the mark")
        XCTAssertEqual(try store.vectorModelWants(), [], "nothing is wanted while the mark holds")
        // A model the room lists supersedes the mark.
        try store.syncIndexes([entry(annModel: F.annModel(revision: 2))])
        XCTAssertEqual(try store.vectorModelWants().map(\.want), [.fetch])
        try store.syncIndexes([entry()])
        // The mark lapses after a claim's life, and the lapse is named.
        let at = Int64(try XCTUnwrap(options(world)["training"]?["at"]?.numberValue))
        XCTAssertEqual(try store.vectorTrainingLapse(), at + 900_000)
        XCTAssertEqual(try store.vectorModelWants(now: at + 900_001).map(\.want), [.train])
        XCTAssertNotNil(try store.vectorTrainingSample(Self.name, now: at + 900_001))
        try store.releaseVectorTraining(Self.name)
        XCTAssertNil(try options(world)["training"])
        XCTAssertNil(try store.vectorTrainingLapse())
        XCTAssertEqual(try store.vectorModelWants().map(\.want), [.train])
        XCTAssertThrowsError(try store.vectorTrainingSample("idx_vec_note_missing"))
    }

    func testTheTrainingParamsResolveAsJsBaosDo() {
        XCTAssertEqual(RecordLogVectorIndex.trainingParams(.ann(nbucket: nil, codesize: nil, quantizer: nil), dims: 100, rows: 100_000),
                       RecordLogVectorTrainingParams(nbucket: 316, codesize: 32, quantizer: "opq"))
        XCTAssertEqual(RecordLogVectorIndex.trainingParams(.ann(nbucket: 64, codesize: nil, quantizer: "none"), dims: 100, rows: 10),
                       RecordLogVectorTrainingParams(nbucket: 64, codesize: 0, quantizer: "none"))
        XCTAssertEqual(RecordLogVectorIndex.trainingParams(.ann(nbucket: nil, codesize: nil, quantizer: "bq"), dims: 100, rows: 5000).codesize, 13)
        XCTAssertEqual(RecordLogVectorIndex.trainingParams(.ann(nbucket: nil, codesize: 12, quantizer: "bq"), dims: 100, rows: 5000).codesize, 7)
        XCTAssertEqual(RecordLogVectorIndex.trainingParams(.ann(nbucket: nil, codesize: nil, quantizer: nil), dims: 16, rows: 10).nbucket, 16)
        XCTAssertEqual(RecordLogVectorIndex.trainingParams(.ann(nbucket: nil, codesize: nil, quantizer: nil), dims: 16, rows: 100_000_000).nbucket, 4096)
        XCTAssertEqual(RecordLogVectorIndex.trainConfig(distance: "l2", RecordLogVectorTrainingParams(nbucket: 20, codesize: 8, quantizer: "pq")),
                       #"{distance:"l2", nbucket:20, codesize:8, quantizer:"pq"}"#)
        XCTAssertEqual(RecordLogVectorIndex.trainConfig(distance: "cos", RecordLogVectorTrainingParams(nbucket: 20, codesize: 0, quantizer: "none")),
                       #"{distance:"cos", nbucket:20, quantizer:"none"}"#)
    }

    func testALocalOnlyEntryWantsATrainingWhenNoModelIsInstalledOrRefused() async throws {
        let (_, store) = try await world(localOnly: true)
        XCTAssertEqual(try store.vectorModelWants(), [RecordLogVectorWant(name: Self.name, want: .train, nbucket: 35, rows: 1200, localOnly: true)])
        _ = try store.installVectorModel(Self.name, generation: nil, revision: nil, bytes: try model(), source: "local")
        _ = try fillAll(store)
        XCTAssertEqual(try store.vectorModelWants(), [])
        XCTAssertEqual(try store.localIndexes().first?.mode, .ann)
        // A list again keeps a local-only db3's own model.
        try store.syncIndexes([entry(generation: nil, revision: nil)])
        XCTAssertEqual(try store.localIndexes().first?.mode, .ann)
    }

    // MARK: - 21, 38: the jobs

    func testTheJobsTellTheWantsOnlyWhenTheyChangeAndFillInTheBackground() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        let told = LockedBox<[RecordLogVectorJobs.Notice]>([])
        let jobs = RecordLogVectorJobs(store: store) { notice in told.withValue { $0.append(notice) } }
        defer { jobs.stop() }
        jobs.after(.open)
        jobs.after(.rows)
        jobs.after(.rows)
        let wants = told.value.compactMap { notice -> [RecordLogVectorWant]? in if case .wants(let wants) = notice { return wants }; return nil }
        XCTAssertEqual(wants, [[RecordLogVectorWant(name: Self.name, want: .fetch, generation: 3, revision: 2)]], "told once")
        // An install: its fill runs in slices on tasks of their own, then the statuses and the (now empty) wants are told.
        _ = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared")
        jobs.after(.install)
        try await eventually(timeout: 20, description: "the fill ends") { try !store.vectorFillPending() }
        try await eventually(timeout: 5, description: "the statuses and wants are told") {
            told.value.filter { if case .statuses = $0 { return true }; return false }.count >= 2
                && told.value.contains { if case .wants(let wants) = $0 { return wants.isEmpty }; return false }
        }
        XCTAssertEqual(try store.localIndexes().first?.mode, .ann)
        XCTAssertEqual(try world.drift(), [])
    }

    func testATrainingMarkLeftByAnEndedRunWakesTheWantsAtItsLapse() async throws {
        let (world, store) = try await world()
        _ = try store.vectorTrainingSample(Self.name)
        // The run ended with its client: the mark is planted to lapse in 600 ms.
        var options = try self.options(world)
        options["training"] = ["generation": 3, "revision": 2, "at": .number(Double(Int64(Date().timeIntervalSince1970 * 1000) - 900_000 + 600))]
        try world.exec("UPDATE record_log_indexes SET options = ? WHERE kind = 'vector'", [.text(RecordLogJSON.text(.object(options)))])
        let reopened = try world.reopen("db3-a")
        let told = LockedBox<[[RecordLogVectorWant]]>([])
        let jobs = RecordLogVectorJobs(store: reopened) { notice in if case .wants(let wants) = notice { told.withValue { $0.append(wants) } } }
        defer { jobs.stop() }
        jobs.after(.open)
        XCTAssertEqual(told.value, [], "the mark holds: nothing wanted, nothing told")
        try await eventually(timeout: 10, description: "the lapse's wake tells the want") { told.value.last?.map(\.want) == [.train] }
    }

    // MARK: - 22: the trainer

    func testTheTrainerTrainsOnATaskOfItsOwnAndItsModelPassesTheDevicesCheck() async throws {
        let (_, store) = try await world()
        let trainer = RecordLogVec1Trainer()
        let sample = try XCTUnwrap(store.vectorTrainingSample(Self.name))
        let trained = try await trainer.train(sample)
        XCTAssertEqual(trainer.running, 0)
        XCTAssertEqual(trained.vec1, try Support.vec1Version())
        let params = RecordLogVectorModelParams(
            vec1: trained.vec1, dims: sample.dims, distance: sample.distance, nbucket: sample.params.nbucket, codesize: sample.params.codesize,
            quantizer: sample.params.quantizer, rows: sample.rows, trainedAt: "2026-11-05T00:00:00.000Z"
        )
        XCTAssertEqual(try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: RecordLogVectorModelCheck.encode(params, model: trained.model), source: "shared").outcome, .building)
        // 100 dims at the default codesize 32: 25 codebooks, which the device's own check admits.
        let wide = Support.clusteredVectors(1200, 100, clusters: 12, seed: 26)
        let sample100 = RecordLogVectorSample(
            name: "x", dims: 100, distance: "cos", rows: 1200, params: RecordLogVectorTrainingParams(nbucket: 20, codesize: 32, quantizer: "opq"),
            vectors: wide.reduce(into: Data()) { $0.append(Support.bytes($1)) }, count: 1200
        )
        let trained100 = try await trainer.train(sample100)
        XCTAssertEqual(trained100.model.subdata(in: 12..<16).reduce(0) { $0 << 8 | Int($1) }, 25)
        let check = RecordLogVectorModelCheck.check(
            RecordLogVectorModelCheck.encode(RecordLogVectorModelParams(vec1: trained100.vec1, dims: 100, distance: "cos", nbucket: 20, codesize: 32, quantizer: "opq",
                                                                        rows: 1200, trainedAt: "2026-11-05T00:00:00.000Z"), model: trained100.model),
            RecordLogVectorModelCheck.Expectation(vec1: trained100.vec1, dims: 100, distance: "cos", index: .ann(nbucket: nil, codesize: nil, quantizer: nil))
        )
        if case .refused(let reason) = check { XCTFail(reason) }
    }

    func testTheStoreAnswersEvery50MsWhileALargeModelTrains() async throws {
        let (_, store) = try await world()
        let trainer = RecordLogVec1Trainer()
        let big = Support.clusteredVectors(20_000, 64, clusters: 40, seed: 22)
        let sample = RecordLogVectorSample(
            name: "big", dims: 64, distance: "cos", rows: 20_000, params: RecordLogVectorTrainingParams(nbucket: 141, codesize: 32, quantizer: "opq"),
            vectors: big.reduce(into: Data()) { $0.append(Support.bytes($1)) }, count: 20_000
        )
        let training = Task { try await trainer.train(sample) }
        var probes: [Double] = []
        try await eventually(timeout: 5, description: "the training starts") { trainer.running == 1 }
        while trainer.running == 1 {
            let started = Date()
            _ = try near(store, rows[probes.count % rows.count].vector)
            probes.append(Date().timeIntervalSince(started) * 1000)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await training.value
        XCTAssertGreaterThan(probes.count, 3, "the training ran long enough to probe")
        XCTAssertLessThan(probes.max() ?? 0, 200, "no probe held: \(probes.max() ?? 0) ms over \(probes.count) probes")
        FileHandle.standardError.write(Data("[5230 measurement] $near probes during a 20,000 x 64 training: \(probes.count), max \(String(format: "%.1f", probes.max() ?? 0)) ms\n".utf8))
    }

    /// F-5230-CODE-005: trainings asked for at once (two `ann` indexes of one
    /// client) run one at a time: the second waits its turn, never two run
    /// together, both answer; a run no longer wanted by its turn trains nothing.
    func testTrainingsAskedForAtOnceRunOneAtATime() async throws {
        let trainer = RecordLogVec1Trainer()
        // The first long enough (as the 50 ms probe test's) that the others are asked for while it trains.
        let sample = { (seed: UInt32, count: Int, nbucket: Int) -> RecordLogVectorSample in
            let vectors = Support.clusteredVectors(count, 64, clusters: 40, seed: seed)
            return RecordLogVectorSample(
                name: "s\(seed)", dims: 64, distance: "cos", rows: count, params: RecordLogVectorTrainingParams(nbucket: nbucket, codesize: 32, quantizer: "opq"),
                vectors: vectors.reduce(into: Data()) { $0.append(Support.bytes($1)) }, count: count
            )
        }
        let (long, short) = (sample(31, 20_000, 141), sample(32, 2_000, 16))
        let peak = LockedBox(0)
        let watching = Task {
            while !Task.isCancelled {
                let running = trainer.running
                peak.withValue { $0 = max($0, running) }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let first = Task { try await trainer.train(long) }
        try await eventually(timeout: 5, description: "the first training starts") { trainer.running == 1 }
        let second = Task { try await trainer.train(short) }
        let unwanted = Task { try await trainer.train(short) { false } }
        try await eventually(timeout: 5, description: "the others wait their turn") { trainer.queued == 2 }
        XCTAssertEqual(trainer.running, 1)
        let (one, two) = (try await first.value, try await second.value)
        XCTAssertFalse(one.model.isEmpty)
        XCTAssertFalse(two.model.isEmpty)
        do {
            _ = try await unwanted.value
            XCTFail("a run no longer wanted trained")
        } catch {
            XCTAssertEqual(RecordLogIndexes.message(error), RecordLogVec1Trainer.unwanted)
        }
        watching.cancel()
        XCTAssertEqual(peak.value, 1, "never two trainings at once")
        XCTAssertEqual(trainer.runs, 2)
        XCTAssertEqual(trainer.running, 0)
        XCTAssertEqual(trainer.queued, 0)
    }

    // MARK: - 37: two stores of one file

    func testTwoStoresOfOneFileFillOnceBetweenThemAndTrainOnce() async throws {
        let (world, store) = try await world(annModel: F.annModel(revision: 2))
        let other = RecordLogStore(host: world.provider, documentId: "db3-a", clientId: "client-2")
        try other.initialize()
        _ = try store.installVectorModel(Self.name, generation: 3, revision: 2, bytes: try model(), source: "shared")
        // Interleaved slices of both, one of them regressed: the rowid probe skips what the other copied.
        try store.continueVectorFill()
        try other.continueVectorFill()
        var options = try self.options(world)
        options["fill"] = ["rowid": 0]
        try world.exec("UPDATE record_log_indexes SET options = ? WHERE kind = 'vector'", [.text(RecordLogJSON.text(.object(options)))])
        while try store.vectorFillPending() {
            try other.continueVectorFill()
            if try store.vectorFillPending() { try store.continueVectorFill() }
        }
        XCTAssertEqual(try F.held(world, annTable()).count, 1200)
        XCTAssertEqual(try world.drift(), [])
        // A local-only db3 trains once between them: the second sample is nil while the mark holds.
        let (localWorld, local) = try await self.world(localOnly: true)
        let second = RecordLogStore(host: localWorld.provider, documentId: "db3-a", clientId: "client-2")
        try second.initialize()
        XCTAssertNotNil(try local.vectorTrainingSample(Self.name))
        XCTAssertNil(try second.vectorTrainingSample(Self.name))
        try local.releaseVectorTraining(Self.name)
        XCTAssertNotNil(try second.vectorTrainingSample(Self.name))
    }
}

extension Db3VectorFixture {
    /// Fill the file's free pages and cap it `headroom` pages past its size
    /// (`PRAGMA max_page_count`, #5322's vehicle), so the next write that
    /// needs more fails "database or disk is full"; answers how to lift the cap.
    static func limitPages(_ world: Db3DeviceIndexWorld, headroom: Int = 40) throws -> () throws -> Void {
        let pragma = { (name: String) throws -> Int in try world.rows("PRAGMA \(name)").first?.columns.values.first?.intValue ?? 0 }
        let saved = try pragma("max_page_count")
        var rounds = 0
        while try pragma("freelist_count") > 0, rounds < 50 {
            let free = try pragma("freelist_count")
            try world.exec("CREATE TABLE IF NOT EXISTS pl_disk_filler_5230 (b BLOB)")
            try world.exec(
                "INSERT INTO pl_disk_filler_5230 (b) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?) SELECT zeroblob(3800) FROM n",
                [.integer(Int64(free))]
            )
            rounds += 1
        }
        let pages = try pragma("page_count")
        _ = try world.rows("PRAGMA max_page_count = \(pages + headroom)")
        return {
            _ = try world.rows("PRAGMA max_page_count = \(saved)")
            try world.exec("DROP TABLE IF EXISTS pl_disk_filler_5230")
        }
    }
}
