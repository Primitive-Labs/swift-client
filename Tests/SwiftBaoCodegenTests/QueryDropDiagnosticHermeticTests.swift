import XCTest
@testable import SwiftBaoCodegen

/// The generated read facade must not drop a row on the floor (#2825).
///
/// `query` / `queryPaged` / `queryOne` / `findByUnique` used to map rows with
/// a bare `compactMap { Model(row: $0) }` (or `flatMap`), so a row that failed
/// typed decode vanished with no error and no log. They now route through
/// `PrimitiveRowDecoder`, which reports each dropped row with the model, the
/// row id, and the unreadable field(s). `find` / `findAll` keep throwing
/// `PrimitiveDecodeError` — those never dropped rows to begin with.
///
/// Source-structural: emits from a TOML string, no toolchain or server.
final class QueryDropDiagnosticHermeticTests: XCTestCase {

    private func emitNote() throws -> String {
        let toml = """
        [models.note]
        [models.note.fields.id]
        type = "id"
        [models.note.fields.title]
        type = "string"
        required = true
        """
        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        let emitter = SwiftEmitter(options: EmitOptions())
        return emitter.emit(schema: try XCTUnwrap(schemas.first))
    }

    func testMultiRowReadsRouteThroughTheReportingDecoder() throws {
        let body = try emitNote()
        XCTAssertFalse(
            body.contains(".compactMap { NoteRecord(row: $0) }"),
            "a bare compactMap drops undecodable rows silently"
        )
        XCTAssertEqual(
            body.components(separatedBy: "PrimitiveRowDecoder.decodeAll(").count - 1, 4,
            "query, query(include:) and both queryPaged overloads decode through PrimitiveRowDecoder"
        )
        XCTAssertTrue(
            body.contains("PrimitiveRowDecoder.decodeAll(rows, as: NoteRecord.self)"),
            "the decoder needs the model type to name the model and its fields"
        )
    }

    func testSingleRowReadsRouteThroughTheReportingDecoder() throws {
        let body = try emitNote()
        XCTAssertFalse(
            body.contains(".flatMap { NoteRecord(row: $0) }"),
            "a bare flatMap turns a drifted row into an indistinguishable nil"
        )
        XCTAssertEqual(
            body.components(separatedBy: "PrimitiveRowDecoder.decodeOne(").count - 1, 3,
            "findByUnique and both queryOne overloads decode through PrimitiveRowDecoder"
        )
    }

    /// The relationship accessors materialize typed rows the same way the
    /// query facade does — `refersTo` resolving to `nil`, or a `hasMany` leg
    /// coming back short, is the same invisible loss and reports the same way.
    func testRelationshipAccessorsAlsoRouteThroughTheReportingDecoder() throws {
        let toml = """
        [models.tasks]
        [models.tasks.fields.id]
        type = "id"
        [models.owner]
        [models.owner.fields.id]
        type = "id"
        [models.owner.fields.taskId]
        type = "string"
        [models.rel]
        [models.rel.fields.id]
        type = "id"
        [models.rel.fields.taskId]
        type = "string"
        [models.rel.relationships.task]
        type = "refersTo"
        model = "tasks"
        related_id_field = "taskId"
        [models.rel.relationships.owners]
        type = "hasMany"
        model = "owner"
        related_id_field = "taskId"
        [models.rel.relationships.viaJoin]
        type = "hasManyThrough"
        model = "owner"
        join_model = "tasks"
        join_model_local_field = "id"
        join_model_related_field = "id"
        """
        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        let emitter = SwiftEmitter(options: EmitOptions())
        let body = try XCTUnwrap(schemas.first { $0.swiftName == "RelRecord" }
            .map { emitter.emit(schema: $0) })

        XCTAssertFalse(body.contains(".compactMap { OwnerRecord(row: $0) }"),
                       "hasMany / hasManyThrough legs must report what they drop")
        XCTAssertFalse(body.contains(".flatMap { TasksRecord(row: $0) }"),
                       "a refersTo target that fails to decode must not read as 'no target'")
        XCTAssertTrue(body.contains("PrimitiveRowDecoder.decodeOne(row, as: TasksRecord.self)"))
        XCTAssertEqual(
            body.components(separatedBy: "PrimitiveRowDecoder.decodeAll(rows, as: OwnerRecord.self)").count - 1, 2,
            "hasMany and hasManyThrough both decode through PrimitiveRowDecoder"
        )
        XCTAssertTrue(body.contains("PrimitiveRowDecoder.decodeAll(page.data, as: OwnerRecord.self)"),
                      "the paginated hasManyThrough leg reports too")
    }

    /// The loud paths stay loud, and now name the field too: `find` /
    /// `findAll` throw an error built against the schema, so the thrown
    /// message reads the same as the logged one.
    func testFindPathsThrowDecodeErrorNamingTheField() throws {
        let body = try emitNote()
        XCTAssertTrue(
            body.contains("throw PrimitiveDecodeError(modelName: modelName, row: row, schema: primitiveSchema)"),
            "find/findAll keep throwing on a drifted row, naming the unreadable field"
        )
    }
}
