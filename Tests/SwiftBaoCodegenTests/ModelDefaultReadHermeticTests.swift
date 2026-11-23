import Foundation
import XCTest
@testable import swift_bao_codegen

/// #6304 phase 2 — a generated model types a read-defaulted field (a
/// `string`, `number`, `boolean`, `date` or `id` field whose `default` is a
/// literal of its type) non-optional and reads its default wherever the
/// stored record has no value of the field's kind: missing, `null`, or of
/// another kind, judged on the stored kind (`fittingValue`).
///
/// - `init?(record:)` and `init?(row:)` do not build a record whose db3's held
///   revision clears such a field (`isCleared`): a non-optional property
///   cannot read as unset.
/// - `init(from:)` decodes a missing, `null` or wrongly typed value to the
///   default and does not throw.
/// - Both initializers keep an optional parameter that stores the default
///   when omitted or `nil`; a default the model supplied (an omitted
///   parameter, a decoded value it filled) is not a pending change.
/// - A field with no default, a generator default, a string set's default and
///   a JSON field read as before (#5896): a string set the record does not
///   hold still reads its default's members, and stays optional.
///
/// `ReadDefaultedModelReadHermeticTests` and `DefaultedFieldReadHermeticTests`
/// run the committed fixture models on the real read paths.
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

    private static let defaulted = """
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

        [models.cards.fields.due]
        type = "date"
        default = "2026-01-01"

        [models.cards.fields.phase]
        ref = "Phase"
        default = "open"
        """

    func testAReadDefaultedFieldIsStoredNonOptional() throws {
        let source = try model(Self.defaulted)
        for line in [
            "    public var title: String {\n", "    public var points: Double {\n", "    public var ratio: Double {\n",
            "    public var done: Bool {\n", "    public var due: String {\n", "    public private(set) var phaseRaw: String {\n",
        ] {
            XCTAssertTrue(source.contains(line), "\(line)\n\(source)")
        }
    }

    /// Behavior 28: a shared-enum field's raw string is non-optional; its
    /// typed accessor stays optional and reads the default's case.
    func testASharedEnumFieldWithADefaultHasANonOptionalRawStringAndAnOptionalAccessor() throws {
        let source = try model(Self.defaulted)
        XCTAssertTrue(source.contains("    public var phase: Phase? {\n        get { .init(rawValue: phaseRaw) }\n        set { if let newValue { phaseRaw = newValue.rawValue } }\n    }\n"), source)
    }

    func testTheRecordAndRowInitializersFillTheDefaultAndRefuseAHeldClear() throws {
        let source = try model(Self.defaulted)
        XCTAssertTrue(source.contains("        guard !record.isCleared(\"title\"),\n              !record.isCleared(\"points\"),\n"), source)
        XCTAssertTrue(source.contains("              !record.isCleared(\"phase\")\n        else { return nil }\n"), source)
        for line in [
            "        let _title = record.fittingValue(\"title\", as: .string)?.asString\n",
            "        let _points = record.fittingValue(\"points\", as: .number)?.asNumber\n",
            "        let _done = record.fittingValue(\"done\", as: .boolean)?.asBoolean\n",
            "        let _due = record.fittingValue(\"due\", as: .date)?.asString\n",
            "        let _phaseRaw = record.fittingValue(\"phase\", as: .string)?.asString\n",
            "        let _points = PrimitiveRecord.fittingValue(\"points\", as: .number, in: row)?.asNumber\n",
            "        let _done = PrimitiveRecord.fittingValue(\"done\", as: .boolean, in: row)?.asBoolean\n",
            "        let _phaseRaw = PrimitiveRecord.fittingValue(\"phase\", as: .string, in: row)?.asString\n",
            "        guard let id = row[\"id\"]?.stringValue,\n              !PrimitiveRecord.isCleared(\"title\", in: row),\n",
        ] {
            XCTAssertTrue(source.contains(line), "\(line)\n\(source)")
        }
        // Each read of a record and of a row fills the default where the
        // record has no value of the field's kind, and records it supplied it.
        for (line, count) in [
            ("        self.title = _title ?? \"Untitled\"\n", 3),
            ("        self.points = _points ?? 3\n", 3),
            ("        self.ratio = _ratio ?? 0.5\n", 3),
            ("        self.done = _done ?? false\n", 3),
            ("        self.due = _due ?? \"2026-01-01T00:00:00.000Z\"\n", 3),
            ("        self.phaseRaw = _phaseRaw ?? \"open\"\n", 3),
            ("        if _points == nil { _suppliedDefaults.insert(\"points\") }\n", 3),
            ("        if _phaseRaw == nil { _suppliedDefaults.insert(\"phase\") }\n", 3),
        ] {
            XCTAssertEqual(source.components(separatedBy: line).count - 1, count, "\(line)\n\(source)")
        }
        XCTAssertFalse(source.contains(".holds("), source)
    }

    func testDecodingFillsTheDefaultAndLeavesASuppliedDefaultUnchanged() throws {
        let source = try model(Self.defaulted)
        XCTAssertTrue(source.contains("        let _points = container.fittingValue(forKey: .points, as: .number)?.asNumber\n"), source)
        XCTAssertTrue(source.contains("        let _phaseRaw = container.fittingValue(forKey: .phaseRaw, as: .string)?.asString\n"), source)
        XCTAssertFalse(source.contains("decodeIfPresent(Double.self, forKey: .points)"), source)
        XCTAssertEqual(source.components(separatedBy: "        self._changedFields = Set(primitiveValues().keys).subtracting(_suppliedDefaults)\n").count - 1, 3,
                       "the two initializers and init(from:) leave a supplied default unchanged\n\(source)")
    }

    /// A supplied default is in no write's values; assigning the field, or
    /// `markAllChanged()`, makes the value the caller's.
    func testASuppliedDefaultIsLeftOutOfTheValuesAWriteSends() throws {
        let source = try model(Self.defaulted)
        XCTAssertTrue(source.contains("    public private(set) var _suppliedDefaults: Set<String> = []\n"), source)
        XCTAssertTrue(source.contains("        if !_suppliedDefaults.contains(\"points\") { values[\"points\"] = .number(points) }\n"), source)
        XCTAssertTrue(source.contains("        if !_suppliedDefaults.contains(\"phase\") { values[\"phase\"] = .string(phaseRaw) }\n"), source)
        XCTAssertTrue(source.contains("        didSet { _changedFields.insert(\"points\"); _suppliedDefaults.remove(\"points\") }\n"), source)
        XCTAssertTrue(source.contains("        didSet { _changedFields.insert(\"phase\"); _suppliedDefaults.remove(\"phase\") }\n"), source)
        XCTAssertTrue(source.contains("    public mutating func markAllChanged() {\n        _suppliedDefaults = []\n        _changedFields = Set(primitiveValues().keys)\n    }\n"), source)
    }

    func testTheInitializersTakeAnOptionalParameterAndStoreTheDefault() throws {
        let source = try model(Self.defaulted)
        XCTAssertTrue(source.contains("        points: Double? = nil,\n"), source)
        XCTAssertTrue(source.contains("        phase: Phase? = nil\n"), source)
        XCTAssertEqual(source.components(separatedBy: "        self.points = points ?? 3\n").count - 1, 2, source)
        XCTAssertEqual(source.components(separatedBy: "        self.phaseRaw = phase?.rawValue ?? \"open\"\n").count - 1, 2, source)
        XCTAssertEqual(source.components(separatedBy: "        if points == nil { _suppliedDefaults.insert(\"points\") }\n").count - 1, 2, source)
        XCTAssertEqual(source.components(separatedBy: "        if phase == nil { _suppliedDefaults.insert(\"phase\") }\n").count - 1, 2, source)
    }

    /// Edge case E4: a required field with a default keeps its type and
    /// parameter, reads its default, and is refused only by a held clear.
    func testARequiredDefaultedFieldKeepsItsTypeAndFillsItsDefault() throws {
        let source = try model("[models.cards.fields.rank]\ntype = \"number\"\nrequired = true\ndefault = 1\n")
        XCTAssertTrue(source.contains("    public var rank: Double {\n"), source)
        XCTAssertTrue(source.contains("        rank: Double\n"), source)
        XCTAssertTrue(source.contains("        guard !record.isCleared(\"rank\")\n        else { return nil }\n"), source)
        XCTAssertTrue(source.contains("        self.rank = _rank ?? 1\n"), source)
        XCTAssertTrue(source.contains("        let _rank = container.fittingValue(forKey: .rank, as: .number)?.asNumber\n"), source)
        XCTAssertFalse(source.contains("if rank == nil"), "a required parameter is never omitted\n\(source)")
    }

    func testAFieldThatIsNotReadDefaultedReadsAsBefore() throws {
        let source = try model("""
            [models.cards.fields.tags]
            type = "stringset"

            [models.cards.fields.note]
            type = "string"

            [models.cards.fields.made]
            type = "date"
            default = "$now"

            [models.cards.fields.slug]
            type = "string"
            default = "$generate_ulid"
            """)
        XCTAssertTrue(source.contains("    public var note: String? {\n"), source)
        XCTAssertTrue(source.contains("    public var made: String? {\n"), "a generator default is not read-defaulted\n\(source)")
        XCTAssertTrue(source.contains("    public var slug: String? {\n"), source)
        XCTAssertTrue(source.contains("        self.tags = record[\"tags\"]?.asStringSet\n"), source)
        XCTAssertTrue(source.contains("        self.note = record[\"note\"]?.asString\n"), source)
        XCTAssertTrue(source.contains("        self.made = record[\"made\"]?.asDateString\n"), source)
        XCTAssertTrue(source.contains("        self.tags = (row[\"tags\"]?.stringArrayValue).map(Set.init)\n"), source)
        XCTAssertTrue(source.contains("        self.made = try container.decodeIfPresent(String.self, forKey: .made)\n"), source)
        XCTAssertFalse(source.contains(".holds("), source)
        XCTAssertFalse(source.contains("isCleared"), source)
        XCTAssertFalse(source.contains("fittingValue"), source)
    }

    /// An escaped `$$` default is not read-defaulted: a server create on a
    /// db3 stores one `$` fewer than a client create, so no read fills it and
    /// the field stays optional, as on the web and the db3 (#6304, E2).
    func testAnEscapedDollarDefaultIsNotReadDefaulted() throws {
        let source = try model("[models.cards.fields.price]\ntype = \"string\"\ndefault = \"$$5\"\n")
        XCTAssertTrue(source.contains("    public var price: String? {\n"), source)
        XCTAssertFalse(source.contains("fittingValue"), source)
    }

    /// js-bao reads a string set through the getter that fills a scalar's
    /// default, so a db3 record without the field reads the default's members.
    /// The read fills it; the field descriptor declares no default, so a create
    /// writes none, and marks the set `defaultOnRead` so a save counts it as
    /// present (#5896, CSO-5896-019). It stays optional (#6304).
    func testAStringSetWithADefaultFallsBackToItsMembersOnEachRead() throws {
        let source = try model("""
            [models.cards.fields.tags]
            type = "stringset"
            default = ["a", "b \\"c\\""]
            """)
        XCTAssertTrue(source.contains("    public var tags: Set<String>? {\n"), source)
        XCTAssertTrue(source.contains("        self.tags = record.holds(\"tags\") == false ? Set([\"a\", \"b \\\"c\\\"\"]) : record[\"tags\"]?.asStringSet\n"), source)
        XCTAssertTrue(source.contains("        self.tags = PrimitiveRecord.holds(\"tags\", in: row) == false ? Set([\"a\", \"b \\\"c\\\"\"]) : (row[\"tags\"]?.stringArrayValue).map(Set.init)\n"), source)
        XCTAssertTrue(source.contains("\"tags\": FieldDescriptor(type: .stringset, defaultOnRead: true),\n"), source)
    }
}
