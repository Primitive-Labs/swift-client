import Foundation
import XCTest
@testable import swift_bao_codegen

/// #5896 phase 3 — a generated model field that refs a shared enum is typed
/// by the module's shared type.
///
/// `swift-bao-codegen` stores the field's string as `<field>Raw`
/// (`private(set)`) and adds a computed `<field>: <Name>?`, where `<Name>` is
/// the type `primitive functions codegen --lang swift` declares in
/// `Primitive.generated.swift`; initializers take `<Name>`. No nested enum is
/// declared for the field; `<Model>.<Field>Value` stays as a deprecated alias
/// unless it would shadow a shared enum the model refs. A model whose own
/// names would shadow or take the generated ones is refused.
///
/// The committed models under
/// `JsBaoClientTests/Schema/CodegenSharedEnum/`, which the client's test
/// target compiles and runs beside the CLI's output for the same tree
/// (`SharedEnumModelRuntimeHermeticTests`), are what the tool writes for that
/// directory's `db3-types/board.toml`.
final class SharedEnumModelHermeticTests: XCTestCase {

    private static let packageRoot: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }()

    private static let fixture = packageRoot.appendingPathComponent("Tests/JsBaoClientTests/Schema/CodegenSharedEnum")

    private static let common = """
        [defs.Status]
        type = "string"
        enum = ["open", "closed"]

        [defs.StatusValue]
        type = "string"
        enum = ["draft", "done"]

        [defs.default]
        type = "string"
        enum = ["a", "b"]

        [defs.Post]
        type = "string"
        enum = ["x"]

        [defs.CodingKeys]
        type = "string"
        enum = ["x"]

        [defs.status]
        type = "string"
        enum = ["open", "closed"]
        """

    /// What one run writes for `documents`, by file name.
    private func render(_ documents: [(String, String)], common: String = common) throws -> [String: String] {
        let shared = SharedEnums(files: [("common", common)], dir: "schemas/")
        let files = try CodegenRun.render(
            documents: documents.map { (sourceName: $0.0, source: $0.1) },
            sharedEnums: documents.map { _ in shared },
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
    }

    private func model(_ fields: String, model: String = "posts", className: String = "PostRecord") throws -> String {
        let files = try render([("board.toml", "[type]\nname = \"board\"\n\n[models.\(model)]\nclass_name = \"\(className)\"\n\n\(fields)")])
        return try XCTUnwrap(files["\(className).swift"])
    }

    private func refusal(_ fields: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            let source = try model(fields)
            XCTFail("expected a refusal, got\n\(source)", file: file, line: line)
            return ""
        } catch let error as CodegenError {
            return error.description
        } catch {
            XCTFail("expected a CodegenError, got \(error)", file: file, line: line)
            return ""
        }
    }

    private static let status = "[models.posts.fields.status]\nref = \"Status\"\n"

    // MARK: - The committed fixture

    func testTheCommittedModelsAreWhatTheToolWritesForTheFixture() throws {
        let inputs = try CodegenInputs.read(try CodegenInputs.expand([Self.fixture.appendingPathComponent("db3-types").path]))
        let files = try CodegenRun.render(
            documents: inputs.map { (sourceName: $0.sourceName, source: $0.source) },
            sharedEnums: CodegenInputs.sharedEnumFiles(for: inputs),
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        let models = files.filter { $0.fileName != SwiftEmitter.barrelFileName }
        XCTAssertEqual(models.map(\.fileName).sorted(), ["EnumCardRecord.swift", "EnumIssueRecord.swift", "EnumLabelRecord.swift", "EnumPostRecord.swift", "EnumStepRecord.swift", "EnumTicketRecord.swift"])
        for (fileName, source) in models {
            let committed = try String(contentsOf: Self.fixture.appendingPathComponent(fileName), encoding: .utf8)
            XCTAssertEqual(source, committed, "\(fileName) is stale; regenerate it with swift-bao-codegen --input \(Self.fixture.path)/db3-types")
        }
    }

    // MARK: - Behavior 18: raw storage beside a typed accessor

    func testARefdFieldStoresItsStringAndIsTypedByTheSharedEnum() throws {
        let source = try model("[models.posts.fields.title]\ntype = \"string\"\n\n" + Self.status)
        XCTAssertTrue(source.contains("    public private(set) var statusRaw: String? {\n        didSet { _changedFields.insert(\"status\") }\n    }\n"), source)
        XCTAssertTrue(source.contains("    public var status: Status? {\n        get { statusRaw.flatMap { .init(rawValue: $0) } }\n        set { statusRaw = newValue?.rawValue }\n    }\n"), source)
        // Both initializers take the shared type.
        XCTAssertEqual(source.components(separatedBy: "        status: Status? = nil").count - 1, 2, source)
        XCTAssertTrue(source.contains("        self.statusRaw = status?.rawValue\n"), source)
        // The stored string is what reads, writes and compares.
        XCTAssertTrue(source.contains(#"        self.statusRaw = record["status"]?.asString"#), source)
        XCTAssertTrue(source.contains(#"        self.statusRaw = row["status"]?.stringValue"#), source)
        XCTAssertTrue(source.contains(#"        if let statusRaw { values["status"] = .string(statusRaw) }"#), source)
        XCTAssertTrue(source.contains("title, statusRaw = \"status\"\n"), source)
        XCTAssertTrue(source.contains("        self.statusRaw = try container.decodeIfPresent(String.self, forKey: .statusRaw)\n"), source)
        XCTAssertTrue(source.contains("        lhs.statusRaw == rhs.statusRaw"), source)
        XCTAssertTrue(source.contains("        hasher.combine(statusRaw)\n"), source)
        // No nested enum for the field.
        XCTAssertFalse(source.contains("enum StatusValue"), source)
        XCTAssertFalse(source.contains("var status: String?"), source)
        // The descriptor is the expanded field's.
        XCTAssertTrue(source.contains(#""status": FieldDescriptor(type: .string),"#), source)
    }

    // MARK: - Behavior 23: a required ref'd field

    func testARequiredRefdFieldStoresAStringAndTakesTheEnum() throws {
        let source = try model(Self.status + "required = true\n")
        XCTAssertTrue(source.contains("    public private(set) var statusRaw: String {\n"), source)
        XCTAssertTrue(source.contains("    public var status: Status? {\n        get { .init(rawValue: statusRaw) }\n        set { if let newValue { statusRaw = newValue.rawValue } }\n    }\n"), source)
        XCTAssertEqual(source.components(separatedBy: "        status: Status\n").count - 1, 2, source)
        XCTAssertTrue(source.contains("        self.statusRaw = status.rawValue\n"), source)
        XCTAssertTrue(source.contains(#"let statusRaw = record["status"]?.asString"#), source)
        XCTAssertTrue(source.contains(#"let statusRaw = row["status"]?.stringValue"#), source)
        XCTAssertTrue(source.contains(#"            "status": .string(statusRaw),"#), source)
        XCTAssertTrue(source.contains("Assigning `nil` leaves the stored value unchanged"), source)
    }

    // MARK: - Behaviors 24, 40, 41: the deprecated alias and accessor

    func testTheDeprecatedAliasAndAccessorNameTheSharedEnum() throws {
        let source = try model(Self.status)
        XCTAssertTrue(source.contains("    @available(*, deprecated, renamed: \"Status\")\n    public typealias StatusValue = Status\n"), source)
        XCTAssertTrue(source.contains("    public static let allowedStatusValues: Set<String> = [\"open\", \"closed\"]\n"), source)
        XCTAssertTrue(source.contains("    @available(*, deprecated, renamed: \"status\")\n    public var statusEnum: Status? {\n        status\n    }\n"), source)
    }

    func testAFieldThatRefsADefNamedLikeItsAliasHasNoAlias() throws {
        let source = try model("[models.posts.fields.status]\nref = \"StatusValue\"\n")
        XCTAssertTrue(source.contains("    public var status: StatusValue? {\n"), source)
        XCTAssertFalse(source.contains("typealias StatusValue"), source)
        XCTAssertFalse(source.contains("enum StatusValue"), source)
        XCTAssertTrue(source.contains("    public var statusEnum: StatusValue? {\n"), source)
        XCTAssertTrue(source.contains("    public static let allowedStatusValues: Set<String> = [\"draft\", \"done\"]\n"), source)
    }

    func testAnAliasNamedLikeAnotherFieldsSharedEnumIsOmitted() throws {
        let source = try model(Self.status + "\n[models.posts.fields.kind]\nref = \"StatusValue\"\n")
        XCTAssertFalse(source.contains("typealias StatusValue"), source)
        XCTAssertTrue(source.contains("    @available(*, deprecated, renamed: \"StatusValue\")\n    public typealias KindValue = StatusValue\n"), source)
        XCTAssertTrue(source.contains("    public var status: Status? {\n"), source)
        XCTAssertTrue(source.contains("    public var kind: StatusValue? {\n"), source)
        XCTAssertTrue(source.contains("    public var statusEnum: Status? {\n"), source)
    }

    // MARK: - Edge cases: keyword names

    func testADefNamedASwiftKeywordIsReferencedWithTheCLIsSuffix() throws {
        let source = try model("[models.posts.fields.grade]\nref = \"default\"\n")
        XCTAssertTrue(source.contains("    public var grade: default_? {\n        get { gradeRaw.flatMap { .init(rawValue: $0) } }\n"), source)
        XCTAssertTrue(source.contains("    public typealias GradeValue = default_\n"), source)
    }

    func testARefdFieldNamedASwiftKeywordHasALegalRawNameAndAnEscapedAccessor() throws {
        let source = try model("[models.posts.fields.default]\nref = \"Status\"\n")
        XCTAssertTrue(source.contains("    public private(set) var defaultRaw: String? {\n        didSet { _changedFields.insert(\"default\") }\n"), source)
        XCTAssertTrue(source.contains("    public var `default`: Status? {\n        get { defaultRaw.flatMap { .init(rawValue: $0) } }\n"), source)
        XCTAssertTrue(source.contains("        `default`: Status? = nil"), source)
        XCTAssertTrue(source.contains("        self.defaultRaw = `default`?.rawValue\n"), source)
        XCTAssertTrue(source.contains("defaultRaw = \"default\"\n"), source)
        XCTAssertTrue(source.contains("    public var defaultEnum: Status? {\n        `default`\n    }\n"), source)
    }

    // MARK: - Edge case: a def named like the model's members (CSO-5896-010)

    /// The getters build the case from context, never by the type's name, so a
    /// def named like the field (`status`) or its stored string does not bind
    /// to the property. `EnumLabelRecord` in the committed fixture compiles it.
    func testADefNamedLikeTheFieldIsNeverNamedInAnExpression() throws {
        let optional = try model("[models.posts.fields.status]\nref = \"status\"\n")
        XCTAssertTrue(optional.contains("    public var status: status? {\n        get { statusRaw.flatMap { .init(rawValue: $0) } }\n"), optional)
        let required = try model("[models.posts.fields.status]\nref = \"status\"\nrequired = true\n")
        XCTAssertTrue(required.contains("    public var status: status? {\n        get { .init(rawValue: statusRaw) }\n"), required)
        XCTAssertFalse(optional.contains("status.init") || required.contains("status.init") || required.contains("status(rawValue:"), required)
    }

    // MARK: - Behaviors 25, 42 and the model-type edge case: refusals

    func testAFieldNamedLikeARefdFieldsRawStorageIsRefused() {
        XCTAssertEqual(
            refusal(Self.status + "\n[models.posts.fields.statusRaw]\ntype = \"string\"\n"),
            "Model `posts` field `status` refs the shared enum `Status`, so its stored string is the generated property `statusRaw`, "
                + "and field `statusRaw` takes that name. Rename one of the two fields."
        )
    }

    /// A relationship's generated members (`<name>()`, `related<Name>`,
    /// `include<Name>`) cannot take a ref'd field's `<field>Raw` (CSO-5896-011).
    func testARelationshipNamedLikeARefdFieldsRawStorageIsRefused() {
        let target = "[models.posts.fields.authorId]\ntype = \"string\"\n\n"
        XCTAssertEqual(
            refusal(target + Self.status + "\n[models.posts.relationships.statusRaw]\ntype = \"refersTo\"\nmodel = \"posts\"\nrelated_id_field = \"authorId\"\n"),
            "Model `posts` field `status` refs the shared enum `Status`, so its stored string is the generated property `statusRaw`, "
                + "and relationship `statusRaw` generates `statusRaw` too. Rename the field or the relationship."
        )
        XCTAssertEqual(
            refusal(target + "[models.posts.fields.relatedPost]\nref = \"Status\"\n\n[models.posts.relationships.postRaw]\ntype = \"refersTo\"\nmodel = \"posts\"\nrelated_id_field = \"authorId\"\n"),
            "Model `posts` field `relatedPost` refs the shared enum `Status`, so its stored string is the generated property `relatedPostRaw`, "
                + "and relationship `postRaw` generates `relatedPostRaw` too. Rename the field or the relationship."
        )
    }

    func testAnInlineEnumWhoseNestedTypeShadowsARefdSharedEnumIsRefused() {
        XCTAssertEqual(
            refusal("[models.posts.fields.status]\ntype = \"string\"\nenum = [\"a\"]\n\n[models.posts.fields.kind]\nref = \"StatusValue\"\n"),
            "Model `posts` field `status` declares the nested type `StatusValue`, which shadows the shared enum `StatusValue` "
                + "(schemas/common.toml#StatusValue) that field `kind` refs. Rename the field or the def."
        )
    }

    func testANestedTypeTheModelAlwaysDeclaresCannotBeARefdSharedEnum() {
        XCTAssertEqual(
            refusal("[models.posts.fields.kind]\nref = \"CodingKeys\"\n"),
            "Model `posts` declares the nested type `CodingKeys`, which shadows the shared enum `CodingKeys` "
                + "(schemas/common.toml#CodingKeys) that field `kind` refs. Rename the def."
        )
    }

    func testASharedEnumNamedLikeAGeneratedModelTypeIsRefused() {
        let toml = "[type]\nname = \"board\"\n\n[models.notes]\nclass_name = \"Post\"\n\n[models.notes.fields.title]\ntype = \"string\"\n\n"
            + "[models.posts]\nclass_name = \"PostRecord\"\n\n[models.posts.fields.kind]\nref = \"Post\"\n"
        XCTAssertThrowsError(try render([("board.toml", toml)])) { error in
            XCTAssertEqual(
                (error as? CodegenError)?.description,
                "Model `posts` field `kind` refs the shared enum `Post` (schemas/common.toml#Post), "
                    + "whose Swift name is the generated model type of `notes`. Rename the def, or set the model's class_name."
            )
        }
    }

    // MARK: - Behavior 26 (pin): no ref, no change

    /// A type with an inline enum and no ref renders as the hand-written
    /// declaration always has: the nested enum and the plain `String`.
    func testAnInlineEnumFieldKeepsItsNestedEnumAndString() throws {
        let source = try model("[models.posts.fields.status]\ntype = \"string\"\nenum = [\"open\", \"closed\"]\n")
        XCTAssertTrue(source.contains("    public enum StatusValue: String, Codable, CaseIterable, Sendable {\n"), source)
        XCTAssertTrue(source.contains("    public var status: String? {\n        didSet { _changedFields.insert(\"status\") }\n    }\n"), source)
        XCTAssertTrue(source.contains("        status.flatMap(StatusValue.init(rawValue:))\n"), source)
        XCTAssertTrue(source.contains(", status\n"), source)
        XCTAssertFalse(source.contains("Raw"), source)
    }
}
