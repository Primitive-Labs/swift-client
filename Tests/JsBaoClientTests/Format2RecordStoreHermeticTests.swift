import XCTest
@testable import JsBaoClient

/// The format-2 record store and the overlay fold (#3436, behaviors 4 and 5,
/// edges E2, E3, E4, E6).
///
/// The store is a real `SQLiteStorageProvider` on a temp file — the system
/// `sqlite3` the package already links, per the intent's Swift-storage
/// decision — and the fold is the SQL statements of `overlaySql.ts`, verbatim.
/// Both are held to js-bao by the parity harness rather than by transcription:
/// this is criterion 12's "the same rows as the TypeScript fold" half.
final class Format2RecordStoreHermeticTests: XCTestCase {

    // MARK: - Fixtures

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    /// A provider on its own temp file, initialized — the shape
    /// `JsBaoClient.setupStorage` builds for `.sqlite(directory)`.
    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory()
            + "/f2-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(
        documentId: String = "doc1",
        clientId: String = "harness-client"
    ) async throws -> Format2RecordStore {
        let provider = try await makeProvider()
        let store = Format2RecordStore(
            host: provider, documentId: documentId, clientId: clientId
        )
        try store.initialize()
        return store
    }

    // MARK: - Behavior 4 — the schema

    func testInitializeCreatesTheJavaScriptSchemaStatementForStatement() async throws {
        let store = try await makeStore(documentId: "doc1")

        let response = try Format2Harness.run(["command": "ddl", "docId": "doc1"])
        let theirs = try XCTUnwrap(response["schema"] as? [[String: Any]])

        // What SQLite ACTUALLY STORED on each side, not a statement against a
        // stored form: `sqlite_master.sql` drops `IF NOT EXISTS`, so the
        // statement text would differ from the stored text on both sides for
        // a reason that has nothing to do with the schema. A database written
        // by either client has to read on the other, and this is the claim
        // that says so.
        let mine = try store.schemaObjects()
        for object in theirs {
            let name = try XCTUnwrap(object["name"] as? String)
            let expected = try XCTUnwrap(object["sql"] as? String, name)
            if name == "_legacy_adopted" {
                // js-bao ONLY, and by construction (#3760). It is the ledger of
                // which writes have been taken over from a PRE-AMENDMENT OPFS
                // pool — the browser used to give every large document its own
                // pool, and a client that ships after the 2026-09-24 amendment
                // names a pool by scope alone, so the old one's unacknowledged
                // writes have to be adopted once and never twice.
                //
                // Swift has nothing to adopt from: it has kept every large
                // document of a client in ONE file-backed store since #3436,
                // under one persisted name per document that no re-keying
                // moved, so there is no second database its writes could be
                // stranded in. A table with no Swift behavior behind it would
                // be dead schema.
                //
                // Asserted as an ABSENCE rather than skipped, so a Swift client
                // that ever grows one has to come back here and say why.
                XCTAssertNil(
                    mine[name],
                    "Swift has no pre-amendment pool to adopt from, so it is "
                        + "expected to carry no adoption ledger"
                )
                continue
            }
            let actual = try XCTUnwrap(
                mine[name],
                "Swift created no object named \(name); it created \(mine.keys.sorted())"
            )
            if name == "_deferred_replay" {
                // The ONE object the two clients deliberately disagree about
                // (#3755, decision D1). js-bao keys the note by
                // `(doc_id, client_id)` because its tabs share one record
                // store and sequence spaces are per client (#3431): a note
                // keyed by document alone would be overwritten by the second
                // tab, and a restarted tab would read a live sibling's
                // `through_seq` against its own sequences. Swift has one
                // client per instance and keeps Swift's key.
                //
                // So the COLUMNS are compared and the key is not. Adding
                // `client_id` to Swift's table is filed rather than done here:
                // it is a Swift source change with no Swift behavior behind it
                // yet.
                XCTAssertEqual(
                    Self.columnTypes(Self.normalize(actual)),
                    Self.columnTypes(Self.normalize(expected))
                        .filter { $0.key != "client_id" },
                    "the deferred-replay note's columns differ by more than its key"
                )
                XCTAssertTrue(
                    Self.normalize(expected).contains("PRIMARY KEY (doc_id, client_id)"),
                    "js-bao's note is expected to be keyed by document AND client"
                )
                XCTAssertTrue(
                    Self.normalize(actual).contains("doc_id TEXT PRIMARY KEY"),
                    "Swift's note is expected to be keyed by document alone"
                )
                continue
            }
            XCTAssertEqual(
                Self.normalize(actual), Self.normalize(expected),
                "SQL differs for \(name)"
            )
        }

        // And the extra objects are NAMED, so "net of the Swift-only tables"
        // is a list somebody wrote down rather than whatever happened to be
        // left over. `_query_projection` is this client's projection marks;
        // `kv_store` is the storage provider's own table, and its presence is
        // the point — the record store shares the provider's one connection
        // rather than opening a second handle on the same WAL file.
        // `_deferred_replay` is no longer among them: js-bao carries the same
        // table since #3755, so the judgement an epoch move owes is durable on
        // both clients and the two differ only by the key compared above.
        let extra = Set(mine.keys).subtracting(theirs.compactMap { $0["name"] as? String })
        XCTAssertEqual(
            extra, ["_query_projection", "kv_store"],
            "Swift added schema objects js-bao does not have"
        )
    }

    func testTheEpochSeedRowExistsAndASecondInitializeChangesNothing() async throws {
        let store = try await makeStore(documentId: "doc1")
        XCTAssertEqual(try store.epoch(), 0)
        XCTAssertEqual(try store.ackedSeq(), 0)

        let before = try store.schemaObjects()
        try store.setEpoch(7)
        try store.initialize()

        XCTAssertEqual(
            try store.schemaObjects().mapValues(Self.normalize),
            before.mapValues(Self.normalize),
            "a second initialize changed the schema"
        )
        XCTAssertEqual(try store.epoch(), 7, "the seed row must not be re-seeded over")
    }

    // MARK: - Behavior 5 — fold parity, entry level

    /// The scripted sequence, run through the Swift store and through js-bao's
    /// own store, compared table by table. Each table is named separately so a
    /// divergence says WHICH one moved.
    func testTheScriptedFoldMatchesTheTypeScriptFoldTableByTable() async throws {
        let steps = Self.parityScript()
        let store = try await makeStore(documentId: "d")
        try Self.runScript(steps, on: store)

        let expected = try Format2Harness.run([
            "command": "fold-script", "docId": "d", "steps": steps,
        ])

        try assertRecordsMatch(expected, store)
        try assertMembersMatch(expected, store)
        try assertPendingMatch(expected, store)
        try assertClientAcksMatch(expected, store)
        try assertEpochMatches(expected, store)
    }

    /// E2 — an explicit `null` never persists a null key on a brand-new row,
    /// and removes the key on an existing one.
    func testAnExplicitNullIsAnUnsetNotAStoredNull() async throws {
        let steps: [[String: Any]] = [
            [
                "kind": "mutation", "model": "Note",
                "mutation": [
                    "id": "r1", "kind": "create",
                    "fields": ["title": "a", "subtitle": NSNull()],
                ],
            ],
            [
                "kind": "mutation", "model": "Note",
                "mutation": ["id": "r1", "kind": "patch", "fields": ["title": NSNull()]],
            ],
        ]
        let store = try await makeStore(documentId: "d")
        try Self.runScript(steps, on: store)

        let row = try XCTUnwrap(try store.read(model: "Note", recordId: "r1"))
        XCTAssertNil(
            row["subtitle"],
            "a null on a brand-new row must not persist as a null key"
        )
        XCTAssertNil(row["title"], "a null on an existing row removes the key")
        XCTAssertEqual(row["id"], .string("r1"))

        let expected = try Format2Harness.run([
            "command": "fold-script", "docId": "d", "steps": steps,
        ])
        try assertRecordsMatch(expected, store)
    }

    /// E3 — a `_replace` that omits a stringset leaves no stale members;
    /// with members it rebuilds in rowid order.
    func testReplaceRebuildsAStringsetAndLeavesNoStaleMembers() async throws {
        let steps: [[String: Any]] = [
            [
                "kind": "mutation", "model": "Note",
                "mutation": [
                    "id": "r1", "kind": "create", "fields": ["title": "a"],
                    "stringSetDeltas": ["tags": ["x": true, "y": true]],
                ],
            ],
            // A re-create that names the stringset not at all.
            [
                "kind": "mutation", "model": "Note",
                "mutation": ["id": "r1", "kind": "create", "fields": ["title": "b"]],
            ],
        ]
        let store = try await makeStore(documentId: "d")
        try Self.runScript(steps, on: store)

        let row = try XCTUnwrap(try store.read(model: "Note", recordId: "r1"))
        XCTAssertNil(row["tags"], "the re-created record never had tags")
        XCTAssertEqual(try store.members(model: "Note", recordId: "r1", field: "tags"), [])

        let expected = try Format2Harness.run([
            "command": "fold-script", "docId": "d", "steps": steps,
        ])
        try assertRecordsMatch(expected, store)
        try assertMembersMatch(expected, store)
    }

    func testABareDeletedFalseWritesNoRow() async throws {
        // The marker a re-create clears carries no content of its own —
        // writing it would mint an empty row for a record never created here.
        let store = try await makeStore(documentId: "d")
        try store.applyRemote(
            model: "Note",
            entry: OverlayRecordEntry(id: "ghost", deleted: false)
        )
        XCTAssertNil(try store.read(model: "Note", recordId: "ghost"))
        XCTAssertEqual(try store.recordIds(model: "Note"), [])
    }

    /// E4 — two documents on one client keep separate tables and epoch rows.
    func testTwoDocumentsOnOneDatabaseNeverReachEachOther() async throws {
        let provider = try await makeProvider()
        let a = Format2RecordStore(host: provider, documentId: "docA", clientId: "c1")
        let b = Format2RecordStore(host: provider, documentId: "docB", clientId: "c1")
        try a.initialize()
        try b.initialize()

        try a.applyRemote(
            model: "Note",
            entry: OverlayRecordEntry(id: "r1", fields: ["title": .string("in A")])
        )
        try b.applyRemote(
            model: "Note",
            entry: OverlayRecordEntry(id: "r1", fields: ["title": .string("in B")])
        )

        XCTAssertEqual(
            try a.read(model: "Note", recordId: "r1")?["title"], .string("in A")
        )
        XCTAssertEqual(
            try b.read(model: "Note", recordId: "r1")?["title"], .string("in B")
        )

        try a.setEpoch(5)
        XCTAssertEqual(try a.epoch(), 5)
        XCTAssertEqual(try b.epoch(), 0, "a sibling document's epoch mark moved")

        // An ack on one prunes nothing on the other.
        _ = try a.commitLocalWrite(
            model: "Note",
            mutation: OverlayMutation(id: "r2", kind: .create, fields: ["t": .string("a")]),
            pending: PendingOpInput(
                model: "Note", recordId: "r2", op: .create, fields: ["t"],
                baseEpoch: 5, ts: 1
            )
        )
        _ = try b.commitLocalWrite(
            model: "Note",
            mutation: OverlayMutation(id: "r2", kind: .create, fields: ["t": .string("b")]),
            pending: PendingOpInput(
                model: "Note", recordId: "r2", op: .create, fields: ["t"],
                baseEpoch: 0, ts: 1
            )
        )
        try a.prunePendingOps(maxContiguousSeq: 1)
        XCTAssertEqual(try a.pendingOps().count, 0)
        XCTAssertEqual(try b.pendingOps().count, 1, "the sibling's log was pruned")
    }

    /// E6 — `nextSeq` is one past `max(highest pending, ackedSeq)` for THIS
    /// client id.
    func testNextSeqIsPerClientAndSurvivesAPrune() async throws {
        let provider = try await makeProvider()
        let mine = Format2RecordStore(host: provider, documentId: "d", clientId: "me")
        let theirs = Format2RecordStore(host: provider, documentId: "d", clientId: "them")
        try mine.initialize()
        try theirs.initialize()

        XCTAssertEqual(try mine.nextSeq(), 1)
        for index in 1...3 {
            let seq = try mine.commitLocalWrite(
                model: "Note",
                mutation: OverlayMutation(
                    id: "r\(index)", kind: .create, fields: ["t": .string("x")]
                ),
                pending: PendingOpInput(
                    model: "Note", recordId: "r\(index)", op: .create, fields: ["t"],
                    baseEpoch: 0, ts: index
                )
            )
            XCTAssertEqual(seq, index)
        }
        XCTAssertEqual(try mine.nextSeq(), 4)
        XCTAssertEqual(try mine.highestLocalSeq(), 3)
        XCTAssertEqual(
            try theirs.nextSeq(), 1,
            "a second client on the same document has its own sequence space"
        )

        // After a prune the ack is the floor: the pending rows are gone, so
        // `MAX(seq)` alone would re-issue sequences the server already has.
        try mine.prunePendingOps(maxContiguousSeq: 3)
        XCTAssertEqual(try mine.pendingOps().count, 0)
        XCTAssertEqual(try mine.ackedSeq(), 3)
        XCTAssertEqual(try mine.nextSeq(), 4)
    }

    func testALowerOrRepeatedAckChangesNothing() async throws {
        let store = try await makeStore(documentId: "d", clientId: "me")
        for index in 1...3 {
            _ = try store.commitLocalWrite(
                model: "Note",
                mutation: OverlayMutation(
                    id: "r\(index)", kind: .create, fields: ["t": .string("x")]
                ),
                pending: PendingOpInput(
                    model: "Note", recordId: "r\(index)", op: .create, fields: ["t"],
                    baseEpoch: 0, ts: index
                )
            )
        }
        try store.prunePendingOps(maxContiguousSeq: 2)
        XCTAssertEqual(try store.pendingOps().map(\.seq), [3])
        XCTAssertEqual(try store.ackedSeq(), 2)

        try store.prunePendingOps(maxContiguousSeq: 1)
        XCTAssertEqual(try store.ackedSeq(), 2, "a lower ack must never lower the mark")
        try store.prunePendingOps(maxContiguousSeq: 2)
        XCTAssertEqual(try store.pendingOps().map(\.seq), [3])
    }

    // MARK: - Sync marks

    func testSyncMarksArePersistedAndAMeasuredZeroOffsetIsNotUnknown() async throws {
        let store = try await makeStore(documentId: "d")
        XCTAssertFalse(
            try store.clockOffsetKnown(),
            "never measured and measured-as-zero are the same number and different facts"
        )
        XCTAssertEqual(try store.clockOffset(), 0)

        try store.noteClockOffset(0)
        XCTAssertTrue(try store.clockOffsetKnown())

        try store.noteSync(at: 1_700_000_000_000, windowDays: 14)
        XCTAssertEqual(try store.lastSyncAt(), 1_700_000_000_000)
        XCTAssertEqual(try store.offlineWindowDays(), 14)

        // The window travels without claiming contact: a frame is proof of a
        // frame, not proof that this client's merged view is the room's.
        try store.noteOfflineWindow(10)
        XCTAssertEqual(try store.offlineWindowDays(), 10)
        XCTAssertEqual(try store.lastSyncAt(), 1_700_000_000_000)
    }

    /// A metadata read that FAILS throws; it never answers the default.
    ///
    /// Each of these defaults is a fact about the device: epoch zero is "this
    /// device is cold", an unset hydration scope is "this device holds the
    /// whole document", an unknown clock offset is "nothing measured". A
    /// suppressed SQL failure hands back the one answer that authorizes the
    /// most — and the scope's is cached, so a single failed read would keep
    /// authorizing reads and folds of every model for the life of the store.
    func testAMetadataReadThatFailsThrowsRatherThanAnsweringItsDefault() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let store = Format2RecordStore(host: failing, documentId: "d", clientId: "me")
        try store.initialize()
        try store.setEpoch(5)
        try store.noteClockOffset(250)
        try store.setHydrationScope(["Note"])

        // A fresh store over the same database, so nothing is memoized yet.
        let reader = Format2RecordStore(host: failing, documentId: "d", clientId: "me")
        failing.failStatementsContaining = "FROM _epoch"
        XCTAssertThrowsError(try reader.epoch(), "a failed read answered 'cold'")
        XCTAssertThrowsError(try reader.clockOffset())
        XCTAssertThrowsError(try reader.clockOffsetKnown())
        XCTAssertThrowsError(try reader.offlineWindowDays())
        XCTAssertThrowsError(try reader.lastSyncAt())
        XCTAssertThrowsError(
            try reader.hydrationScope(), "a failed read answered 'the whole document'"
        )
        XCTAssertThrowsError(try reader.isHydrated("Tag"))
        XCTAssertThrowsError(try reader.read(model: "Note", recordId: "r1"))
        failing.failStatementsContaining = nil

        // And the failure was not cached as a successful read: the scope the
        // database actually holds is still the answer.
        XCTAssertEqual(try reader.epoch(), 5)
        XCTAssertEqual(try reader.hydrationScope(), ["Note"])
        XCTAssertTrue(try reader.isHydrated("Note"))
        XCTAssertFalse(
            try reader.isHydrated("Tag"),
            "the failed scope read was cached as 'this device holds everything'"
        )
    }

    // MARK: - #3688 — the per-record member delete's index

    /// The vehicle, before anything is asked of it: `EXPLAIN QUERY PLAN` is an
    /// ordinary statement through the same `query` path every case here uses,
    /// but no Swift suite has run one before, so it is smoked first.
    func testExplainQueryPlanAnswersThroughTheStoreConnection() async throws {
        let provider = try await makeProvider()
        let store = Format2RecordStore(
            host: provider, documentId: "doc1", clientId: "harness-client"
        )
        try store.initialize()

        let plan = try provider.withConnection { connection in
            try connection.query(
                "EXPLAIN QUERY PLAN SELECT _id FROM \(store.tableNames.records) WHERE _type = ?",
                [.text("Note")]
            )
        }
        XCTAssertFalse(plan.isEmpty, "EXPLAIN QUERY PLAN returned no rows")
        XCTAssertNotNil(plan.first?["detail"].stringValue, "no `detail` column")
    }

    /// The fold's own member delete, explained through the store's connection.
    func testTheFoldsMemberDeletePlansThroughTheRecordIdIndex() async throws {
        let provider = try await makeProvider()
        let store = Format2RecordStore(
            host: provider, documentId: "doc1", clientId: "harness-client"
        )
        try store.initialize()
        let members = store.tableNames.stringSetIndex
        let statement = OverlayFold.Statements(tables: store.tableNames).deleteAllMembers

        let detail = try provider.withConnection { connection in
            try connection.query(
                "EXPLAIN QUERY PLAN \(statement)", [.text("Note"), .text("r1")]
            )
        }
        .compactMap { $0["detail"].stringValue }
        .joined(separator: " | ")

        // Name and `SEARCH`, not an exact string: the wording is a property of
        // the SQLite the device links (edge E8).
        XCTAssertTrue(detail.contains("SEARCH"), detail)
        XCTAssertTrue(detail.contains("idx_\(members)_trf"), detail)
    }

    /// A database the previous build wrote picks the new index up on open.
    func testInitializeReplacesTheRetiredMemberIndex() async throws {
        let provider = try await makeProvider()
        let store = Format2RecordStore(
            host: provider, documentId: "doc1", clientId: "harness-client"
        )
        let other = Format2RecordStore(
            host: provider, documentId: "doc2", clientId: "harness-client"
        )
        try store.initialize()
        try other.initialize()
        let members = store.tableNames.stringSetIndex
        let otherMembers = other.tableNames.stringSetIndex

        // What the build before this one left on disk, for both documents.
        try provider.withConnection { connection in
            for table in [members, otherMembers] {
                try connection.executeScript("DROP INDEX IF EXISTS idx_\(table)_trf")
                try connection.executeScript(
                    "CREATE INDEX IF NOT EXISTS idx_\(table)_tfr "
                        + "ON \(table)(_type, field, _record_id)"
                )
            }
        }
        XCTAssertNotNil(try store.schemaObjects()["idx_\(members)_tfr"])

        try store.initialize()

        XCTAssertNotNil(
            try store.schemaObjects()["idx_\(members)_trf"],
            "the new index was not created"
        )
        XCTAssertNil(
            try store.schemaObjects()["idx_\(members)_tfr"],
            "the retired index survived the open"
        )
        // The name is per document: opening one never drops another's.
        XCTAssertNotNil(
            try store.schemaObjects()["idx_\(otherMembers)_tfr"],
            "another document's index was dropped"
        )

        // Idempotent: a second open changes nothing.
        let after = try store.schemaObjects()
        try store.initialize()
        XCTAssertEqual(
            Set(try store.schemaObjects().keys), Set(after.keys),
            "a second initialize changed the schema"
        )
    }

    // MARK: - Helpers

    /// A scripted sequence covering every fold shape that has been a source of
    /// drift: create, patch, an explicit unset, stringset add and tombstone,
    /// a delete, a re-create after a delete, a marker-named field, and a
    /// second model.
    static func parityScript() -> [[String: Any]] { [
        ["kind": "epoch", "epoch": 3],
        [
            "kind": "mutation", "model": "Note",
            "mutation": [
                "id": "r1", "kind": "create",
                "fields": ["title": "first", "count": 2, "flag": true],
                "stringSetDeltas": ["tags": ["a": true, "b": true]],
            ],
        ],
        [
            "kind": "mutation", "model": "Note",
            "mutation": [
                "id": "r1", "kind": "patch",
                "fields": ["title": "second", "count": NSNull()],
                "stringSetDeltas": ["tags": ["b": false, "c": true]],
            ],
        ],
        [
            "kind": "mutation", "model": "Note",
            "mutation": [
                "id": "r2", "kind": "create",
                "fields": ["title": "other", "_replace": "a field", "a/b": "slash"],
            ],
        ],
        ["kind": "mutation", "model": "Note", "mutation": ["id": "r2", "kind": "delete"]],
        [
            "kind": "mutation", "model": "Note",
            "mutation": ["id": "r2", "kind": "create", "fields": ["title": "reborn"]],
        ],
        [
            "kind": "mutation", "model": "Tag",
            "mutation": ["id": "t1", "kind": "create", "fields": ["name": "x"]],
        ],
    ] }

    /// Run the harness's own script shape through the Swift store, folding
    /// each step the way an arriving update is folded.
    static func runScript(_ steps: [[String: Any]], on store: Format2RecordStore) throws {
        let overlay = OverlayDocument()
        for step in steps {
            switch step["kind"] as? String {
            case "epoch":
                try store.setEpoch(step["epoch"] as? Int ?? 0)
            case "ack":
                try store.prunePendingOps(maxContiguousSeq: step["seq"] as? Int ?? 0)
            default:
                let model = try XCTUnwrap(step["model"] as? String)
                let mutation = try XCTUnwrap(
                    OverlayMutation(harness: step["mutation"] as? [String: Any] ?? [:])
                )
                let touched = overlay.apply(mutation, model: model)
                var grouped = OverlayKeys.group(touched)
                overlay.complete(&grouped, model: model)
                for entry in grouped.values.sorted(by: { $0.id < $1.id }) {
                    try store.applyRemote(model: model, entry: entry)
                }
            }
        }
    }

    private func assertRecordsMatch(
        _ expected: [String: Any], _ store: Format2RecordStore,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rows = try XCTUnwrap(expected["records"] as? [[String: Any]])
        let mine = try store.dumpRecords()
        XCTAssertEqual(mine.count, rows.count, "records row count", file: file, line: line)
        for (index, row) in rows.enumerated() where index < mine.count {
            XCTAssertEqual(mine[index].type, row["_type"] as? String, file: file, line: line)
            XCTAssertEqual(mine[index].id, row["_id"] as? String, file: file, line: line)
            // Compare the DECODED object: SQLite's json_patch does not promise
            // a key order, and the rows are equal as records either way.
            XCTAssertEqual(
                Self.decode(mine[index].data),
                Self.decode(row["_data"] as? String ?? ""),
                "_data differs for \(mine[index].type)/\(mine[index].id)",
                file: file, line: line
            )
        }
    }

    private func assertMembersMatch(
        _ expected: [String: Any], _ store: Format2RecordStore,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rows = try XCTUnwrap(expected["members"] as? [[String: Any]])
        let mine = try store.dumpMembers()
        XCTAssertEqual(mine.count, rows.count, "members row count", file: file, line: line)
        for (index, row) in rows.enumerated() where index < mine.count {
            XCTAssertEqual(mine[index].type, row["_type"] as? String, file: file, line: line)
            XCTAssertEqual(
                mine[index].recordId, row["_record_id"] as? String, file: file, line: line
            )
            XCTAssertEqual(mine[index].field, row["field"] as? String, file: file, line: line)
            XCTAssertEqual(mine[index].value, row["value"] as? String, file: file, line: line)
        }
    }

    private func assertPendingMatch(
        _ expected: [String: Any], _ store: Format2RecordStore,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rows = try XCTUnwrap(expected["pending"] as? [[String: Any]])
        XCTAssertEqual(
            try store.pendingOps().count, rows.count, "pending row count",
            file: file, line: line
        )
    }

    private func assertClientAcksMatch(
        _ expected: [String: Any], _ store: Format2RecordStore,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rows = try XCTUnwrap(expected["clientAcks"] as? [[String: Any]])
        let mine = try store.dumpClientAcks()
        XCTAssertEqual(mine.count, rows.count, "clientAcks row count", file: file, line: line)
    }

    private func assertEpochMatches(
        _ expected: [String: Any], _ store: Format2RecordStore,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rows = try XCTUnwrap(expected["epoch"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first, file: file, line: line)
        XCTAssertEqual(try store.epoch(), row["epoch"] as? Int, "epoch", file: file, line: line)
        XCTAssertEqual(
            try store.lastSyncAt(), row["last_sync_at"] as? Int, "last_sync_at",
            file: file, line: line
        )
    }

    private static func decode(_ json: String) -> [String: JSONValue]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return JSONValue(harness: object).objectValue
    }

    /// The object a `CREATE TABLE` / `CREATE INDEX` statement names.
    private static func objectName(of statement: String) -> String? {
        let pattern = #"CREATE (?:TABLE|INDEX) IF NOT EXISTS (\w+)"#
        guard let match = statement.range(of: pattern, options: .regularExpression)
        else { return nil }
        return String(statement[match]).components(separatedBy: " ").last
    }

    /// Whitespace-insensitive comparison: the DDL is a formatted string in
    /// both places and a differing newline is not a differing schema.
    private static func normalize(_ sql: String) -> String {
        sql.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Column name → declared type, from a normalized `CREATE TABLE`.
    ///
    /// Used where two clients keep one table under different KEYS and the claim
    /// is about its columns: comparing the whole statement would fail on the
    /// key, and comparing nothing would let a column drift unnoticed.
    private static func columnTypes(_ sql: String) -> [String: String] {
        guard
            let open = sql.firstIndex(of: "("),
            let close = sql.lastIndex(of: ")")
        else { return [:] }
        var types: [String: String] = [:]
        for part in sql[sql.index(after: open)..<close].components(separatedBy: ",") {
            let words = part
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            guard words.count >= 2 else { continue }
            // A table constraint rather than a column: `PRIMARY KEY (...)`,
            // `UNIQUE(...)`. Those live in the key claim, not here.
            if words[0].uppercased() == "PRIMARY" || words[0].uppercased() == "UNIQUE" {
                continue
            }
            types[words[0]] = words[1].uppercased()
        }
        return types
    }
}
