import XCTest
@testable import JsBaoClient
import YSwift

/// The overlay observer: what turns an arriving Yjs update into merged rows
/// (#3436, behaviors 6, 9 and 36, edge E15).
///
/// `YMap.observe` fires synchronously inside the commit, under yswift's
/// recursive FFI lock, so the callback may not open a write transaction — it
/// captures the touched KEYS and a serial fold queue materializes their values
/// and folds them afterwards. A fold that fails leaves the merged row wrong
/// while Yjs already holds the update, so the state is sticky: reads and
/// writes are refused until a rebind's whole-overlay catch-up repairs it.
final class Format2ObserverHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-obs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private struct Fixture {
        let store: Format2RecordStore
        let overlay: OverlayDocument
        let observer: Format2Observer
    }

    private func makeFixture(
        host: (any Format2SqlHost)? = nil,
        models: [String] = ["Note", "Tag"]
    ) async throws -> Fixture {
        let provider: any Format2SqlHost
        if let host {
            provider = host
        } else {
            provider = try await makeProvider()
        }
        let store = Format2RecordStore(
            host: provider, documentId: "d", clientId: "me"
        )
        try store.initialize()
        let overlay = OverlayDocument()
        let observer = Format2Observer(store: store, overlay: overlay)
        for model in models { observer.register(model: model) }
        return Fixture(store: store, overlay: overlay, observer: observer)
    }

    // MARK: - Behavior 6 — fold parity at the update level

    func testAnUpdateWrittenByJavaScriptFoldsToTheSameRows() async throws {
        // The overlay is written by the REAL js-bao encoder, shipped as a Yjs
        // update, and applied to the Swift epoch doc. Anything the Swift
        // encoder got wrong is invisible to this test by construction —
        // that is the point of driving it from the other side.
        let mutations: [[String: Any]] = [
            [
                "model": "Note",
                "mutation": [
                    "id": "r1", "kind": "create",
                    "fields": ["title": "hello", "count": 3],
                    "stringSetDeltas": ["tags": ["a": true, "b": true]],
                ],
            ],
            [
                "model": "Note",
                "mutation": [
                    "id": "r2", "kind": "create", "fields": ["title": "second"],
                ],
            ],
            [
                "model": "Tag",
                "mutation": ["id": "t1", "kind": "create", "fields": ["name": "x"]],
            ],
        ]
        let written = try Format2Harness.run([
            "command": "write-overlay", "docId": "d", "mutations": mutations,
        ])
        let update = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(written["update"] as? String))
        )

        let fixture = try await makeFixture()
        try fixture.overlay.applyUpdate([UInt8](update))
        try fixture.observer.drain()

        let expected = try Format2Harness.run([
            "command": "fold-update", "docId": "d",
            "update": update.base64EncodedString(),
            "models": ["Note", "Tag"],
        ])

        try assertRecordsMatch(expected, fixture.store)
        try assertMembersMatch(expected, fixture.store)
    }

    // MARK: - Behavior 9 — remote folds

    func testAPeerUpdateTouchingTwoRecordsFoldsBoth() async throws {
        let fixture = try await makeFixture()
        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            model: "Note"
        )
        peer.apply(
            OverlayMutation(id: "r2", kind: .create, fields: ["title": .string("b")]),
            model: "Note"
        )

        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())
        try fixture.observer.drain()

        XCTAssertEqual(
            try fixture.store.read(model: "Note", recordId: "r1")?["title"], .string("a")
        )
        XCTAssertEqual(
            try fixture.store.read(model: "Note", recordId: "r2")?["title"], .string("b")
        )
    }

    func testAReplaceRebuildsFromTheWholeOverlayNotJustTheArrivingKeys() async throws {
        // One peer patches a record while another deletes and re-creates it.
        // Yjs merges their keys per key; folding the `_replace` update alone
        // would drop the concurrent patch the overlay itself still holds.
        let fixture = try await makeFixture()

        // Seed both sides from the live document so the two writes are
        // genuinely concurrent edits of one overlay rather than a race whose
        // winner Yjs picks.
        let patcher = OverlayDocument()
        try patcher.applyUpdate(fixture.overlay.encodeStateAsUpdate())
        patcher.apply(
            OverlayMutation(id: "r1", kind: .patch, fields: ["colour": .string("blue")]),
            model: "Note"
        )
        try fixture.overlay.applyUpdate(patcher.encodeStateAsUpdate())
        try fixture.observer.drain()

        let creator = OverlayDocument()
        try creator.applyUpdate(fixture.overlay.encodeStateAsUpdate())
        creator.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("fresh")]),
            model: "Note"
        )
        try fixture.overlay.applyUpdate(creator.encodeStateAsUpdate())
        try fixture.observer.drain()

        let row = try XCTUnwrap(try fixture.store.read(model: "Note", recordId: "r1"))
        XCTAssertEqual(row["title"], .string("fresh"))
        XCTAssertEqual(
            row["colour"], .string("blue"),
            "the concurrent patch the overlay still holds was dropped by the rebuild"
        )
    }

    func testABareDeletedFalseFoldsToNoRow() async throws {
        let fixture = try await makeFixture()
        let peer = OverlayDocument()
        // Not a create: only the tombstone-clearing marker, which a re-create
        // writes and which carries no content of its own.
        _ = peer.map(for: "Note")  // register the map on the peer side
        _ = peer.applyRawEntries(
            [(OverlayKeys.markerKey(recordId: "ghost", marker: OverlayKeys.markerDeleted), .bool(false))],
            model: "Note"
        )

        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())
        try fixture.observer.drain()

        XCTAssertNil(try fixture.store.read(model: "Note", recordId: "ghost"))
        XCTAssertEqual(try fixture.store.recordIds(model: "Note"), [])
    }

    /// A key the overlay no longer HOLDS is skipped, not read as a null.
    ///
    /// `materializeOverlayEntries` skips it (`!modelMap.has(key)`), and the
    /// difference is not cosmetic: a null IS the explicit unset the fold
    /// applies, so reading a removed `r1/title` as null clears the field that
    /// the server — which never saw a value for that key — still holds. Key
    /// removal is cleanup (a re-create drops the previous lifetime's keys);
    /// the record-level markers are what express a delete.
    func testARemovedOverlayKeyIsNotAnExplicitUnset() async throws {
        let fixture = try await makeFixture()
        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(
                id: "r1", kind: .create,
                fields: ["title": .string("a"), "colour": .string("blue")],
                stringSetDeltas: ["tags": ["x": true]]
            ),
            model: "Note"
        )
        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())
        try fixture.observer.drain()

        // Remove two overlay keys directly — a field's and a member's — the
        // way a peer's cleanup transaction would.
        let map = fixture.overlay.map(for: "Note")
        fixture.overlay.document.transactSync { transaction in
            _ = map.removeValue(forKey: "r1/colour", transaction: transaction)
            _ = map.removeValue(forKey: "r1/tags/x", transaction: transaction)
        }
        XCTAssertGreaterThan(
            fixture.observer.pendingKeyCount, 0, "the removal was not captured"
        )
        try fixture.observer.drain()

        let row = try XCTUnwrap(try fixture.store.read(model: "Note", recordId: "r1"))
        XCTAssertEqual(
            row["colour"], .string("blue"),
            "a removed overlay key was folded as an explicit unset"
        )
        XCTAssertEqual(
            try fixture.store.members(model: "Note", recordId: "r1", field: "tags"), ["x"],
            "a removed member key was folded as a member tombstone"
        )

        // And an explicit null still unsets, which is the state a removal must
        // not be confused with.
        let unsetter = OverlayDocument()
        try unsetter.applyUpdate(fixture.overlay.encodeStateAsUpdate())
        unsetter.apply(
            OverlayMutation(id: "r1", kind: .patch, fields: ["colour": .null]),
            model: "Note"
        )
        try fixture.overlay.applyUpdate(unsetter.encodeStateAsUpdate())
        try fixture.observer.drain()
        XCTAssertNil(
            try fixture.store.read(model: "Note", recordId: "r1")?["colour"],
            "an explicit null must still remove the field"
        )
    }

    /// A catch-up of SOME models folds those models whole and leaves every
    /// other model's captured keys alone.
    ///
    /// The catch-up a model registered after the bind runs is exactly this
    /// shape. Clearing the whole pending batch would leave an arrived update
    /// unfolded with nothing to show for it — no pending work, no refusal, and
    /// a merged row stale for good, because sync need never send that update
    /// again.
    func testAPartialCatchUpKeepsTheOtherModelsPendingWork() async throws {
        let fixture = try await makeFixture()
        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            model: "Note"
        )
        peer.apply(
            OverlayMutation(id: "t1", kind: .create, fields: ["name": .string("x")]),
            model: "Tag"
        )
        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())

        try fixture.observer.catchUp(models: ["Tag"])
        XCTAssertNotNil(try fixture.store.read(model: "Tag", recordId: "t1"))

        try fixture.observer.drain()
        XCTAssertEqual(
            try fixture.store.read(model: "Note", recordId: "r1")?["title"], .string("a"),
            "a catch-up of Tag discarded the update Note was waiting to fold"
        )
    }

    func testAPartialCatchUpDoesNotReportTheDocumentRepaired() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)

        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            model: "Note"
        )
        peer.apply(
            OverlayMutation(id: "t1", kind: .create, fields: ["name": .string("x")]),
            model: "Tag"
        )
        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())
        failing.failStatementsContaining = "INSERT INTO records_f2_"
        XCTAssertThrowsError(try fixture.observer.drain())
        failing.failStatementsContaining = nil
        XCTAssertTrue(fixture.observer.isFoldBroken)

        try fixture.observer.catchUp(models: ["Tag"])
        XCTAssertTrue(
            fixture.observer.isFoldBroken,
            "a catch-up of one model reported a document-wide repair it did not make"
        )
        assertFoldBroken { try fixture.observer.read(model: "Note", recordId: "r1") }

        // The whole-overlay catch-up is what repairs it.
        try fixture.observer.catchUp()
        XCTAssertFalse(fixture.observer.isFoldBroken)
        XCTAssertEqual(
            try fixture.store.read(model: "Note", recordId: "r1")?["title"], .string("a")
        )
    }

    func testTheObserverCallbackNeverOpensAWriteTransaction() async throws {
        // `YMap.observe` fires under yswift's recursive FFI lock, inside the
        // commit. A callback that folded inline would be holding that lock
        // across a SQLite write, and a fold that itself wrote to the Y.Doc
        // would re-enter the transaction it is being told about. So the
        // callback captures keys and returns; the fold runs afterwards.
        let fixture = try await makeFixture()
        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            model: "Note"
        )

        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())
        XCTAssertGreaterThan(
            fixture.observer.pendingKeyCount, 0,
            "the callback should have captured keys and left them for the queue"
        )
        XCTAssertNil(
            try fixture.store.read(model: "Note", recordId: "r1"),
            "the fold must not have run inside the observer callback"
        )

        try fixture.observer.drain()
        XCTAssertEqual(fixture.observer.pendingKeyCount, 0)
        XCTAssertNotNil(try fixture.store.read(model: "Note", recordId: "r1"))
    }

    // MARK: - Behavior 36 — the sticky fold-broken state

    func testAFailedFoldIsStickyAndRefusesReadsAndWritesUntilARebindRepairsIt() async throws {
        let provider = try await makeProvider()
        // A host that fails the fold's record upsert exactly once, so the
        // repair has something to repair rather than a permanently broken
        // database.
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)

        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            model: "Note"
        )
        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())

        failing.failStatementsContaining = "INSERT INTO records_f2_"
        XCTAssertThrowsError(try fixture.observer.drain())
        failing.failStatementsContaining = nil

        XCTAssertTrue(fixture.observer.isFoldBroken, "the state must be sticky")

        // Every read and write is refused with the typed code carrying the
        // error, rather than answering from a merged row known to be wrong.
        assertFoldBroken { try fixture.observer.read(model: "Note", recordId: "r1") }
        assertFoldBroken { try fixture.observer.readAll(model: "Note") }
        assertFoldBroken {
            try fixture.observer.assertWritable()
        }

        // A later update is not folded while broken — continuing would layer
        // a delta over a row that is already wrong.
        let second = OverlayDocument()
        try second.applyUpdate(fixture.overlay.encodeStateAsUpdate())
        second.apply(
            OverlayMutation(id: "r2", kind: .create, fields: ["title": .string("b")]),
            model: "Note"
        )
        try fixture.overlay.applyUpdate(second.encodeStateAsUpdate())
        XCTAssertThrowsError(try fixture.observer.drain())

        // The repair: a rebind's whole-overlay catch-up fold. Afterwards the
        // rows equal a fresh fold of the same overlay.
        try fixture.observer.catchUp()
        XCTAssertFalse(fixture.observer.isFoldBroken, "a committed catch-up clears the state")
        XCTAssertEqual(
            try fixture.store.read(model: "Note", recordId: "r1")?["title"], .string("a")
        )
        XCTAssertEqual(
            try fixture.store.read(model: "Note", recordId: "r2")?["title"], .string("b")
        )
    }

    /// A fold fails on the fold QUEUE, where no caller is waiting for it. The
    /// refusals that follow are not enough on their own to tell an application
    /// what happened: `find` answers `nil` and `delete` reports nothing — both
    /// are non-throwing — which is exactly what an absent record and a
    /// completed delete look like. So the transition is announced once, and the
    /// spec's Observability section names `FORMAT2_FOLD_BROKEN` among the
    /// codes a `ConnectionErrorEvent` carries.
    func testTheFirstFoldFailureIsAnnouncedOnceWithItsCode() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)

        final class Announcements: @unchecked Sendable {
            private let lock = NSLock()
            private var errors: [JsBaoError] = []
            func note(_ error: JsBaoError) { lock.withLock { errors.append(error) } }
            var all: [JsBaoError] { lock.withLock { errors } }
        }
        let announced = Announcements()
        fixture.observer.onFoldBroken = { announced.note($0) }

        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            model: "Note"
        )
        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())

        failing.failStatementsContaining = "INSERT INTO records_f2_"
        XCTAssertThrowsError(try fixture.observer.drain())

        XCTAssertEqual(announced.all.count, 1, "the fold failure was never announced")
        let error = try XCTUnwrap(announced.all.first)
        XCTAssertEqual(error.code, .format2FoldBroken)
        XCTAssertNotNil(
            error.details?["error"],
            "and it names the cause, which is what an operator needs"
        )

        // The state is sticky, so the announcement is the TRANSITION and not
        // one per refused fold — a document that is already broken has already
        // said so.
        let second = OverlayDocument()
        try second.applyUpdate(fixture.overlay.encodeStateAsUpdate())
        second.apply(
            OverlayMutation(id: "r2", kind: .create, fields: ["title": .string("b")]),
            model: "Note"
        )
        try fixture.overlay.applyUpdate(second.encodeStateAsUpdate())
        XCTAssertThrowsError(try fixture.observer.drain())
        XCTAssertEqual(
            announced.all.count, 1,
            "a document already known broken announced itself again"
        )
    }

    /// E15 — a write attempted while fold-broken is refused BEFORE the
    /// serialized operation starts: no pending op, no publish.
    func testAWriteWhileFoldBrokenLeavesNoPendingOpAndNoOverlayKey() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)

        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            model: "Note"
        )
        try fixture.overlay.applyUpdate(peer.encodeStateAsUpdate())
        failing.failStatementsContaining = "INSERT INTO records_f2_"
        XCTAssertThrowsError(try fixture.observer.drain())
        failing.failStatementsContaining = nil

        let keysBefore = fixture.overlay.entries(model: "Note").count
        assertFoldBroken { try fixture.observer.assertWritable() }

        XCTAssertEqual(try fixture.store.pendingOps().count, 0, "a pending op was written")
        XCTAssertEqual(
            fixture.overlay.entries(model: "Note").count, keysBefore,
            "an overlay key was published"
        )
    }

    // MARK: - Helpers

    private func assertFoldBroken(
        _ body: () throws -> Any?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try body()
            XCTFail("expected a FORMAT2_FOLD_BROKEN refusal", file: file, line: line)
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .format2FoldBroken, file: file, line: line)
            XCTAssertNotNil(
                error.details?["error"], "the refusal must name the fold's own error",
                file: file, line: line
            )
        } catch {
            XCTFail("expected a JsBaoError, got \(error)", file: file, line: line)
        }
    }

    /// Records, with stringset arrays compared as SETS.
    ///
    /// Everything else is compared exactly. The one thing that cannot be is a
    /// stringset's ORDER within one update: the JS fold inserts members in the
    /// order `groupOverlayEntries` met their keys, which on this path is the
    /// order Yjs enumerates the model map — and Yjs does not specify one, so
    /// two updates carrying the same members come back in different orders
    /// from js-bao itself (measured: the same mutations re-encoded give
    /// `["a","b"]` for one update and `["b","a"]` for the next). Swift sorts
    /// instead, which is at least self-consistent. Asserting the JS order here
    /// would be asserting noise; the MEMBERS are the claim, and the ordered
    /// case is pinned in the store suite where both sides apply the mutations
    /// one at a time and both are deterministic.
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
            XCTAssertEqual(
                Self.orderInsensitive(Self.decode(mine[index].data)),
                Self.orderInsensitive(Self.decode(row["_data"] as? String ?? "")),
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
        // Per record and field, the same members — see `assertRecordsMatch`
        // for why the rowid ORDER is not the claim on this path.
        let theirs = Set(rows.map {
            "\($0["_type"] ?? "")/\($0["_record_id"] ?? "")/\($0["field"] ?? "")/\($0["value"] ?? "")"
        })
        XCTAssertEqual(
            Set(mine.map { "\($0.type)/\($0.recordId)/\($0.field)/\($0.value)" }),
            theirs,
            file: file, line: line
        )
    }

    /// Sort any array value, so a stringset's unspecified order does not read
    /// as a differing record.
    private static func orderInsensitive(
        _ row: [String: JSONValue]?
    ) -> [String: JSONValue]? {
        row?.mapValues { value in
            guard case .array(let members) = value else { return value }
            return .array(members.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") })
        }
    }

    private static func decode(_ json: String) -> [String: JSONValue]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return JSONValue(harness: object).objectValue
    }
}

/// A `Format2SqlHost` that fails one named statement, so a fold failure can be
/// provoked without a broken database.
///
/// A DECORATOR over a real connection, which is why `Format2SqlConnection` is
/// a protocol: the failure path stays honest (a real transaction really rolls
/// back) and the library carries no test seam of its own.
final class FailingSqlHost: Format2SqlHost, @unchecked Sendable {
    private let wrapped: any Format2SqlHost
    private let lock = NSLock()
    private var _failStatementsContaining: String?

    var failStatementsContaining: String? {
        get { lock.withLock { _failStatementsContaining } }
        set { lock.withLock { _failStatementsContaining = newValue } }
    }

    init(wrapped: any Format2SqlHost) { self.wrapped = wrapped }

    func withConnection<T>(_ body: (any Format2SqlConnection) throws -> T) throws -> T {
        let fragment = failStatementsContaining
        return try wrapped.withConnection { connection in
            guard let fragment else { return try body(connection) }
            return try body(FailingConnection(wrapped: connection, failOn: fragment))
        }
    }
}

/// Forwards everything except the one statement it is told to fail.
final class FailingConnection: Format2SqlConnection {
    private let wrapped: any Format2SqlConnection
    private let failOn: String

    init(wrapped: any Format2SqlConnection, failOn: String) {
        self.wrapped = wrapped
        self.failOn = failOn
    }

    struct InjectedFailure: Error, CustomStringConvertible {
        let sql: String
        var description: String { "injected failure for: \(sql)" }
    }

    func execute(_ sql: String, _ bindings: [Format2SqlValue]) throws {
        if sql.contains(failOn) { throw InjectedFailure(sql: sql) }
        try wrapped.execute(sql, bindings)
    }

    func query(_ sql: String, _ bindings: [Format2SqlValue]) throws -> [Format2SqlRow] {
        if sql.contains(failOn) { throw InjectedFailure(sql: sql) }
        return try wrapped.query(sql, bindings)
    }

    func executeScript(_ sql: String) throws {
        if sql.contains(failOn) { throw InjectedFailure(sql: sql) }
        try wrapped.executeScript(sql)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try wrapped.transaction(body)
    }

    var inTransaction: Bool { wrapped.inTransaction }

    /// Forwarded, not withheld: the file-backed query engine prepares its own
    /// statements on this handle, and a decorator that answered `nil` would
    /// make every projection fail for a reason the test did not inject.
    var rawHandle: OpaquePointer? { wrapped.rawHandle }
}
