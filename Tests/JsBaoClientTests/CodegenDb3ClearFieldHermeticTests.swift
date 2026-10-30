import XCTest
@testable import JsBaoClient

/// #5021 behaviors 19, 20 and 21 and edge cases E7 and E9 — a generated
/// Swift model clears a field on a db3 by setting it to `nil`, with no
/// server.
///
/// The generated `primitiveValues()` leaves a nil field out, and its
/// `_changedFields` still names it: a save on a db3 reads that as a clear and
/// writes the field `null`, as the web's `undefined` does. A cleared field
/// leaves the state the save validates, so a cleared required field is
/// refused and a unique constraint over it is not enforced. A format-1
/// document saves as before.
final class CodegenDb3ClearFieldHermeticTests: XCTestCase {

    private static let db3Id = "01JD5021C1EARF1E1DXXXXXXXX"
    private static let date = "2026-10-29T00:00:00.000Z"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    /// A client over its own SQLite store with no server, the generated models
    /// registered and configured as the default client.
    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/codegen-db3-clear-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "codegen-db3-clear-5021",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([TaskRecord.self, CrashTestRecord.self])
        client.registerModels([Self.stamped])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        JsBaoClient.configureDefault(client)
        return client
    }

    /// A client holding the db3 `db3Id`, adopted from its create answer, so it is resident at once.
    private func db3Client() async throws -> JsBaoClient {
        let client = try await client()
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Tasks", "createdBy": "user-a", "createdAt": "2026-10-29T00:00:00.000Z",
         "modifiedAt": "2026-10-29T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": null, "tags": []}
        """
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 201, json: answer), client: client)
            .create(title: "Tasks", custodian: "user:user-a")
        XCTAssertTrue(try XCTUnwrap(client.recordLogBinding(Self.db3Id)).isResident)
        return client
    }

    /// This client's entries the room has not judged, oldest first.
    private func entries(_ client: JsBaoClient) throws -> [RecordLogPendingEntry] {
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        return try binding.store.pendingOf(binding.writer)
    }

    /// Every mutation of an entry: `m` and `also`.
    private func mutations(_ entry: RecordLogPendingEntry?) -> [RecordLogMutation] {
        guard let entry else { return [] }
        return [entry.m] + (entry.also ?? [])
    }

    private func task(_ id: String) throws -> TaskRecord? {
        try TaskRecord.query(options: QueryOptions(db3: [Self.db3Id])).first { $0.id == id }
    }

    // MARK: - Behavior 19

    func testAClearOnlySaveWritesOneEntryWithTheFieldNull() async throws {
        let client = try await db3Client()
        var record = try TaskRecord(id: "t1", title: "Close me", priority: 2, tags: ["a"], createdAt: Self.date).save(in: Self.db3Id)
        XCTAssertEqual(try task("t1")?.createdAt, Self.date)
        let before = try entries(client).count
        let pendingBefore = try await client.db3.state(Self.db3Id).pendingWrites

        record.createdAt = nil
        let saved = try record.save(in: Self.db3Id)
        XCTAssertNil(saved.createdAt)

        let after = try entries(client)
        XCTAssertEqual(after.count, before + 1, "the clear-only save wrote one entry")
        let pendingAfter = try await client.db3.state(Self.db3Id).pendingWrites
        XCTAssertEqual(pendingAfter, pendingBefore + 1)
        let cleared = try XCTUnwrap(after.last?.m)
        XCTAssertEqual(cleared.id, "t1")
        XCTAssertEqual(cleared.fields, ["createdAt": .null])

        let read = try XCTUnwrap(try task("t1"))
        XCTAssertNil(read.createdAt)
        XCTAssertEqual(read.title, "Close me")
        XCTAssertEqual(read.priority, 2)
        XCTAssertEqual(read.tags, ["a"])
        XCTAssertNil(try TaskRecord.find("t1")?.createdAt)
    }

    func testAClearThroughAGuardedSaveCarriesTheNullAndTheCondition() async throws {
        let client = try await db3Client()
        var record = try TaskRecord(id: "t2", title: "Guarded", createdAt: Self.date).save(in: Self.db3Id)
        let before = try entries(client).count
        record.createdAt = nil
        _ = try await record.save(in: Self.db3Id, options: Db3WriteOptions(condition: ["title": "Guarded"]))
        let after = try entries(client)
        XCTAssertEqual(after.count, before + 1)
        let cleared = try XCTUnwrap(after.last?.m)
        XCTAssertEqual(cleared.fields?["createdAt"], .null)
        XCTAssertEqual(cleared.condition, ["title": "Guarded"])
    }

    /// E7: a clear inside `transact` folds into the transaction's one entry.
    func testAClearInsideATransactionFoldsIntoItsEntry() async throws {
        let client = try await db3Client()
        var first = try TaskRecord(id: "x1", title: "One", createdAt: Self.date).save(in: Self.db3Id)
        let second = try TaskRecord(id: "x2", title: "Two").save(in: Self.db3Id)
        let before = try entries(client).count
        let member = try XCTUnwrap(client.sharedModel("tasks")?.member(docId: Self.db3Id))
        try member.transact {
            first.createdAt = nil
            first = try first.save(in: Self.db3Id)
            var other = second
            other.priority = 9
            _ = try other.save(in: Self.db3Id)
        }
        let after = try entries(client)
        XCTAssertEqual(after.count, before + 1, "one entry for the transaction")
        let byId = Dictionary(uniqueKeysWithValues: mutations(after.last).map { ($0.id, $0) })
        XCTAssertEqual(byId["x1"]?.fields?["createdAt"], .null)
        XCTAssertEqual(byId["x2"]?.fields?["priority"], .number(9))
        XCTAssertNil(try task("x1")?.createdAt)
    }

    /// E9: a clear and a value in one save are one entry; a field cleared then set again writes the value.
    func testAClearAndAValueInOneSaveAndASetAgainWritesTheValue() async throws {
        let client = try await db3Client()
        var record = try TaskRecord(id: "t3", title: "Both", priority: 1, createdAt: Self.date).save(in: Self.db3Id)
        var before = try entries(client).count
        record.createdAt = nil
        record.priority = 4
        record = try record.save(in: Self.db3Id)
        var after = try entries(client)
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.last?.m.fields, ["createdAt": .null, "priority": .number(4)])

        before = after.count
        record.priority = nil
        record.priority = 6
        _ = try record.save(in: Self.db3Id)
        after = try entries(client)
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.last?.m.fields, ["priority": .number(6)])
        XCTAssertEqual(try task("t3")?.priority, 6)
    }

    // MARK: - Behavior 20

    func testAClearedRequiredFieldIsRefusedAndWritesNothing() async throws {
        let client = try await db3Client()
        _ = try TaskRecord(id: "t4", title: "Needed").save(in: Self.db3Id)
        let before = try entries(client).count
        XCTAssertThrowsError(
            try client.codegen.save(TaskRecord.primitiveSchema, id: "t4", values: [:], in: Self.db3Id, changedFields: ["title"])
        ) { error in
            guard case FieldValidationError.requiredFieldMissing(let field, _)? = error as? FieldValidationError else {
                return XCTFail("expected requiredFieldMissing, got \(error)")
            }
            XCTAssertEqual(field, "title")
        }
        XCTAssertEqual(try entries(client).count, before)
        XCTAssertEqual(try task("t4")?.title, "Needed")
    }

    func testAClearedStringSetRemovesEveryMember() async throws {
        let client = try await db3Client()
        var record = try TaskRecord(id: "t5", title: "Tagged", tags: ["a", "b"]).save(in: Self.db3Id)
        let before = try entries(client).count
        record.tags = nil
        _ = try record.save(in: Self.db3Id)
        let after = try entries(client)
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.last?.m.stringSetDeltas?["tags"], ["a": false, "b": false])
        let tags = try task("t5")?.tags
        XCTAssertTrue(tags == nil || tags == [], "no members left: \(String(describing: tags))")
    }

    func testClearingAFieldTheRecordDoesNotHoldWritesNothing() async throws {
        let client = try await db3Client()
        var record = try TaskRecord(id: "t6", title: "Bare").save(in: Self.db3Id)
        let before = try entries(client).count
        record.createdAt = nil
        _ = try record.save(in: Self.db3Id)
        XCTAssertEqual(try entries(client).count, before)
    }

    func testAUniqueConstraintOverAClearedFieldIsNotHeld() async throws {
        let client = try await db3Client()
        var holder = try CrashTestRecord(id: "c1", requiredTags: ["r"], email: "a@x.test").save(in: Self.db3Id)
        let before = try entries(client).count
        holder.email = nil
        _ = try holder.save(in: Self.db3Id)
        XCTAssertEqual(try entries(client).count, before + 1, "the clear is written, not refused")
        // The cleared value no longer holds the constraint: another record takes it.
        _ = try CrashTestRecord(id: "c2", requiredTags: ["r"], email: "a@x.test").save(in: Self.db3Id)
        let rows = try CrashTestRecord.query(options: QueryOptions(db3: [Self.db3Id]))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.email) }), ["c1": nil, "c2": "a@x.test"])
    }

    // MARK: - 5021-C003: a stamped field is written, never cleared

    /// A model whose `updatedAt` is stamped on every write.
    private static let stamped = PrimitiveSchema(
        name: "stampedNotes",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "updatedAt": FieldDescriptor(type: .number, autoStamp: .update),
        ]
    )

    /// Setting an `update`-stamped field to nil stamps it, even when the stamp
    /// equals the stored value (two saves in one millisecond, which back to
    /// back saves reach often): the save keeps the stamp and never writes null.
    func testClearingAnUpdateStampedFieldKeepsTheStamp() async throws {
        let client = try await db3Client()
        _ = try client.codegen.save(Self.stamped, id: "s1", values: ["title": .string("Stamped")], in: Self.db3Id)
        let before = try entries(client).count
        for round in 0..<500 {
            let saved = try client.codegen.save(Self.stamped, id: "s1", values: [:], in: Self.db3Id, changedFields: ["updatedAt"])
            XCTAssertNotNil(saved["updatedAt"]?.asNumber, "round \(round): the stamp stays")
            if saved["updatedAt"]?.asNumber == nil { break }
        }
        for entry in try entries(client).dropFirst(before) {
            for mutation in mutations(entry) where mutation.id == "s1" {
                XCTAssertNotEqual(mutation.fields?["updatedAt"], .null, "no entry writes the stamped field null")
            }
        }
    }

    // MARK: - Behavior 21 (pin): a format-1 document saves as before

    func testOnAFormat1DocumentAClearSavesAsBefore() async throws {
        let client = try await client()
        let created = try await client.createDocument(options: CreateDocumentOptions(title: "plain"))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        var record = try TaskRecord(id: "f1", title: "Legacy", createdAt: Self.date).save(in: documentId)
        record.createdAt = nil
        _ = try record.save(in: documentId)
        XCTAssertEqual(try TaskRecord.find("f1")?.createdAt, Self.date)
    }
}
