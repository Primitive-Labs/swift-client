import XCTest
@testable import JsBaoClient

/// The snapshot manifest and the checks every reader of one runs (#3436,
/// behavior 21, edge E7's addressability half).
///
/// The manifest decides which chunks a load fetches, which ordinal a resume
/// keys on, and which id range each one covers. A reader that disagreed with
/// the writer about any of those fails QUIETLY: two entries sharing an ordinal
/// make an interrupted load skip a chunk and report success. So the assertions
/// here are parity assertions — the same manifest through `js-bao`'s own
/// `validateSnapshotManifest` and through Swift's, compared verdict for
/// verdict, refusal sentence for refusal sentence.
final class Format2SnapshotManifestHermeticTests: XCTestCase {

    // MARK: - Fixtures

    /// A manifest as JSON, so the fixture the harness validates and the
    /// fixture Swift validates are the same bytes.
    private func manifest(
        version: Int = 3,
        kind: String? = nil,
        chunks: [[String: Any]],
        totals: [String: Any]? = nil,
        ingest: [String: Any]? = nil
    ) -> [String: Any] {
        var object: [String: Any] = [
            "version": version,
            "epoch": 7,
            "buildId": "b-1",
            "createdAt": 1_700_000_000_000,
            "schema": ["Note": ["stringSetFields": ["tags"]]],
            "chunks": chunks,
            "totals": totals ?? [
                "rows": chunks.reduce(0) { $0 + ($1["rows"] as? Int ?? 0) },
                "bytes": chunks.reduce(0) { $0 + ($1["bytes"] as? Int ?? 0) },
            ],
        ]
        if let kind { object["kind"] = kind }
        if let ingest { object["ingest"] = ingest }
        return object
    }

    private func chunk(
        _ ordinal: Int,
        model: String = "Note",
        path: String? = nil,
        rows: Int = 2,
        firstId: String = "a",
        lastId: String = "b",
        bytes: Int = 100,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "key": "app/doc/7-b-1/\(model)/\(ordinal).ndjson.gz",
            "ordinal": ordinal,
            "model": model,
            "bytes": bytes,
            "rows": rows,
            "firstId": firstId,
            "lastId": lastId,
            "sha256": String(repeating: "0", count: 64),
        ]
        if let path { object["path"] = path }
        for (key, value) in extra { object[key] = value }
        return object
    }

    /// Every fixture in the set, with a name so a failure says which one.
    private func fixtures() -> [(name: String, manifest: [String: Any])] {
        [
            ("a valid version-2 manifest", manifest(version: 2, chunks: [chunk(0)])),
            (
                "a valid version-3 manifest with a sourced path",
                manifest(chunks: [
                    chunk(0, path: "Note/0", firstId: "a", lastId: "b"),
                    chunk(1, path: "4-older-build/Note/1", firstId: "c", lastId: "d"),
                ])
            ),
            ("an empty manifest", manifest(chunks: [])),
            (
                "two models, each ascending on its own",
                manifest(chunks: [
                    chunk(0, model: "Note", firstId: "a", lastId: "b"),
                    chunk(1, model: "Note", firstId: "c", lastId: "d"),
                    chunk(2, model: "Task", firstId: "a", lastId: "b"),
                ])
            ),
            (
                "a rows:0 chunk between two that carry rows (edge E7)",
                manifest(chunks: [
                    chunk(0, firstId: "a", lastId: "b"),
                    // Its bounds run backwards and sit inside the previous
                    // chunk's range; with no rows they say nothing and are
                    // not checked.
                    chunk(1, rows: 0, firstId: "z", lastId: "a"),
                    chunk(2, firstId: "c", lastId: "d"),
                ])
            ),
            ("version 4 — newer than this reader", manifest(version: 4, chunks: [])),
            ("version 1 — older than the format", manifest(version: 1, chunks: [])),
            ("a bulk-load manifest", manifest(kind: "ingest", chunks: [])),
            ("a manifest that says it is a snapshot", manifest(kind: "snapshot", chunks: [chunk(0)])),
            (
                "two chunks sharing an ordinal",
                manifest(chunks: [chunk(0), chunk(0, firstId: "c", lastId: "d")])
            ),
            (
                "an ordinal that is not an integer",
                manifest(chunks: [chunk(0, extra: ["ordinal": 1.5])])
            ),
            (
                "a path outside the grammar",
                manifest(chunks: [chunk(0, path: "../secrets/0")])
            ),
            (
                "a path whose model segment is not a model name",
                manifest(chunks: [chunk(0, path: "9Note/0")])
            ),
            (
                "a path whose chunk segment is not a number",
                manifest(chunks: [chunk(0, path: "Note/first")])
            ),
            (
                "a range that runs backwards",
                manifest(chunks: [chunk(0, firstId: "z", lastId: "a")])
            ),
            (
                "two chunks of one model that overlap",
                manifest(chunks: [
                    chunk(0, firstId: "a", lastId: "m"),
                    chunk(1, firstId: "c", lastId: "z"),
                ])
            ),
            (
                "two chunks of one model that touch at a boundary",
                manifest(chunks: [
                    chunk(0, firstId: "a", lastId: "m"),
                    chunk(1, firstId: "m", lastId: "z"),
                ])
            ),
            (
                "totals that do not add up",
                manifest(chunks: [chunk(0)], totals: ["rows": 99, "bytes": 100])
            ),
            ("no totals at all", manifest(chunks: [chunk(0)], totals: [:])),
            (
                "an ingest block naming no session",
                manifest(chunks: [], ingest: ["epoch": 4, "ranges": []])
            ),
            (
                "an ingest block naming epoch 0",
                manifest(chunks: [], ingest: ["sessionId": "s1", "epoch": 0, "ranges": []])
            ),
            (
                "an ingest range that runs backwards",
                manifest(chunks: [], ingest: [
                    "sessionId": "s1", "epoch": 4,
                    "ranges": [["model": "Note", "firstId": "z", "lastId": "a", "rows": 1]],
                ])
            ),
            (
                "two ingest ranges of one model that overlap",
                manifest(chunks: [], ingest: [
                    "sessionId": "s1", "epoch": 4,
                    "ranges": [
                        ["model": "Note", "firstId": "a", "lastId": "m", "rows": 1],
                        ["model": "Note", "firstId": "c", "lastId": "z", "rows": 1],
                    ],
                ])
            ),
            (
                "an ingest range naming something that is not a model",
                manifest(chunks: [], ingest: [
                    "sessionId": "s1", "epoch": 4,
                    "ranges": [["model": "9Note", "firstId": "a", "lastId": "b", "rows": 1]],
                ])
            ),
            (
                "a well-formed ingest block",
                manifest(chunks: [], ingest: [
                    "sessionId": "s1", "epoch": 4,
                    "ranges": [
                        ["model": "Note", "firstId": "a", "lastId": "m", "rows": 3],
                        ["model": "Note", "firstId": "n", "lastId": "z", "rows": 3],
                        ["model": "Task", "firstId": "a", "lastId": "b", "rows": 1],
                    ],
                ])
            ),
        ]
    }

    // MARK: - Behavior 21 — validation parity

    func testEveryFixtureGetsTheVerdictTheTypeScriptValidatorGivesIt() throws {
        let cases = fixtures()
        let response = try Format2Harness.run([
            "command": "validate-manifest",
            "manifests": cases.map(\.manifest),
        ])
        let verdicts = try XCTUnwrap(response["verdicts"] as? [[String: Any]])
        XCTAssertEqual(verdicts.count, cases.count)

        for (index, each) in cases.enumerated() {
            let expected = verdicts[index]
            let raw = try JSONDecoder().decode(
                JSONValue.self,
                from: JSONSerialization.data(withJSONObject: each.manifest)
            )
            let accepted = expected["ok"] as? Bool == true
            do {
                _ = try SnapshotManifest.decode(raw)
                XCTAssertTrue(
                    accepted,
                    "Swift accepted \(each.name); js-bao refused it with "
                        + "\(expected["message"] as? String ?? "?")"
                )
            } catch let error as JsBaoError {
                XCTAssertFalse(
                    accepted, "Swift refused \(each.name), which js-bao accepts: \(error.message)"
                )
                guard !accepted else { continue }
                XCTAssertEqual(
                    error.code.rawValue, expected["code"] as? String,
                    "\(each.name): refusal code"
                )
                XCTAssertEqual(
                    error.message, expected["message"] as? String,
                    "\(each.name): refusal sentence"
                )
            }
        }
    }

    /// The whole fixture set has to exercise BOTH verdicts, or a validator
    /// that accepted everything would pass this suite.
    func testTheFixtureSetHoldsBothAcceptancesAndRefusals() throws {
        let response = try Format2Harness.run([
            "command": "validate-manifest",
            "manifests": fixtures().map(\.manifest),
        ])
        let verdicts = try XCTUnwrap(response["verdicts"] as? [[String: Any]])
        let accepted = verdicts.filter { $0["ok"] as? Bool == true }.count
        XCTAssertGreaterThanOrEqual(accepted, 5, "fixtures js-bao accepts")
        XCTAssertGreaterThanOrEqual(
            verdicts.count - accepted, 10, "fixtures js-bao refuses"
        )
    }

    /// The two refusals are different answers and the caller acts on them
    /// differently: an invalid manifest is a broken build, an unsupported one
    /// is a client that has to be upgraded.
    func testAnUnsupportedVersionIsItsOwnCodeAndNotMerelyInvalid() throws {
        let raw = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONSerialization.data(
                withJSONObject: manifest(version: 4, chunks: [])
            )
        )
        XCTAssertThrowsError(try SnapshotManifest.decode(raw)) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .snapshotManifestUnsupported)
        }
    }

    /// A manifest from a NEWER platform may carry a chunk list this reader
    /// cannot read, and the honest answer is "upgrade the client", never
    /// "chunk 4 is malformed". So the version gate runs first.
    func testAnUnsupportedVersionIsReportedBeforeAnythingBelowItIsRead() throws {
        var broken = manifest(version: 9, chunks: [])
        broken["chunks"] = "not an array"
        let raw = try JSONDecoder().decode(
            JSONValue.self, from: JSONSerialization.data(withJSONObject: broken)
        )
        XCTAssertThrowsError(try SnapshotManifest.decode(raw)) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .snapshotManifestUnsupported)
        }
    }

    // MARK: - Behavior 21 — id order

    func testRecordIdsAreOrderedByTheirUtf8Bytes() throws {
        // The pair the intent's own note names: a character in U+E000–U+FFFF
        // against one past U+FFFF. UTF-8 puts the supplementary code point
        // above; UTF-16 code units put it below, and Swift's own `<` collates
        // rather than comparing bytes at all.
        let ids = [
            "\u{E000}", "\u{1F600}", "b", "a", "ab", "aa", "A", "_", "0",
            "note-1", "note-10", "note-2", "ünïcode", "zz", "z",
            // The two spellings of `á`: one code point, and `a` plus a
            // combining acute. Swift calls them the same string; the table
            // they came out of does not.
            "a\u{0301}", "\u{00E1}",
        ]
        let response = try Format2Harness.run(["command": "compare-ids", "ids": ids])
        let expected = try XCTUnwrap(response["sorted"] as? [String])
        let sorted = ids.sorted { compareRecordIds($0, $1) < 0 }
        XCTAssertEqual(sorted, expected)
    }

    /// The guard that says the test above is measuring something: Swift's own
    /// `String` comparison is NOT byte order, so an implementation that used
    /// it would give a different answer from the table the ids came out of.
    ///
    /// The pair that shows it is the two spellings of `á`. Swift normalizes,
    /// so it calls them EQUAL; SQLite's BINARY collation compares bytes, where
    /// the decomposed form sorts first. An `a`-with-combining-acute id and a
    /// precomposed one are two records, and a partitioner that thought they
    /// were one would cut a boundary that does not exist.
    func testSwiftsOwnStringComparisonIsNotTheOrderTheTableUses() {
        let decomposed = "a\u{0301}"
        let precomposed = "\u{00E1}"
        XCTAssertEqual(decomposed, precomposed, "Swift normalizes these to one string")
        XCTAssertNotEqual(
            compareRecordIds(decomposed, precomposed), 0,
            "the table they came out of holds them as two records"
        )
        XCTAssertEqual(compareRecordIds(decomposed, precomposed), -1)

        XCTAssertEqual(compareRecordIds("a", "a"), 0)
        XCTAssertEqual(compareRecordIds("a", "ab"), -1)
        XCTAssertEqual(compareRecordIds("ab", "a"), 1)
        // And the supplementary-plane pair the JS side's surrogate-rank
        // arithmetic exists for, which both ends have to agree on.
        XCTAssertEqual(compareRecordIds("\u{E000}", "\u{1F600}"), -1)
    }

    // MARK: - Behavior 23's grammar, and edge E7's addressability half

    func testChunkPathsAreReadThroughTheOneGrammar() throws {
        let own = try XCTUnwrap(parseSnapshotChunkPath("Note/12"))
        XCTAssertEqual(own.model, "Note")
        XCTAssertEqual(own.index, 12)
        XCTAssertNil(own.source?.buildId)

        let sourced = try XCTUnwrap(parseSnapshotChunkPath("4-build_id-9/Note/3"))
        XCTAssertEqual(sourced.model, "Note")
        XCTAssertEqual(sourced.index, 3)
        XCTAssertEqual(sourced.source?.epoch, 4)
        XCTAssertEqual(sourced.source?.buildId, "build_id-9")

        for refused in [
            "", "Note", "Note/", "/0", "Note/0/extra", "../secrets/0",
            "9Note/0", "Note/first", "x-build/Note/0", "4-/Note/0",
            "Note/0/", "4-build/9Note/0",
        ] {
            XCTAssertNil(
                parseSnapshotChunkPath(refused),
                "\(refused) is not an addressable chunk path"
            )
        }
    }

    /// A manifest's own `path` wins over anything derivable from the key: the
    /// key of a REUSED entry names an object under a build the grant is not
    /// for, while the path is the form the download route resolves.
    func testTheEntrysOwnPathWinsAndTheKeyIsTheFallback() throws {
        let reused = SnapshotChunkEntry(
            key: "app/doc/4-older/Note/3.ndjson.gz",
            path: "4-older/Note/3", ordinal: 3, model: "Note",
            bytes: 1, rows: 1, firstId: "a", lastId: "a", sha256: "x"
        )
        XCTAssertEqual(try snapshotChunkPath(reused), "4-older/Note/3")

        let old = SnapshotChunkEntry(
            key: "app/doc/7-b1/Note/5.ndjson.gz", model: "Note",
            bytes: 1, rows: 1, firstId: "a", lastId: "a", sha256: "x"
        )
        XCTAssertEqual(try snapshotChunkPath(old), "Note/5")

        let unaddressable = SnapshotChunkEntry(
            key: "app/doc/whatever", model: "Note",
            bytes: 1, rows: 1, firstId: "a", lastId: "a", sha256: "x"
        )
        XCTAssertThrowsError(try snapshotChunkPath(unaddressable))
    }

    func testAnOrdinalFallsBackToThePositionInTheManifest() {
        let withOrdinal = SnapshotChunkEntry(
            key: "k", ordinal: 9, model: "Note",
            bytes: 1, rows: 1, firstId: "a", lastId: "a", sha256: "x"
        )
        let without = SnapshotChunkEntry(
            key: "k", model: "Note", bytes: 1, rows: 1,
            firstId: "a", lastId: "a", sha256: "x"
        )
        XCTAssertEqual(resolveChunkOrdinal(withOrdinal, at: 2), 9)
        XCTAssertEqual(resolveChunkOrdinal(without, at: 2), 2)
    }

    // MARK: - What a decoded manifest carries

    func testADecodedManifestCarriesTheFieldsALoadNeeds() throws {
        let raw = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONSerialization.data(withJSONObject: manifest(chunks: [
                chunk(0, path: "Note/0", firstId: "a", lastId: "b"),
                chunk(1, model: "Task", path: "Task/0", firstId: "a", lastId: "b"),
            ]))
        )
        let decoded = try SnapshotManifest.decode(raw)
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.epoch, 7)
        XCTAssertEqual(decoded.buildId, "b-1")
        XCTAssertEqual(decoded.chunks.count, 2)
        XCTAssertEqual(decoded.totalRows, 4)
        XCTAssertEqual(decoded.chunks[1].model, "Task")
        // The schema is what makes a stringset field a set rather than an
        // array of strings in the merged row.
        XCTAssertEqual(decoded.stringSetFields(for: "Note"), ["tags"])
        XCTAssertEqual(decoded.stringSetFields(for: "Task"), [])
        // And a manifest that decoded is one that validates.
        XCTAssertNoThrow(try decoded.validate())
    }

    func testBytesThatAreNotAManifestAtAllAreRefusedByName() {
        XCTAssertThrowsError(
            try SnapshotManifest.decode(bytes: Data("not json".utf8))
        ) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .snapshotManifestInvalid)
        }
    }
}
