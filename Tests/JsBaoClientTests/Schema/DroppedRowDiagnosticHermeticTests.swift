import XCTest
@testable import JsBaoClient

/// A query row that fails typed decode is surfaced, never silently dropped
/// (#2825).
///
/// The generated `Model.query()` facade maps rows through `init?(row:)` and
/// keeps the ones that decode — a row whose required field is missing or
/// mistyped used to vanish with no error and no log, which is how ~1,000
/// transactions disappeared from an app while the engine still held them.
/// Every drop now goes through `PrimitiveRowDecoder`, which names the model,
/// the row id, and the field(s) that could not be read.
///
/// Server-free: rows are dictionaries, decoded against a hand-written model
/// in the shape codegen emits.
final class DroppedRowDiagnosticHermeticTests: XCTestCase {

    /// Shaped like a generated model: `id` + required scalars read through the
    /// row accessors, `note` optional.
    struct Txn: PrimitiveModel, PrimitiveRowDecodable, Equatable {
        static let modelName = "transactions_2825"
        static let primitiveSchema = PrimitiveSchema(
            name: "transactions_2825",
            fields: [
                "id":      FieldDescriptor(type: .id),
                "amount":  FieldDescriptor(type: .number, required: true),
                "pending": FieldDescriptor(type: .boolean, required: true),
                "tags":    FieldDescriptor(type: .stringset, required: true),
                "note":    FieldDescriptor(type: .string),
            ]
        )

        var id: String
        var amount: Double
        var pending: Bool
        var tags: Set<String>
        var note: String?

        init(id: String, amount: Double, pending: Bool, tags: Set<String>, note: String? = nil) {
            self.id = id; self.amount = amount; self.pending = pending
            self.tags = tags; self.note = note
        }

        init?(record: PrimitiveRecord) {
            return nil // not exercised here — this suite is the row path
        }

        init?(row: [String: JSONValue]) {
            guard let id = row["id"]?.stringValue,
                  let amount = row["amount"]?.numberValue,
                  let pending = row["pending"]?.rowBoolValue,
                  let tags = (row["tags"]?.stringArrayValue).map(Set.init)
            else { return nil }
            self.id = id; self.amount = amount; self.pending = pending
            self.tags = tags; self.note = row["note"]?.stringValue
        }

        func primitiveValues() -> [String: PrimitiveValue] { [:] }
    }

    /// Collects what the failure hook reports. The hook is `@Sendable` (it
    /// fires on whichever thread ran the query), so the collection lives
    /// behind a lock in a reference type rather than in a captured `var`.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [PrimitiveDecodeError] = []

        var failures: [PrimitiveDecodeError] { lock.withLock { storage } }

        func install() {
            PrimitiveRowDecoder.onDecodeFailure = { [self] error in
                lock.withLock { storage.append(error) }
            }
        }
    }

    private func goodRow(id: String) -> [String: JSONValue] {
        [
            "id": .string(id),
            "amount": .number(10),
            "pending": .number(0),
            "tags": .array([.string("a")]),
        ]
    }

    override func tearDown() {
        PrimitiveRowDecoder.onDecodeFailure = nil
        super.tearDown()
    }

    // MARK: - Reporting

    /// The decodable rows still come back; the undecodable one is reported
    /// with its model, id, and offending field instead of vanishing.
    func testDroppedRowIsReportedWithModelIdAndField() throws {
        let recorder = Recorder()
        recorder.install()

        var drifted = goodRow(id: "bad")
        drifted["pending"] = .null

        let decoded = PrimitiveRowDecoder.decodeAll(
            [goodRow(id: "ok1"), drifted, goodRow(id: "ok2")], as: Txn.self
        )

        XCTAssertEqual(decoded.map(\.id), ["ok1", "ok2"])
        let failure = try XCTUnwrap(recorder.failures.first)
        XCTAssertEqual(recorder.failures.count, 1)
        XCTAssertEqual(failure.modelName, "transactions_2825")
        XCTAssertEqual(failure.recordId, "bad")
        XCTAssertEqual(failure.fields, ["pending"])
    }

    /// Every unreadable required field is named — diagnosing the row shouldn't
    /// take one round trip per field. Optional fields never appear: a missing
    /// `note` is not why the row dropped.
    func testReportNamesEveryUnreadableRequiredField() {
        let recorder = Recorder()
        recorder.install()

        let drifted: [String: JSONValue] = [
            "id": .string("bad"),
            "amount": .string("10"),   // wrong type
            // "pending" missing entirely
            "tags": .array([.string("a")]),
        ]
        XCTAssertTrue(PrimitiveRowDecoder.decodeAll([drifted], as: Txn.self).isEmpty)
        XCTAssertEqual(recorder.failures.first?.fields, ["amount", "pending"],
                       "fields should be named, sorted, and required-only")
    }

    /// A row with no readable `id` still reports — `id` itself is the field
    /// that failed, and the record id is empty rather than guessed.
    func testUnreadableIdIsItselfReported() {
        let recorder = Recorder()
        recorder.install()

        var drifted = goodRow(id: "x")
        drifted["id"] = .number(7)

        XCTAssertTrue(PrimitiveRowDecoder.decodeAll([drifted], as: Txn.self).isEmpty)
        XCTAssertEqual(recorder.failures.first?.recordId, "")
        XCTAssertEqual(recorder.failures.first?.fields, ["id"])
    }

    /// The message an app sees names the model, the row, and the field, so a
    /// dropped row is diagnosable from a log line alone.
    func testMessageNamesModelIdAndField() throws {
        let error = PrimitiveDecodeError(
            modelName: "transactions_2825",
            row: ["id": .string("01M08V57Q1"), "pending": .null],
            schema: Txn.primitiveSchema
        )
        XCTAssertEqual(error.fields, ["amount", "pending", "tags"])
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("transactions_2825"), message)
        XCTAssertTrue(message.contains("01M08V57Q1"), message)
        XCTAssertTrue(message.contains("pending"), message)
    }

    /// Rows that all decode report nothing — the diagnostic is for drift, not
    /// a per-query log line.
    func testCleanQueryReportsNothing() {
        let recorder = Recorder()
        recorder.install()
        XCTAssertEqual(
            PrimitiveRowDecoder.decodeAll([goodRow(id: "a"), goodRow(id: "b")], as: Txn.self).count,
            2
        )
        XCTAssertTrue(recorder.failures.isEmpty)
    }

    // MARK: - The other row shapes the facade hands in

    /// `queryPaged` rows arrive as `PrimitiveRow`; single-row reads
    /// (`queryOne` / `findByUnique`) hand in one optional row. Both route
    /// through the same reporting.
    func testPrimitiveRowAndSingleRowPathsAlsoReport() {
        let recorder = Recorder()
        recorder.install()

        var drifted = goodRow(id: "bad")
        drifted["tags"] = .string("not-an-array")

        let paged = PrimitiveRowDecoder.decodeAll(
            [PrimitiveRow(raw: goodRow(id: "ok")), PrimitiveRow(raw: drifted)], as: Txn.self
        )
        XCTAssertEqual(paged.map(\.id), ["ok"])
        XCTAssertNil(PrimitiveRowDecoder.decodeOne(drifted, as: Txn.self))
        XCTAssertEqual(PrimitiveRowDecoder.decodeOne(goodRow(id: "ok"), as: Txn.self)?.id, "ok")
        XCTAssertNil(PrimitiveRowDecoder.decodeOne(nil, as: Txn.self))

        XCTAssertEqual(recorder.failures.count, 2, "paged row + single row both report")
        XCTAssertEqual(recorder.failures.map(\.fields), [["tags"], ["tags"]])
    }
}
