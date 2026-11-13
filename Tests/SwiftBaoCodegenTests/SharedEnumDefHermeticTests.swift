import Foundation
import XCTest
@testable import swift_bao_codegen

/// #5896 phase 1 — `swift-bao-codegen` keeps the def a field's shared-enum
/// `ref` named beside the expansion: `ParsedField.sharedEnum` holds the
/// def's `schemas/` file stem and name, and every other part of the parsed
/// field is the hand-expanded type's.
final class SharedEnumDefHermeticTests: XCTestCase {

    private static let common = """
        [defs.Status]
        type = "string"
        enum = ["open", "doing", "done"]
        """

    private static func workspace(_ status: String) -> String {
        """
        [type]
        name = "workspace"

        [models.tasks]
        class_name = "Task"

        [models.tasks.fields.title]
        type = "string"

        [models.tasks.fields.status]
        \(status)
        indexed = true
        """
    }

    private func parse(_ source: String, shared: SharedEnums?) throws -> ParsedSchema {
        let schemas = try TomlParser.parseAll(
            documents: [(sourceName: "workspace.toml", source: source)],
            sharedEnums: [shared],
            swiftNameSuffix: "Record"
        )
        return try XCTUnwrap(schemas.first)
    }

    func testEachRefFormRecordsTheDefBesideTheExpandedField() throws {
        let shared = SharedEnums(files: [("common", Self.common)], dir: "schemas/")
        let hand = try parse(Self.workspace(#"type = "string"\#nenum = ["open", "doing", "done"]"#), shared: nil)
        XCTAssertNil(hand.fields["status"]?.sharedEnum)
        for ref in ["Status", "common.Status", "schemas.common.Status"] {
            let parsed = try parse(Self.workspace("ref = \"\(ref)\""), shared: shared)
            let status = try XCTUnwrap(parsed.fields["status"])
            XCTAssertEqual(status.sharedEnum, SharedEnumRef(file: "common", name: "Status"), ref)
            XCTAssertNil(parsed.fields["title"]?.sharedEnum, ref)
            // Apart from the def, the field is the hand-expanded one.
            var withoutDef = status
            withoutDef.sharedEnum = nil
            XCTAssertEqual(withoutDef, hand.fields["status"], ref)
        }
    }
}
