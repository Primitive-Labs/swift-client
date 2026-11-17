import Foundation
import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` over a db3 type that renames a field (#6022 behavior
/// 38). Until generated models map renamed fields, codegen stops with an
/// error naming the field and the model when a field declares `storedAs`,
/// strict or not, so no build writes the current name over the socket. A
/// type without `storedAs` generates what it did.
///
/// Hermetic: `TomlParser` over in-memory documents.
final class StoredAsCodegenGuardHermeticTests: XCTestCase {

    private static func workspace(stored: Bool) -> String {
        """
        [type]
        name = "workspace"

        [models.tasks]
        class_name = "Task"

        [models.tasks.fields.title]
        type = "string"

        [models.tasks.fields.dueAt]
        type = "number"
        \(stored ? #"storedAs = "due""# : "")
        """
    }

    func testStoredAsStopsCodegenNamingTheField() {
        for strict in [true, false] {
            XCTAssertThrowsError(try TomlParser.parse(tomlString: Self.workspace(stored: true), swiftNameSuffix: "Record", strict: strict)) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("tasks"), message)
                XCTAssertTrue(message.contains("dueAt"), message)
                XCTAssertTrue(message.contains("storedAs"), message)
            }
        }
    }

    func testATypeWithoutStoredAsStillParses() throws {
        let schemas = try TomlParser.parse(tomlString: Self.workspace(stored: false), swiftNameSuffix: "Record", strict: true)
        XCTAssertEqual(schemas[0].fieldOrder.filter { $0 != "id" }, ["title", "dueAt"])
    }
}
