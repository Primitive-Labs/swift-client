import Foundation
import XCTest
@testable import JsBaoClient

/// #6021 — `TomlSchemaLoader` over a db3 type file that retires fields.
///
/// `deprecated` and `cleared` are known field keys and `removedFields` a known
/// model key in strict mode, as in js-bao's loader and `swift-bao-codegen`, so
/// a bundled type file that uses them still loads. A deprecated field stays in
/// the schema; a cleared field and a tombstoned name are not fields of it.
final class TomlSchemaLoaderFieldLifecycleHermeticTests: XCTestCase {

    private static let typeFile = """
        [type]
        name = "workspace"

        [models.tasks]
        removedFields = ["veryOld"]

        [models.tasks.fields.title]
        type = "string"

        [models.tasks.fields.legacyNotes]
        type = "string"
        deprecated = true

        [models.tasks.fields.oldScore]
        type = "number"
        deprecated = true
        cleared = true
        """

    func testStrictLoadTakesTheKeys() throws {
        let schemas = try TomlSchemaLoader.load(tomlString: Self.typeFile)
        XCTAssertEqual(schemas.map(\.name), ["tasks"])
    }

    /// A single-field constraint over a cleared field goes with the field, as
    /// the room's install drops it; one over live fields stays.
    func testASingleFieldConstraintOverAClearedFieldGoesWithIt() throws {
        let source = Self.typeFile + """


            [[models.tasks.unique_constraints]]
            name = "score_once"
            fields = ["oldScore"]

            [[models.tasks.unique_constraints]]
            name = "title_once"
            fields = ["title"]
            """
        let tasks = try XCTUnwrap(try TomlSchemaLoader.load(tomlString: source).first)
        XCTAssertEqual(Array(tasks.constraints.keys), ["title_once"])
        XCTAssertNil(tasks.fields["oldScore"])
    }

    func testADeprecatedFieldStaysAndAClearedOneIsNoField() throws {
        let tasks = try XCTUnwrap(try TomlSchemaLoader.load(tomlString: Self.typeFile).first)
        XCTAssertNotNil(tasks.fields["legacyNotes"])
        XCTAssertNil(tasks.fields["oldScore"])
        XCTAssertNil(tasks.fields["veryOld"])
    }
}
