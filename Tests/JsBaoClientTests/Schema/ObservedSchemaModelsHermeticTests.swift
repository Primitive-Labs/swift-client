import XCTest
@testable import JsBaoClient

/// The TOML exported from a document's observed schema
/// (`SwiftBaoCodegenTests/Fixtures/observed-schema-4624.toml`) loads at
/// runtime in strict mode, describing the models generated from it, and a
/// generated model reads a value that does not fit its type as missing,
/// never failing the record (#4624 behaviour 23).
final class ObservedSchemaModelsHermeticTests: XCTestCase {

    func testTheExportLoadsStrictAndAGeneratedModelReadsAMisfitAsMissing() throws {
        let toml = try ClientSourceText.packageFile("Tests/SwiftBaoCodegenTests/Fixtures/observed-schema-4624.toml")
        let schemas = try TomlSchemaLoader.load(tomlString: toml, strict: true)
        XCTAssertEqual(Set(schemas.map(\.name)), ["Mix", "Shelf", "any", "primitive_row", "tasks", "tasks_record"])
        let generated: [PrimitiveSchema] = [
            Mix.primitiveSchema, Shelf.primitiveSchema, AnyModel.primitiveSchema, PrimitiveRowModel.primitiveSchema,
            TasksRecord.primitiveSchema, TasksRecordModel.primitiveSchema,
        ]
        for schema in generated {
            let loaded = try XCTUnwrap(schemas.first { $0.name == schema.name }, schema.name)
            XCTAssertEqual(loaded.fields.mapValues(\.type), schema.fields.mapValues(\.type), schema.name)
        }

        let misfit = try XCTUnwrap(Mix(row: ["id": "m1", "mixed": 3, "n": 1, "at": true, "nothing": nil, "tags": ["a"], "Title": "t"]))
        XCTAssertNil(misfit.mixed)
        XCTAssertNil(misfit.n)
        XCTAssertNil(misfit.at)
        XCTAssertNil(misfit.nothing)
        XCTAssertEqual(misfit.tags, ["a"])
        XCTAssertEqual(misfit.Title, "t")
        let fitting = try XCTUnwrap(Mix(row: ["id": "m2", "mixed": "a", "n": "5"]))
        XCTAssertEqual(fitting.mixed, "a")
        XCTAssertEqual(fitting.n, "5")
    }
}
