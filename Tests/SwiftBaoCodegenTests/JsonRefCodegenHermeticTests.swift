import Foundation
import XCTest
@testable import swift_bao_codegen

/// #5899 behavior 25 — `swift-bao-codegen` over a db3 field whose `ref` names
/// a `schemas/` object def.
///
/// Asked for object defs (the tool's own inputs are), `SharedEnums` resolves
/// such a ref in the shared enum's three spellings, under its ambiguity rules,
/// to the def's id, and expands the field to a plain `type = "string"` field
/// with `required` kept and the def named beside it. Every refusal is js-bao's
/// sentence (`packages/js-bao/src/models/sharedEnums.ts`, and the CLI's for a
/// unique constraint and a file with no `[type]` table), over the cases of
/// `tests/unit/workflows/db3-json-ref-resolver-5899.test.ts`.
final class JsonRefCodegenHermeticTests: XCTestCase {

    private static let common = """
        [defs.Status]
        type = "string"
        enum = ["open", "done"]

        [defs.Address]
        type = "object"
        description = "Where an order ships."
        [defs.Address.properties.city]
        type = "string"

        [defs.Money]
        [defs.Money.fields.amount]
        type = "number"
        required = true

        [defs.Tags]
        type = "array"
        items = { type = "string" }

        [defs.Count]
        type = "number"

        [defs.Plain]
        type = "string"
        """

    private static let aliases = """
        [defs.ShippingAddress]
        "$ref" = "#/$defs/Address"
        description = "Where this order ships."

        [defs.ByRef]
        ref = "common.Address"

        [defs.ByBareRef]
        ref = "Money"

        [defs.Chained]
        "$ref" = "#/$defs/ShippingAddress"

        [defs.Address]
        type = "object"
        [defs.Address.properties.city]
        type = "string"

        [defs.Money]
        [defs.Money.fields.amount]
        type = "number"

        [defs.Kind]
        type = "string"
        enum = ["a", "b"]

        [defs.ToEnum]
        "$ref" = "#/$defs/Kind"

        [defs.ToMissing]
        "$ref" = "#/$defs/Nowhere"

        [defs.LoopA]
        "$ref" = "#/$defs/LoopB"

        [defs.LoopB]
        "$ref" = "#/$defs/LoopA"

        [defs.Nullable]
        "$ref" = "#/$defs/Address"
        nullable = true
        """

    private static func shop(_ field: String, typed: Bool = true, extra: String = "") -> String {
        """
        \(typed ? "[type]\nname = \"shop\"\n" : "")
        [models.orders]
        class_name = "Order"

        [models.orders.fields.title]
        type = "string"

        [models.orders.fields.shipping]
        \(field)
        \(extra)
        """
    }

    private static let noKeys = (db3: [String](), function: [String](), prompt: [String]())

    private func objects(_ files: [(String, String)], keys: (db3: [String], function: [String], prompt: [String]) = noKeys) -> SharedEnums {
        SharedEnums(files: files, dir: "schemas/", db3: keys.db3, function: keys.function, prompt: keys.prompt, objects: true)
    }

    private func parse(_ toml: String, _ shared: SharedEnums) throws -> ParsedSchema {
        let schemas = try TomlParser.parseAll(documents: [(sourceName: "shop.toml", source: toml)], sharedEnums: [shared], swiftNameSuffix: "Record")
        return try XCTUnwrap(schemas.first { $0.name == "orders" })
    }

    private func failure(_ toml: String, _ shared: SharedEnums, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try parse(toml, shared)
            XCTFail("expected a refusal", file: file, line: line)
            return ""
        } catch let error as CodegenError {
            return error.description
        } catch {
            XCTFail("expected a CodegenError, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - Behaviors 1 and 2

    func testAnObjectRefResolvesInEachSpellingToAPlainStringFieldNamingTheDef() throws {
        for ref in ["Address", "common.Address", "schemas.common.Address"] {
            let schema = try parse(Self.shop("ref = \"\(ref)\"\nrequired = true"), objects([("common", Self.common)]))
            let field = try XCTUnwrap(schema.fields["shipping"], ref)
            XCTAssertEqual(field.type, .string, ref)
            XCTAssertTrue(field.required, ref)
            XCTAssertNil(field.enumValues, ref)
            XCTAssertNil(field.sharedEnum, ref)
            XCTAssertEqual(field.json, Db3JSONRef(file: "common", name: "Address"), ref)
            XCTAssertEqual(field.json?.id, "schemas.common.Address", ref)
            XCTAssertNil(schema.fields["title"]?.json)
        }
    }

    func testAFieldTableDefIsAnObjectDefAndASharedEnumStillExpands() throws {
        let shared = objects([("common", Self.common)])
        XCTAssertEqual(try parse(Self.shop(#"ref = "Money""#), shared).fields["shipping"]?.json, Db3JSONRef(file: "common", name: "Money"))
        let status = try XCTUnwrap(try parse(Self.shop(#"ref = "Status""#), shared).fields["shipping"])
        XCTAssertEqual(status.enumValues, ["open", "done"])
        XCTAssertEqual(status.sharedEnum, SharedEnumRef(file: "common", name: "Status"))
        XCTAssertNil(status.json)
    }

    func testADefWhoseRootRefsAnObjectDefIsOne() throws {
        let shared = objects([("common", "[defs.Address]\ntype = \"object\"\n"), ("shop", Self.aliases)])
        for (ref, name) in [("ShippingAddress", "ShippingAddress"), ("shop.ByRef", "ByRef"), ("ByBareRef", "ByBareRef"), ("Chained", "Chained")] {
            XCTAssertEqual(try parse(Self.shop("ref = \"\(ref)\""), shared).fields["shipping"]?.json, Db3JSONRef(file: "shop", name: name), ref)
        }
        let cross = objects([("common", "[defs.Address]\ntype = \"object\"\n"), ("shop", "[defs.Ship]\n\"$ref\" = \"schemas:common#/$defs/Address\"\n")])
        XCTAssertEqual(try parse(Self.shop(#"ref = "Ship""#), cross).fields["shipping"]?.json, Db3JSONRef(file: "shop", name: "Ship"))
        for name in ["ToEnum", "ToMissing", "LoopA", "Nullable"] {
            XCTAssertTrue(failure(Self.shop("ref = \"\(name)\""), shared).hasPrefix(
                "[models.orders.fields.shipping]: ref \"\(name)\": schemas/shop.toml#\(name) is neither a shared enum, an object def nor a list def: it declares no type;"), name)
        }
    }

    func testTheEnumsAmbiguityRulesHoldAndAMalformedRefNamesBothKinds() {
        let shared = objects([("common", Self.common), ("billing", "[defs.Address]\ntype = \"object\"\n")], keys: (db3: ["billing"], function: [], prompt: []))
        let prefix = { (ref: String) in "[models.orders.fields.shipping]: ref \"\(ref)\": " }
        XCTAssertEqual(failure(Self.shop(#"ref = "Address""#), shared),
                       prefix("Address") + "more than one schemas/ file declares Address; use a long form: schemas.billing.Address, schemas.common.Address.")
        XCTAssertEqual(failure(Self.shop(#"ref = "billing.Address""#), shared),
                       prefix("billing.Address") + "billing is a key in more than one family; use a long form: db3.billing.Address, schemas.billing.Address.")
        XCTAssertEqual(failure(Self.shop(#"ref = "a.b.c.d""#), shared),
                       prefix("a.b.c.d") + #"a db3 field refs only a shared enum, an object def or a list def in schemas/; write "<Name>", "<file>.<Name>" or "schemas.<file>.<Name>"."#)
        XCTAssertEqual(failure(Self.shop(#"ref = "shared.Address""#), shared),
                       prefix("shared.Address") + #"there is no schemas/shared.toml; a db3 field refs only a shared enum, an object def or a list def in schemas/, so fix the file name or write "schemas.<file>.Address"."#)
        XCTAssertEqual(failure(Self.shop(#"ref = "platform.Address""#), shared),
                       prefix("platform.Address") + #"the platform prefix is reserved; name a shared enum, an object def or a list def in schemas/ as "schemas.<file>.<Name>"."#)
        XCTAssertEqual(failure(Self.shop(#"ref = "common.Address#row""#), shared),
                       prefix("common.Address#row") + "a projection (#row) applies to a db3 model ref and a shared enum, an object def or a list def has none; drop the suffix.")
    }

    // MARK: - Behavior 3

    func testOnlyRequiredMaySitBesideAnObjectRef() {
        let shared = objects([("common", Self.common)])
        let cases: [(String, String)] = [
            (#"type = "string""#, "type cannot sit beside a ref to an object or list def: the field is stored as JSON text in a string field, so remove it."),
            (#"enum = ["a"]"#, "enum cannot sit beside a ref to an object or list def: the def declares the value's shape, so remove it."),
            ("indexed = true", "indexed cannot sit beside a ref to an object or list def: an index on JSON text neither orders nor matches the values inside it, so remove it."),
            ("unique = true", "unique cannot sit beside a ref to an object or list def: uniqueness of JSON text is not uniqueness of the values inside it, so remove it."),
            (#"default = "{}""#, "default cannot sit beside a ref to an object or list def: a JSON field has no default, so remove it."),
            ("max_length = 10", "max_length cannot sit beside a ref to an object or list def: bound the value in the def (maxLength, maxItems) instead, so remove it."),
            ("max_count = 10", "max_count cannot sit beside a ref to an object or list def: it bounds a stringset field, so remove it."),
            (#"auto_assign = "ulid""#, "auto_assign cannot sit beside a ref to an object or list def: the client writes a JSON field's value, so remove it."),
            (#"auto_stamp = "create""#, "auto_stamp cannot sit beside a ref to an object or list def: the client writes a JSON field's value, so remove it."),
            ("dims = 3", "dims cannot sit beside a ref to an object or list def: it shapes a vector field, so remove it."),
            (#"element = "f32""#, "element cannot sit beside a ref to an object or list def: it shapes a vector field, so remove it."),
            (#"colour = "red""#, "colour cannot sit beside a ref to an object or list def: only required may, so remove it."),
        ]
        for (extra, sentence) in cases {
            XCTAssertEqual(failure(Self.shop(#"ref = "Address""#, extra: extra), shared),
                           "[models.orders.fields.shipping]: ref \"Address\": \(sentence)", extra)
        }
        // Beside a ref to a shared enum, type and enum keep today's sentence.
        XCTAssertEqual(failure(Self.shop("ref = \"Status\"\ntype = \"string\""), shared),
                       #"[models.orders.fields.shipping]: ref "Status": type cannot sit beside ref; the shared enum supplies it, so remove it."#)
    }

    func testAUniqueConstraintNamingAJSONFieldIsRefused() {
        let toml = Self.shop(#"ref = "Address""#) + "\n\n[[models.orders.unique_constraints]]\nname = \"pair\"\nfields = [\"title\", \"shipping\"]\n"
        XCTAssertEqual(failure(toml, objects([("common", Self.common)])),
                       #"[[models.orders.unique_constraints]] "pair" names shipping, a JSON field (ref "Address"): uniqueness of JSON text is not uniqueness of the values inside it, so remove the field from the constraint."#)
    }

    // MARK: - Behavior 4

    func testADefThatIsNeitherKindIsRefusedNamingBoth() {
        let shared = objects([("common", Self.common)])
        // #6307 — a list def (`Tags`) is a JSON field now; see JsonListRefCodegenHermeticTests.
        for (name, what) in [("Count", #"type = "number""#), ("Plain", "no enum")] {
            XCTAssertEqual(failure(Self.shop("ref = \"\(name)\""), shared),
                           "[models.orders.fields.shipping]: ref \"\(name)\": schemas/common.toml#\(name) is neither a shared enum, an object def nor a list def: it declares \(what); "
                           + #"a db3 field refs a def with type = "string" and a non-empty enum of distinct strings, a def with type = "object", or a def with type = "array"."#)
        }
    }

    // MARK: - Behavior 5

    func testAnObjectRefInAFileWithNoTypeTableIsRefused() {
        XCTAssertEqual(failure(Self.shop(#"ref = "Address""#, typed: false), objects([("common", Self.common)])),
                       #"[models.orders.fields.shipping]: ref "Address": a ref to an object or list def belongs to a db3 type file, one with a [type] table; add [type] to the file, or declare the field type = "string"."#)
        // A shared enum ref is still read there, as it always was.
        XCTAssertNoThrow(try parse(Self.shop(#"ref = "Status""#, typed: false), objects([("common", Self.common)])))
    }

    // MARK: - Behavior 14 (pin) and the tool's own inputs

    func testAResolverThatDoesNotAskForObjectDefsKeepsTodaysSentence() {
        let shared = SharedEnums(files: [("common", Self.common)], dir: "schemas/")
        XCTAssertEqual(failure(Self.shop(#"ref = "Address""#), shared),
                       #"[models.orders.fields.shipping]: ref "Address": schemas/common.toml#Address is not a shared enum: it declares type = "object"; a db3 field refs only a def with type = "string" and a non-empty enum of distinct strings."#)
    }

    func testTheToolsInputsAskForObjectDefs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "swift-bao-5899-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (path, text) in [("schemas/common.toml", Self.common), ("db3-types/shop.toml", Self.shop(#"ref = "Address""#))] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let inputs = try CodegenInputs.read(try CodegenInputs.expand([root.appending(path: "db3-types").path]))
        let schemas = try TomlParser.parseAll(
            documents: inputs.map { (sourceName: $0.sourceName, source: $0.source) },
            sharedEnums: CodegenInputs.sharedEnumFiles(for: inputs),
            swiftNameSuffix: "Record"
        )
        XCTAssertEqual(schemas.first?.fields["shipping"]?.json, Db3JSONRef(file: "common", name: "Address"))
    }

    func testTwoDeclarationsOfOneModelThatRefDifferentDefsDiffer() {
        let shared = objects([("common", Self.common)])
        do {
            _ = try TomlParser.parseAll(
                documents: [(sourceName: "a.toml", source: Self.shop(#"ref = "Address""#)), (sourceName: "b.toml", source: Self.shop(#"ref = "Money""#))],
                sharedEnums: [shared, shared], swiftNameSuffix: "Record")
            XCTFail("expected a refusal")
        } catch let error as CodegenError {
            XCTAssertTrue(error.description.contains("field `shipping` differs"), error.description)
        } catch {
            XCTFail("\(error)")
        }
    }
}
