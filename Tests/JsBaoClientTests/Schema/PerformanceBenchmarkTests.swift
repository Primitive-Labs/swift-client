import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Formal benchmarks for the Work Item 2 acceptance criteria.
///
/// Two quantities each test tracks:
///  - `rowWriteCount` on `BaoModelQueryEngine` — deterministic,
///    unaffected by CI noise, the primary assertion.
///  - Wall-clock time via `CFAbsoluteTimeGetCurrent()` — printed for
///    human review, asserted only against a loose upper bound to
///    catch catastrophic regressions.
///
/// Before Phase B, a single field change on a 1000-record model
/// rewrote all 1000 SQLite rows (full-table rebuild on next query).
/// After Phase B, the same change writes ≤2 rows.
final class PerformanceBenchmarkTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "bench_items",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "name":  FieldDescriptor(type: .string),
            "score": FieldDescriptor(type: .number),
        ]
    )

    private func freshModel(seed: Int = 0) throws -> DynamicModel {
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: schema)
        for i in 0..<seed {
            _ = try model.create(id: "r\(i)", values: [
                "name": .string("n\(i)"), "score": .number(Double(i)),
            ])
        }
        _ = model.query(nil) // drain post-seed async observer work
        return model
    }

    private func timed(_ block: () throws -> Void) rethrows -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        try block()
        return CFAbsoluteTimeGetCurrent() - start
    }

    // MARK: - Work Item 2 acceptance criterion #1

    /// 1000-record model + one field change on one record. SQLite
    /// writes must be bounded by a small constant (2 — direct path
    /// plus the idempotent observer-echo), independent of N.
    /// Pre-Phase-B behavior: 1000 row writes.
    func testSingleUpdateOnLargeModelWritesBoundedRows() throws {
        let model = try freshModel(seed: 1000)
        let before = model.queryEngineInternal.rowWriteCount

        let elapsed = try timed {
            try model.update(id: "r500", values: ["score": .number(9999)])
            _ = model.query(["id": "r500"])  // drain
        }

        let delta = model.queryEngineInternal.rowWriteCount - before
        print("[bench] single-update on 1000 records: \(delta) row writes in \(Int(elapsed * 1000))ms")

        XCTAssertLessThanOrEqual(delta, 2,
            "Single update must write ≤2 rows regardless of model size; got \(delta)")
        XCTAssertLessThan(elapsed, 1.0,
            "Single update must complete well under 1s; took \(elapsed)s")
    }

    // MARK: - Work Item 2 acceptance criterion #2

    /// 100 interleaved writes + queries — total row writes stay
    /// proportional to N + M, not N × M. With the old dirty-flag
    /// rebuild, each query after any write triggered a full table
    /// rewrite, giving O(N² + N·M) writes for N interleaved create+query
    /// pairs.
    func testInterleavedWritesAndQueriesStayLinear() throws {
        let model = try freshModel()
        let before = model.queryEngineInternal.rowWriteCount
        let n = 100

        let elapsed = try timed {
            for i in 0..<n {
                _ = try model.create(id: "r\(i)", values: [
                    "name": .string("n\(i)"), "score": .number(Double(i)),
                ])
                _ = model.query(nil)
            }
        }

        let delta = model.queryEngineInternal.rowWriteCount - before
        print("[bench] 100 interleaved writes+queries: \(delta) row writes in \(Int(elapsed * 1000))ms")

        // Linear upper bound: at most a small constant (3 from the
        // direct + observer-echo duplicate, plus any reconcile-fired
        // touches) per create. Strictly O(N), no N² term.
        let linearBound = n * 3
        XCTAssertLessThanOrEqual(delta, linearBound,
            "100 interleaved ops must stay linear; got \(delta) (bound \(linearBound))")
        XCTAssertLessThan(elapsed, 2.0,
            "100 interleaved ops must complete under 2s; took \(elapsed)s")
    }

    // MARK: - No quadratic regressions on bulk ops

    /// 1000 sequential creates. With the old dirty-flag path a
    /// trailing `query()` would trigger a 1000-row rebuild; per-create
    /// cost was amortized. Now each create writes its own row
    /// directly (plus an observer echo). Total row writes should be
    /// linear in N.
    func testBulkCreateScalesLinearly() throws {
        let model = try freshModel()
        let before = model.queryEngineInternal.rowWriteCount
        let n = 1000

        let elapsed = try timed {
            for i in 0..<n {
                _ = try model.create(id: "r\(i)", values: [
                    "name": .string("n\(i)"), "score": .number(Double(i)),
                ])
            }
            _ = model.query(nil)  // final drain
        }

        let delta = model.queryEngineInternal.rowWriteCount - before
        print("[bench] 1000 bulk creates: \(delta) row writes in \(Int(elapsed * 1000))ms")

        // Bound: direct path + observer-echo = 2 writes per create.
        // Reconcile may nudge the count slightly higher; 3·N is safe.
        XCTAssertLessThanOrEqual(delta, n * 3,
            "1000 creates must stay linear; got \(delta)")
        // Loose upper bound for CI. Tightens as the impl improves.
        XCTAssertLessThan(elapsed, 5.0,
            "1000 creates must complete under 5s; took \(elapsed)s")
    }

    /// 100 queries after the mirror is populated — each query should
    /// be O(result size), not O(total records). The `awaitObserverDrain`
    /// call at the top of `query` is a no-op when the queue is idle.
    func testBulkQueriesAfterSeedAreCheap() throws {
        let model = try freshModel(seed: 1000)
        let before = model.queryEngineInternal.rowWriteCount
        let n = 100

        let elapsed = try timed {
            for _ in 0..<n {
                _ = model.query(["score": ["$gt": 500]])
            }
        }

        let delta = model.queryEngineInternal.rowWriteCount - before
        print("[bench] 100 queries over 1000-row mirror: \(delta) row writes in \(Int(elapsed * 1000))ms")

        // Queries must write ZERO rows — they're pure reads.
        XCTAssertEqual(delta, 0,
            "Queries must not touch the mirror; got \(delta) writes")
        XCTAssertLessThan(elapsed, 2.0,
            "100 queries over 1000 rows must complete under 2s; took \(elapsed)s")
    }

    // MARK: - Print a human-readable summary table

    /// Runs a small matrix of (model size × operation) timings.
    /// Asserts nothing new — all individual checks live in the tests
    /// above — but prints a compact table useful for eyeballing
    /// regressions across runs.
    func testPrintBenchmarkSummary() throws {
        var lines: [String] = [
            "",
            "┌─────────────────────────────┬──────────┬───────────┐",
            "│ scenario                    │ row writes │ time (ms)   │",
            "├─────────────────────────────┼──────────┼───────────┤",
        ]

        func row(_ label: String, _ ops: () throws -> Int) rethrows {
            let start = CFAbsoluteTimeGetCurrent()
            let writes = try ops()
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            lines.append(
                String(format: "│ %-27s │ %8d │ %9d │", (label as NSString).utf8String!, writes, ms)
            )
        }

        try row("seed 1000 records") {
            let m = try freshModel()
            let before = m.queryEngineInternal.rowWriteCount
            for i in 0..<1000 {
                _ = try m.create(id: "r\(i)", values: [
                    "name": .string("n\(i)"), "score": .number(Double(i)),
                ])
            }
            _ = m.query(nil)
            return m.queryEngineInternal.rowWriteCount - before
        }

        try row("update 1 of 1000") {
            let m = try freshModel(seed: 1000)
            let before = m.queryEngineInternal.rowWriteCount
            try m.update(id: "r500", values: ["score": .number(-1)])
            _ = m.query(nil)
            return m.queryEngineInternal.rowWriteCount - before
        }

        try row("100 interleaved writes") {
            let m = try freshModel()
            let before = m.queryEngineInternal.rowWriteCount
            for i in 0..<100 {
                _ = try m.create(id: "r\(i)", values: ["score": .number(Double(i))])
                _ = m.query(nil)
            }
            return m.queryEngineInternal.rowWriteCount - before
        }

        try row("100 queries over 1000") {
            let m = try freshModel(seed: 1000)
            let before = m.queryEngineInternal.rowWriteCount
            for _ in 0..<100 {
                _ = m.query(["score": ["$gt": 500]])
            }
            return m.queryEngineInternal.rowWriteCount - before
        }

        lines.append("└─────────────────────────────┴──────────┴───────────┘")
        print(lines.joined(separator: "\n"))
    }
}
