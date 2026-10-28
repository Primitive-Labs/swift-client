import XCTest
@testable import swift_bao_codegen

/// #4942 behaviors 6 and 16, edge cases E1 and E7 — every generated model
/// carries a db3 write's guards and `increment`.
///
/// The emitter appends three members after `delete(in:)`:
/// `save(in:options:)`, `delete(in:options:)` and the static
/// `increment(id:fields:in:options:)`, each delegating to `client.codegen` as
/// `save(in:)` does, so an app reaches the guards and counters through its
/// generated model. The static `increment` is a literal member name, so the
/// reserved field-name list classifies it, and the compiled probe model
/// declares a field of that name beside it.
final class SwiftEmitterDb3WritesHermeticTests: XCTestCase {

    private static let packageRoot: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }()

    /// The acceptance fixture's `TaskRecord`, as `swift-bao-codegen` emits it.
    private func taskRecord() throws -> String {
        let toml = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Tests/JsBaoClientTests/Schema/CodegenAcceptance/fixture.toml"),
            encoding: .utf8
        )
        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record", strict: true)
        let emitter = SwiftEmitter(options: EmitOptions(
            sourcePath: "fixture.toml",
            swiftNamesByModel: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) })
        ))
        let schema = try XCTUnwrap(schemas.first { $0.swiftName == "TaskRecord" })
        return emitter.emit(schema: schema)
    }

    /// The text of the member whose signature is `signature`, up to the next blank line.
    private func member(_ source: String, _ signature: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "missing: \(signature)")
        let end = source.range(of: "\n\n", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        return String(source[start.lowerBound..<end])
    }

    // MARK: - Behavior 6

    func testTheThreeMembersAreEmittedAndDelegateToTheFacade() throws {
        let source = try taskRecord()
        let save = try member(source, "    func save(in documentId: String, options: JsBaoClient.Db3WriteOptions) async throws -> TaskRecord {\n")
        XCTAssertTrue(save.contains(
            "codegen.save(Self.primitiveSchema, id: id, values: primitiveValues(), in: documentId, changedFields: _changedFields, options: options)"
        ))
        let delete = try member(source, "    func delete(in documentId: String, options: JsBaoClient.Db3WriteOptions) async throws {\n")
        XCTAssertTrue(delete.contains("codegen.delete(Self.primitiveSchema, id: id, in: documentId, options: options)"))
        let increment = try member(
            source,
            "    static func increment(id: String, fields: [String: Double], in documentId: String, options: JsBaoClient.Db3WriteOptions = JsBaoClient.Db3WriteOptions()) async throws -> [String: Double] {\n"
        )
        XCTAssertTrue(increment.contains("codegen.increment(primitiveSchema, id: id, fields: fields, in: documentId, options: options)"))
        XCTAssertTrue(source.contains("    @discardableResult\n    func save(in documentId: String, options: JsBaoClient.Db3WriteOptions)"))
        XCTAssertTrue(source.contains("    @discardableResult\n    static func increment(id: String,"))
    }

    func testTheGuardedSaveRebuildsItsReturnValueAsSaveInDoes() throws {
        let source = try taskRecord()
        let plain = try member(source, "    func save(in documentId: String) throws -> TaskRecord {\n")
        let guarded = try member(source, "    func save(in documentId: String, options: JsBaoClient.Db3WriteOptions) async throws -> TaskRecord {\n")
        // Everything after the facade call is the same rebuild.
        let rebuild = { (body: String) -> String in
            String(body[body.range(of: "guard var saved")!.lowerBound...])
        }
        XCTAssertEqual(rebuild(guarded), rebuild(plain))
        XCTAssertTrue(guarded.contains("saved.related = related"))
        XCTAssertTrue(guarded.contains("saved._explicitId = _explicitId"))
        XCTAssertTrue(guarded.contains("fallback.discardChanges()"))
    }

    func testTheMembersComeAfterDeleteInAndCloseTheFacade() throws {
        let source = try taskRecord()
        let delete = try XCTUnwrap(source.range(of: "    func delete(in documentId: String) throws {\n"))
        let save = try XCTUnwrap(source.range(of: "    func save(in documentId: String, options: JsBaoClient.Db3WriteOptions)"))
        let deleteGuarded = try XCTUnwrap(source.range(of: "    func delete(in documentId: String, options: JsBaoClient.Db3WriteOptions)"))
        let increment = try XCTUnwrap(source.range(of: "    static func increment(id: String,"))
        XCTAssertLessThan(delete.lowerBound, save.lowerBound)
        XCTAssertLessThan(save.lowerBound, deleteGuarded.lowerBound)
        XCTAssertLessThan(deleteGuarded.lowerBound, increment.lowerBound)
        // `delete(in:)` keeps its body and is followed by the appended members.
        XCTAssertTrue(source.contains(
            "    func delete(in documentId: String) throws {\n"
                + "        try JsBaoClient.requireDefault().codegen.delete(Self.primitiveSchema, id: id, in: documentId)\n"
                + "    }\n\n"
        ))
        XCTAssertTrue(source.hasSuffix("    }\n}\n"))
    }

    // MARK: - A model named `Db3WriteOptions` (4942-C001)

    /// A schema may still name a model `Db3WriteOptions` (the TOML parser
    /// accepts the `class_name`; only the schema exporter avoids it). That
    /// model is a type in the app's module and shadows the imported options
    /// type, so the emitter never writes the options type's bare name: every
    /// reference goes through `JsBaoClient.`, which the facade calls need
    /// already. `Db3WriteOptionsShadowHermeticTests` (JsBaoClientTests) shows
    /// the qualified name resolving to the client's type under such a shadow.
    func testAModelNamedDb3WriteOptionsDoesNotShadowTheOptionsType() throws {
        let toml = """
        [models.write_options]
        class_name = "Db3WriteOptions"

        [models.write_options.fields.id]
        type = "id"
        auto_assign = true

        [models.write_options.fields.views]
        type = "number"
        """
        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record", strict: true)
        let schema = try XCTUnwrap(schemas.first)
        XCTAssertEqual(schema.swiftName, "Db3WriteOptions")
        let source = SwiftEmitter(options: EmitOptions(
            sourcePath: "write-options.toml",
            swiftNamesByModel: [schema.name: schema.swiftName]
        )).emit(schema: schema)

        XCTAssertTrue(source.contains("struct Db3WriteOptions: PrimitiveModel"))
        XCTAssertTrue(source.contains("    func save(in documentId: String, options: JsBaoClient.Db3WriteOptions) async throws -> Db3WriteOptions {\n"))
        XCTAssertTrue(source.contains("    func delete(in documentId: String, options: JsBaoClient.Db3WriteOptions) async throws {\n"))
        XCTAssertTrue(source.contains(
            "options: JsBaoClient.Db3WriteOptions = JsBaoClient.Db3WriteOptions()) async throws -> [String: Double] {\n"
        ))
        // Exactly the three members' four references are the options type, all qualified.
        XCTAssertEqual(source.components(separatedBy: "JsBaoClient.Db3WriteOptions").count - 1, 4)
        XCTAssertFalse(source.contains("options: Db3WriteOptions"))
        XCTAssertFalse(source.contains("= Db3WriteOptions()"))
    }

    // MARK: - Edge cases E1 and E7: the doc comments say what a caller sees

    func testTheDocCommentsStateTheHeldGuessAndTheUnsubscribedWait() throws {
        let source = try taskRecord()
        let start = try XCTUnwrap(source.range(of: "    func delete(in documentId: String) throws {\n"))
        let appended = String(source[start.upperBound...])
        XCTAssertTrue(appended.contains("shows on this device only once the room accepts it"), "E1: the held guess")
        XCTAssertTrue(appended.contains("waits for the next subscribe"), "E7: a confirmed write while unsubscribed")
    }

    // MARK: - Behavior 16: the static is classified, and the probe declares a field of its name

    func testIncrementIsAnExemptFieldNameAndTheProbeDeclaresIt() throws {
        XCTAssertTrue(ReservedFieldNames.exempt.contains("increment"))
        XCTAssertNil(ReservedFieldNames.reasons["increment"])
        let probe = try String(
            contentsOf: Self.packageRoot.appendingPathComponent(ReservedFieldNamesInvariantHermeticTests.probePath),
            encoding: .utf8
        )
        XCTAssertTrue(probe.contains("    internal var increment: String? {"))
        XCTAssertTrue(probe.contains("    static func increment(id: String, fields: [String: Double], in documentId: String,"))
    }
}
