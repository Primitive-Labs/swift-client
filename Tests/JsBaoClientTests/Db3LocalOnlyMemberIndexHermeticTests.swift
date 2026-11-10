import XCTest
@testable import JsBaoClient

/// #5156 behavior 11 and edge case E8 (registry half) — a local-only db3
/// registers a member index on the device by the room's rules, in the room's
/// order: the registration the field holds answers first (its member index
/// again whatever the field's declaration has become; a scalar index
/// `DB3_INDEX_EXISTS`), and only then is a field declared with another type
/// than `stringset` `DB3_INDEX_NOT_SET_FIELD`. Pure functions: no store.
final class Db3LocalOnlyMemberIndexRulesHermeticTests: XCTestCase {

    private static let fields: [String: FieldDescriptor] = [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
        "slug": FieldDescriptor(type: .string, indexed: true), "tags": FieldDescriptor(type: .stringset),
    ]
    private let schemas = [PrimitiveSchema(name: "Note", fields: fields)]
    private let member = RecordLogLocalIndex(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, members: true)
    private let named = [Db3IndexOrigin(kind: .named, unique: false)]

    private func refusal(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> JsBaoError? {
        do {
            try body()
            XCTFail("the registration was not refused", file: file, line: line)
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("threw \(error)", file: file, line: line)
        }
        return nil
    }

    func testAddsAMemberRegistrationListedWithMembersAndANamedOriginAddingNoConstraint() throws {
        let planned = try RecordLogLocalOnly.register(schemas, [], Db3IndexRegistration(model: "Note", field: "tags", members: true))
        XCTAssertEqual(planned.registrations, [member])
        XCTAssertEqual(planned.index, Db3Index(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, members: true, origins: named, kind: .members, on: .device))
        XCTAssertTrue(RecordLogLocalOnly.indexList(schemas, planned.registrations).contains(planned.index))
        XCTAssertEqual(RecordLogLocalOnly.constraints(schemas, planned.registrations), RecordLogLocalOnly.constraints(schemas, []))
        // Stored as js-bao stores it, and read back the same.
        XCTAssertEqual(member.json["members"], .bool(true))
        XCTAssertEqual(RecordLogLocalIndex(json: member.json), member)
        XCTAssertEqual(RecordLogLocalOnly.entries(RecordLogLocalOnly.indexList(schemas, planned.registrations)).first { $0.fields == ["tags"] }?.members, true)
    }

    func testOptsInAnUndeclaredFieldAndNamesASecondModelDifferingInCase_2() throws {
        let both = schemas + [PrimitiveSchema(name: "note", fields: ["id": FieldDescriptor(type: .id)])]
        let first = try RecordLogLocalOnly.register(both, [], Db3IndexRegistration(model: "Note", field: "labels", members: true))
        XCTAssertEqual(first.index.name, "idx_members_note_labels")
        let second = try RecordLogLocalOnly.register(both, first.registrations, Db3IndexRegistration(model: "note", field: "labels", members: true))
        XCTAssertEqual(second.index.name, "idx_members_note_labels_2")
        XCTAssertEqual(second.index.model, "note")
        XCTAssertEqual(Set(second.registrations.map(\.name)), ["idx_members_note_labels", "idx_members_note_labels_2"])
    }

    func testRefusesMembersBesideFieldsUniqueOrName() {
        // The public initializers build no such body; a decoded one could carry it.
        for body in [
            Db3IndexRegistration(model: "Note", field: nil, fields: ["tags"], unique: nil, name: nil, members: true),
            Db3IndexRegistration(model: "Note", field: "tags", fields: nil, unique: false, name: nil, members: true),
            Db3IndexRegistration(model: "Note", field: "tags", fields: nil, unique: nil, name: "by_tag", members: true),
        ] {
            XCTAssertEqual(refusal { _ = try RecordLogLocalOnly.register(schemas, [], body) }?.code, .db3IndexInvalid)
        }
    }

    func testAnswersTheSameRowAgainIncludingAfterTheFieldIsDeclaredString() throws {
        let planned = try RecordLogLocalOnly.register(schemas, [], Db3IndexRegistration(model: "Note", field: "tags", members: true))
        let again = try RecordLogLocalOnly.register(schemas, planned.registrations, Db3IndexRegistration(model: "Note", field: "tags", members: true))
        XCTAssertEqual(again.registrations, planned.registrations)
        XCTAssertEqual(again.index, planned.index)
        var redeclared = Self.fields
        redeclared["tags"] = FieldDescriptor(type: .string)
        let changed = [PrimitiveSchema(name: "Note", fields: redeclared)]
        let after = try RecordLogLocalOnly.register(changed, planned.registrations, Db3IndexRegistration(model: "Note", field: "tags", members: true))
        XCTAssertEqual(after.registrations, planned.registrations)
        XCTAssertEqual(after.index.name, member.name)
        XCTAssertTrue(after.index.members)
    }

    func testRefusesAFieldAScalarIndexHoldsBeforeJudgingItsType() throws {
        let declared = refusal { _ = try RecordLogLocalOnly.register(self.schemas, [], Db3IndexRegistration(model: "Note", field: "slug", members: true)) }
        XCTAssertEqual(declared?.code, .db3IndexExists)
        XCTAssertEqual(declared?.details?["index"], .string("idx_records_note_slug"))
        let title = try RecordLogLocalOnly.register(schemas, [], Db3IndexRegistration(model: "Note", field: "title"))
        let registered = refusal {
            _ = try RecordLogLocalOnly.register(self.schemas, title.registrations, Db3IndexRegistration(model: "Note", field: "title", members: true))
        }
        XCTAssertEqual(registered?.code, .db3IndexExists)
        XCTAssertEqual(registered?.details?["index"], .string("idx_records_note_title"))
    }

    func testRefusesAFieldDeclaredWithAnotherTypeAndNoRegistration() {
        let scalar = refusal { _ = try RecordLogLocalOnly.register(self.schemas, [], Db3IndexRegistration(model: "Note", field: "title", members: true)) }
        XCTAssertEqual(scalar?.code, .db3IndexNotSetField)
        XCTAssertEqual(scalar?.details?["field"], .string("title"))
    }

    func testRefusesAScalarRegistrationOnAMemberIndexedFieldAndDropsTheMemberIndex() throws {
        let planned = try RecordLogLocalOnly.register(schemas, [], Db3IndexRegistration(model: "Note", field: "tags", members: true))
        let scalar = refusal { _ = try RecordLogLocalOnly.register(self.schemas, planned.registrations, Db3IndexRegistration(model: "Note", field: "tags")) }
        XCTAssertEqual(scalar?.code, .db3IndexExists)
        XCTAssertEqual(scalar?.details?["index"], .string(member.name))
        let remaining = try RecordLogLocalOnly.drop(schemas, planned.registrations, name: member.name)
        XCTAssertEqual(remaining, [])
        XCTAssertFalse(RecordLogLocalOnly.indexList(schemas, remaining).contains { $0.name == member.name })
    }

    func testPointsADeclaredStringSetRegisteredWithoutMembersAtMembersTrue() {
        let set = refusal { _ = try RecordLogLocalOnly.register(self.schemas, [], Db3IndexRegistration(model: "Note", field: "tags")) }
        XCTAssertEqual(set?.code, .db3IndexSetField)
        XCTAssertEqual(set?.details?["field"], .string("tags"))
        XCTAssertTrue(set?.message.contains("members: true") == true)
    }
}

/// #5156 behavior 12 and edge case E10 — a local-only db3's member index in
/// the record-log store: `syncIndexes` caches a member entry of a local-only
/// document with its device table, builds the table in the room's shape with
/// three triggers on the view and gathers the store's statistics (this test
/// runs no `ANALYZE`); the triggers keep the table equal to the view's
/// arrays across every local write; a synced document's entry builds and
/// gathers nothing; dropping the entry or purging the db3 drops the table
/// and its triggers; a store at storage version 4 opens at 5.
final class Db3LocalOnlyMemberIndexStoreHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    static let member = RecordLogIndexEntry(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, members: true)

    /// The device table `documentId`'s member index on `Note.tags` is kept in.
    static func table(_ documentId: String) -> String {
        "idx_record_log_members_\(documentId.utf16.count)_\(documentId.lowercased())_4_note_4_tags"
    }

    private func provider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/db3-member-index-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// `documentId`'s store on `provider`, its writer minted, marked local-only unless `synced`, enforcing a unique `slug`.
    private func store(_ provider: SQLiteStorageProvider, _ documentId: String, synced: Bool = false) throws -> (RecordLogStore, String) {
        let store = RecordLogStore(host: provider, documentId: documentId, clientId: "client-1")
        try store.initialize()
        let writer = try store.mintWriter()
        try store.setState(
            writer: writer, constraints: [RecordLogConstraint(model: "Note", name: "slug_unique", fields: ["slug"])],
            localOnly: synced ? nil : true
        )
        return (store, writer)
    }

    @discardableResult
    private func commit(_ store: RecordLogStore, _ writer: String, _ mutations: [RecordLogMutation], upsertOn: String? = nil) throws -> RecordLogCommitReply {
        let reply = try store.commitEntries(writer: writer, writes: mutations.map { RecordLogWrite(mutations: [$0], upsertOn: upsertOn) })
        try store.flush()
        return reply
    }

    private func create(_ id: String, _ fields: [String: JSONValue], model: String = "Note") -> RecordLogMutation {
        RecordLogMutation(model: model, id: id, kind: .create, fields: fields)
    }

    private func rows(_ provider: SQLiteStorageProvider, _ sql: String, _ bindings: [Format2SqlValue] = []) throws -> [Format2SqlRow] {
        try provider.withConnection { try $0.query(sql, bindings) }
    }

    /// The members `documentId`'s view holds for `Note.tags`, as `value|rid`, by the view alone.
    private func truth(_ provider: SQLiteStorageProvider, _ documentId: String) throws -> [String] {
        try rows(
            provider,
            """
            SELECT m.value AS value, v.rowid AS rid FROM record_log_view v, json_each(v._data, '$.tags') m
             WHERE v.doc_id = ? AND v._type = 'Note' AND json_type(v._data, '$.tags') = 'array' ORDER BY 1, 2
            """,
            [.text(documentId)]
        ).map { "\($0["value"].stringValue ?? "")|\($0["rid"].intValue ?? 0)" }
    }

    /// A member table's rows, as `value|rid`.
    private func held(_ provider: SQLiteStorageProvider, _ table: String) throws -> [String] {
        try rows(provider, "SELECT value, rid FROM \"\(table)\" ORDER BY 1, 2").map { "\($0["value"].stringValue ?? "")|\($0["rid"].intValue ?? 0)" }
    }

    /// The member family's tables and triggers, as `type name`.
    private func family(_ provider: SQLiteStorageProvider) throws -> [String] {
        try rows(provider, #"SELECT type, name FROM sqlite_master WHERE name LIKE 'idx\_record\_log\_members\_%' ESCAPE '\' ORDER BY type, name"#)
            .map { "\($0["type"].stringValue ?? "") \($0["name"].stringValue ?? "")" }
    }

    private func familyOf(_ documentId: String) -> [String] {
        let table = Self.table(documentId)
        return ["table \(table)", "trigger \(table)__d", "trigger \(table)__i", "trigger \(table)__u"]
    }

    /// The tables SQLite holds statistics for; none when it never gathered any.
    private func statistics(_ provider: SQLiteStorageProvider) throws -> [String] {
        guard try !rows(provider, "SELECT 1 FROM sqlite_master WHERE name = 'sqlite_stat1'").isEmpty else { return [] }
        return Array(Set(try rows(provider, "SELECT tbl FROM sqlite_stat1").compactMap { $0["tbl"].stringValue })).sorted()
    }

    private func mark(_ provider: SQLiteStorageProvider) throws -> Int? {
        try rows(provider, "SELECT value FROM record_log_meta WHERE key = 'statistics_rowid'").first?["value"].intValue
    }

    private func highestRowid(_ provider: SQLiteStorageProvider) throws -> Int {
        try rows(provider, "SELECT MAX(rowid) AS n FROM record_log_view").first?["n"].intValue ?? 0
    }

    func testCachesBuildsAndAnalyzesAPopulatedLocalOnlyDb3sMemberIndex() async throws {
        let provider = try await provider()
        let (store, writer) = try store(provider, "db3-local")
        try commit(store, writer, [
            create("r1", ["slug": "a", "tags": ["a", "b"]]), create("r2", ["slug": "b", "tags": ["b", "c"]]),
            create("r3", ["slug": "c", "tags": "a"]), create("r4", ["slug": "d"]), create("t1", ["tags": ["a"]], model: "Tag"),
        ])
        try store.syncIndexes([Self.member])
        let cached = try rows(provider, "SELECT model, fields, members FROM record_log_indexes WHERE doc_id = 'db3-local'")
        XCTAssertEqual(cached.map { $0["members"].stringValue }, [Self.table("db3-local")])
        XCTAssertEqual(try family(provider), familyOf("db3-local"))
        let columns = try rows(provider, "SELECT name, type, \"notnull\", pk FROM pragma_table_info(?) ORDER BY cid", [.text(Self.table("db3-local"))])
        XCTAssertEqual(columns.map { "\($0["name"].stringValue ?? "") \($0["type"].stringValue ?? "") \($0["notnull"].intValue ?? 0) \($0["pk"].intValue ?? 0)" },
                       ["value TEXT 1 1", "rid INTEGER 1 2"])
        XCTAssertEqual(try rows(provider, "SELECT wr FROM pragma_table_list WHERE name = ?", [.text(Self.table("db3-local"))]).first?["wr"].intValue, 1)
        XCTAssertEqual(try held(provider, Self.table("db3-local")), try truth(provider, "db3-local"))
        XCTAssertEqual(try held(provider, Self.table("db3-local")).map { String($0.split(separator: "|")[0]) }, ["a", "b", "b", "c"])
        XCTAssertEqual(try statistics(provider), [Self.table("db3-local"), "record_log_view"].sorted())
        XCTAssertEqual(try mark(provider), try highestRowid(provider))
        // A second sync with the same list builds nothing.
        XCTAssertEqual(try store.syncIndexes([Self.member]), RecordLogIndexSync(created: 0, dropped: 0))
    }

    func testTheTriggersKeepTheTableEqualToTheViewsArraysAcrossEveryLocalWrite() async throws {
        let provider = try await provider()
        let (store, writer) = try store(provider, "db3-local")
        let (other, otherWriter) = try self.store(provider, "db3-other")
        try store.syncIndexes([Self.member])
        let table = Self.table("db3-local")
        func equal(_ step: String) throws { XCTAssertEqual(try held(provider, table), try truth(provider, "db3-local"), step) }

        try commit(store, writer, [create("r1", ["slug": "s1", "tags": ["a", "b"]])])
        try equal("a create with members")
        try commit(store, writer, [RecordLogMutation(model: "Note", id: "r1", kind: .patch, stringSetDeltas: ["tags": ["c": true, "a": false]])])
        try equal("a patch adding and removing members")
        try commit(store, writer, [create("r2", ["slug": "s2", "tags": ["b"]])])
        try commit(store, writer, [RecordLogMutation(model: "Note", id: "r2", kind: .patch, fields: ["tags": ["d", "e"]])])
        try equal("a patch replacing the set")
        try commit(store, writer, [RecordLogMutation(model: "Note", id: "r1", kind: .patch, fields: ["tags": []])])
        try equal("the set emptied")
        try commit(store, writer, [RecordLogMutation(model: "Note", id: "r2", kind: .patch, fields: ["title": "renamed"])])
        try equal("another field patched")
        try commit(store, writer, [RecordLogMutation(model: "Note", id: "r2", kind: .delete)])
        try equal("a delete")
        try commit(store, writer, [create("r2", ["slug": "s2", "tags": ["f"]])])
        try equal("a revival with members")
        try commit(store, writer, [create("r3", ["slug": "s3", "tags": ["g", "h"]])])
        try equal("a new record")
        let upsert = try commit(store, writer, [create("r9", ["slug": "s3", "tags": ["i"]])], upsertOn: "slug")
        XCTAssertEqual(upsert.aliases.first?.to, "r3")
        try equal("an upsert landing on another record")
        try commit(store, writer, [RecordLogMutation(model: "Note", id: "r3", kind: .patch, fields: ["tags": "g"])])
        try equal("a set written as a string")
        try commit(store, writer, [create("r7", ["slug": "s7", "tags": ["it's", "back\\slash", "naïve"]])])
        try equal("members holding a quote, a backslash and a non-ASCII letter")
        XCTAssertTrue(try held(provider, table).contains { $0.hasPrefix("naïve|") })
        try commit(store, writer, [create("r1", ["slug": "s1", "tags": ["j"]])])
        try equal("a re-create with members")
        // The bulk shape: a batch of view rows deleted, then inserted again from the confirmed rows.
        try provider.withConnection { connection in
            try connection.execute("DELETE FROM record_log_view WHERE doc_id = 'db3-local' AND _type = 'Note' AND _id IN ('r1', 'r2', 'r7')", [])
            try connection.execute(
                """
                INSERT INTO record_log_view (doc_id, _type, _id, _data)
                  SELECT doc_id, _type, _id, _data FROM record_log_rows WHERE doc_id = 'db3-local' AND _type = 'Note' AND _id IN ('r1', 'r2', 'r7')
                """, []
            )
        }
        try equal("the bulk shape")
        // Another db3's and another model's writes leave the table as it was.
        let before = try held(provider, table)
        try commit(other, otherWriter, [create("r1", ["tags": ["zz"]])])
        try commit(other, otherWriter, [RecordLogMutation(model: "Note", id: "r1", kind: .delete)])
        try commit(store, writer, [create("t1", ["tags": ["zz"]], model: "Tag")])
        XCTAssertEqual(try held(provider, table), before)
    }

    func testASyncedDb3sMemberEntryBuildsAndGathersNothing() async throws {
        let provider = try await provider()
        let (store, writer) = try store(provider, "db3-synced", synced: true)
        try commit(store, writer, [create("r1", ["slug": "a", "tags": ["a"]])])
        try store.syncIndexes([Self.member])
        XCTAssertTrue(try rows(provider, "SELECT 1 FROM record_log_indexes WHERE doc_id = 'db3-synced'").isEmpty)
        XCTAssertEqual(try family(provider), [])
        XCTAssertEqual(try statistics(provider), [])
        XCTAssertNil(try mark(provider))
    }

    func testDroppingTheEntryOrPurgingTheDb3DropsItsTableAndTriggers() async throws {
        let provider = try await provider()
        let (store, writer) = try store(provider, "db3-local")
        let (other, otherWriter) = try self.store(provider, "db3-other")
        try commit(store, writer, [create("r1", ["slug": "a", "tags": ["a"]])])
        try commit(other, otherWriter, [create("r1", ["slug": "a", "tags": ["z"]])])
        try store.syncIndexes([Self.member])
        try other.syncIndexes([Self.member])
        XCTAssertEqual(try family(provider), (familyOf("db3-local") + familyOf("db3-other")).sorted())
        XCTAssertEqual(try store.syncIndexes([]), RecordLogIndexSync(created: 0, dropped: 1))
        XCTAssertEqual(try family(provider), familyOf("db3-other"))
        try store.syncIndexes([Self.member])
        XCTAssertEqual(try held(provider, Self.table("db3-local")), try truth(provider, "db3-local"))
        XCTAssertTrue(try store.purge(force: true).purged)
        XCTAssertEqual(try family(provider), familyOf("db3-other"))
        try commit(other, otherWriter, [create("r2", ["slug": "b", "tags": ["y"]])])
        XCTAssertEqual(try held(provider, Self.table("db3-other")), try truth(provider, "db3-other"))
    }

    func testAVersion4StoreOpensAtTheVersionWithTheMembersAndKindColumnsAndItsDb3sUnchanged() async throws {
        let provider = try await provider()
        let (synced, writer) = try store(provider, "db3-synced", synced: true)
        try commit(synced, writer, [create("r1", ["slug": "a"])])
        try synced.syncIndexes([RecordLogIndexEntry(name: "idx_records_note_slug", model: "Note", fields: ["slug"], unique: true)])
        let (local, localWriter) = try store(provider, "db3-local")
        try commit(local, localWriter, [create("r1", ["slug": "a", "tags": ["a"]])])
        let before = try synced.storedState()
        let tuples = try synced.indexTuples()
        // The cache as version 4 kept it: no `members` column (#5156), no `kind` (#5223).
        try provider.withConnection { connection in
            let cached = try connection.query("SELECT doc_id, model, fields, is_unique, room_name FROM record_log_indexes", [])
            try connection.executeScript("DROP TABLE record_log_indexes")
            try connection.executeScript(Db3DeviceIndexWorld.indexCache(version: 4))
            for row in cached {
                try connection.execute(
                    "INSERT INTO record_log_indexes (doc_id, model, fields, is_unique, room_name) VALUES (?, ?, ?, ?, ?)",
                    [row["doc_id"], row["model"], row["fields"], row["is_unique"], row["room_name"]]
                )
            }
            try connection.execute("UPDATE record_log_meta SET value = '4' WHERE key = 'storage_version'", [])
        }
        let reopened = RecordLogStore(host: provider, documentId: "db3-synced", clientId: "client-1")
        try reopened.initialize()
        XCTAssertEqual(try rows(provider, "SELECT value FROM record_log_meta WHERE key = 'storage_version'").first?["value"].stringValue,
                       String(RecordLogSchema.storageVersion))
        XCTAssertGreaterThanOrEqual(RecordLogSchema.storageVersion, 6)
        XCTAssertEqual(try rows(provider, "SELECT name FROM pragma_table_info('record_log_indexes') ORDER BY cid").compactMap { $0["name"].stringValue },
                       ["doc_id", "model", "fields", "kind", "is_unique", "room_name", "members", "text", "options", "vector"])
        XCTAssertEqual(try rows(provider, "SELECT kind, members FROM record_log_indexes").map { "\($0["kind"].stringValue ?? "") \($0["members"].isNull)" },
                       ["scalar true"])
        let after = try reopened.storedState()
        XCTAssertEqual(after.cursor, before.cursor)
        XCTAssertEqual(after.rows, before.rows)
        XCTAssertEqual(after.writers, before.writers)
        XCTAssertEqual(try reopened.indexTuples(), tuples)
        XCTAssertTrue(try local.marks().localOnly)
        XCTAssertEqual(try family(provider), [])
    }
}

/// A local-only db3's store on a provider of its own, for the read and growth suites below.
private final class MemberIndexStoreWorld {
    let provider: SQLiteStorageProvider
    let store: RecordLogStore
    let writer: String
    let documentId: String
    private let directory: String

    init(_ documentId: String, label: String) async throws {
        directory = NSTemporaryDirectory() + "/db3-member-index-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        self.documentId = documentId
        store = RecordLogStore(host: provider, documentId: documentId, clientId: "client-1")
        try store.initialize()
        writer = try store.mintWriter()
        try store.setState(writer: writer, localOnly: true)
    }

    func remove() { try? FileManager.default.removeItem(atPath: directory) }

    func commit(_ mutations: [RecordLogMutation]) throws {
        for start in stride(from: 0, to: mutations.count, by: 500) {
            let slice = mutations[start..<min(start + 500, mutations.count)]
            _ = try store.commitEntries(writer: writer, writes: slice.map { RecordLogWrite(mutations: [$0]) })
        }
        try store.flush()
    }

    func rows(_ sql: String, _ bindings: [Format2SqlValue] = []) throws -> [Format2SqlRow] {
        try provider.withConnection { try $0.query(sql, bindings) }
    }

    func plan(_ statement: String) throws -> String {
        try rows("EXPLAIN QUERY PLAN \(statement)").compactMap { $0["detail"].stringValue }.joined(separator: " | ")
    }

    func reader(_ documents: [String]? = nil) -> RecordLogViewReader {
        RecordLogViewReader(store: store, documents: documents ?? [documentId])
    }
}

/// The member-index statements a read ran: those naming the view or a member table.
private func reads(_ trace: RecordLogStatementTrace) -> [String] {
    trace.statements.filter { statement in
        let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("SELECT") && (text.contains("record_log_view") || text.contains("idx_record_log_members_"))
            && !text.contains("record_log_indexes") && !text.contains("record_log_state")
    }
}

/// #5156 behavior 13 and edge cases E1, E3, E4 — a local-only db3's reads
/// answer from its member index in the Swift store: `$contains`, an any-of,
/// a membership level and an unfiltered facet read the device table (the
/// plan, with the store's own statistics, probing the view by rowid) and
/// answer exactly what a copy without the index answers; every other read
/// emits the statement it emits without the index.
final class Db3LocalOnlyMemberIndexReadsHermeticTests: XCTestCase {

    private static let genres = ["Action", "Comedy", "Drama", "Horror", "Romance", "Sci-Fi", "Thriller", "War", "Western"]
    private static let odd = ["it's", "back\\slash", "naïve"]
    private static let document = "db3-reads"
    private static var table: String { Db3LocalOnlyMemberIndexStoreHermeticTests.table(document) }
    private static var probe: String { "record_log_view.rowid IN (SELECT rid FROM \"\(table)\" WHERE value = ?)" }

    private var worlds: [MemberIndexStoreWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    /// 600 deterministic Notes with `tags` from nine genres, `labels`, a year and a title, and the edge records.
    private static func fixture() -> [RecordLogMutation] {
        var state: UInt32 = 5156
        func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / 4_294_967_296
        }
        var out: [RecordLogMutation] = []
        for n in 1...600 {
            var tags: [String: Bool] = [:]
            for _ in 0..<Int(next() * 4) { tags[genres[Int(next() * Double(genres.count))]] = true }
            out.append(RecordLogMutation(
                model: "Note", id: String(format: "n%04d", n), kind: .create,
                fields: ["title": .string("t\(Int(next() * 50))"), "year": .number(Double(1950 + Int(next() * 70))), "labels": ["l"]],
                stringSetDeltas: ["tags": tags]
            ))
        }
        out.append(RecordLogMutation(model: "Note", id: "e1", kind: .create, fields: ["title": "string", "tags": "Drama"]))
        out.append(RecordLogMutation(model: "Note", id: "e2", kind: .create, fields: ["title": "empty", "tags": []]))
        out.append(RecordLogMutation(model: "Note", id: "e3", kind: .create, fields: ["title": "none"]))
        out.append(RecordLogMutation(model: "Note", id: "e4", kind: .create, fields: ["title": "number", "tags": 7]))
        out.append(RecordLogMutation(model: "Note", id: "e5", kind: .create, fields: ["title": "object", "tags": ["a": "Drama"]]))
        out.append(RecordLogMutation(
            model: "Note", id: "e6", kind: .create, fields: ["title": "odd", "year": 1980],
            stringSetDeltas: ["tags": Dictionary(uniqueKeysWithValues: odd.map { ($0, true) })]
        ))
        return out
    }

    /// The fixture in a local-only store, holding the member index on `tags` when `indexed` (registered after the rows).
    private func world(indexed: Bool) async throws -> MemberIndexStoreWorld {
        let world = try await MemberIndexStoreWorld(Self.document, label: indexed ? "indexed" : "plain")
        worlds.append(world)
        try world.commit(Self.fixture())
        if indexed { try world.store.syncIndexes([Db3LocalOnlyMemberIndexStoreHermeticTests.member]) }
        return world
    }

    private static let filters: [(String, DocumentFilter)] = [
        ("contains", ["tags": ["$contains": "Drama"]]),
        ("anyOf", ["$or": [["tags": ["$contains": "War"]], ["tags": ["$contains": "Western"]]]]),
        ("all", ["tags": ["$all": ["Drama", "Comedy"]]]),
        ("size", ["tags": ["$size": 2]]),
        ("sizeZero", ["tags": ["$size": 0]]),
        ("containsText", ["tags": ["$containsText": "ram"]]),
        ("startsWith", ["tags": ["$startsWith": "Sci"]]),
        ("containsAndRange", ["tags": ["$contains": "Comedy"], "year": ["$gte": 2000]]),
        ("containsNobody", ["tags": ["$contains": "Nobody"]]),
        ("quote", ["tags": ["$contains": "it's"]]),
        ("backslash", ["tags": ["$contains": "back\\slash"]]),
        ("nonAscii", ["tags": ["$contains": "naïve"]]),
        ("notOptedIn", ["labels": ["$contains": "l"]]),
    ]

    private static func aggregates() -> [(String, AggregateOptions)] {
        let count = AggregateOperation(type: .count)
        let avg = AggregateOperation(type: .avg, field: "year")
        return [
            ("facet", AggregateOptions(groupBy: ["tags"], operations: [count])),
            ("facetAvg", AggregateOptions(groupBy: ["tags"], operations: [count, avg])),
            ("facetFiltered", AggregateOptions(groupBy: ["tags"], operations: [count], filter: ["year": ["$gte": 2000]])),
            ("membership", AggregateOptions(groupBy: [.stringSetMembership(field: "tags", contains: "Drama")], operations: [count, avg])),
            ("facetSorted", AggregateOptions(groupBy: ["tags"], operations: [count], sort: AggregateSort(field: "tags", direction: -1), limit: 5)),
            ("facetByCount", AggregateOptions(groupBy: ["tags"], operations: [count], sort: AggregateSort(field: "count", direction: -1))),
            ("facetByCountLimited", AggregateOptions(groupBy: ["tags"], operations: [count], sort: AggregateSort(field: "count", direction: 1), limit: 4)),
        ]
    }

    private func ids(_ world: MemberIndexStoreWorld, _ filter: DocumentFilter, sorted: Bool = false) throws -> [String] {
        let options = QueryOptions(sortOrder: sorted ? [("year", -1), ("id", 1)] : nil, limit: 10_000)
        return try world.store.queryView("Note", filter, options: options).data.compactMap { $0["id"]?.stringValue }
    }

    func testEveryShapeAnswersTheSameFromTheIndexAsFromACopyWithoutIt() async throws {
        let indexed = try await world(indexed: true)
        let plain = try await world(indexed: false)
        for (name, filter) in Self.filters {
            XCTAssertEqual(Set(try ids(indexed, filter)), Set(try ids(plain, filter)), "\(name): unsorted")
            XCTAssertEqual(try ids(indexed, filter, sorted: true), try ids(plain, filter, sorted: true), "\(name): sorted")
            XCTAssertEqual(try indexed.store.countView("Note", filter), try plain.store.countView("Note", filter), "\(name): count")
        }
        for (name, options) in Self.aggregates() {
            let fromIndex = try indexed.reader().aggregate("Note", options, setFields: ["tags"])
            let fromData = try plain.reader().aggregate("Note", options, setFields: ["tags"])
            if options.sort != nil {
                XCTAssertEqual(fromIndex, fromData, name)
            } else {
                XCTAssertEqual(Set(fromIndex.map { RecordLogJSON.text(.object($0)) }), Set(fromData.map { RecordLogJSON.text(.object($0)) }), name)
            }
            XCTAssertFalse(fromData.isEmpty, "\(name) answers rows")
        }
        // E1, E3: the odd members are found, and no record without an array is.
        for member in Self.odd { XCTAssertEqual(try ids(indexed, ["tags": ["$contains": .string(member)]]), ["e6"]) }
        XCTAssertFalse(try ids(indexed, ["tags": ["$contains": "Drama"]]).contains { ["e1", "e2", "e3", "e4", "e5"].contains($0) })
    }

    func testTheIndexedShapesReadTheDeviceTableAndTheRestReadData() async throws {
        let indexed = try await world(indexed: true)
        let plain = try await world(indexed: false)
        let indexedTrace = try RecordLogStatementTrace.install(on: indexed.provider, self)
        let plainTrace = try RecordLogStatementTrace.install(on: plain.provider, self)
        func ran(_ world: MemberIndexStoreWorld, _ trace: RecordLogStatementTrace, _ read: (MemberIndexStoreWorld) throws -> Void) throws -> String {
            trace.clear()
            try read(world)
            return try XCTUnwrap(reads(trace).last, "a read ran")
        }

        let contains = try ran(indexed, indexedTrace) { _ = try $0.store.countView("Note", ["tags": ["$contains": "Drama"]]) }
        XCTAssertTrue(contains.contains(Self.probe), contains)
        XCTAssertFalse(contains.contains("json_each"), contains)
        let steps = try indexed.plan(contains)
        XCTAssertTrue(steps.contains("SEARCH record_log_view USING INTEGER PRIMARY KEY (rowid=?)"), steps)
        XCTAssertFalse(steps.contains("sqlite_autoindex_record_log_view_1"), steps)
        let page = try ran(indexed, indexedTrace) { _ = try $0.store.queryView("Note", ["tags": ["$contains": "Drama"]]) }
        XCTAssertTrue(page.contains(Self.probe), page)
        let anyOf = try ran(indexed, indexedTrace) {
            _ = try $0.store.countView("Note", ["$or": [["tags": ["$contains": "War"]], ["tags": ["$contains": "Western"]]]])
        }
        XCTAssertEqual(anyOf.components(separatedBy: Self.probe).count - 1, 2, anyOf)
        let membership = try ran(indexed, indexedTrace) {
            _ = try $0.reader().aggregate("Note", AggregateOptions(groupBy: [.stringSetMembership(field: "tags", contains: "Drama")], operations: [AggregateOperation(type: .count)]), setFields: ["tags"])
        }
        XCTAssertTrue(membership.contains("CASE WHEN \(Self.probe) THEN 'true' ELSE 'false' END"), membership)
        let counted = try ran(indexed, indexedTrace) {
            _ = try $0.reader().aggregate("Note", AggregateOptions(groupBy: ["tags"], operations: [AggregateOperation(type: .count)]), setFields: ["tags"])
        }
        XCTAssertTrue(counted.contains("FROM \"\(Self.table)\" AS _facet GROUP BY"), counted)
        XCTAssertFalse(counted.contains("record_log_view"), counted)
        let averaged = try ran(indexed, indexedTrace) {
            _ = try $0.reader().aggregate("Note", AggregateOptions(groupBy: ["tags"], operations: [AggregateOperation(type: .count), AggregateOperation(type: .avg, field: "year")]), setFields: ["tags"])
        }
        XCTAssertTrue(averaged.contains("FROM \"\(Self.table)\" AS _facet JOIN record_log_view ON record_log_view.rowid = _facet.rid"), averaged)
        XCTAssertTrue(try indexed.plan(averaged).contains("SEARCH record_log_view USING INTEGER PRIMARY KEY (rowid=?)"))

        // Every other read emits the statement it emits without the index.
        for filter: DocumentFilter in [
            ["tags": ["$all": ["Drama", "Comedy"]]], ["tags": ["$size": 2]], ["tags": ["$startsWith": "Sci"]],
            ["tags": ["$endsWith": "ma"]], ["tags": ["$containsText": "ram"]], ["labels": ["$contains": "l"]],
        ] {
            let a = try ran(indexed, indexedTrace) { _ = try $0.store.countView("Note", filter) }
            let b = try ran(plain, plainTrace) { _ = try $0.store.countView("Note", filter) }
            XCTAssertEqual(a, b, "\(filter)")
        }
        let filtered = AggregateOptions(groupBy: ["tags"], operations: [AggregateOperation(type: .count)], filter: ["year": ["$gte": 2000]])
        XCTAssertEqual(
            try ran(indexed, indexedTrace) { _ = try $0.reader().aggregate("Note", filtered, setFields: ["tags"]) },
            try ran(plain, plainTrace) { _ = try $0.reader().aggregate("Note", filtered, setFields: ["tags"]) }
        )
        // E4: a read over two db3s reads `_data`.
        let both = [Self.document, "db3-other"]
        let a = try ran(indexed, indexedTrace) { _ = try $0.reader(both).count("Note", ["tags": ["$contains": "Drama"]]) }
        let b = try ran(plain, plainTrace) { _ = try $0.reader(both).count("Note", ["tags": ["$contains": "Drama"]]) }
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.contains(Self.table), a)
    }
}

/// #5156 behavior 17 (Swift half) and edge case E5 — a store holding a
/// member index gathers statistics as its view grows: none on an empty
/// registration or below 1,000 rows, at the commit reaching 1,000 (after
/// which the rare `$contains` the reader runs probes the view by rowid),
/// then none until ten times the mark; a refused gathering leaves the
/// commit and the index as they were.
final class Db3LocalOnlyMemberIndexGrowthHermeticTests: XCTestCase {

    private var worlds: [MemberIndexStoreWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func notes(_ range: Range<Int>) -> [RecordLogMutation] {
        range.map { n in
            RecordLogMutation(model: "Note", id: String(format: "g%06d", n), kind: .create, fields: ["tags": n % 500 == 0 ? ["rare"] : ["x"]])
        }
    }

    private func statistics(_ world: MemberIndexStoreWorld) throws -> [String] {
        guard try !world.rows("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_stat1'").isEmpty else { return [] }
        return Array(Set(try world.rows("SELECT tbl FROM sqlite_stat1").compactMap { $0["tbl"].stringValue })).sorted()
    }

    private func mark(_ world: MemberIndexStoreWorld) throws -> Int? {
        try world.rows("SELECT value FROM record_log_meta WHERE key = 'statistics_rowid'").first?["value"].intValue
    }

    func testGathersNoneBelow1000RowsAtTheCommitReaching1000ThenNoneUntilTenTimesTheMark() async throws {
        let world = try await MemberIndexStoreWorld("db3-growth", label: "growth")
        worlds.append(world)
        let table = Db3LocalOnlyMemberIndexStoreHermeticTests.table("db3-growth")
        try world.store.syncIndexes([Db3LocalOnlyMemberIndexStoreHermeticTests.member])
        XCTAssertEqual(try world.rows("SELECT COUNT(*) AS n FROM \"\(table)\"").first?["n"].intValue, 0)
        XCTAssertEqual(try statistics(world), [])
        XCTAssertNil(try mark(world))

        try world.commit(notes(0..<999))
        XCTAssertEqual(try statistics(world), [])
        XCTAssertNil(try mark(world))
        try world.commit(notes(999..<1000))
        XCTAssertEqual(try statistics(world), [table, "record_log_view"].sorted())
        XCTAssertEqual(try mark(world), 1000)
        // The rare count the reader runs, planned through the statistics the store gathered by itself.
        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        XCTAssertEqual(try world.store.countView("Note", ["tags": ["$contains": "rare"]]), 2)
        let statement = try XCTUnwrap(reads(trace).last)
        XCTAssertTrue(statement.contains("\"\(table)\""), statement)
        let steps = try world.plan(statement)
        XCTAssertTrue(steps.contains("SEARCH record_log_view USING INTEGER PRIMARY KEY (rowid=?)"), steps)
        XCTAssertFalse(steps.contains("sqlite_autoindex_record_log_view_1"), steps)

        try world.commit(notes(1000..<9999))
        XCTAssertEqual(try mark(world), 1000)
        try world.commit(notes(9999..<10000))
        XCTAssertEqual(try mark(world), 10000)
    }

    func testARefusedGatheringLeavesTheCommitAndTheIndexIntact() async throws {
        let world = try await MemberIndexStoreWorld("db3-refused", label: "refused")
        worlds.append(world)
        let table = Db3LocalOnlyMemberIndexStoreHermeticTests.table("db3-refused")
        try world.store.syncIndexes([Db3LocalOnlyMemberIndexStoreHermeticTests.member])
        try world.commit(notes(0..<999))
        // The mark cannot be written: the gathering is refused and undone.
        try world.provider.withConnection { connection in
            try connection.executeScript("DROP TABLE record_log_meta")
            try connection.executeScript("CREATE VIEW record_log_meta AS SELECT 'storage_version' AS key, '\(RecordLogSchema.storageVersion)' AS value")
        }
        let reply = try world.store.commitEntries(writer: world.writer, writes: notes(999..<1000).map { RecordLogWrite(mutations: [$0]) })
        try world.store.flush()
        XCTAssertEqual(reply.cursor, 1000)
        XCTAssertEqual(try world.store.read(model: "Note", id: "g000999")?["tags"], ["x"])
        XCTAssertEqual(try world.rows("SELECT COUNT(*) AS n FROM \"\(table)\"").first?["n"].intValue, 1000)
        XCTAssertEqual(try statistics(world), [])
        XCTAssertEqual(try world.store.countView("Note", ["tags": ["$contains": "rare"]]), 2)
    }
}

/// #5156 behavior 14 — a local-only db3's member index through
/// `client.db3.indexes`, with no server: `register(members: true)` answers
/// the member index and `list` shows it, saves through the `Note` model keep
/// its table, `$contains` through the model answers the same rows before and
/// after, `drop` removes it, a declared string field is refused
/// `.db3IndexNotSetField`, and nothing is sent.
final class Db3LocalOnlyMemberIndexSurfaceHermeticTests: XCTestCase {

    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        await world.tearDown()
        try await super.tearDown()
    }

    private func rows(_ client: JsBaoClient, _ db3Id: String, _ sql: String, _ bindings: [Format2SqlValue] = []) throws -> [Format2SqlRow] {
        let binding = try XCTUnwrap(client.recordLogBinding(db3Id))
        return try binding.store.readView { try $0.rows(sql, bindings) }
    }

    private func family(_ client: JsBaoClient, _ db3Id: String) throws -> [String] {
        try rows(client, db3Id, #"SELECT name FROM sqlite_master WHERE name LIKE 'idx\_record\_log\_members\_%' ESCAPE '\' ORDER BY name"#)
            .compactMap { $0["name"].stringValue }
    }

    private func expectTableEqualsView(_ client: JsBaoClient, _ db3Id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let table = Db3LocalOnlyMemberIndexStoreHermeticTests.table(db3Id)
        let held = try rows(client, db3Id, "SELECT value, rid FROM \"\(table)\" ORDER BY 1, 2").map { "\($0["value"].stringValue ?? "")|\($0["rid"].intValue ?? 0)" }
        let truth = try rows(
            client, db3Id,
            """
            SELECT m.value AS value, v.rowid AS rid FROM record_log_view v, json_each(v._data, '$.tags') m
             WHERE v.doc_id = ? AND v._type = 'Note' AND json_type(v._data, '$.tags') = 'array' ORDER BY 1, 2
            """,
            [.text(db3Id)]
        ).map { "\($0["value"].stringValue ?? "")|\($0["rid"].intValue ?? 0)" }
        XCTAssertEqual(held, truth, file: file, line: line)
        XCTAssertFalse(held.isEmpty, file: file, line: line)
    }

    func testRegistersListsKeepsReadsFromAndDropsAMemberIndexSendingNothing() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 500, json: "{}")
        let info = try await world.createLocalOnly(client, transport: transport)
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let notes = try world.notes(client, info.id)
        for n in 0..<12 {
            let tags: Set<String> = n % 5 == 0 ? ["rare", "common"] : n % 2 == 0 ? ["common"] : ["x"]
            _ = try notes.save(id: "n\(n)", values: ["slug": .string("s\(n)"), "tags": .stringset(tags)])
        }
        let rare = { () throws -> [String] in
            try notes.query(["tags": ["$contains": "rare"]]).compactMap { $0["id"]?.stringValue }.sorted()
        }
        let before = try rare()
        XCTAssertEqual(before, ["n0", "n10", "n5"])

        let index = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", field: "tags", members: true))
        XCTAssertEqual(index.name, "idx_members_note_tags")
        XCTAssertTrue(index.members)
        XCTAssertFalse(index.unique)
        XCTAssertEqual(index.origins, [Db3IndexOrigin(kind: .named, unique: false)])
        let listed = try await db3.indexes.list(info.id)
        XCTAssertTrue(listed.contains(index))
        XCTAssertEqual(try family(client, info.id).first, Db3LocalOnlyMemberIndexStoreHermeticTests.table(info.id))
        try expectTableEqualsView(client, info.id)
        XCTAssertEqual(try rare(), before)

        // Saves after the registration are kept in the table.
        _ = try notes.save(id: "n99", values: ["slug": .string("s99"), "tags": .stringset(["rare"])])
        try notes.update(id: "n0", values: ["tags": .stringset(["x"])])
        try expectTableEqualsView(client, info.id)
        XCTAssertEqual(try rare(), ["n10", "n5", "n99"])

        let notSet = await db3LocalOnlyThrown {
            _ = try await db3.indexes.register(info.id, Db3IndexRegistration(model: "Note", field: "title", members: true))
        }
        XCTAssertEqual(notSet?.code, .db3IndexNotSetField)
        XCTAssertEqual(notSet?.details?["field"], .string("title"))
        XCTAssertEqual(notSet?.details?["db3Id"], .string(info.id))

        try await db3.indexes.drop(info.id, name: index.name)
        XCTAssertEqual(try family(client, info.id), [])
        let dropped = try await db3.indexes.list(info.id)
        XCTAssertFalse(dropped.contains { $0.members })
        XCTAssertEqual(try rare(), ["n10", "n5", "n99"])
        XCTAssertEqual(transport.calls.count, 0, "nothing is sent")
        XCTAssertEqual(world.remoteCreates, 0)
    }
}
