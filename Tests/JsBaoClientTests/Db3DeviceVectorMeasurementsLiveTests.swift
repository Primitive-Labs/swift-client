import Accelerate
import XCTest
@testable import JsBaoClient

/// #5230 behavior 33 (measurement) — what a device vector index costs and
/// answers in the Swift store, the twin of js-bao's
/// `db3-device-vector-measurements-5229.test.ts`, on the same real set:
/// GloVe 6B, 100 dimensions (`fse/glove-wiki-gigaword-100` on Hugging Face,
/// the `.npy` of `<f4`). The first 101,000 vectors are fetched with one byte
/// range, once, into `tests/perf/db3-storage/data/` (the file js-bao's
/// `tests/helpers/db3-glove-5229.ts` keeps, so either suite reuses the
/// other's); a fetch that fails fails the measurement, which never
/// substitutes synthetic vectors. "Live": it needs the network the first time.
///
/// The first 100,000 are a db3's records, loaded into a file-backed store; the
/// next 1,000 are the queries. A `cos` `ann` index with every option at its
/// default is registered through `syncIndexes`, the store's sample trained by
/// `RecordLogVec1Trainer`, the model installed in its `pvm1` envelope and the
/// ANN table filled a slice at a time, as a device does. Each figure is one
/// `[5230 measurement]` line; recall@10 against a brute-force `cos` answer is
/// asserted at 0.80, everything else is logged. Then, on synthetic
/// 768-dimensional vectors: a 20,000-row load without and with the index's
/// triggers, the flat table built after the load, exact `$near` at 20,000
/// rows, a 768-d training, and each element type's storage split into the
/// records, the flat table and the ANN table (`dbstat`, × 5 for 100,000).
///
/// A measurement, not a regression check (principle 9): it runs only when
/// asked, `DB3_VECTOR_MEASUREMENTS=1 swift test --filter
/// Db3DeviceVectorMeasurementsLiveTests`, so its two minutes stay out of the
/// whole suite's hour. That the bundled SQLite has `dbstat` is pinned by
/// `BundledSQLiteHermeticTests` on every run.
final class Db3DeviceVectorMeasurementsLiveTests: XCTestCase {

    private typealias Support = Db3VectorTestSupport

    private static let source = "https://huggingface.co/fse/glove-wiki-gigaword-100/resolve/main/glove-wiki-gigaword-100.model.vectors.npy"
    private static let gloveDims = 100
    private static let rows = Int(ProcessInfo.processInfo.environment["DB3_VECTOR_ROWS"] ?? "") ?? 100_000
    private static let queries = Int(ProcessInfo.processInfo.environment["DB3_VECTOR_QUERIES"] ?? "") ?? 1_000
    private static let name = "idx_vec_note_embedding"

    private var worlds: [Db3DeviceIndexWorld] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DB3_VECTOR_MEASUREMENTS"] == "1",
            "a measurement: set DB3_VECTOR_MEASUREMENTS=1 to run it"
        )
    }

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func world(_ label: String) async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("measure-vector-\(label)")
        worlds.append(world)
        return world
    }

    private static func log(_ name: String, _ value: String) {
        FileHandle.standardError.write(Data("[5230 measurement] \(name): \(value)\n".utf8))
    }

    private static func ms(_ since: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
    }

    private static func fixed(_ value: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    private static func mib(_ bytes: Double) -> String { String(format: "%.1f MiB", bytes / 1_048_576) }

    // MARK: - The real set

    private static var dataDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        // The checkout's root: past this file, `JsBaoClientTests`, `Tests` and `swift-client`.
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("tests/perf/db3-storage/data")
    }

    /// The first `count` GloVe vectors, one after another, fetched once with a byte range and kept under `data/`.
    private static func glove(_ count: Int) async throws -> [Float] {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let file = dataDirectory.appendingPathComponent("glove-wiki-gigaword-100-\(count).f32")
        if !FileManager.default.fileExists(atPath: file.path) {
            let url = try XCTUnwrap(URL(string: source))
            var head = URLRequest(url: url)
            head.setValue("bytes=0-511", forHTTPHeaderField: "Range")
            let (prefix, _) = try await URLSession.shared.data(for: head)
            guard prefix.count > 10, prefix[0] == 0x93, String(decoding: prefix[1..<6], as: UTF8.self) == "NUMPY" else {
                throw JsBaoError(code: .unavailable, message: "the GloVe file is not an .npy")
            }
            let headerLength = Int(prefix[8]) | Int(prefix[9]) << 8
            let header = String(decoding: prefix[10..<(10 + headerLength)], as: UTF8.self)
            guard header.contains("'<f4'"), header.contains("(400000, 100)"), header.contains("'fortran_order': False") else {
                throw JsBaoError(code: .unavailable, message: "the GloVe file's header is not <f4 (400000, 100) in C order: \(header)")
            }
            let start = 10 + headerLength
            var range = URLRequest(url: url)
            range.setValue("bytes=\(start)-\(start + count * gloveDims * 4 - 1)", forHTTPHeaderField: "Range")
            let (body, response) = try await URLSession.shared.data(for: range)
            guard (response as? HTTPURLResponse)?.statusCode == 206 else {
                throw JsBaoError(code: .unavailable, message: "the range fetch answered \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            try body.write(to: file)
        }
        let bytes = try Data(contentsOf: file)
        guard bytes.count == count * gloveDims * 4 else {
            throw JsBaoError(code: .unavailable, message: "\(file.path) holds \(bytes.count) bytes, not \(count * gloveDims * 4)")
        }
        return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Each query's `k` nearest rows by cosine distance, brute force (Accelerate's `vDSP_mmul` over unit vectors).
    private static func exactNearestCos(_ all: [Float], rows: Int, dims: Int, queries: [[Float]], k: Int) -> [[Int]] {
        func unit(_ v: ArraySlice<Float>) -> [Float] {
            var norm: Float = 0
            vDSP_svesq(Array(v), 1, &norm, vDSP_Length(dims))
            let scale = norm > 0 ? 1 / norm.squareRoot() : 0
            return v.map { $0 * scale }
        }
        // The unit rows transposed (dims × rows), so one product scores a batch of queries against every row.
        var transposed = [Float](repeating: 0, count: rows * dims)
        for r in 0..<rows {
            for (d, x) in unit(all[r * dims..<(r + 1) * dims]).enumerated() { transposed[d * rows + r] = x }
        }
        var answers: [[Int]] = []
        let batch = 50
        for start in stride(from: 0, to: queries.count, by: batch) {
            let slice = Array(queries[start..<min(queries.count, start + batch)])
            let q = slice.flatMap { unit($0[...]) }
            var scores = [Float](repeating: 0, count: slice.count * rows)
            vDSP_mmul(q, 1, transposed, 1, &scores, 1, vDSP_Length(slice.count), vDSP_Length(rows), vDSP_Length(dims))
            for i in 0..<slice.count {
                var best: [(score: Float, row: Int)] = []
                var floor = -Float.infinity
                for r in 0..<rows {
                    let score = scores[i * rows + r]
                    guard best.count < k || score > floor else { continue }
                    best.append((score, r))
                    best.sort { $0.score > $1.score }
                    if best.count > k { best.removeLast() }
                    floor = best.count == k ? best[k - 1].score : -Float.infinity
                }
                answers.append(best.map(\.row))
            }
        }
        return answers
    }

    // MARK: - The store

    private static func id(_ i: Int) -> String { String(format: "g%06d", i) }

    /// A synced store of `count` notes whose `embedding` (`encoding`) is `vector(i)`, from one bulk load; and the load's time.
    private func loaded(
        _ world: Db3DeviceIndexWorld, _ count: Int, _ encoding: VectorEncoding, entry: RecordLogIndexEntry? = nil, vector: (Int) -> [Float]
    ) throws -> (store: RecordLogStore, ms: Double) {
        let store = try world.store("db3-measure")
        let writer = world.writer("db3-measure")
        if let entry { try store.syncIndexes([entry]) }
        var lines: [RecordLogLoadLine] = []
        lines.reserveCapacity(count)
        for i in 0..<count {
            lines.append(RecordLogLoadLine(id: Self.id(i), patch: ["title": .string("note \(i)"), "embedding": .string(try VectorCodec.encode(vector(i), encoding: encoding))]))
        }
        let attempt = try store.beginReceipt(writer: writer, kind: .load, id: "LMEASURE").attempt
        let started = DispatchTime.now()
        for start in stride(from: 0, to: count, by: 5_000) {
            _ = try store.applyLoadChunk(writer: writer, sessionId: "LMEASURE", attempt: attempt, model: "Note", lines: Array(lines[start..<min(start + 5_000, count)]))
        }
        _ = try store.completeLoad(writer: writer, sessionId: "LMEASURE", attempt: attempt, mode: .merge, models: ["Note"])
        return (store, Self.ms(started))
    }

    private static func entry(_ encoding: VectorEncoding, index: JSONValue = ["mode": "ann"]) -> RecordLogIndexEntry {
        Support.vectorEntry("Note", "embedding", encoding, index: index)
    }

    /// Train the store's sample on the trainer, in its envelope: the bytes, the sample's size and the training's time.
    private static func train(_ store: RecordLogStore) async throws -> (bytes: Data, sample: RecordLogVectorSample, ms: Double) {
        let sample = try XCTUnwrap(try store.vectorTrainingSample(name))
        let started = DispatchTime.now()
        let trained = try await RecordLogVec1Trainer().train(sample)
        let ms = Self.ms(started)
        let params = RecordLogVectorModelParams(
            vec1: trained.vec1, dims: sample.dims, distance: sample.distance, nbucket: sample.params.nbucket, codesize: sample.params.codesize,
            quantizer: sample.params.quantizer, rows: sample.rows, trainedAt: Db3IndexesAPI.isoDate(Date())
        )
        return (RecordLogVectorModelCheck.encode(params, model: trained.model), sample, ms)
    }

    /// Install `bytes` and fill the ANN table to the end: the fill's time and its slices.
    private static func installAndFill(_ store: RecordLogStore, _ bytes: Data) throws -> (ms: Double, slices: Int) {
        let install = try store.installVectorModel(name, generation: 1, revision: 1, bytes: bytes, source: "shared")
        XCTAssertNotEqual(install.outcome, .refused)
        let started = DispatchTime.now()
        var slices = 0
        while try store.vectorFillPending() {
            _ = try store.continueVectorFill()
            slices += 1
        }
        return (Self.ms(started), slices)
    }

    private static func near(_ store: RecordLogStore, _ vector: [Float], k: Int = 10) throws -> [RecordLogRow] {
        try store.queryView("Note", ["$near": ["field": "embedding", "vector": .array(vector.map { .number(Double($0)) }), "k": .number(Double(k))]],
                            options: QueryOptions(limit: 100)).data
    }

    private static func mode(_ store: RecordLogStore) throws -> String? {
        let local: [Db3LocalIndex] = try store.localIndexes()
        return local.first { $0.name == name }?.mode?.rawValue
    }

    /// The median of `count` one-row commits of a new note, each flushed.
    private static func commitCost(_ world: Db3DeviceIndexWorld, _ store: RecordLogStore, _ encoding: VectorEncoding, tag: String, count: Int = 1_000) throws -> Double {
        let vectors = Support.randomVectors(count, encoding.dims, seed: 5230)
        var samples: [Double] = []
        for (i, vector) in vectors.enumerated() {
            let fields: [String: JSONValue] = ["title": .string("\(tag) \(i)"), "embedding": .string(try VectorCodec.encode(vector, encoding: encoding))]
            let started = DispatchTime.now()
            _ = try store.commitEntries(writer: world.writer("db3-measure"), writes: [RecordLogWrite(mutations: [
                RecordLogMutation(model: "Note", id: "\(tag)-\(i)", kind: .create, fields: fields),
            ])])
            try store.flush()
            samples.append(Self.ms(started))
        }
        return Self.percentile(Array(samples.dropFirst(count / 10)), 0.5)
    }

    /// The store file's bytes by what holds them: the records (confirmed rows and the view), the flat table and the ANN table.
    private static func storage(_ world: Db3DeviceIndexWorld) throws -> (records: Double, flat: Double, ann: Double) {
        let flat = RecordLogVectorIndex.tableName(documentId: "db3-measure", model: "Note", field: "embedding")
        let ann = RecordLogVectorIndex.annTable(flat)
        var out = (records: 0.0, flat: 0.0, ann: 0.0)
        let rows = try world.rows(
            "SELECT m.tbl_name AS tbl, SUM(d.pgsize) AS bytes FROM dbstat AS d JOIN sqlite_master AS m ON m.name = d.name GROUP BY m.tbl_name"
        )
        for row in rows {
            guard let table = row["tbl"].stringValue, let bytes = row["bytes"].intValue else { continue }
            if table == "record_log_rows" || table == "record_log_view" { out.records += Double(bytes) }
            else if table.hasPrefix(ann) { out.ann += Double(bytes) }
            else if table.hasPrefix(flat) { out.flat += Double(bytes) }
        }
        return out
    }

    // MARK: - GloVe, 100 dimensions

    func testRecallLatencyAndCostsOverGloVe() async throws {
        let all = try await Self.glove(101_000)
        let dims = Self.gloveDims
        let encoding = VectorEncoding(dims: dims, element: .f32)
        let row = { (i: Int) in Array(all[i * dims..<(i + 1) * dims]) }
        let queries = (0..<Self.queries).map { row(100_000 + $0) }
        let world = try await world("glove")
        let (store, loadMs) = try loaded(world, Self.rows, encoding, vector: row)
        Self.log("GloVe 100-d, \(Self.rows) rows bulk-loaded with no vector index (ms)", Self.fixed(loadMs, 0))

        let plainCommit = try Self.commitCost(world, store, encoding, tag: "plain")
        let built = DispatchTime.now()
        try store.syncIndexes([Self.entry(encoding)])
        Self.log("flat table built over \(Self.rows) rows, registered after them (ms)", Self.fixed(Self.ms(built), 0))
        XCTAssertEqual(try Self.mode(store), "exact")

        var exact: [Double] = []
        for query in queries {
            let started = DispatchTime.now()
            XCTAssertEqual(try Self.near(store, query).count, 10)
            exact.append(Self.ms(started))
        }
        Self.log("exact $near k=10 over \(Self.rows) x 100 through queryView, p50 / p95 (ms)", "\(Self.fixed(Self.percentile(exact, 0.5))) / \(Self.fixed(Self.percentile(exact, 0.95)))")
        let flatCommit = try Self.commitCost(world, store, encoding, tag: "flat")

        let (bytes, sample, trainMs) = try await Self.train(store)
        Self.log("training, \(sample.count) x \(sample.dims) sample (nbucket \(sample.params.nbucket), codesize \(sample.params.codesize), \(sample.params.quantizer)) on RecordLogVec1Trainer (ms)", Self.fixed(trainMs, 0))
        Self.log("model in its pvm1 envelope (bytes)", "\(bytes.count)")
        let fill = try Self.installAndFill(store, bytes)
        Self.log("ANN fill over \(Self.rows) rows, \(fill.slices) slices (ms)", Self.fixed(fill.ms, 0))
        XCTAssertEqual(try Self.mode(store), "ann")

        var approximate: [Double] = []
        var answers: [[String]] = []
        for query in queries {
            let started = DispatchTime.now()
            let rows = try Self.near(store, query)
            approximate.append(Self.ms(started))
            answers.append(rows.compactMap { $0["id"]?.stringValue })
        }
        Self.log("ann $near k=10 over \(Self.rows) x 100 through queryView, p50 / p95 (ms)", "\(Self.fixed(Self.percentile(approximate, 0.5))) / \(Self.fixed(Self.percentile(approximate, 0.95)))")
        let reference = Self.exactNearestCos(all, rows: Self.rows, dims: dims, queries: queries, k: 10)
        var hits = 0
        for (answer, truth) in zip(answers, reference) { hits += Set(answer).intersection(truth.map(Self.id)).count }
        let recall = Double(hits) / Double(queries.count * 10)
        Self.log("recall@10 of ann against a brute-force cos answer, \(queries.count) queries", Self.fixed(recall, 3))
        XCTAssertGreaterThanOrEqual(recall, 0.80)
        let annCommit = try Self.commitCost(world, store, encoding, tag: "ann")
        Self.log("one-row commit, 100-d f32, median: no vector index / flat table only / flat and ANN tables (ms)",
                 "\(Self.fixed(plainCommit, 3)) / \(Self.fixed(flatCommit, 3)) / \(Self.fixed(annCommit, 3))")
        let held = try Self.storage(world)
        let scale = 100_000 / Double(Self.rows)
        Self.log("storage per 100,000 rows, 100-d f32: records / flat table / ANN table", "\(Self.mib(held.records * scale)) / \(Self.mib(held.flat * scale)) / \(Self.mib(held.ann * scale))")
        XCTAssertEqual(try world.drift(), [])
    }

    // MARK: - 768 dimensions

    func testA768DimensionalLoadQueryTrainingAndStoragePerElement() async throws {
        let count = 20_000
        let vectors = Support.randomVectors(count, 768, seed: 768)
        var model: Data?
        for element in [VectorElement.f32, .f16, .i8] {
            let encoding = VectorEncoding(dims: 768, element: element)
            if element == .f32 {
                let without = try loaded(try await world("768-plain"), count, encoding) { vectors[$0] }
                let withTriggers = try loaded(try await world("768-triggers"), count, encoding, entry: Self.entry(encoding, index: "exact")) { vectors[$0] }
                Self.log("\(count)-row bulk load of 768-d f32: no vector index / with its triggers (ms)", "\(Self.fixed(without.ms, 0)) / \(Self.fixed(withTriggers.ms, 0))")
                let built = DispatchTime.now()
                try without.store.syncIndexes([Self.entry(encoding, index: "exact")])
                Self.log("flat table built after a \(count)-row load of 768-d f32 (ms)", Self.fixed(Self.ms(built), 0))
                var exact: [Double] = []
                for query in Support.randomVectors(50, 768, seed: 769) {
                    let started = DispatchTime.now()
                    XCTAssertEqual(try Self.near(withTriggers.store, query).count, 10)
                    exact.append(Self.ms(started))
                }
                Self.log("exact $near k=10 at \(count) x 768, p50 / p95 (ms)", "\(Self.fixed(Self.percentile(exact, 0.5))) / \(Self.fixed(Self.percentile(exact, 0.95)))")
            }
            let world = try await world("768-\(element.rawValue)")
            let (store, _) = try loaded(world, count, encoding, entry: Self.entry(encoding)) { vectors[$0] }
            if model == nil {
                let trained = try await Self.train(store)
                Self.log("768-d training, \(trained.sample.count) x 768 sample (nbucket \(trained.sample.params.nbucket), codesize \(trained.sample.params.codesize), \(trained.sample.params.quantizer)) (ms)", Self.fixed(trained.ms, 0))
                Self.log("768-d model in its envelope (bytes)", "\(trained.bytes.count)")
                model = trained.bytes
            }
            _ = try Self.installAndFill(store, try XCTUnwrap(model))
            XCTAssertEqual(try Self.mode(store), "ann")
            let held = try Self.storage(world)
            let field = Double(try VectorCodec.encode(vectors[0], encoding: encoding).utf8.count) * 100_000
            Self.log("storage per 100,000 rows (\(count) measured, x 5), 768-d \(element.rawValue): records / the field's base64 per copy / flat table / ANN table",
                     "\(Self.mib(held.records * 5)) / \(Self.mib(field)) / \(Self.mib(held.flat * 5)) / \(Self.mib(held.ann * 5))")
        }
    }
}
