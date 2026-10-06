import XCTest
@testable import JsBaoClient

/// A string set in canonical order, with byte-distinct members, on the Swift
/// client (#3881, behaviors 4, 22 and 24; edges E3 and E12).
///
/// A string set is unordered and every surface returns it sorted by Unicode
/// code point — SQLite's `ORDER BY value`, which is UTF-8 byte order. Swift
/// never sorts members itself: the fold and `members()` take their order from
/// SQLite. Values are distinct by BYTES, as they are on the server and in JS,
/// so `"é"` (U+00E9) and `"é"` (e + U+0301) are two members — which a Swift
/// `String`-keyed dictionary would merge into one, because `String` equality
/// is canonical equivalence. Member maps are keyed by ``ByteKey`` for that
/// reason, from the overlay's grouping through the snapshot reader.
///
/// Every comparison of member text below is by UTF-8 bytes: `XCTAssertEqual`
/// on two `String`s would call the two spellings equal.
final class Format2StringSetOrderHermeticTests: XCTestCase {

    private static let precomposed = "\u{00E9}"
    private static let decomposed = "e\u{0301}"
    /// E3's seven values, in SQLite's `ORDER BY value` order.
    private static let canonicalSeven = ["", "B", "a", "b", "e\u{0301}", "\u{00E9}", "\u{1F600}"]

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-order-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(
        documentId: String = "d", provider: SQLiteStorageProvider? = nil
    ) async throws -> Format2RecordStore {
        let host: SQLiteStorageProvider
        if let provider { host = provider } else { host = try await makeProvider() }
        let store = Format2RecordStore(host: host, documentId: documentId, clientId: "me")
        try store.initialize()
        return store
    }

    private static func bytes(_ values: [String]) -> [[UInt8]] {
        values.map { Array($0.utf8) }
    }

    private static func bytes(_ value: JSONValue?) -> [[UInt8]]? {
        guard case .array(let members)? = value else { return nil }
        return members.map { Array(($0.stringValue ?? "<not a string>").utf8) }
    }

    private static func members(_ values: [String], present: Bool = true) -> [ByteKey: Bool] {
        Dictionary(uniqueKeysWithValues: values.map { (ByteKey($0), present) })
    }

    // MARK: - Behavior 4 — the overlay keeps byte-distinct members

    func testGroupKeepsCanonicallyEquivalentMembersApart() throws {
        let grouped = OverlayKeys.group([
            (OverlayKeys.memberKey(recordId: "r1", field: "tags", member: Self.precomposed), JSONValue.bool(true)),
            (OverlayKeys.memberKey(recordId: "r1", field: "tags", member: Self.decomposed), JSONValue.bool(true)),
        ])
        let entry = try XCTUnwrap(grouped[ByteKey("r1")])
        let tags = try XCTUnwrap(entry.stringSets["tags"])
        XCTAssertEqual(tags.count, 2, "the two spellings are two members")
        XCTAssertEqual(tags[ByteKey(Self.precomposed)], true)
        XCTAssertEqual(tags[ByteKey(Self.decomposed)], true)
    }

    func testEncodeEmitsBothSpellingsOfAMember() {
        let entries = OverlayKeys.encode(OverlayMutation(
            id: "r1", kind: .patch,
            stringSetDeltas: ["tags": Self.members([Self.precomposed, Self.decomposed])]
        ))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(
            Set(entries.map { Array($0.key.utf8) }),
            Set([
                Array(OverlayKeys.memberKey(recordId: "r1", field: "tags", member: Self.precomposed).utf8),
                Array(OverlayKeys.memberKey(recordId: "r1", field: "tags", member: Self.decomposed).utf8),
            ])
        )
    }

    func testTheFoldStoresBothSpellingsInCodePointOrderAndRemovesEitherAlone() async throws {
        for removed in [Self.precomposed, Self.decomposed] {
            let store = try await makeStore()
            try store.applyRemote(model: "Note", entry: OverlayRecordEntry(
                id: "r1",
                stringSets: ["tags": Self.members([Self.precomposed, Self.decomposed])],
                replace: true
            ))
            XCTAssertEqual(
                Self.bytes(try store.members(model: "Note", recordId: "r1", field: "tags")),
                Self.bytes([Self.decomposed, Self.precomposed])
            )
            XCTAssertEqual(
                Self.bytes(try store.read(model: "Note", recordId: "r1")?["tags"]),
                Self.bytes([Self.decomposed, Self.precomposed])
            )

            try store.applyRemote(model: "Note", entry: OverlayRecordEntry(
                id: "r1", stringSets: ["tags": Self.members([removed], present: false)]
            ))
            // By bytes: `==` on `String` would call the two spellings equal.
            let kept = ByteKey(removed) == ByteKey(Self.precomposed)
                ? Self.decomposed : Self.precomposed
            XCTAssertEqual(
                Self.bytes(try store.members(model: "Note", recordId: "r1", field: "tags")),
                Self.bytes([kept])
            )
            XCTAssertEqual(
                Self.bytes(try store.read(model: "Note", recordId: "r1")?["tags"]),
                Self.bytes([kept])
            )
        }
    }

    /// E3 — seven values, case and non-ASCII among them, in SQLite's order.
    func testTheFoldAndMembersAnswerCodePointOrder() async throws {
        let store = try await makeStore()
        try store.applyRemote(model: "Note", entry: OverlayRecordEntry(
            id: "r1",
            stringSets: ["tags": Self.members(["b", "B", "a", Self.precomposed, Self.decomposed, "\u{1F600}", ""])],
            replace: true
        ))
        XCTAssertEqual(
            Self.bytes(try store.members(model: "Note", recordId: "r1", field: "tags")),
            Self.bytes(Self.canonicalSeven)
        )
        XCTAssertEqual(
            Self.bytes(try store.read(model: "Note", recordId: "r1")?["tags"]),
            Self.bytes(Self.canonicalSeven)
        )
    }

    // MARK: - Behavior 24 — a snapshot chunk keeps byte-distinct members

    func testASnapshotRowLoadsEveryMemberExactlyAsTheJavaScriptLoaderDoes() async throws {
        let data = "{\"id\":\"r1\",\"title\":\"t\",\"tags\":[\"zeta\",\"\u{00E9}\",\"B\",\"e\u{0301}\",\"\",\"\u{1F600}\",\"a\",\"b\"]}"
        let parsed = try XCTUnwrap(
            JSONValue(harness: try JSONSerialization.jsonObject(with: Data(data.utf8))).objectValue
        )
        let entry = SnapshotChunkReader.overlayEntry(
            id: "r1", data: parsed, stringSetFields: ["tags"]
        )
        XCTAssertEqual(entry.stringSets["tags"]?.count, 8, "no member is lost to String equality")

        let store = try await makeStore()
        try store.applyRemote(model: "Note", entry: entry)
        let expected = ["", "B", "a", "b", Self.decomposed, "zeta", Self.precomposed, "\u{1F600}"]
        XCTAssertEqual(
            Self.bytes(try store.members(model: "Note", recordId: "r1", field: "tags")),
            Self.bytes(expected)
        )

        let theirs = try Format2Harness.run([
            "command": "fold-snapshot-rows", "docId": "d", "model": "Note",
            "stringSetFields": ["tags"], "rows": [["id": "r1", "data": data]],
        ])
        let theirMembers = try XCTUnwrap(theirs["members"] as? [[String: Any]])
        XCTAssertEqual(
            Self.bytes(theirMembers.compactMap { $0["value"] as? String }),
            Self.bytes(try store.dumpMembers().map(\.value))
        )
        let theirRecords = try XCTUnwrap(theirs["records"] as? [[String: Any]])
        let theirRow = try XCTUnwrap(
            JSONValue(harness: try JSONSerialization.jsonObject(
                with: Data(try XCTUnwrap(theirRecords.first?["_data"] as? String).utf8)
            )).objectValue
        )
        XCTAssertEqual(
            Self.bytes(try store.read(model: "Note", recordId: "r1")?["tags"]),
            Self.bytes(theirRow["tags"])
        )
        XCTAssertEqual(Self.bytes(theirRow["tags"]), Self.bytes(expected))
    }

    // MARK: - Behavior 22 — a store persisted before the change

    func testAStoreWrittenInInsertionOrderReadsCanonicalWithoutARewrite() async throws {
        let provider = try await makeProvider()
        let store = try await makeStore(documentId: "legacy", provider: provider)
        let tables = Format2TableNames(documentId: "legacy")
        try provider.withConnection { connection in
            try connection.execute(
                "INSERT INTO \(tables.records) (_id, _type, _data) VALUES (?, ?, ?)",
                [.text("r1"), .text("Note"), .text("{\"id\":\"r1\",\"tags\":[\"zeta\",\"alpha\"]}")]
            )
            for value in ["zeta", "alpha"] {
                try connection.execute(
                    "INSERT INTO \(tables.stringSetIndex) (_record_id, _type, field, value) VALUES (?, ?, ?, ?)",
                    [.text("r1"), .text("Note"), .text("tags"), .text(value)]
                )
            }
        }
        let storedRows: () throws -> [String] = {
            try provider.withConnection { connection in
                try connection.query(
                    "SELECT rowid AS rid, value FROM \(tables.stringSetIndex) ORDER BY rowid", []
                ).map { "\($0["rid"].intValue ?? -1):\($0["value"].stringValue ?? "")" }
            }
        }
        let rowsBefore = try storedRows()

        // Reopened under this build, with no update for the record.
        let reopened = try await makeStore(documentId: "legacy", provider: provider)
        XCTAssertEqual(try reopened.members(model: "Note", recordId: "r1", field: "tags"), ["alpha", "zeta"])
        // The raw merged-view read is the internal contract: the stored array.
        XCTAssertEqual(
            try reopened.read(model: "Note", recordId: "r1")?["tags"],
            .array([.string("zeta"), .string("alpha")])
        )
        XCTAssertEqual(try storedRows(), rowsBefore, "the read rewrote nothing")
        _ = store

        // A later delta touching the set stores it canonically.
        try reopened.applyRemote(model: "Note", entry: OverlayRecordEntry(
            id: "r1", stringSets: ["tags": ["mid": true]]
        ))
        XCTAssertEqual(
            try reopened.read(model: "Note", recordId: "r1")?["tags"],
            .array([.string("alpha"), .string("mid"), .string("zeta")])
        )
    }

    // MARK: - Behavior 4 — the pending-op log keeps byte-distinct members

    /// A clear of a set holding both spellings tombstones both, and the
    /// pending-op log is what a crash between the SQLite commit and the
    /// overlay's persistence is recovered from — so it has to hold both
    /// tombstones, and both prior values, or the replay removes one member and
    /// leaves the other on the server (finding 3881-CR-01).
    func testAClearOfBothSpellingsSurvivesAReopenAndReplaysBoth() async throws {
        let provider = try await makeProvider()
        let store = try await makeStore(provider: provider)
        let overlay = OverlayDocument()
        let observer = Format2Observer(store: store, overlay: overlay)
        observer.register(model: "Note")
        let writer = Format2WritePath(store: store, overlay: overlay, observer: observer)
        let both = [Self.precomposed, Self.decomposed]
        _ = try writer.write(
            model: "Note",
            mutation: OverlayMutation(
                id: "r1", kind: .create, stringSetDeltas: ["tags": Self.members(both)]
            ),
            fields: ["tags"]
        )
        _ = try writer.write(
            model: "Note",
            mutation: OverlayMutation(
                id: "r1", kind: .patch,
                stringSetDeltas: ["tags": Self.members(both, present: false)]
            ),
            fields: ["tags"]
        )

        // The process ends here: the SQLite commit landed, the overlay's Yjs
        // update did not. A relaunch reads the log.
        let reopened = try await makeStore(provider: provider)
        let ops = try reopened.pendingOps()
        let clear = try XCTUnwrap(ops.last?.mutation)
        XCTAssertEqual(
            Set(try XCTUnwrap(clear.stringSetDeltas["tags"]).keys),
            Set(both.map { ByteKey($0) }),
            "both tombstones are in the log"
        )
        XCTAssertEqual(clear.stringSetDeltas["tags"]?.values.allSatisfy { !$0 }, true)
        XCTAssertEqual(
            ops.last?.priorOverlay,
            Dictionary(uniqueKeysWithValues: both.map {
                (ByteKey(OverlayKeys.memberKey(recordId: "r1", field: "tags", member: $0)),
                 JSONValue.bool(true))
            }),
            "both prior values are in the log"
        )

        let restored = OverlayDocument()
        Format2PendingRestore.restorePendingOverlay(overlay: restored, ops: ops)
        for member in both {
            XCTAssertEqual(
                restored.value(
                    model: "Note",
                    key: OverlayKeys.memberKey(recordId: "r1", field: "tags", member: member)
                ),
                .bool(false),
                "the replay removes \(Array(member.utf8))"
            )
        }
    }

    /// A log row in the shape js-bao writes, and this client wrote before
    /// #3881, reads back with every member key it holds.
    func testAStoredMutationReadsEveryMemberKeyItHolds() throws {
        let text = "{\"id\":\"r1\",\"kind\":\"patch\",\"fields\":{\"title\":\"t\"},"
            + "\"stringSetDeltas\":{\"tags\":{\"\(Self.precomposed)\":false,\"\(Self.decomposed)\":true}}}"
        let mutation = try XCTUnwrap(OverlayMutation(storedText: text))
        XCTAssertEqual(mutation.fields, ["title": .string("t")])
        XCTAssertEqual(
            mutation.stringSetDeltas["tags"],
            [ByteKey(Self.precomposed): false, ByteKey(Self.decomposed): true]
        )
        XCTAssertEqual(OverlayMutation(storedText: try mutation.storedText()), mutation)
    }
}
