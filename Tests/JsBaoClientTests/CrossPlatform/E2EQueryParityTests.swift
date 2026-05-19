import XCTest
@testable import JsBaoClient

/// **Cross-language end-to-end query parity.**
///
/// Drives two independent CLIs as subprocesses, each backed by a
/// real implementation of the codegen + runtime path:
///
///   - **Swift mini-app** (`E2EMiniApp` target) — uses
///     `swift-bao-codegen` at build time to materialize a
///     `TaskRecord` struct from `E2E/swift/Models/schema.toml`,
///     drives writes via `TypedModel<TaskRecord>` and queries via
///     `dynamic.query` + the codegen-emitted `init?(row:)`.
///
///   - **JS mini-app** (`E2E/js/main.js`) — uses js-bao's
///     `loadSchemaFromTomlString` at *runtime* to load the SAME
///     TOML file, attaches the resulting `DefinedModelSchema` to a
///     hand-written `class Tasks extends BaseModel {}` shell, and
///     drives writes/queries through `BaseModel.save` /
///     `BaseModel.query`.
///
/// **Asymmetry:** Swift codegen is build-time, JS schema loading is
/// runtime. js-bao's own codegen tool (`js-bao-codegen`) does
/// something different from `swift-bao-codegen` — it generates
/// typed relationship-method augmentations on top of hand-written
/// TS classes, NOT TS classes from a TOML. Runtime loading is the
/// closest analog to Swift codegen that js-bao supports today.
/// Both arrive at equivalent `PrimitiveSchema` / `DefinedModelSchema`
/// values from the same TOML; this suite verifies that **records
/// written via either side round-trip with byte-equivalent JSON
/// query results on the other side**.
///
/// The tests also surface a real **js-bao bug**: the BaseModel-
/// level stringset reader (`getStringSetFromYjs` in js-bao 0.3.1)
/// returns Y.Map class-internal property names instead of the
/// actual set members when reading docs another client wrote.
/// The JS CLI documents-and-works-around this by reading the
/// nested Y.Map directly. See the docblock on `taskToJson` in
/// `js/main.js` and the `TestKnownDivergences` group below.
///
/// Skipped via `XCTSkip` if Node isn't installed or the codegen
/// build hasn't run yet.
final class E2EQueryParityTests: XCTestCase {

    // MARK: - Codegen lifecycle

    /// Run `js-bao-codegen-v2` against the shared `schema.toml` once
    /// per test process so the JS subprocess imports a fresh barrel.
    /// Mirrored on the Swift side by SwiftPM's build plugin, which
    /// re-runs `swift-bao-codegen` whenever the TOML changes.
    private static let codegenOnce: Void = {
        do {
            try runJsCodegen()
        } catch {
            // setUp can't throw XCTSkip from a static initializer;
            // record and let `runJsCli` surface the failure as the
            // test starts.
            codegenError = error
        }
    }()
    // XCTest runs cases serially by default in this suite, so plain
    // shared state is fine here without a lock.
    private static var codegenError: Error?

    /// Invoke `E2E/js/codegen.mjs` synchronously. Throws if the
    /// script is missing or exits non-zero. The tail of stderr is
    /// included in any failure so a broken TOML surfaces clearly.
    private static func runJsCodegen() throws {
        let nodePath = try CrossPlatformHarness.nodePath()
        let codegenScript = thisDir
            .appendingPathComponent("E2E/js/codegen.mjs").path
        guard FileManager.default.fileExists(atPath: codegenScript) else {
            throw XCTSkip("E2E/js/codegen.mjs missing at \(codegenScript)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [codegenScript]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "E2EQueryParityTests",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "js-bao-codegen-v2 failed (exit \(proc.terminationStatus)): " +
                    (String(data: errData, encoding: .utf8) ?? "")
                ]
            )
        }
    }

    // MARK: - Sanity: each side writes-then-queries against itself

    func testSwift_writes_then_queries_self() throws {
        let doc = try seedSwift(Self.fixtureRecords)
        let results = try querySwift(
            doc: doc, filter: ["priority": ["$gte": 3]]
        )
        // Should see the two records with priority >= 3 (id: a, c).
        XCTAssertEqual(idsFrom(results), ["a", "c"])
    }

    func testJs_writes_then_queries_self() throws {
        let doc = try seedJs(Self.fixtureRecords)
        let results = try queryJs(
            doc: doc, filter: ["priority": ["$gte": 3]]
        )
        XCTAssertEqual(idsFrom(results), ["a", "c"])
    }

    // MARK: - Cross-language: same query → same results

    func testSwiftWrites_JsQueriesByEq() throws {
        let doc = try seedSwift(Self.fixtureRecords)
        let results = try queryJs(
            doc: doc, filter: ["completed": true]
        )
        XCTAssertEqual(idsFrom(results), ["b"])
    }

    func testSwiftWrites_JsQueriesByGte() throws {
        let doc = try seedSwift(Self.fixtureRecords)
        let results = try queryJs(
            doc: doc, filter: ["priority": ["$gte": 5]]
        )
        XCTAssertEqual(idsFrom(results), ["a"])
    }

    func testSwiftWrites_JsQueriesByContainsStringset() throws {
        let doc = try seedSwift(Self.fixtureRecords)
        let results = try queryJs(
            doc: doc, filter: ["tags": ["$contains": "urgent"]]
        )
        XCTAssertEqual(idsFrom(results), ["a"])
    }

    func testJsWrites_SwiftQueriesByEq() throws {
        let doc = try seedJs(Self.fixtureRecords)
        let results = try querySwift(
            doc: doc, filter: ["completed": true]
        )
        XCTAssertEqual(idsFrom(results), ["b"])
    }

    func testJsWrites_SwiftQueriesByGte() throws {
        let doc = try seedJs(Self.fixtureRecords)
        let results = try querySwift(
            doc: doc, filter: ["priority": ["$gte": 5]]
        )
        XCTAssertEqual(idsFrom(results), ["a"])
    }

    /// **REAL CROSS-LANGUAGE BUG — fails today.**
    ///
    /// Swift writes stringsets as a *nested Y.Map* whose keys are
    /// the set members. js-bao's `BaseModel.save()` writes them as
    /// a plain Y.Object value (`{member: true, ...}`) — a
    /// different Yjs primitive entirely. Cross-client reads via
    /// `record["tags"]?.asStringSet` (Swift) on records js-bao
    /// wrote yield empty / garbage, so a `$contains` filter on a
    /// JS-written doc matches nothing.
    ///
    /// Fix candidates:
    ///   - js-bao adopts Swift's nested-Y.Map shape on write
    ///   - swift-client teaches `.asStringSet` to also handle
    ///     the JSON-object shape on read
    ///   - both: coordinated migration to a canonical format
    ///
    /// See E2E/README.md → Known divergences.
    func testJsWritesStringset_SwiftReadsContent() throws {
        let doc = try seedJs(Self.fixtureRecords)
        let results = try querySwift(
            doc: doc, filter: ["tags": ["$contains": "urgent"]]
        )
        // The 'a' record has tag "urgent" — Swift should find it.
        XCTAssertEqual(idsFrom(results), ["a"],
                       "Swift should find JS-written stringset members via $contains — see test docblock for fix candidates")
    }

    // MARK: - Sort + limit parity

    func testSwiftWrites_BothQueryWithSort_OrderMatches() throws {
        let doc = try seedSwift(Self.fixtureRecords)
        let sortDesc: [[String: Any]] = [
            ["field": "priority", "dir": -1],
            ["field": "id", "dir": 1],
        ]
        let s = try querySwift(doc: doc, sort: sortDesc)
        let j = try queryJs(doc: doc, sort: sortDesc)
        XCTAssertEqual(idsFrom(s), idsFrom(j),
                       "Swift and JS should agree on multi-field sort order")
        // Sanity: priority-desc → highest first.
        XCTAssertEqual(idsFrom(s).first, "a",
                       "highest priority record should be first")
    }

    func testLimitAgreesAcrossLanguages() throws {
        // `limit` is the simplest pagination primitive — both
        // clients support it identically. Cursor-based pagination
        // (the more interesting case) is exercised by
        // `testCursorPaginationAgreesAcrossLanguages` below.
        let doc = try seedJs(Self.fixtureRecords)
        let sortAsc: [[String: Any]] = [["field": "id", "dir": 1]]
        let s = try querySwift(doc: doc, sort: sortAsc, limit: 2)
        let j = try queryJs(doc: doc, sort: sortAsc, limit: 2)
        XCTAssertEqual(idsFrom(s), idsFrom(j),
                       "limit-only pagination should agree across languages")
        XCTAssertEqual(idsFrom(s).count, 2,
                       "limit=2 should yield exactly two records")
    }

    /// Cursor-based pagination parity. Swift's `QueryOptions.cursor`
    /// and js-bao's `uniqueStartKey` are the canonical pagination
    /// primitive on both sides — opaque string, "after this row in
    /// the sort order." Walk every page on each client and assert
    /// they cover the same row sequence.
    ///
    /// The cursor itself is opaque per-client (Swift's encoding
    /// doesn't have to match js-bao's), so the test feeds each
    /// client back its own `nextCursor` rather than swapping
    /// cursors across the language boundary. The contract under
    /// test is: given the same data and the same page size, both
    /// clients walk the same rows in the same order.
    ///
    /// Replaces the older offset-based test — `QueryOptions.offset`
    /// is now deprecated on Swift (unstable under concurrent
    /// inserts in CRDT-backed docs), js-bao never had it.
    func testCursorPaginationAgreesAcrossLanguages() throws {
        // Five records ensures multi-page walks at limit:2.
        let records: [[String: Any]] = ["a", "b", "c", "d", "e"].map { id in
            [
                "id": id, "title": "T\(id)",
                "priority": 1, "completed": false,
                "tags": ["x"],
                "createdAt": "2026-04-30T00:00:00Z",
            ]
        }
        let doc = try seedSwift(records)
        let sortAsc: [[String: Any]] = [["field": "id", "dir": 1]]

        let swiftIds = try walkAllPagesSwift(
            doc: doc, sort: sortAsc, pageSize: 2
        )
        let jsIds = try walkAllPagesJs(
            doc: doc, sort: sortAsc, pageSize: 2
        )

        XCTAssertEqual(swiftIds, ["a", "b", "c", "d", "e"],
                       "Swift cursor pagination should walk all rows in sort order")
        XCTAssertEqual(jsIds, ["a", "b", "c", "d", "e"],
                       "JS cursor pagination should walk all rows in sort order")
        XCTAssertEqual(swiftIds, jsIds,
                       "Swift and JS should walk the same row sequence under cursor pagination")
    }

    /// Walk every page on the Swift CLI and concatenate ids.
    /// Stops when `nextCursor` is nil. Bounded by a safety counter
    /// so a faulty cursor implementation can't hang the test.
    private func walkAllPagesSwift(
        doc: String,
        sort: [[String: Any]],
        pageSize: Int,
        mode: String = "typed",
        model: String = "tasks"
    ) throws -> [String] {
        var ids: [String] = []
        var cursor: String? = nil
        for _ in 0..<100 {
            let page = try queryPagedSwift(
                doc: doc, sort: sort, limit: pageSize,
                cursor: cursor, mode: mode, model: model
            )
            ids.append(contentsOf: idsFrom(page.rows))
            guard let next = page.nextCursor else { return ids }
            cursor = next
        }
        XCTFail("walkAllPagesSwift exceeded 100 pages — likely a cursor loop")
        return ids
    }

    private func walkAllPagesJs(
        doc: String,
        sort: [[String: Any]],
        pageSize: Int,
        model: String = "tasks"
    ) throws -> [String] {
        var ids: [String] = []
        var cursor: String? = nil
        for _ in 0..<100 {
            let page = try queryPagedJs(
                doc: doc, sort: sort, limit: pageSize,
                cursor: cursor, model: model
            )
            ids.append(contentsOf: idsFrom(page.rows))
            guard let next = page.nextCursor else { return ids }
            cursor = next
        }
        XCTFail("walkAllPagesJs exceeded 100 pages — likely a cursor loop")
        return ids
    }

    // MARK: - Field-by-field equivalence on the FULL set

    func testSwiftWrites_JsRoundTripsEveryFieldByteEquivalent() throws {
        let doc = try seedSwift(Self.fixtureRecords)
        let s = try querySwift(doc: doc, sort: [["field": "id", "dir": 1]])
        let j = try queryJs(doc: doc, sort: [["field": "id", "dir": 1]])
        XCTAssertEqual(s.count, j.count, "row counts should match")
        for (sr, jr) in zip(s, j) {
            XCTAssertEqual(canonicalize(sr), canonicalize(jr),
                           "records should be byte-equivalent across language boundary: id=\(sr["id"] ?? "?")")
        }
    }

    // MARK: - Swift typed vs Swift dynamic — same data, two paths
    //
    // Verifies that `TypedModel<TaskRecord>` (codegen) and
    // `DynamicModel(doc:, schema:)` (runtime stringly access)
    // produce identical observable results when reading the same
    // doc. Catches drift between Swift's two runtime paths.

    func testSwiftTypedAndDynamicProduceIdenticalResults() throws {
        let doc = try seedSwift(Self.fixtureRecords)
        let typed = try querySwift(
            doc: doc, sort: [["field": "id", "dir": 1]], mode: "typed"
        )
        let dynamic = try querySwift(
            doc: doc, sort: [["field": "id", "dir": 1]], mode: "dynamic"
        )
        XCTAssertEqual(idsFrom(typed), idsFrom(dynamic),
                       "Swift typed and dynamic paths should return same row set")
        for (t, d) in zip(typed, dynamic) {
            XCTAssertEqual(canonicalize(t), canonicalize(d),
                           "Swift typed and dynamic should agree per record")
        }
    }

    func testSwiftDynamicSeedReadByJsAndSwiftAgree() throws {
        // Seed via Swift dynamic, then read the same doc via JS
        // (runtime) and via Swift typed (codegen). All three paths
        // should agree on the result set.
        let doc = try seedSwift(
            Self.fixtureRecords, mode: "dynamic"
        )
        let jsResults = try queryJs(
            doc: doc, sort: [["field": "id", "dir": 1]]
        )
        let swiftTyped = try querySwift(
            doc: doc, sort: [["field": "id", "dir": 1]], mode: "typed"
        )
        XCTAssertEqual(idsFrom(jsResults), idsFrom(swiftTyped),
                       "JS and Swift typed should both read what Swift dynamic wrote")
        for (j, s) in zip(jsResults, swiftTyped) {
            XCTAssertEqual(canonicalize(j), canonicalize(s))
        }
    }

    // MARK: - Comprehensive field-type round trip
    //
    // The `everything` model exercises every TOML field type with
    // edge-case values: Unicode, integer boundaries, float
    // precision, multiple ISO date formats, mixed-script
    // stringsets. Each test pins a specific field's behavior.

    func testEverything_swiftSeedJsRead_scalars() throws {
        // Seed `everything` via Swift dynamic mode (no codegen
        // wrapper exists for this model), read back via JS.
        // Verifies: int, float, boolean, string Unicode, date all
        // survive cross-language.
        let doc = try seedSwift(
            Self.everythingFixture, mode: "dynamic", model: "everything"
        )
        let result = try findJs(
            doc: doc, id: "kitchen-sink", model: "everything"
        )
        let r = try XCTUnwrap(result, "JS should find Swift-written record")

        XCTAssertEqual(r["label"] as? String, "the one record")
        XCTAssertEqual(r["intSmall"] as? Int, 42)
        XCTAssertEqual(r["floatNeg"] as? Double, -3.14159)
        XCTAssertEqual(r["flag"] as? Bool, true)
        XCTAssertEqual(r["textChinese"] as? String,
                       "中文测试 — 繁體字 — ひらがな — 한글")
        XCTAssertEqual(r["textEmoji"] as? String, "🎉🎊✨ 🐉 👨‍👩‍👧‍👦 🇯🇵")
        XCTAssertEqual(r["textSpecial"] as? String,
                       "embedded \"quote\" + newline\nlast")
        XCTAssertEqual(r["tsZ"] as? String, "2026-04-30T12:00:00Z")
        XCTAssertEqual(r["tsOffset"] as? String, "2026-04-30T21:00:00+09:00")
        XCTAssertEqual(r["tsFractional"] as? String, "2026-04-30T12:00:00.123Z")
    }

    func testEverything_jsSeedSwiftRead_scalars() throws {
        let doc = try seedJs(Self.everythingFixture, model: "everything")
        let result = try findSwift(
            doc: doc, id: "kitchen-sink",
            mode: "dynamic", model: "everything"
        )
        let r = try XCTUnwrap(result, "Swift should find JS-written record")

        XCTAssertEqual(r["label"] as? String, "the one record")
        XCTAssertEqual(r["intSmall"] as? Int, 42)
        XCTAssertEqual(r["floatNeg"] as? Double, -3.14159)
        XCTAssertEqual(r["flag"] as? Bool, true)
        XCTAssertEqual(r["textChinese"] as? String,
                       "中文测试 — 繁體字 — ひらがな — 한글")
        XCTAssertEqual(r["textEmoji"] as? String, "🎉🎊✨ 🐉 👨‍👩‍👧‍👦 🇯🇵")
        XCTAssertEqual(r["textSpecial"] as? String,
                       "embedded \"quote\" + newline\nlast")
        XCTAssertEqual(r["tsZ"] as? String, "2026-04-30T12:00:00Z")
    }

    func testEverything_floatPrecisionSurvivesBothDirections() throws {
        // 0.1 + 0.2 = 0.30000000000000004 in IEEE-754. Both clients
        // should preserve the exact bit pattern.
        let docFromSwift = try seedSwift(
            Self.everythingFixture, mode: "dynamic", model: "everything"
        )
        let r1 = try XCTUnwrap(try findJs(
            doc: docFromSwift, id: "kitchen-sink", model: "everything"
        ))
        XCTAssertEqual(r1["floatPrecise"] as? Double, 0.1 + 0.2,
                       "0.1 + 0.2 should round-trip Swift→JS bit-exact")

        let docFromJs = try seedJs(Self.everythingFixture, model: "everything")
        let r2 = try XCTUnwrap(try findSwift(
            doc: docFromJs, id: "kitchen-sink",
            mode: "dynamic", model: "everything"
        ))
        XCTAssertEqual(r2["floatPrecise"] as? Double, 0.1 + 0.2,
                       "0.1 + 0.2 should round-trip JS→Swift bit-exact")
    }

    func testEverything_intLargeAtMaxSafe_bothDirections() throws {
        // 9_007_199_254_740_991 = Number.MAX_SAFE_INTEGER. AT this
        // boundary, both clients preserve exactness. ABOVE it, JS
        // loses precision (any integer > 2^53 - 1 gets rounded). We
        // pin AT the boundary here; an above-boundary test would be
        // a known divergence.
        let doc = try seedSwift(
            Self.everythingFixture, mode: "dynamic", model: "everything"
        )
        let r = try XCTUnwrap(try findJs(
            doc: doc, id: "kitchen-sink", model: "everything"
        ))
        // JSON deserialization may produce Int or Double for large
        // values depending on the platform. Coerce both ways.
        let n: Int64? = (r["intLarge"] as? Int).map { Int64($0) }
            ?? (r["intLarge"] as? Double).map { Int64($0) }
        XCTAssertEqual(n, 9_007_199_254_740_991,
                       "MAX_SAFE_INTEGER should round-trip exactly")
    }

    /// **REAL CROSS-LANGUAGE BUG — fails today.** Same wire-format
    /// mismatch as `testJsWritesStringset_SwiftReadsContent`,
    /// confirmed with mixed-script Unicode members. The Swift→JS
    /// direction works (JS reads via raw-Y.Map workaround); the
    /// JS→Swift direction returns empty.
    ///
    /// See E2E/README.md → Known divergences.
    func testEverything_stringsetMixedScript_roundTripsBothDirections() throws {
        // Swift→JS direction works (JS bypasses BaseModel stringset
        // wrapper via the raw Y.Map / plain Y.Object fallback).
        let docFromSwift = try seedSwift(
            Self.everythingFixture, mode: "dynamic", model: "everything"
        )
        let r1 = try XCTUnwrap(try findJs(
            doc: docFromSwift, id: "kitchen-sink", model: "everything"
        ))
        XCTAssertEqual(
            (r1["tags"] as? [String])?.sorted(),
            ["english", "with space", "中文", "🎉"].sorted(),
            "Swift→JS stringset Unicode round-trip"
        )

        // JS→Swift fails today: Swift's `.asStringSet` expects a
        // nested Y.Map but js-bao writes a plain Y.Object.
        let docFromJs = try seedJs(Self.everythingFixture, model: "everything")
        let r2 = try XCTUnwrap(try findSwift(
            doc: docFromJs, id: "kitchen-sink",
            mode: "dynamic", model: "everything"
        ))
        XCTAssertEqual(
            (r2["tags"] as? [String])?.sorted(),
            ["english", "with space", "中文", "🎉"].sorted(),
            "JS→Swift stringset Unicode round-trip — fails because Swift expects nested Y.Map but js-bao writes plain Y.Object"
        )
    }

    // MARK: - Wire-byte equality (inspect command)
    //
    // For each declared field, both clients dump the raw value
    // stored under that key in the record's nested Y.Map. For
    // scalars, this is the JSON-encoded bytes (`"\"hello\""`,
    // `"42"`, `"true"`). For stringsets, both sides are normalized
    // to a sorted member array (the storage shape differs, but the
    // logical set should match).

    func testInspect_swiftWritesEverything_swiftAndJsByteEquivalent() throws {
        let doc = try seedSwift(
            Self.everythingFixture, mode: "dynamic", model: "everything"
        )
        let s = try inspectSwift(doc: doc, id: "kitchen-sink", model: "everything")
        let j = try inspectJs(doc: doc, id: "kitchen-sink", model: "everything")

        // Per-field comparison. Stringsets are arrays; scalars are
        // raw JSON-encoded strings as written by PrimitiveValue
        // (JS reads the same raw string from the Y.Map).
        for fname in [
            "id", "label", "intSmall", "intLarge", "floatPrecise",
            "floatNeg", "flag", "textChinese", "textEmoji",
            "textSpecial", "tsZ", "tsOffset", "tsFractional",
            "tags",
        ] {
            let sv = s[fname]
            let jv = j[fname]
            // Stringset: both arrays.
            if let sa = sv as? [String], let ja = jv as? [String] {
                XCTAssertEqual(sa.sorted(), ja.sorted(),
                               "stringset field '\(fname)' wire-byte mismatch")
            } else {
                XCTAssertEqual(
                    String(describing: sv ?? NSNull()),
                    String(describing: jv ?? NSNull()),
                    "field '\(fname)' wire-byte mismatch: swift=\(sv ?? "nil") js=\(jv ?? "nil")"
                )
            }
        }
    }

    // MARK: - Shared-doc / merge semantics
    //
    // Build a doc up across multiple subprocess invocations:
    // one client seeds record A, the other receives the doc bytes
    // and adds record B, then both query and assert both records
    // are present. Tests CRDT merge behavior across the boundary.

    func testSharedDoc_swiftSeedsThenJsAdds_bothQueryWithBoth() throws {
        // 1. Swift writes record A
        let doc1 = try seedSwift([
            ["id": "swift-a", "title": "From Swift",
             "priority": 1, "completed": false,
             "tags": ["origin-swift"],
             "createdAt": "2026-04-30T10:00:00Z"],
        ])
        // 2. JS receives doc bytes, adds record B without touching A
        let doc2 = try seedJs([
            ["id": "js-b", "title": "From JS",
             "priority": 2, "completed": true,
             "tags": ["origin-js"],
             "createdAt": "2026-04-30T11:00:00Z"],
        ], existingDoc: doc1)
        // 3. Both clients should see both records
        let bySwift = try querySwift(doc: doc2,
                                     sort: [["field": "id", "dir": 1]])
        let byJs = try queryJs(doc: doc2,
                               sort: [["field": "id", "dir": 1]])
        XCTAssertEqual(idsFrom(bySwift), ["js-b", "swift-a"])
        XCTAssertEqual(idsFrom(byJs), ["js-b", "swift-a"])
    }

    func testSharedDoc_jsSeedsThenSwiftAdds_bothQueryWithBoth() throws {
        let doc1 = try seedJs([
            ["id": "js-a", "title": "From JS",
             "priority": 1, "completed": false,
             "tags": ["origin-js"],
             "createdAt": "2026-04-30T10:00:00Z"],
        ])
        let doc2 = try seedSwift([
            ["id": "swift-b", "title": "From Swift",
             "priority": 2, "completed": true,
             "tags": ["origin-swift"],
             "createdAt": "2026-04-30T11:00:00Z"],
        ], existingDoc: doc1)
        let bySwift = try querySwift(doc: doc2,
                                     sort: [["field": "id", "dir": 1]])
        let byJs = try queryJs(doc: doc2,
                               sort: [["field": "id", "dir": 1]])
        XCTAssertEqual(idsFrom(bySwift), ["js-a", "swift-b"])
        XCTAssertEqual(idsFrom(byJs), ["js-a", "swift-b"])
    }

    // MARK: - Cross-language relationship resolution
    //
    // Both mini-apps load the SAME schema.toml — including the
    // `users` ↔ `posts` ↔ `tags` (via `post_tag_links`) relationship
    // models. Each test seeds via one language's mini-app and
    // resolves the relationship via the other. The asserted
    // invariant is "same input doc + same relationship name + same
    // record id → same resolved set in the same order, regardless
    // of which language wrote vs which read".
    //
    // The resolver implementations are independent ports (Swift's
    // `RelationshipResolution` extension on `PrimitiveRecord`; JS's
    // auto-attached BaseModel methods via `RelationshipManager`).
    // They share NO code, so this is a real parity guard against
    // future divergence in filter/sort/edge-case semantics.

    /// `refersTo` — Swift writes posts + author; JS resolves
    /// `post.author()` → matching user record. Round-trips the
    /// FK string field plus the resolver's `find(id:)` behavior.
    func testRefersTo_swiftWritesPosts_jsResolvesAuthor() throws {
        var doc = try seedSwift(
            [["id": "u1", "name": "Alice"]],
            mode: "dynamic", model: "users"
        )
        doc = try seedSwift(
            [["id": "p1", "title": "hello", "userId": "u1",
              "createdAt": "2026-01-01T00:00:00Z"]],
            existingDoc: doc, mode: "dynamic", model: "posts"
        )
        let results = try resolveRelationshipJs(
            doc: doc, model: "posts", id: "p1", relationship: "author"
        )
        XCTAssertEqual(results.count, 1, "refersTo should resolve to 1 user")
        XCTAssertEqual(results.first?["id"] as? String, "u1")
        XCTAssertEqual(results.first?["name"] as? String, "Alice")
    }

    /// `refersTo` reverse direction — JS writes; Swift resolves.
    func testRefersTo_jsWritesPosts_swiftResolvesAuthor() throws {
        var doc = try seedJs(
            [["id": "u1", "name": "Alice"]], model: "users"
        )
        doc = try seedJs(
            [["id": "p1", "title": "hello", "userId": "u1",
              "createdAt": "2026-01-01T00:00:00Z"]],
            existingDoc: doc, model: "posts"
        )
        let results = try resolveRelationshipSwift(
            doc: doc, model: "posts", id: "p1", relationship: "author"
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["id"] as? String, "u1")
        XCTAssertEqual(results.first?["name"] as? String, "Alice")
    }

    /// `refersTo` with a missing target id — both sides should
    /// return empty results, not crash. Pins resolver behavior at
    /// the FK-points-nowhere edge.
    func testRefersTo_missingTarget_emptyOnBothSides() throws {
        // Seed posts whose userId doesn't exist as a user; verify
        // both resolvers return [].
        let doc = try seedSwift(
            [["id": "p1", "title": "orphan", "userId": "ghost",
              "createdAt": "2026-01-01T00:00:00Z"]],
            mode: "dynamic", model: "posts"
        )
        XCTAssertEqual(try resolveRelationshipSwift(
            doc: doc, model: "posts", id: "p1", relationship: "author"
        ).count, 0)
        XCTAssertEqual(try resolveRelationshipJs(
            doc: doc, model: "posts", id: "p1", relationship: "author"
        ).count, 0)
    }

    /// `hasMany` with `order_by_field` + `order_direction` — Swift
    /// writes a user + multiple posts in arbitrary insertion order;
    /// JS resolves `user.posts()` and the result must come back in
    /// `createdAt asc` order, filtered to just this user's posts.
    func testHasMany_swiftWritesPosts_jsResolvesUserPostsInOrder() throws {
        var doc = try seedSwift(
            [["id": "u1", "name": "Alice"], ["id": "u2", "name": "Bob"]],
            mode: "dynamic", model: "users"
        )
        doc = try seedSwift(
            [
              // Insert out of `createdAt` order to make the asc-sort
              // assertion below meaningful.
              ["id": "p2", "title": "second", "userId": "u1",
               "createdAt": "2026-02-01T00:00:00Z"],
              ["id": "p1", "title": "first",  "userId": "u1",
               "createdAt": "2026-01-01T00:00:00Z"],
              ["id": "px", "title": "other-user", "userId": "u2",
               "createdAt": "2026-01-15T00:00:00Z"],
            ],
            existingDoc: doc, mode: "dynamic", model: "posts"
        )
        let results = try resolveRelationshipJs(
            doc: doc, model: "users", id: "u1", relationship: "posts"
        )
        XCTAssertEqual(idsFrom(results), ["p1", "p2"],
                       "hasMany should filter to u1's posts and sort by createdAt asc")
    }

    /// `hasMany` reverse direction — JS writes, Swift resolves.
    func testHasMany_jsWritesPosts_swiftResolvesUserPostsInOrder() throws {
        var doc = try seedJs(
            [["id": "u1", "name": "Alice"], ["id": "u2", "name": "Bob"]],
            model: "users"
        )
        doc = try seedJs(
            [
              ["id": "p2", "title": "second", "userId": "u1",
               "createdAt": "2026-02-01T00:00:00Z"],
              ["id": "p1", "title": "first",  "userId": "u1",
               "createdAt": "2026-01-01T00:00:00Z"],
              ["id": "px", "title": "other-user", "userId": "u2",
               "createdAt": "2026-01-15T00:00:00Z"],
            ],
            existingDoc: doc, model: "posts"
        )
        let results = try resolveRelationshipSwift(
            doc: doc, model: "users", id: "u1", relationship: "posts"
        )
        XCTAssertEqual(idsFrom(results), ["p1", "p2"])
    }

    /// `hasManyThrough` — Swift writes posts + tags + join rows;
    /// JS resolves `post.tags()` walking through `post_tag_links`.
    /// Pins both legs of the join (`joinModelLocalField`,
    /// `joinModelRelatedField`) plus the target lookup.
    func testHasManyThrough_swiftWrites_jsResolvesPostTags() throws {
        var doc = try seedSwift(
            [["id": "u1", "name": "Alice"]],
            mode: "dynamic", model: "users"
        )
        doc = try seedSwift(
            [["id": "p1", "title": "hello", "userId": "u1",
              "createdAt": "2026-01-01T00:00:00Z"]],
            existingDoc: doc, mode: "dynamic", model: "posts"
        )
        doc = try seedSwift(
            [["id": "t1", "name": "swift"], ["id": "t2", "name": "yjs"],
             ["id": "t3", "name": "decoy-not-on-p1"]],
            existingDoc: doc, mode: "dynamic", model: "tags"
        )
        doc = try seedSwift(
            [["id": "l1", "postId": "p1", "tagId": "t1"],
             ["id": "l2", "postId": "p1", "tagId": "t2"],
             // Decoy: a join row pointing at a different post.
             ["id": "l3", "postId": "other", "tagId": "t3"]],
            existingDoc: doc, mode: "dynamic", model: "post_tag_links"
        )
        let results = try resolveRelationshipJs(
            doc: doc, model: "posts", id: "p1", relationship: "tags"
        )
        let resolvedIds = Set(results.compactMap { $0["id"] as? String })
        XCTAssertEqual(resolvedIds, ["t1", "t2"],
                       "hasManyThrough should walk join rows for p1 and resolve tag ids")
    }

    /// `hasManyThrough` reverse direction — JS writes, Swift resolves.
    func testHasManyThrough_jsWrites_swiftResolvesPostTags() throws {
        var doc = try seedJs(
            [["id": "u1", "name": "Alice"]], model: "users"
        )
        doc = try seedJs(
            [["id": "p1", "title": "hello", "userId": "u1",
              "createdAt": "2026-01-01T00:00:00Z"]],
            existingDoc: doc, model: "posts"
        )
        doc = try seedJs(
            [["id": "t1", "name": "swift"], ["id": "t2", "name": "yjs"],
             ["id": "t3", "name": "decoy-not-on-p1"]],
            existingDoc: doc, model: "tags"
        )
        doc = try seedJs(
            [["id": "l1", "postId": "p1", "tagId": "t1"],
             ["id": "l2", "postId": "p1", "tagId": "t2"],
             ["id": "l3", "postId": "other", "tagId": "t3"]],
            existingDoc: doc, model: "post_tag_links"
        )
        let results = try resolveRelationshipSwift(
            doc: doc, model: "posts", id: "p1", relationship: "tags"
        )
        let resolvedIds = Set(results.compactMap { $0["id"] as? String })
        XCTAssertEqual(resolvedIds, ["t1", "t2"])
    }

    // MARK: - Fixtures + helpers

    /// Fixture set used by every test. Three records covering each
    /// query-relevant axis:
    ///   - id "a": priority 5, NOT completed, has 'urgent' tag
    ///   - id "b": priority 1, completed, has 'done' tag
    ///   - id "c": priority 3, NOT completed, has 'wip' tag
    private static let fixtureRecords: [[String: Any]] = [
        [
            "id": "a", "title": "Ship it",
            "priority": 5, "completed": false,
            "tags": ["urgent", "ship-blocker"],
            "createdAt": "2026-04-28T10:00:00Z",
        ],
        [
            "id": "b", "title": "Polish",
            "priority": 1, "completed": true,
            "tags": ["done"],
            "createdAt": "2026-04-28T11:00:00Z",
        ],
        [
            "id": "c", "title": "Rewrite",
            "priority": 3, "completed": false,
            "tags": ["wip"],
            "createdAt": "2026-04-28T12:00:00Z",
        ],
    ]

    /// Comprehensive `everything` fixture — one record exercising
    /// every field type with edge cases (Chinese, emoji, integer
    /// boundaries, float precision, multiple ISO date formats).
    /// Driven through dynamic mode on Swift (no codegen wrapper for
    /// `everything`) and runtime-loaded on JS. Each test does a
    /// per-field round-trip assertion.
    private static let everythingFixture: [[String: Any]] = [
        [
            "id": "kitchen-sink",
            "label": "the one record",
            // Integer edges. JS Number is f64, so anything > 2^53 - 1
            // (9_007_199_254_740_991) loses precision when round-
            // tripped through JSON.parse. We test below the limit
            // here; an above-limit test is marked _KNOWN_DIVERGENCE.
            "intSmall": 42,
            "intLarge": 9_007_199_254_740_991,  // Number.MAX_SAFE_INTEGER
            // Floats — both clients use f64. `0.1 + 0.2` is the
            // canonical floating-point pinata; both should produce
            // 0.30000000000000004 byte-equivalent.
            "floatPrecise": 0.1 + 0.2,
            "floatNeg":     -3.14159,
            "flag": true,
            // Unicode survival across the boundary.
            "textChinese":  "中文测试 — 繁體字 — ひらがな — 한글",
            "textEmoji":    "🎉🎊✨ 🐉 👨‍👩‍👧‍👦 🇯🇵",
            "textSpecial":  "embedded \"quote\" + newline\nlast",
            // ISO date variants.
            "tsZ":           "2026-04-30T12:00:00Z",
            "tsOffset":      "2026-04-30T21:00:00+09:00",
            "tsFractional":  "2026-04-30T12:00:00.123Z",
            // Stringset with mixed scripts.
            "tags": ["english", "中文", "🎉", "with space"],
        ],
    ]

    private func idsFrom(_ records: [[String: Any]]) -> [String] {
        records.compactMap { $0["id"] as? String }
    }

    /// Convert a record dict to a stable `String` for byte-comparison
    /// across language boundaries. JSON object key order isn't stable
    /// in `JSONSerialization`, so sort keys explicitly.
    private func canonicalize(_ record: [String: Any]) -> String {
        let sortedKeys = record.keys.sorted()
        var pairs: [String] = []
        for k in sortedKeys {
            let v = record[k]
            // For arrays (stringsets), pre-sort.
            if let arr = v as? [String] {
                pairs.append("\(k)=[\(arr.sorted().joined(separator: ","))]")
            } else {
                pairs.append("\(k)=\(String(describing: v ?? NSNull()))")
            }
        }
        return pairs.joined(separator: "|")
    }

    // MARK: - CLI subprocess plumbing

    private func seedSwift(
        _ records: [[String: Any]],
        existingDoc: String? = nil,
        mode: String = "typed",
        model: String = "tasks"
    ) throws -> String {
        var cmd: [String: Any] = [
            "cmd": "seed", "records": records,
            "mode": mode, "model": model,
        ]
        if let existingDoc { cmd["doc"] = existingDoc }
        let out = try runSwiftCli(cmd: cmd)
        return try XCTUnwrap(out["doc"] as? String, "swift seed didn't produce 'doc'")
    }

    private func seedJs(
        _ records: [[String: Any]],
        existingDoc: String? = nil,
        model: String = "tasks"
    ) throws -> String {
        var cmd: [String: Any] = [
            "cmd": "seed", "records": records, "model": model,
        ]
        if let existingDoc { cmd["doc"] = existingDoc }
        let out = try runJsCli(cmd: cmd)
        return try XCTUnwrap(out["doc"] as? String, "js seed didn't produce 'doc'")
    }

    private func querySwift(
        doc: String,
        filter: [String: Any]? = nil,
        sort: [[String: Any]]? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        mode: String = "typed",
        model: String = "tasks"
    ) throws -> [[String: Any]] {
        return try queryPagedSwift(
            doc: doc, filter: filter, sort: sort, limit: limit,
            cursor: cursor, mode: mode, model: model
        ).rows
    }

    private func queryJs(
        doc: String,
        filter: [String: Any]? = nil,
        sort: [[String: Any]]? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        model: String = "tasks"
    ) throws -> [[String: Any]] {
        return try queryPagedJs(
            doc: doc, filter: filter, sort: sort, limit: limit,
            cursor: cursor, model: model
        ).rows
    }

    /// Paginated query: returns rows + opaque `nextCursor` (nil when
    /// the page is the last one). Used by the cross-language cursor
    /// pagination test to walk pages on each side.
    private struct PagedResponse {
        let rows: [[String: Any]]
        let nextCursor: String?
    }

    private func queryPagedSwift(
        doc: String,
        filter: [String: Any]? = nil,
        sort: [[String: Any]]? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        mode: String = "typed",
        model: String = "tasks"
    ) throws -> PagedResponse {
        var cmd: [String: Any] = [
            "cmd": "query", "doc": doc,
            "mode": mode, "model": model,
        ]
        if let filter { cmd["filter"] = filter }
        if let sort   { cmd["sort"] = sort }
        if let limit  { cmd["limit"] = limit }
        if let cursor { cmd["cursor"] = cursor }
        let out = try runSwiftCli(cmd: cmd)
        return PagedResponse(
            rows: (out["results"] as? [[String: Any]]) ?? [],
            nextCursor: out["nextCursor"] as? String
        )
    }

    private func queryPagedJs(
        doc: String,
        filter: [String: Any]? = nil,
        sort: [[String: Any]]? = nil,
        limit: Int? = nil,
        cursor: String? = nil,
        model: String = "tasks"
    ) throws -> PagedResponse {
        var cmd: [String: Any] = ["cmd": "query", "doc": doc, "model": model]
        if let filter { cmd["filter"] = filter }
        if let sort   { cmd["sort"] = sort }
        if let limit  { cmd["limit"] = limit }
        if let cursor { cmd["cursor"] = cursor }
        let out = try runJsCli(cmd: cmd)
        return PagedResponse(
            rows: (out["results"] as? [[String: Any]]) ?? [],
            nextCursor: out["nextCursor"] as? String
        )
    }

    /// Find one record on Swift side; defaults to typed mode.
    private func findSwift(
        doc: String, id: String,
        mode: String = "typed", model: String = "tasks"
    ) throws -> [String: Any]? {
        let cmd: [String: Any] = [
            "cmd": "find", "doc": doc, "id": id,
            "mode": mode, "model": model,
        ]
        let out = try runSwiftCli(cmd: cmd)
        return (out["record"] as? [String: Any])
    }

    /// Find one record on JS side.
    private func findJs(
        doc: String, id: String, model: String = "tasks"
    ) throws -> [String: Any]? {
        let cmd: [String: Any] = [
            "cmd": "find", "doc": doc, "id": id, "model": model,
        ]
        let out = try runJsCli(cmd: cmd)
        return (out["record"] as? [String: Any])
    }

    /// Wire-byte inspect (raw Y.Map field values) on Swift side.
    private func inspectSwift(doc: String, id: String, model: String) throws -> [String: Any] {
        let cmd: [String: Any] = [
            "cmd": "inspect", "doc": doc, "id": id, "model": model,
        ]
        let out = try runSwiftCli(cmd: cmd)
        return (out["fields"] as? [String: Any]) ?? [:]
    }

    /// Resolve a named relationship on a record (Swift side).
    /// Always returns an array — refersTo is normalized to a 0/1
    /// element list to keep the JS↔Swift parity assertions uniform.
    private func resolveRelationshipSwift(
        doc: String, model: String, id: String, relationship: String
    ) throws -> [[String: Any]] {
        let cmd: [String: Any] = [
            "cmd": "resolveRelationship",
            "doc": doc, "model": model, "id": id,
            "relationship": relationship,
        ]
        let out = try runSwiftCli(cmd: cmd)
        return (out["results"] as? [[String: Any]]) ?? []
    }

    /// Resolve a named relationship on a record (JS side).
    private func resolveRelationshipJs(
        doc: String, model: String, id: String, relationship: String
    ) throws -> [[String: Any]] {
        let cmd: [String: Any] = [
            "cmd": "resolveRelationship",
            "doc": doc, "model": model, "id": id,
            "relationship": relationship,
        ]
        let out = try runJsCli(cmd: cmd)
        return (out["results"] as? [[String: Any]]) ?? []
    }

    /// Wire-byte inspect on JS side.
    private func inspectJs(doc: String, id: String, model: String) throws -> [String: Any] {
        let cmd: [String: Any] = [
            "cmd": "inspect", "doc": doc, "id": id, "model": model,
        ]
        let out = try runJsCli(cmd: cmd)
        return (out["fields"] as? [String: Any]) ?? [:]
    }

    /// Spawn the Swift `E2EMiniApp` CLI built by SwiftPM. Locates
    /// the binary via the standard `.build/debug` path so we don't
    /// have to keep a hardcoded path in sync with build settings.
    private func runSwiftCli(cmd: [String: Any]) throws -> [String: Any] {
        let binaryPath = try locateSwiftBinary()
        return try runSubprocess(
            executable: binaryPath,
            arguments: [],
            stdinJSON: cmd
        )
    }

    /// Spawn the JS CLI via `node <vite-node bin> main.ts`. We don't
    /// run plain `node main.ts` because the v2-generated barrel uses
    /// Vite's `?raw` import to inline `schema.toml` — that import
    /// shape is bundler-only, and `vite-node` is the runner that
    /// ships exactly that transform under Node.
    ///
    /// Both binaries (Node + vite-node) are resolved against the
    /// workspace's hoisted `node_modules`. The codegen output under
    /// `E2E/js/generated/` is regenerated once per test class via
    /// `setUp()` so a stale TOML is never picked up.
    private func runJsCli(cmd: [String: Any]) throws -> [String: Any] {
        // Force the codegen to run (or surface its error) before the
        // first JS spawn. The static initializer runs once per test
        // process, so subsequent calls are no-ops.
        _ = E2EQueryParityTests.codegenOnce
        if let err = E2EQueryParityTests.codegenError { throw err }

        let nodePath = try CrossPlatformHarness.nodePath()
        let mainTs = E2EQueryParityTests.thisDir
            .appendingPathComponent("E2E/js/main.ts").path
        guard FileManager.default.fileExists(atPath: mainTs) else {
            throw XCTSkip("E2E/js/main.ts missing at \(mainTs)")
        }
        let viteNodeBin = try E2EQueryParityTests.viteNodeBinPath()
        return try runSubprocess(
            executable: nodePath,
            arguments: [viteNodeBin, mainTs],
            stdinJSON: cmd
        )
    }

    /// Walk up from this test file looking for
    /// `node_modules/vite-node/vite-node.mjs`. The workspace's hoisted
    /// `node_modules` lives at the repo root, several levels above
    /// the test file; the climb keeps the lookup robust to layout
    /// changes.
    private static func viteNodeBinPath() throws -> String {
        var dir = thisDir
        for _ in 0..<12 {
            let candidate = dir
                .appendingPathComponent("node_modules/vite-node/vite-node.mjs")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw XCTSkip(
            "vite-node not found in any parent node_modules. " +
            "Run `pnpm install` at the repo root."
        )
    }

    /// Find the `E2EMiniApp` binary in `.build/<config>/E2EMiniApp`.
    /// Skips with a clear message if the binary isn't built yet.
    private func locateSwiftBinary() throws -> String {
        // `#filePath` resolves to .../Tests/JsBaoClientTests/CrossPlatform/E2EQueryParityTests.swift
        // Walk up to swift-client root, then descend into .build.
        let testsURL = URL(fileURLWithPath: #filePath)
        let swiftClientRoot = testsURL
            .deletingLastPathComponent()  // .../CrossPlatform/
            .deletingLastPathComponent()  // .../JsBaoClientTests/
            .deletingLastPathComponent()  // .../Tests/
            .deletingLastPathComponent()  // .../swift-client/
        // Try debug first, then release. Test runner usually uses debug.
        for config in ["debug", "release"] {
            let candidate = swiftClientRoot
                .appendingPathComponent(".build")
                .appendingPathComponent(config)
                .appendingPathComponent("E2EMiniApp")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        // Try architecture-specific layouts.
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: swiftClientRoot.appendingPathComponent(".build"),
            includingPropertiesForKeys: nil
        )) ?? []
        for archDir in candidates {
            for config in ["debug", "release"] {
                let candidate = archDir
                    .appendingPathComponent(config)
                    .appendingPathComponent("E2EMiniApp")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
        }
        throw XCTSkip(
            "E2EMiniApp binary not built. Run: swift build --target E2EMiniApp"
        )
    }

    /// Generic subprocess driver: writes the JSON command to stdin,
    /// reads JSON from stdout, surfaces stderr in the error message
    /// on non-zero exit.
    private func runSubprocess(
        executable: String,
        arguments: [String],
        stdinJSON: [String: Any]
    ) throws -> [String: Any] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let stdin  = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput  = stdin
        proc.standardOutput = stdout
        proc.standardError  = stderr

        try proc.run()
        let cmdData = try JSONSerialization.data(withJSONObject: stdinJSON, options: [])
        stdin.fileHandleForWriting.write(cmdData)
        stdin.fileHandleForWriting.write(Data("\n".utf8))
        try stdin.fileHandleForWriting.close()
        proc.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            throw NSError(
                domain: "E2EQueryParityTests",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "subprocess exit \(proc.terminationStatus): " +
                    (String(data: errData, encoding: .utf8) ?? "")
                ]
            )
        }
        // The CLI may emit log lines + a final JSON line. Take the
        // last non-empty line as the JSON response.
        let outString = String(data: outData, encoding: .utf8) ?? ""
        let lastLine = outString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .last ?? ""
        guard !lastLine.isEmpty else {
            throw NSError(
                domain: "E2EQueryParityTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "subprocess produced no JSON line. stdout=\(outString); stderr=\(String(data: errData, encoding: .utf8) ?? "")"
                ]
            )
        }
        guard let lineData = lastLine.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            throw NSError(
                domain: "E2EQueryParityTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "could not parse last line as JSON: \(lastLine)"
                ]
            )
        }
        return obj
    }

    /// Directory containing this test file.
    private static var thisDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }
}
