import Foundation
import XCTest
@testable import swift_bao_codegen

/// #6270 — the typed reads a generated model gets, held by the compiler.
///
/// A generated model carries one token per field on `fields` and conforms to
/// `TypedQueryModel`, which gives it `query(where:)`, `queryPaged(where:)`,
/// `queryOne(where:)`, `count(where:)` and `aggregate(groupBy:operations:)`.
/// The tests render a type file's models in process and run
/// `swiftc -typecheck` over them and a usage file, against the `JsBaoClient`
/// module this test run built (the vehicle of `SharedEnumOlderCLIHermeticTests`):
///
/// - an accepted usage file compiles with no diagnostic at all;
/// - in a refused usage file every line marked `// REFUSE` carries an error,
///   and no other line does, so each refusal is the one change on its line;
/// - a usage file of the `DocumentFilter` calls compiles unchanged;
/// - models written before this change compile against the library.
final class TypedQueryCompileHermeticTests: XCTestCase {

    private static let packageRoot: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }()

    private static let common = """
        [defs.Status6270]
        type = "string"
        enum = ["open", "done"]
        """

    /// One model of every field kind, a keyword-named field, a renamed field
    /// and a declared stamp field; one model the type's timestamps cover that
    /// declares no stamp; one model with no fields.
    private static let ledger = """
        [type]
        name = "ledger6270"
        timestamps = { create = "createdAt", update = "updatedAt", models = ["entries6270", "accounts6270"] }

        [models.entries6270]
        class_name = "Entry6270"

        [models.entries6270.fields.accountId]
        type = "string"

        [models.entries6270.fields.amount]
        type = "number"

        [models.entries6270.fields.cleared]
        type = "boolean"

        [models.entries6270.fields.bookedOn]
        type = "date"

        [models.entries6270.fields.tags]
        type = "stringset"

        [models.entries6270.fields.memo]
        type = "string"

        [models.entries6270.fields.embedding]
        type = "vector"
        dims = 3
        element = "f32"

        [models.entries6270.fields.status]
        ref = "Status6270"

        [models.entries6270.fields.default]
        type = "number"

        [models.entries6270.fields.dueAt]
        type = "number"
        storedAs = "due"

        [models.entries6270.fields.createdAt]
        type = "number"

        [models.accounts6270]
        class_name = "Account6270"

        [models.accounts6270.fields.name]
        type = "string"

        [models.empties6270]
        class_name = "Empty6270"
        """

    /// What `primitive functions codegen --lang swift` declares for the shared enum.
    private static let sharedEnumSource = """
        public enum Status6270: String, Codable, CaseIterable, Sendable {
            case open = "open"
            case done = "done"
        }
        """

    // MARK: - Emitted tokens

    func testEachModelCarriesOneTokenPerFieldAndConformsToTypedQueryModel() throws {
        let files = try renderLedger()
        let entry = try XCTUnwrap(files["Entry6270.swift"])
        XCTAssertTrue(entry.contains("public struct Entry6270: PrimitiveModel, PrimitiveRowDecodable, Equatable, Hashable, Codable, TypedQueryModel {"), entry)
        let tokens = [
            #"        public let id: Entry6270._IdFieldToken = .init("id")"#,
            #"        public let accountId: Entry6270._StringFieldToken = .init("accountId")"#,
            #"        public let amount: Entry6270._NumberFieldToken = .init("amount")"#,
            #"        public let cleared: Entry6270._BooleanFieldToken = .init("cleared")"#,
            #"        public let bookedOn: Entry6270._DateFieldToken = .init("bookedOn")"#,
            #"        public let tags: Entry6270._StringSetFieldToken = .init("tags")"#,
            #"        public let memo: Entry6270._StringFieldToken = .init("memo")"#,
            #"        public let status: Entry6270._EnumFieldToken<Status6270> = .init("status")"#,
            #"        public let `default`: Entry6270._NumberFieldToken = .init("default")"#,
            #"        public let dueAt: Entry6270._NumberFieldToken = .init("dueAt")"#,
            #"        public let createdAt: Entry6270._NumberFieldToken = .init("createdAt")"#,
        ]
        let block = "    public struct Fields: Sendable {\n" + tokens.joined(separator: "\n") + "\n    }\n"
        XCTAssertTrue(entry.contains(block), entry)
        XCTAssertTrue(entry.contains("\n    public static let fields = Fields()\n"), entry)
        XCTAssertFalse(entry.contains("let embedding: Model"), "a vector field has no token")

        let account = try XCTUnwrap(files["Account6270.swift"])
        XCTAssertTrue(account.contains("    public struct Fields: Sendable {\n"
            + #"        public let id: Account6270._IdFieldToken = .init("id")"# + "\n"
            + #"        public let name: Account6270._StringFieldToken = .init("name")"# + "\n    }\n"), account)
        XCTAssertFalse(account.contains("createdAt"), "a stamp the model does not declare has no token")

        let empty = try XCTUnwrap(files["Empty6270.swift"])
        XCTAssertTrue(empty.contains("    public struct Fields: Sendable {\n"
            + #"        public let id: Empty6270._IdFieldToken = .init("id")"# + "\n    }\n"), empty)
    }

    // MARK: - Typed reads

    func testTheTypedReadsCompile() throws {
        let result = try typecheck(ledger: Self.accepted)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(result.output.contains("warning:"), result.output)
    }

    func testAnUndeclaredFieldAWrongOperandOrAMissingOperatorFailsToCompile() throws {
        let result = try typecheck(ledger: Self.refused)
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertEqual(errorLines(result.output, file: "usage.swift"), refuseLines(Self.refused), result.output)
    }

    func testAJSONFieldTakesExistsOnlyAndNoSort() throws {
        let json = Self.packageRoot.appending(path: "Tests/JsBaoClientTests/Schema/CodegenJson")
        let inputs = try CodegenInputs.read(try CodegenInputs.expand([json.appending(path: "db3-types").path]))
        let rendered = try CodegenRun.render(
            documents: inputs.map { (sourceName: $0.sourceName, source: $0.source) },
            sharedEnums: CodegenInputs.sharedEnumFiles(for: inputs),
            emptyLabel: "", accessLevel: "public", moduleImport: "JsBaoClient", swiftNameSuffix: "Record", strict: true
        )
        let shared = json.appending(path: "Generated/JsonShared.generated.swift")
        let accepted = try typecheck(rendered, extra: [shared], usage: Self.jsonAccepted)
        XCTAssertEqual(accepted.status, 0, accepted.output)
        let refused = try typecheck(rendered, extra: [shared], usage: Self.jsonRefused)
        XCTAssertNotEqual(refused.status, 0, refused.output)
        XCTAssertEqual(errorLines(refused.output, file: "usage.swift"), refuseLines(Self.jsonRefused), refused.output)
    }

    /// A model whose type is named `Fields`, with fields named like the
    /// token types and like the fallback struct name, and a model whose
    /// relationship names it: each model's tokens are its own, and the
    /// typed reads compile.
    func testFieldAndModelNamesLikeTheGeneratedTypesCompile() throws {
        let files = try CodegenRun.render(
            documents: [(sourceName: "names.toml", source: Self.names)],
            sharedEnums: [],
            emptyLabel: "", accessLevel: "public", moduleImport: "JsBaoClient", swiftNameSuffix: "Record", strict: true
        )
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
        XCTAssertTrue(try XCTUnwrap(byName["Fields.swift"]).contains("    public struct FieldTokens2: Sendable {\n"))
        XCTAssertTrue(try XCTUnwrap(byName["Chore6270.swift"]).contains("    public struct FieldTokens: Sendable {\n"))
        let result = try typecheck(files, extra: [], usage: Self.namesUsage)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(result.output.contains("warning:"), result.output)
    }

    /// Models of the run named like each token type, beside a model with a
    /// field of each kind: the models compile, every model's tokens are the
    /// library's, and the typed reads compile.
    func testModelsNamedLikeTheTokenTypesCompile() throws {
        let files = try CodegenRun.render(
            documents: [(sourceName: "tokens.toml", source: Self.tokenNamedModels)],
            sharedEnums: [SharedEnums(files: [("common", Self.common)], dir: "schemas/")],
            emptyLabel: "", accessLevel: "public", moduleImport: "JsBaoClient", swiftNameSuffix: "Record", strict: true
        )
        let directory = try scratch()
        let shared = directory.appending(path: "Status6270.swift")
        try Self.sharedEnumSource.write(to: shared, atomically: true, encoding: .utf8)
        let result = try typecheck(files, extra: [shared], usage: Self.tokenNamedUsage, in: directory)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(result.output.contains("warning:"), result.output)
    }

    /// A model named like a protocol every generated model conforms to is
    /// refused by the generator, naming the model and the protocol.
    func testAModelNamedLikeAConformedProtocolIsRefused() throws {
        for name in ["TypedQueryModel", "PrimitiveModel", "PrimitiveRowDecodable"] {
            let source = """
                [type]
                name = "protocols6270"

                [models.protocols6270]
                class_name = "\(name)"
                """
            XCTAssertThrowsError(try CodegenRun.render(
                documents: [(sourceName: "protocols.toml", source: source)],
                sharedEnums: [],
                emptyLabel: "", accessLevel: "public", moduleImport: "JsBaoClient", swiftNameSuffix: "Record", strict: true
            )) { error in
                guard case let .reservedProtocolName(model, swiftName) = error as? CodegenError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertEqual(model, "protocols6270")
                XCTAssertEqual(swiftName, name)
            }
        }
    }

    private static let tokenNamedModels = """
        [type]
        name = "tokens6270"

        [models.idTokens6270]
        class_name = "ModelIdField"

        [models.idTokens6270.fields.label]
        type = "string"

        [models.stringTokens6270]
        class_name = "ModelStringField"

        [models.stringTokens6270.fields.label]
        type = "string"

        [models.numberTokens6270]
        class_name = "ModelNumberField"

        [models.numberTokens6270.fields.size]
        type = "number"

        [models.booleanTokens6270]
        class_name = "ModelBooleanField"

        [models.booleanTokens6270.fields.on]
        type = "boolean"

        [models.dateTokens6270]
        class_name = "ModelDateField"

        [models.dateTokens6270.fields.day]
        type = "date"

        [models.setTokens6270]
        class_name = "ModelStringSetField"

        [models.setTokens6270.fields.tags]
        type = "stringset"

        [models.enumTokens6270]
        class_name = "ModelEnumField"

        [models.enumTokens6270.fields.status]
        ref = "Status6270"

        [models.jsonTokens6270]
        class_name = "ModelJSONField"

        [models.kinds6270]
        class_name = "Kinds6270"

        [models.kinds6270.fields.label]
        type = "string"

        [models.kinds6270.fields.size]
        type = "number"

        [models.kinds6270.fields.on]
        type = "boolean"

        [models.kinds6270.fields.day]
        type = "date"

        [models.kinds6270.fields.tags]
        type = "stringset"

        [models.kinds6270.fields.status]
        ref = "Status6270"
        """

    private static let tokenNamedUsage = """
        import JsBaoClient

        func tokenNamed() throws {
            let k = Kinds6270.fields
            let _: [Kinds6270] = try Kinds6270.query(
                where: .and([k.id.eq("k1"), k.label.startsWith("a"), k.size.gt(1), k.on.eq(true), k.day.lt("2026-01-01"), k.tags.contains("x"),
                             k.status.eq(.open)]),
                sort: [.asc(k.label), .desc(k.size)])
            let _: [ModelIdField] = try ModelIdField.query(where: ModelIdField.fields.label.eq("a"), sort: [.asc(ModelIdField.fields.id)])
            let _: Int = try ModelStringField.count(where: ModelStringField.fields.label.eq("a"))
            let _: Int = try ModelNumberField.count(where: ModelNumberField.fields.size.gte(1))
            let _: Int = try ModelBooleanField.count(where: ModelBooleanField.fields.on.eq(false))
            let _: Int = try ModelDateField.count(where: ModelDateField.fields.day.gt("2026-01-01"))
            let _: Int = try ModelStringSetField.count(where: ModelStringSetField.fields.tags.contains("x"))
            let _: Int = try ModelEnumField.count(where: ModelEnumField.fields.status.eq(.done))
            let _: Int = try ModelJSONField.count(where: ModelJSONField.fields.id.eq("j1"))
        }
        """

    private static let names = """
        [type]
        name = "names6270"

        [models.fields6270]
        class_name = "Fields"

        [models.fields6270.fields.ModelIdField]
        type = "string"

        [models.fields6270.fields.ModelStringField]
        type = "string"

        [models.fields6270.fields.ModelNumberField]
        type = "number"

        [models.fields6270.fields.FieldTokens]
        type = "string"

        [models.chores6270]
        class_name = "Chore6270"

        [models.chores6270.fields.title]
        type = "string"

        [models.chores6270.fields.ownerId]
        type = "string"

        [models.chores6270.relationships.owner]
        type = "refersTo"
        model = "fields6270"
        related_id_field = "ownerId"
        """

    private static let namesUsage = """
        import JsBaoClient

        func names() throws {
            let f = Fields.fields
            let _: ModelIdField<Fields> = f.id
            let _: ModelStringField<Fields> = f.ModelIdField
            let _: [Fields] = try Fields.query(where: .and([f.ModelIdField.eq("a"), f.ModelNumberField.gt(1), f.FieldTokens.eq("x")]),
                                               sort: [.asc(f.ModelStringField), .desc(f.id)])
            let _: Int = try Fields.count(where: f.id.eq("f1"))
            let c = Chore6270.fields
            let _: ModelStringField<Chore6270> = c.title
            let _: [Chore6270] = try Chore6270.query(where: c.ownerId.eq("f1"), sort: [.asc(c.title)])
        }
        """

    // MARK: - What compiled before

    func testTodaysDocumentFilterCallsCompileUnchanged() throws {
        let result = try typecheck(ledger: Self.today)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(result.output.contains("ambiguous"), result.output)
        XCTAssertFalse(result.output.contains("warning:"), result.output)
    }

    func testModelsEmittedBeforeThisChangeCompileAgainstTheLibrary() throws {
        let fixture = Self.packageRoot.deletingLastPathComponent().appending(path: "tests/fixtures/swift-models-pre-6270")
        let models = try FileManager.default.contentsOfDirectory(atPath: fixture.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertEqual(models, ["CrashTestRecord.swift", "TaskRecord.swift"])
        for model in models {
            XCTAssertFalse(try String(contentsOf: fixture.appending(path: model), encoding: .utf8).contains("TypedQueryModel"),
                           "\(model) is a model emitted before typed reads")
        }
        let result = try typecheckFiles(models.map { fixture.appending(path: $0) }, usage: Self.preChangeUsage)
        XCTAssertEqual(result.status, 0, result.output)
    }

    // MARK: - Usage files

    private static let accepted = """
        import Foundation
        import JsBaoClient

        func typedReads() throws {
            let f = Entry6270.fields
            let _: [Entry6270] = try Entry6270.query(where: f.accountId.eq("a1"))
            let _: [Entry6270] = try Entry6270.query(where: nil, sort: [.desc(f.amount)])
            let _: [Entry6270] = try Entry6270.query(where: .and([f.amount.gt(100), .or([f.memo.startsWith("rent"), f.memo.isNull()])]),
                                                     sort: [.asc(f.bookedOn), .desc(f.amount)], options: QueryOptions(limit: 10))
            let _: [Entry6270] = try Entry6270.query(where: f.tags.contains("x"), include: [])
            let page: PagedQueryResult<Entry6270> = try Entry6270.queryPaged(where: f.cleared.eq(true), sort: [.asc(f.id)], options: QueryOptions(limit: 2))
            _ = page.nextCursor
            let _: PagedQueryResult<Entry6270> = try Entry6270.queryPaged(where: nil, include: [])
            let _: Entry6270? = try Entry6270.queryOne(where: f.status.eq(.open))
            let _: Entry6270? = try Entry6270.queryOne(where: f.status.eq("done"), sort: [.asc(f.status)], include: [])
            let _: Int = try Entry6270.count(where: .or([f.status.in([.open, .done]), f.status.notIn(["x"]), f.status.ne(.done)]))
            let _: Int = try Entry6270.count(where: nil, options: QueryOptions(db3: ["d"]))

            // Every operator of every kind.
            _ = f.id.in(["e1"]); _ = f.id.gte("e"); _ = f.id.ne("e2")
            _ = f.accountId.ne("x"); _ = f.accountId.notIn(["x"]); _ = f.accountId.exists(); _ = f.accountId.exists(false)
            _ = f.accountId.gte("a"); _ = f.accountId.lt("b"); _ = f.accountId.lte("b")
            _ = f.memo.endsWith("x"); _ = f.memo.containsText("x")
            _ = f.amount.eq(3); _ = f.amount.lt(2.5); _ = f.amount.in([1, 2]); _ = f.amount.isNull()
            _ = f.cleared.ne(false); _ = f.cleared.in([true]); _ = f.cleared.exists()
            _ = f.bookedOn.gte("2026-01-01"); _ = f.bookedOn.lt(Date().ISO8601Format()); _ = f.bookedOn.in(["2026-01-01"])
            _ = f.tags.all(["a", "b"]); _ = f.tags.size(2); _ = f.tags.exists(false); _ = f.tags.startsWith("a"); _ = f.tags.isNull()
            _ = f.tags.size(.gt(1)); _ = f.tags.size(.gte(1), .lt(3)); _ = f.tags.size(.eq(0)); _ = f.tags.size(.ne(1)); _ = f.tags.size(.lte(2))
            _ = f.tags.all([])
            _ = f.default.lt(3); _ = f.dueAt.gte(1); _ = f.createdAt.gt(0)
            _ = ModelFilter<Entry6270>(unchecked: ["$search": "rent"])
            _ = ModelFilter<Entry6270>.and([])
            let _: [Entry6270] = try Entry6270.query(where: f.default.eq(1), sort: [.asc(f.dueAt), .desc(f.createdAt), .asc(f.default), .asc(f.tags)])
            let _: [Account6270] = try Account6270.query(where: Account6270.fields.name.eq("x"))
            let _: [Empty6270] = try Empty6270.query(where: Empty6270.fields.id.eq("x"), sort: [.asc(Empty6270.fields.id)])
        }

        func typedAggregates() throws {
            let f = Entry6270.fields
            let account = f.accountId.group, month = f.bookedOn.period(.month), red = f.tags.has("red")
            let tag = f.tags.group, cleared = f.cleared.group, amount = f.amount.group, status = f.status.group
            let total = f.amount.sum(), n = Entry6270.aggregateCount(), low = f.amount.min(), mean = f.amount.avg()
            let latest = f.bookedOn.max(), named = f.amount.sum(as: "total"), counted = Entry6270.aggregateCount(as: "n")
            let rows: [AggregateRow<Entry6270>] = try Entry6270.aggregate(
                groupBy: [account, month, red, cleared, amount, status], operations: [total, n, low, mean, latest, named, counted],
                where: f.cleared.eq(true), sort: AggregateSort(field: "count", direction: -1), limit: 5)
            let row = rows[0]
            let _: String? = row[account]
            let _: String? = row[month]
            let _: Bool? = row[red]
            let _: Bool? = row[cleared]
            let _: Double? = row[amount]
            let _: String? = row[status]
            let _: Double? = row[total]
            let _: Int? = row[n]
            let _: Double? = row[low]
            let _: Double? = row[mean]
            let _: String? = row[latest]
            let _: Double? = row[named]
            let _: Int? = row[counted]
            let _: [String: JSONValue] = row.raw
            let facets = try Entry6270.aggregate(groupBy: [tag], operations: [n])
            let _: String? = facets[0][tag]
            let mixed = try Entry6270.aggregate(groupBy: [tag, account], operations: [n], where: nil, documents: ["d"], db3: ["d"])
            let _: String? = mixed[0][tag]
            let ungrouped = try Entry6270.aggregate(groupBy: [], operations: [total])
            let _: Double? = ungrouped[0][total]
            let firstId = f.id.min(), lastId = f.id.max(), lowStatus = f.status.min(as: "lowStatus"), highStatus = f.status.max()
            let strings = try Entry6270.aggregate(groupBy: [status], operations: [firstId, lastId, lowStatus, highStatus])
            let _: String? = strings[0][firstId]
            let _: String? = strings[0][lastId]
            let _: String? = strings[0][lowStatus]
            let _: String? = strings[0][highStatus]
        }
        """

    private static let refused = """
        import Foundation
        import JsBaoClient

        func refused() throws {
            let f = Entry6270.fields
            let d: Double = 1
            let n = Entry6270.aggregateCount()
            _ = try Entry6270.query(where: f.acountId.eq("a1")) // REFUSE
            _ = try Entry6270.queryPaged(where: f.nope.eq("x"), sort: [], options: nil) // REFUSE
            _ = try Entry6270.queryOne(where: f.nope.eq("x")) // REFUSE
            _ = try Entry6270.count(where: f.nope.eq("x")) // REFUSE
            _ = try Entry6270.aggregate(groupBy: [f.nope.group], operations: [n]) // REFUSE
            _ = try Entry6270.query(where: .and([f.amount.gt(1), .or([f.nope.eq("x")])])) // REFUSE
            _ = try Entry6270.query(where: f.amount.gt("100")) // REFUSE
            _ = try Entry6270.query(where: f.memo.eq(d)) // REFUSE
            _ = try Entry6270.query(where: f.cleared.eq("true")) // REFUSE
            _ = try Entry6270.query(where: f.cleared.gt(true)) // REFUSE
            _ = try Entry6270.query(where: f.amount.startsWith("1")) // REFUSE
            _ = try Entry6270.query(where: f.memo.contains("x")) // REFUSE
            _ = try Entry6270.query(where: f.tags.gt("a")) // REFUSE
            _ = try Entry6270.query(where: f.tags.eq("x")) // REFUSE
            _ = try Entry6270.query(where: f.tags.ne("x")) // REFUSE
            _ = try Entry6270.query(where: f.tags.in(["x"])) // REFUSE
            _ = try Entry6270.query(where: f.tags.notIn(["x"])) // REFUSE
            _ = try Entry6270.query(where: f.tags.size(.gt("1"))) // REFUSE
            _ = try Entry6270.query(where: f.tags.size(.gt(1.5))) // REFUSE
            _ = try Entry6270.query(where: f.tags.size()) // REFUSE
            _ = try Entry6270.query(where: f.amount.size(1)) // REFUSE
            _ = try Entry6270.query(where: f.amount.size(.gt(1))) // REFUSE
            _ = try Entry6270.query(where: f.memo.all(["a"])) // REFUSE
            _ = try Entry6270.query(where: f.cleared.size(.eq(1))) // REFUSE
            _ = try Entry6270.query(where: f.status.all(["open"])) // REFUSE
            _ = try Entry6270.query(where: f.bookedOn.eq(Date())) // REFUSE
            _ = try Entry6270.query(where: f.bookedOn.gt(Date())) // REFUSE
            _ = try Entry6270.query(where: f.bookedOn.in([Date()])) // REFUSE
            _ = try Entry6270.query(where: f.due.eq(1)) // REFUSE
            _ = try Entry6270.query(where: f.embedding.exists()) // REFUSE
            _ = try Entry6270.query(where: Account6270.fields.name.eq("x")) // REFUSE
            _ = try Account6270.query(where: Account6270.fields.createdAt.gt(0)) // REFUSE
            _ = try Entry6270.query(where: nil, sort: [.asc(Account6270.fields.name)]) // REFUSE
            _ = try Entry6270.query(where: nil, sort: [.asc(f.nope)]) // REFUSE
            _ = try Account6270.query(where: nil, sort: [.desc(Account6270.fields.createdAt)]) // REFUSE
            _ = try Entry6270.aggregate(groupBy: [Account6270.fields.name.group], operations: [n]) // REFUSE
            _ = try Entry6270.aggregate(groupBy: [], operations: [Account6270.aggregateCount()]) // REFUSE
            _ = try Entry6270.aggregate(groupBy: [], operations: [f.memo.sum()]) // REFUSE
            _ = try Entry6270.aggregate(groupBy: [], operations: [f.status.sum()]) // REFUSE
            let _: Double? = try Entry6270.aggregate(groupBy: [], operations: [f.id.max()])[0][f.id.max()] // REFUSE
            let rows = try Entry6270.aggregate(groupBy: [f.tags.group], operations: [f.amount.sum()])
            let _: String? = rows[0][f.amount.sum()] // REFUSE
            let _: Set<String>? = rows[0][f.tags.group] // REFUSE
            let _: Int? = rows[0][Account6270.aggregateCount()] // REFUSE
        }
        """

    private static let jsonAccepted = """
        import JsBaoClient

        func json() throws {
            let f = JsonOrderRecord.fields
            _ = try JsonOrderRecord.query(where: f.shipping_address.exists())
            _ = try JsonOrderRecord.query(where: f.shipping_address.exists(false))
        }
        """

    private static let jsonRefused = """
        import JsBaoClient

        func json() throws {
            let f = JsonOrderRecord.fields
            _ = try JsonOrderRecord.query(where: f.shipping_address.eq("x")) // REFUSE
            _ = try JsonOrderRecord.query(where: f.shipping_address.isNull()) // REFUSE
            _ = try JsonOrderRecord.query(where: f.shipping_address.gt("x")) // REFUSE
            _ = try JsonOrderRecord.query(where: f.shipping_address.startsWith("x")) // REFUSE
            _ = try JsonOrderRecord.query(where: nil, sort: [.asc(f.shipping_address)]) // REFUSE
        }
        """

    /// The `DocumentFilter` reads as apps call them today.
    private static let today = """
        import JsBaoClient

        func today() throws {
            let _: [Entry6270] = try Entry6270.query()
            let _: [Entry6270] = try Entry6270.query(["memo": "x"])
            let _: [Entry6270] = try Entry6270.query(nil, options: QueryOptions(limit: 1))
            let _: [Entry6270] = try Entry6270.query(options: QueryOptions(sort: ["amount": -1]))
            let _: [Entry6270] = try Entry6270.query(["amount": ["$gt": 1]], options: nil, include: [])
            let _: PagedQueryResult<Entry6270> = try Entry6270.queryPaged()
            let _: PagedQueryResult<Entry6270> = try Entry6270.queryPaged(["cleared": true], options: QueryOptions(limit: 2))
            let _: Entry6270? = try Entry6270.queryOne()
            let _: Entry6270? = try Entry6270.queryOne(["memo": "x"])
            let _: Int = try Entry6270.count()
            let _: Int = try Entry6270.count(["cleared": true])
            let _: Int = try Entry6270.count(options: QueryOptions(db3: ["d"]))
            let filter: DocumentFilter = ["accountId": .string("a1")]
            let _: [Entry6270] = try Entry6270.query(filter)
            let rows: [[String: JSONValue]] = try Entry6270.aggregate(AggregateOptions(
                groupBy: ["accountId"], operations: [AggregateOperation(type: .count)], filter: ["cleared": true]))
            _ = rows.first?["group"]
        }
        """

    /// The pre-change models' reads, through the `DocumentFilter` forms.
    private static let preChangeUsage = """
        import JsBaoClient

        func preChange() throws {
            let _: [TaskRecord] = try TaskRecord.query(["title": "x"], options: QueryOptions(sort: ["priority": -1]))
            let _: Int = try CrashTestRecord.count(["active": true])
            let _: [[String: JSONValue]] = try TaskRecord.aggregate(AggregateOptions(groupBy: ["title"], operations: [AggregateOperation(type: .count)]))
        }
        """

    // MARK: - Helpers

    /// The ledger's models as this swift-bao-codegen writes them, by file name.
    private func renderLedger() throws -> [String: String] {
        let files = try CodegenRun.render(
            documents: [(sourceName: "ledger.toml", source: Self.ledger)],
            sharedEnums: [SharedEnums(files: [("common", Self.common)], dir: "schemas/")],
            emptyLabel: "", accessLevel: "public", moduleImport: "JsBaoClient", swiftNameSuffix: "Record", strict: true
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
    }

    /// `swiftc -typecheck` over the ledger's models, the shared enum and `usage`.
    private func typecheck(ledger usage: String) throws -> (status: Int32, output: String) {
        let files = try CodegenRun.render(
            documents: [(sourceName: "ledger.toml", source: Self.ledger)],
            sharedEnums: [SharedEnums(files: [("common", Self.common)], dir: "schemas/")],
            emptyLabel: "", accessLevel: "public", moduleImport: "JsBaoClient", swiftNameSuffix: "Record", strict: true
        )
        let directory = try scratch()
        let shared = directory.appending(path: "Status6270.swift")
        try Self.sharedEnumSource.write(to: shared, atomically: true, encoding: .utf8)
        return try typecheck(files, extra: [shared], usage: usage, in: directory)
    }

    private func typecheck(
        _ rendered: [(fileName: String, source: String)], extra: [URL], usage: String, in directory: URL? = nil
    ) throws -> (status: Int32, output: String) {
        let directory = try directory ?? scratch()
        var urls: [URL] = []
        for file in rendered where file.fileName != SwiftEmitter.barrelFileName {
            let url = directory.appending(path: file.fileName)
            try file.source.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        return try typecheckFiles(urls + extra, usage: usage, in: directory)
    }

    private func typecheckFiles(_ files: [URL], usage: String, in directory: URL? = nil) throws -> (status: Int32, output: String) {
        let directory = try directory ?? scratch()
        let usageURL = directory.appending(path: "usage.swift")
        try usage.write(to: usageURL, atomically: true, encoding: .utf8)
        return try swiftcTypecheck(files + [usageURL])
    }

    private var directories: [URL] = []

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "typed-query-6270-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    /// The 1-based lines of `source` marked `// REFUSE`.
    private func refuseLines(_ source: String) -> [Int] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { $0.element.hasSuffix("// REFUSE") }.map { $0.offset + 1 }
    }

    /// The sorted, distinct lines of `file` an error falls on.
    private func errorLines(_ output: String, file: String) -> [Int] {
        var lines = Set<Int>()
        for line in output.split(separator: "\n") {
            guard line.contains(": error:"), let range = line.range(of: "/\(file):") else { continue }
            let rest = line[range.upperBound...]
            if let number = Int(rest.prefix { $0.isNumber }) { lines.insert(number) }
        }
        return lines.sorted()
    }

    /// `swiftc -typecheck` over `files`, importing the `JsBaoClient` module
    /// from the products directory this test bundle was built into.
    private func swiftcTypecheck(_ files: [URL]) throws -> (status: Int32, output: String) {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let modules = [products, products.appendingPathComponent("Modules")]
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("JsBaoClient.swiftmodule").path) }
        guard let moduleDirectory = modules.first else {
            XCTFail("no JsBaoClient.swiftmodule in \(products.path); run the package's tests, which build it")
            return (-1, "")
        }
        var arguments = ["-typecheck", "-swift-version", "6", "-parse-as-library", "-I", moduleDirectory.path]
        let include = products.appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: include.path) { arguments += ["-I", include.path] }
        for map in moduleMaps(products) { arguments += ["-Xcc", "-fmodule-map-file=\(map.path)"] }
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let (executable, prefix) = FileManager.default.isExecutableFile(atPath: xcrun.path)
            ? (xcrun, ["swiftc"]) : (URL(fileURLWithPath: "/usr/bin/env"), ["swiftc"])
        let process = Process()
        process.executableURL = executable
        process.arguments = prefix + arguments + files.map(\.path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The C module maps the package's modules were built with.
    private func moduleMaps(_ products: URL) -> [URL] {
        let fm = FileManager.default
        let generated = products.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex/GeneratedModuleMaps")
        var maps: [URL] = []
        if let names = try? fm.contentsOfDirectory(atPath: generated.path) {
            maps += names.filter { $0.hasSuffix(".modulemap") }.sorted().map { generated.appendingPathComponent($0) }
        }
        if let names = try? fm.contentsOfDirectory(atPath: products.path) {
            for name in names.sorted() where name.hasSuffix(".build") {
                let map = products.appendingPathComponent(name).appendingPathComponent("module.modulemap")
                if fm.fileExists(atPath: map.path) { maps.append(map) }
            }
        }
        return maps
    }
}
