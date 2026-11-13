import Foundation
import XCTest
@testable import swift_bao_codegen

/// #5896 phase 4 — a generated model fills a field's literal `default` on
/// read where the stored record does not hold the field, as js-bao's getter
/// does on a db3 document.
///
/// `init?(record:)` asks the record (`PrimitiveRecord.holds(_:)`) and
/// `init?(row:)` the row (`PrimitiveRecord.holds(_:in:)`): each answers `false`
/// only where the document can tell a field never written from one cleared,
/// so a cleared field (stored `null`) and a Y.Map record read as they did. A
/// field with no literal default, a string set's array included, reads as it
/// did. `DefaultedFieldReadHermeticTests` runs the committed fixture model on
/// the real read paths.
final class ModelDefaultReadHermeticTests: XCTestCase {

    private func model(_ fields: String) throws -> String {
        let toml = "[type]\nname = \"board\"\n\n[models.cards]\nclass_name = \"CardRecord\"\n\n\(fields)"
        let files = try CodegenRun.render(
            documents: [(sourceName: "board.toml", source: toml)],
            sharedEnums: [SharedEnums(files: [("common", "[defs.Phase]\ntype = \"string\"\nenum = [\"open\", \"closed\"]\n")], dir: "schemas/")],
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        return try XCTUnwrap(files.first { $0.fileName == "CardRecord.swift" }?.source)
    }

    func testAnOptionalDefaultedFieldFallsBackToItsLiteralOnEachRead() throws {
        let source = try model("""
            [models.cards.fields.title]
            type = "string"
            default = "Untitled"

            [models.cards.fields.points]
            type = "number"
            default = 3

            [models.cards.fields.ratio]
            type = "number"
            default = 0.5

            [models.cards.fields.done]
            type = "boolean"
            default = false

            [models.cards.fields.phase]
            ref = "Phase"
            default = "open"
            """)
        XCTAssertTrue(source.contains("        self.title = record.holds(\"title\") == false ? \"Untitled\" : record[\"title\"]?.asString\n"), source)
        XCTAssertTrue(source.contains("        self.points = record.holds(\"points\") == false ? 3 : record[\"points\"]?.asNumber\n"), source)
        XCTAssertTrue(source.contains("        self.ratio = record.holds(\"ratio\") == false ? 0.5 : record[\"ratio\"]?.asNumber\n"), source)
        XCTAssertTrue(source.contains("        self.done = record.holds(\"done\") == false ? false : record[\"done\"]?.asBoolean\n"), source)
        XCTAssertTrue(source.contains("        self.phaseRaw = record.holds(\"phase\") == false ? \"open\" : record[\"phase\"]?.asString\n"), source)
        XCTAssertTrue(source.contains("        self.title = PrimitiveRecord.holds(\"title\", in: row) == false ? \"Untitled\" : row[\"title\"]?.stringValue\n"), source)
        XCTAssertTrue(source.contains("        self.points = PrimitiveRecord.holds(\"points\", in: row) == false ? 3 : row[\"points\"]?.numberValue\n"), source)
        XCTAssertTrue(source.contains("        self.done = PrimitiveRecord.holds(\"done\", in: row) == false ? false : row[\"done\"]?.rowBoolValue\n"), source)
        XCTAssertTrue(source.contains("        self.phaseRaw = PrimitiveRecord.holds(\"phase\", in: row) == false ? \"open\" : row[\"phase\"]?.stringValue\n"), source)
    }

    func testARequiredDefaultedFieldFillsInsideItsGuard() throws {
        let source = try model("[models.cards.fields.rank]\ntype = \"number\"\nrequired = true\ndefault = 1\n")
        XCTAssertTrue(source.contains("        guard let rank = record.holds(\"rank\") == false ? 1 : record[\"rank\"]?.asNumber\n"), source)
        XCTAssertTrue(source.contains("              let rank = PrimitiveRecord.holds(\"rank\", in: row) == false ? 1 : row[\"rank\"]?.numberValue\n"), source)
    }

    func testAFieldWithNoLiteralDefaultReadsAsBefore() throws {
        let source = try model("""
            [models.cards.fields.tags]
            type = "stringset"

            [models.cards.fields.note]
            type = "string"
            """)
        XCTAssertTrue(source.contains("        self.tags = record[\"tags\"]?.asStringSet\n"), source)
        XCTAssertTrue(source.contains("        self.note = record[\"note\"]?.asString\n"), source)
        XCTAssertTrue(source.contains("        self.tags = (row[\"tags\"]?.stringArrayValue).map(Set.init)\n"), source)
        XCTAssertFalse(source.contains(".holds("), source)
    }

    /// js-bao reads a string set through the getter that fills a scalar's
    /// default, so a db3 record without the field reads the default's members.
    /// The read fills it; the field descriptor still declares no default, so
    /// a create writes none, as before.
    func testAStringSetWithADefaultFallsBackToItsMembersOnEachRead() throws {
        let source = try model("""
            [models.cards.fields.tags]
            type = "stringset"
            default = ["a", "b \\"c\\""]
            """)
        XCTAssertTrue(source.contains("        self.tags = record.holds(\"tags\") == false ? Set([\"a\", \"b \\\"c\\\"\"]) : record[\"tags\"]?.asStringSet\n"), source)
        XCTAssertTrue(source.contains("        self.tags = PrimitiveRecord.holds(\"tags\", in: row) == false ? Set([\"a\", \"b \\\"c\\\"\"]) : (row[\"tags\"]?.stringArrayValue).map(Set.init)\n"), source)
        XCTAssertTrue(source.contains("\"tags\": FieldDescriptor(type: .stringset),\n"), source)
    }
}
