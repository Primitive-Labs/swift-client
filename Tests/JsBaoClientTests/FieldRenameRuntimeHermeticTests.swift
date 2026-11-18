import Foundation
import XCTest
@testable import JsBaoClient

/// #6023 behaviors 29, 30, 31, 43, 44, 45 and 46 — a Swift model whose
/// generated schema renames a field (`dueAt` stored as `due`), at the
/// runtime's edges.
///
/// - `CodegenAPI` translates the names app code writes (filter, sort,
///   projection, aggregate options, increment fields, unique lookups and
///   upsert targets) to stored names, and aggregate keys back.
/// - `client.db3.records(id)` (`DocumentRecords`) maps in and out for a model
///   the owning client registered, on a db3 whose held type is one the schema
///   was generated from; any other model, type or an untyped db3 keeps
///   stored names.
final class FieldRenameRuntimeHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private func provider(_ label: String) async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/db3-rename-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// The generated schema of a build declaring `current` stored as `due`, from type `type`.
    private static func schema(current: String = "dueAt", types: [String] = ["workspace"]) -> PrimitiveSchema {
        PrimitiveSchema(
            name: "tasks",
            fields: [
                "id": FieldDescriptor(type: .id, autoAssign: true),
                "title": FieldDescriptor(type: .string),
                "due": FieldDescriptor(type: .number, unique: true),
            ],
            constraints: ["deadline": ConstraintDescriptor(name: "deadline", fields: ["title"])],
            fieldNames: [current: "due"],
            fieldNameTypes: types
        )
    }

    private static let live: [String: [String: String]] = ["tasks": ["title": "string", "due": "number"]]

    private func binding(_ label: String, type: String? = "workspace", register: PrimitiveSchema? = schema()) async throws -> (RecordLogDocumentBinding, DocumentRecords) {
        let provider = try await provider(label)
        let documentId = "rl-rename-\(UUID().uuidString.prefix(8))"
        let binding = try RecordLogDocumentBinding(host: provider, documentId: documentId, clientId: "client-1", logger: Logger(level: .none))
        if let type { try binding.setState(type: .typed(name: type, hash: "h1", models: Self.live)) }
        if let register { try binding.registerModel(register) }
        return (binding, DocumentRecords(documentId: documentId) { binding })
    }

    // MARK: - Behavior 29

    func testCodegenAPITranslatesWhatAppCodeWritesAndAggregateKeysBack() {
        let schema = Self.schema()
        let filter = CodegenAPI.storedFilter(schema, ["dueAt": .number(1), "$or": .array([.object(["due": .number(2)]), .object(["title": .string("x")])])])
        XCTAssertEqual(filter?["due"], .number(1))
        XCTAssertNil(filter?["dueAt"])
        XCTAssertEqual(filter?["$or"], .array([.object(["due": .number(2)]), .object(["title": .string("x")])]))
        var options = QueryOptions()
        options.sort = ["dueAt": -1]
        options.projection = ["dueAt": 1, "title": 1]
        let stored = CodegenAPI.storedOptions(schema, options)
        XCTAssertEqual(stored?.sort, ["due": -1])
        XCTAssertEqual(stored?.projection, ["due": 1, "title": 1])
        let aggregate = CodegenAPI.storedAggregate(schema, AggregateOptions(
            groupBy: [.field("dueAt"), .datePeriod(field: "dueAt", period: .month)],
            operations: [AggregateOperation(type: .sum, field: "dueAt"), AggregateOperation(type: .count)],
            filter: ["dueAt": .number(3)],
            sort: AggregateSort(field: "sum_dueAt", direction: -1)
        ))
        XCTAssertEqual(aggregate.groupBy, [.field("due"), .datePeriod(field: "due", period: .month)])
        XCTAssertEqual(aggregate.operations.map(\.field), ["due", nil])
        XCTAssertEqual(aggregate.filter, ["due": .number(3)])
        XCTAssertEqual(aggregate.sort?.field, "sum_due")
        let keys = CodegenAPI.currentAggregateKeys(schema.fieldNames, sent: aggregate)
        XCTAssertEqual(keys.group, ["due": "dueAt", "due_month": "dueAt_month"])
        XCTAssertEqual(keys.row, ["sum_due": "sum_dueAt"])
        XCTAssertEqual(PrimitiveFieldNames.storedKeys(["dueAt": 1.0], in: schema.fieldNames), ["due": 1.0])
        // A unique lookup by the field's current or stored name is the field's own constraint.
        XCTAssertEqual(CodegenAPI.constraintName(schema, "dueAt"), "tasks_due_unique")
        XCTAssertEqual(CodegenAPI.constraintName(schema, "due"), "tasks_due_unique")
        XCTAssertEqual(CodegenAPI.constraintName(schema, "tasks_due_unique"), "tasks_due_unique")
    }

    /// Second opinion R005: two spellings of one field keep both predicates, under `$and`.
    func testAFilterNamingOneFieldByBothNamesKeepsBothPredicates() {
        let schema = Self.schema()
        let filter = CodegenAPI.storedFilter(schema, [
            "dueAt": .object(["$gte": .number(3)]),
            "due": .object(["$lt": .number(5)]),
            "title": .string("x"),
            "$and": .array([.object(["dueAt": .number(4)])]),
        ])
        XCTAssertNil(filter?["due"])
        XCTAssertNil(filter?["dueAt"])
        XCTAssertEqual(filter?["title"], .string("x"))
        guard case .array(let and)? = filter?["$and"] else { return XCTFail("no $and: \(String(describing: filter))") }
        XCTAssertEqual(and.count, 3)
        XCTAssertTrue(and.contains(.object(["due": .number(4)])))
        XCTAssertTrue(and.contains(.object(["due": .object(["$gte": .number(3)])])))
        XCTAssertTrue(and.contains(.object(["due": .object(["$lt": .number(5)])])))
    }

    /// Second opinion R006: only the keys the request's own shapes make over a
    /// renamed field are renamed; a field spelled like such a key is not.
    func testAggregateKeysFollowTheRequestsShapes() {
        let schema = Self.schema(current: "deadline")
        let sent = CodegenAPI.storedAggregate(schema, AggregateOptions(
            groupBy: [.field("sum_due"), .field("deadline"), .datePeriod(field: "deadline", period: .month), .stringSetMembership(field: "title", contains: "x")],
            operations: [AggregateOperation(type: .sum, field: "deadline"), AggregateOperation(type: .max, field: "deadline", outputField: "latest"), AggregateOperation(type: .count)],
            sort: AggregateSort(field: "deadline_month", direction: 1)
        ))
        XCTAssertEqual(sent.sort?.field, "due_month")
        let keys = CodegenAPI.currentAggregateKeys(schema.fieldNames, sent: sent)
        XCTAssertEqual(keys.group, ["due": "deadline", "due_month": "deadline_month"])
        XCTAssertEqual(keys.row, ["sum_due": "sum_deadline"])
    }

    /// Second opinion R001: a write's condition travels in stored names.
    func testAWritesConditionIsTranslatedToStoredNames() {
        let schema = Self.schema()
        let options = CodegenAPI.storedWriteOptions(schema, Db3WriteOptions(condition: ["dueAt": .object(["$exists": .bool(false)])], confirm: true))
        XCTAssertEqual(options.condition, ["due": .object(["$exists": .bool(false)])])
        XCTAssertTrue(options.confirm)
        let plain = PrimitiveSchema(name: "tasks", fields: ["id": FieldDescriptor(type: .id), "due": FieldDescriptor(type: .number)])
        XCTAssertEqual(CodegenAPI.storedWriteOptions(plain, Db3WriteOptions(condition: ["dueAt": .number(1)])).condition, ["dueAt": .number(1)])
    }

    // MARK: - Behavior 46

    func testAnUpsertTargetResolvesAConstraintNameBeforeARenamedField() {
        let schema = Self.schema(current: "deadline")
        let constraints = schema.resolvedUniqueConstraints.map(\.name)
        XCTAssertEqual(PrimitiveFieldNames.upsertTarget("deadline", constraintNames: constraints, in: schema.fieldNames), "deadline")
        let plain = Self.schema(current: "deadline")
        var noConstraint = plain
        noConstraint.constraints = [:]
        XCTAssertEqual(
            PrimitiveFieldNames.upsertTarget("deadline", constraintNames: noConstraint.resolvedUniqueConstraints.map(\.name), in: noConstraint.fieldNames),
            "due"
        )
        XCTAssertEqual(CodegenAPI.constraintName(schema, "deadline"), "deadline")
    }

    // MARK: - Behavior 30

    func testRecordsTakeAndAnswerTheCurrentNameWhileTheRowHoldsTheStoredOne() async throws {
        let (binding, records) = try await binding("records")
        let put = try records.put("tasks", ["id": "r1", "title": "a", "dueAt": 5])
        XCTAssertEqual(put["dueAt"], 5)
        XCTAssertNil(put["due"])
        XCTAssertEqual(try binding.store.read(model: "tasks", id: "r1")?["due"], .number(5))
        XCTAssertNil(try binding.store.read(model: "tasks", id: "r1")?["dueAt"])
        _ = try records.patch("tasks", id: "r1", ["due": 6])
        XCTAssertEqual(try records.get("tasks", id: "r1")?["dueAt"], 6)
        _ = try records.put("tasks", ["id": "r2", "title": "b", "dueAt": 2])
        var options = QueryOptions()
        options.sort = ["dueAt": 1]
        let page = try records.query("tasks", ["dueAt": .object(["$gte": .number(1)])], options: options)
        XCTAssertEqual(page.data.map { $0["dueAt"] }, [2, 6])
        XCTAssertEqual(try records.count("tasks", ["dueAt": 6]), 1)
        XCTAssertThrowsError(try records.put("tasks", ["id": "r3", "dueAt": 1, "due": 2])) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
        }
    }

    func testAStrayKeyEqualToTheCurrentNameLosesToTheStoredField() async throws {
        let (binding, records) = try await binding("stray")
        // A row holding both the stored field and a stray undeclared `dueAt` (written raw).
        _ = try records.put("tasks", ["id": "s1", "title": "s", "dueAt": 4])
        _ = try binding.withOperation {
            let mutations = planRecordLogRecordWrites(RecordLogRecordWriteInput(
                model: "tasks", id: "s1", kind: .patch, existing: try binding.store.read(model: "tasks", id: "s1"), data: ["dueAt": "stray"]
            ))
            return try binding.commit([RecordLogWrite(mutations: mutations)])
        }
        XCTAssertEqual(try binding.store.read(model: "tasks", id: "s1")?["dueAt"], .string("stray"))
        XCTAssertEqual(try records.get("tasks", id: "s1")?["dueAt"], 4)
    }

    // MARK: - Behaviors 31, 44 (pins and the type rule)

    func testAModelNotRegisteredAnotherTypeAndAnUntypedDb3KeepStoredNames() async throws {
        let unregistered = try await binding("unregistered", register: nil)
        _ = try unregistered.1.put("tasks", ["id": "u1", "title": "u", "due": 1])
        XCTAssertEqual(try unregistered.1.get("tasks", id: "u1")?["due"], 1)
        XCTAssertNil(try unregistered.1.get("tasks", id: "u1")?["dueAt"])

        let otherType = try await binding("other-type", type: "elsewhere")
        _ = try otherType.1.put("tasks", ["id": "o1", "title": "o", "due": 2])
        XCTAssertEqual(try otherType.1.get("tasks", id: "o1")?["due"], 2)

        let untyped = try await binding("untyped", type: nil)
        _ = try untyped.1.put("tasks", ["id": "n1", "title": "n", "dueAt": 3])
        XCTAssertEqual(try untyped.0.store.read(model: "tasks", id: "n1")?["dueAt"], .number(3))
        XCTAssertNil(try untyped.0.store.read(model: "tasks", id: "n1")?["due"])
    }

    // MARK: - Behavior 43

    func testTwoClientsMapByTheirOwnRegistrations() async throws {
        let a = try await binding("client-a", register: Self.schema(current: "dueAt"))
        let b = try await binding("client-b", register: Self.schema(current: "deadline"))
        let c = try await binding("client-c", register: PrimitiveSchema(name: "tasks", fields: [
            "id": FieldDescriptor(type: .id, autoAssign: true), "title": FieldDescriptor(type: .string), "due": FieldDescriptor(type: .number),
        ]))
        _ = try a.1.put("tasks", ["id": "x", "title": "x", "dueAt": 1])
        _ = try b.1.put("tasks", ["id": "x", "title": "x", "deadline": 1])
        _ = try c.1.put("tasks", ["id": "x", "title": "x", "due": 1])
        XCTAssertEqual(try a.1.get("tasks", id: "x")?["dueAt"], 1)
        XCTAssertEqual(try b.1.get("tasks", id: "x")?["deadline"], 1)
        XCTAssertEqual(try c.1.get("tasks", id: "x")?["due"], 1)
        for (binding, _) in [a, b, c] {
            XCTAssertEqual(try binding.store.read(model: "tasks", id: "x")?["due"], .number(1))
        }
    }

    // MARK: - Behavior 45 (pin)

    func testAFormerNameTheBuildNeverDeclaredIsAnUndeclaredNameOnTheDevice() async throws {
        let (binding, records) = try await binding("former", register: Self.schema(current: "deadline"))
        _ = try records.put("tasks", ["id": "f1", "title": "f", "deadline": 1])
        XCTAssertEqual(try records.count("tasks", ["deadline": 1]), 1)
        XCTAssertEqual(try records.count("tasks", ["due": 1]), 1)
        XCTAssertEqual(try records.count("tasks", ["dueAt": 1]), 0)
        XCTAssertEqual(try binding.store.read(model: "tasks", id: "f1")?["due"], .number(1))
    }
}

/// #6023 behavior 29, include specs — an include written with current names
/// reaches the store in stored names, each field by the model it belongs to,
/// nested includes too.
final class FieldRenameIncludeHermeticTests: XCTestCase {
    func testAnIncludeSpecMapsByTheModelEachFieldBelongsTo() {
        let tasks = PrimitiveSchema(
            name: "tasks",
            fields: ["id": FieldDescriptor(type: .id, autoAssign: true), "due": FieldDescriptor(type: .number), "project": FieldDescriptor(type: .string)],
            fieldNames: ["dueAt": "due", "projectId": "project"],
            fieldNameTypes: ["workspace"]
        )
        let projects = PrimitiveSchema(name: "projects", fields: ["id": FieldDescriptor(type: .id, autoAssign: true)])
        let taskModel = MultiDocModel(schema: tasks)
        let nested = Include(type: .hasMany, target: taskModel, foreignKey: "projectId", filter: ["dueAt": .number(1)], sort: ["dueAt": -1], projection: ["dueAt": 1])
        let spec = Include(type: .hasMany, target: taskModel, foreignKey: "projectId", filter: ["dueAt": .number(2)], sort: ["dueAt": 1], include: [nested])
        let stored = CodegenAPI.storedIncludes(projects, [spec])
        XCTAssertEqual(stored[0].foreignKey, "project")
        XCTAssertEqual(stored[0].filter, ["due": .number(2)])
        XCTAssertEqual(stored[0].sort, ["due": 1])
        XCTAssertEqual(stored[0].include?[0].foreignKey, "project")
        XCTAssertEqual(stored[0].include?[0].filter, ["due": .number(1)])
        XCTAssertEqual(stored[0].include?[0].projection, ["due": 1])
        let back = CodegenAPI.storedIncludes(tasks, [Include(type: .refersTo, target: MultiDocModel(schema: projects), sourceField: "projectId")])
        XCTAssertEqual(back[0].sourceField, "project")
    }
}

/// Second opinion R001, R003, R007 and R008 — a renamed model's writes and
/// traversals through `client.codegen` on a db3 this client holds.
final class FieldRenameCodegenWritesHermeticTests: XCTestCase {
    private static let db3Id = "01JD6023C0DEGENWR1TESXXXXX"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    /// `deadline` stored as `due`, and a unique constraint named `deadline` over `title`.
    private static let tasks = PrimitiveSchema(
        name: "tasks",
        fields: [
            "id": FieldDescriptor(type: .id, autoAssign: true),
            "title": FieldDescriptor(type: .string),
            "due": FieldDescriptor(type: .number, unique: true),
        ],
        constraints: ["deadline": ConstraintDescriptor(name: "deadline", fields: ["title"])],
        fieldNames: ["deadline": "due"],
        fieldNameTypes: ["workspace"]
    )
    private static let tags = PrimitiveSchema(name: "tags", fields: ["id": FieldDescriptor(type: .id, autoAssign: true), "label": FieldDescriptor(type: .string)])
    /// A join model whose related-id field `tagRef` is stored as `tag`.
    private static let taskTags = PrimitiveSchema(
        name: "taskTags",
        fields: ["id": FieldDescriptor(type: .id, autoAssign: true), "task": FieldDescriptor(type: .string), "tag": FieldDescriptor(type: .string)],
        fieldNames: ["tagRef": "tag"],
        fieldNameTypes: ["workspace"]
    )

    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/db3-rename-writes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-rename-writes-6023",
            token: makeTestJwt(userId: "user-a"), logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([Self.tasks, Self.tags, Self.taskTags])
        try await client.bindStoredDb3(Self.db3Id)
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        binding.createdLocally = true
        try binding.setState(type: .typed(name: "workspace", hash: "h1", models: [
            "tasks": ["title": "string", "due": "number"],
            "tags": ["label": "string"],
            "taskTags": ["task": "string", "tag": "string"],
        ]))
        return client
    }

    /// R003: `upsert(on:)` with a constraint's name upserts on the constraint, not on the renamed field.
    func testUpsertOnAConstraintNamedLikeARenamedFieldUpsertsOnTheConstraint() async throws {
        let client = try await client()
        _ = try client.codegen.save(Self.tasks, id: "t1", values: ["title": .string("same"), "due": .number(1)], in: Self.db3Id)
        let result = try client.codegen.upsert(
            Self.tasks, id: "t2", values: ["title": .string("same"), "due": .number(2)], on: "deadline", in: Self.db3Id
        )
        XCTAssertEqual(result.record.id, "t1")
        XCTAssertEqual(try client.codegen.count(Self.tasks), 1)
        XCTAssertEqual(client.codegen.find(Self.tasks, id: "t1")?["due"], .number(2))
    }

    /// R008: an increment answers under the current name, whichever name the caller wrote.
    func testAnIncrementAnswersUnderTheCurrentName() async throws {
        let client = try await client()
        _ = try client.codegen.save(Self.tasks, id: "t1", values: ["title": .string("a"), "due": .number(1)], in: Self.db3Id)
        let byStored = try await client.codegen.increment(Self.tasks, id: "t1", fields: ["due": 2], in: Self.db3Id)
        XCTAssertEqual(byStored, ["deadline": 3])
        let byCurrent = try await client.codegen.increment(Self.tasks, id: "t1", fields: ["deadline": 1], in: Self.db3Id)
        XCTAssertEqual(byCurrent, ["deadline": 4])
    }

    /// R007: `hasManyThrough` reads a renamed join field under its stored name.
    func testHasManyThroughReadsARenamedJoinFieldUnderItsStoredName() async throws {
        let client = try await client()
        _ = try client.codegen.save(Self.tasks, id: "t1", values: ["title": .string("a"), "due": .number(1)], in: Self.db3Id)
        _ = try client.codegen.save(Self.tags, id: "g1", values: ["label": .string("red")], in: Self.db3Id)
        _ = try client.codegen.save(Self.tags, id: "g2", values: ["label": .string("blue")], in: Self.db3Id)
        _ = try client.codegen.save(Self.taskTags, id: "j1", values: ["task": .string("t1"), "tag": .string("g1")], in: Self.db3Id)
        _ = try client.codegen.save(Self.taskTags, id: "j2", values: ["task": .string("t1"), "tag": .string("g2")], in: Self.db3Id)
        let related = try client.codegen.hasManyThrough(
            target: Self.tags, joinModel: Self.taskTags, sourceId: "t1",
            joinModelLocalField: "task", joinModelRelatedField: "tagRef"
        )
        XCTAssertEqual(related.compactMap { $0["id"]?.stringValue }.sorted(), ["g1", "g2"])
        let page = try client.codegen.hasManyThrough(
            target: Self.tags, joinModel: Self.taskTags, sourceId: "t1",
            joinModelLocalField: "task", joinModelRelatedField: "tagRef", limit: 10
        )
        XCTAssertEqual(page.data.compactMap { $0["id"]?.stringValue }.sorted(), ["g1", "g2"])
    }
}
