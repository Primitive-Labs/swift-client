import XCTest
@testable import JsBaoClient
import YSwift

/// What large-document support costs, measured rather than argued (#3436,
/// behavior 20; principle 9).
///
/// Nothing here is thresholded. A number that depends on the machine it ran on
/// is a finding to read, not a gate to fail: the run records them, the project
/// log carries them with the machine, and a later run comparing its own
/// numbers against those is how a regression is noticed.
///
/// The one claim these cases DO enforce is that every measurement was actually
/// taken — a suite that silently measured nothing and printed zeros is worse
/// than no suite, because it looks like evidence (#3435's log records exactly
/// that mistake on the JS side).
final class Format2LatencyHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
            "views": FieldDescriptor(type: .number, indexed: true),
        ]
    )

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-latency-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    // MARK: - Measuring

    /// Milliseconds, p50 and p95, of `body` run `samples` times.
    private func measure(
        _ samples: Int, _ body: (Int) throws -> Void
    ) rethrows -> (p50: Double, p95: Double, count: Int) {
        var timings: [Double] = []
        timings.reserveCapacity(samples)
        for index in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            try body(index)
            timings.append(
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            )
        }
        let sorted = timings.sorted()
        return (
            p50: sorted[sorted.count / 2],
            p95: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            count: sorted.count
        )
    }

    /// Report a row. `print` rather than a logger: this is output for whoever
    /// reads the run, not for the client's log level.
    private func report(_ what: String, _ result: (p50: Double, p95: Double, count: Int)) {
        print(String(
            format: "[#3436 latency] %@ — p50 %.4f ms, p95 %.4f ms (%d samples)",
            what, result.p50, result.p95, result.count
        ))
    }

    // MARK: - The numbers

    /// An ordinary document's read path, with the large-document branch NOT
    /// taken — which is every read on every client that has never opened one.
    ///
    /// The branch itself is one optional test (`if let format2`) in front of
    /// the same engine call the client has always made; what this measures is
    /// that the path around it is intact.
    func testReportsTheOrdinaryReadPathLatency() throws {
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: "ordinary", doc: YDocument())
        for index in 0..<1_000 {
            _ = try model.create(id: "n\(index)", values: [
                "title": .string("row \(index)"), "views": .number(Double(index)),
            ])
        }

        let find = measure(500) { index in
            XCTAssertNotNil(model.find(id: "n\(index % 1_000)"))
        }
        let query = try measure(200) { index in
            let rows = try model.query(["views": .number(Double(index % 1_000))])
            XCTAssertEqual(rows.count, 1)
        }
        let crossDocument = try measure(200) { index in
            _ = try shared.query(["views": .number(Double(index % 1_000))])
        }

        report("format-1 find(id:)", find)
        report("format-1 query(filter)", query)
        report("format-1 cross-document query(filter)", crossDocument)
        XCTAssertEqual(find.count, 500)
        XCTAssertEqual(query.count, 200)
        XCTAssertEqual(crossDocument.count, 200)
    }

    /// A large document's write path end to end: the serialized operation, the
    /// SQLite commit of the merged row and the pending op, the projected row,
    /// and the overlay publish — plus the observer's second, idempotent fold
    /// of the client's own write.
    func testReportsTheLargeDocumentWriteAndFoldLatency() async throws {
        let provider = try await makeProvider()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let document = YDocument()
        let binding = try coordinator.bind(
            documentId: "latency", models: ["Note"], document: document
        )
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: "latency", doc: document)
        model.bindFormat2(binding)

        let create = try measure(200) { index in
            _ = try model.create(id: "w\(index)", values: [
                "title": .string("row \(index)"), "views": .number(Double(index)),
            ])
        }
        binding.settleFolds()

        let find = measure(200) { index in
            XCTAssertNotNil(model.find(id: "w\(index % 200)"))
        }
        let query = try measure(200) { index in
            XCTAssertEqual(try model.query(["views": .number(Double(index % 200))]).count, 1)
        }

        // A peer's whole-page update, from the moment it lands to the moment
        // the merged view answers for it.
        let peer = OverlayDocument()
        try peer.applyUpdate(binding.overlay.encodeStateAsUpdate())
        for index in 0..<1_000 {
            peer.apply(
                OverlayMutation(
                    id: "r\(index)", kind: .create,
                    fields: ["title": .string("remote \(index)")]
                ),
                model: "Note"
            )
        }
        let update = peer.encodeStateAsUpdate()
        let foldStart = DispatchTime.now().uptimeNanoseconds
        try binding.overlay.applyUpdate(update)
        binding.settleFolds()
        let foldMs = Double(DispatchTime.now().uptimeNanoseconds - foldStart) / 1_000_000

        report("format-2 create()", create)
        report("format-2 find(id:)", find)
        report("format-2 query(filter)", query)
        print(String(
            format: "[#3436 latency] format-2 1,000-record remote fold to settlement — %.1f ms",
            foldMs
        ))

        XCTAssertEqual(create.count, 200)
        XCTAssertEqual(
            try model.count(nil), 1_200,
            "the fold settled: every record, local and remote, answers a filtered read"
        )
        XCTAssertGreaterThan(foldMs, 0, "the fold was measured, not skipped")

        // #3437, behavior 13 — the same numbers after the offline-window gate
        // was put at the commit boundary, reported beside the ones #3436
        // recorded on this machine so a regression is visible rather than
        // inferred (principle 9). The intent's declared hot path is the write
        // path, and `create()` is what runs every part of it.
        print("[#3437 latency] after the window gate at the commit boundary, "
            + "against #3436's numbers on this machine:")
        print(String(
            format: "[#3437 latency] format-2 create() — p50 %.4f ms (#3436: 1.0545), "
                + "p95 %.4f ms (#3436: 1.5332)",
            create.p50, create.p95
        ))
        print(String(
            format: "[#3437 latency] format-2 find(id:) — p50 %.4f ms (#3436: 0.0188), "
                + "p95 %.4f ms (#3436: 0.0252)",
            find.p50, find.p95
        ))
        print(String(
            format: "[#3437 latency] format-2 query(filter) — p50 %.4f ms (#3436: 0.0368), "
                + "p95 %.4f ms (#3436: 0.0462)",
            query.p50, query.p95
        ))
        print(String(
            format: "[#3437 latency] format-2 1,000-record fold — %.1f ms (#3436: 99.7)",
            foldMs
        ))

        // And the gate ITSELF, isolated: it is what the write path gained, and
        // it is the reason the window's two numbers are mirrored in memory
        // rather than read from the `_epoch` row on every write.
        let gate = measure(2_000) { _ in
            _ = binding.store.offlineWindowStatus(now: 1_700_000_000_000)
        }
        print(String(
            format: "[#3437 latency] format-2 the offline-window check alone — "
                + "p50 %.4f ms, p95 %.4f ms (%d samples)",
            gate.p50, gate.p95, gate.count
        ))
        XCTAssertEqual(gate.count, 2_000, "the gate was measured, not skipped")
        XCTAssertLessThan(
            gate.p95, 0.05,
            "the window check runs once per write on the declared hot path; a "
            + "p95 this far above an in-memory read means it is reading SQL"
        )
        // A generous ceiling rather than a tight one — this is a tripwire for
        // a change of ORDER, not a benchmark to tune against on a shared
        // machine (#3433's lesson about grading a number).
        XCTAssertLessThan(
            create.p50, 1.0545 * 4,
            "format-2 create() p50 is more than four times #3436's: report it "
            + "as a finding rather than accepting it"
        )
    }
}
