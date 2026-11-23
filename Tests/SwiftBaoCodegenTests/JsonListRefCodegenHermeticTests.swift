import Foundation
import XCTest
@testable import swift_bao_codegen

/// #6307 behavior 4 — Swift's `SharedEnums` gives a ref to a `schemas/` list
/// def js-bao's results and sentences (`tests/unit/workflows/db3-json-list-resolver-6307.test.ts`):
/// a list def, or a root-ref alias to one, resolves to the JSON def and the
/// field expands to a plain `type = "string"` field; a def that is none of the
/// three kinds is refused naming them.
final class JsonListRefCodegenHermeticTests: XCTestCase {

    private static let common = """
        [defs.Tags]
        type = "array"
        items = { type = "string" }

        [defs.Address]
        type = "object"
        [defs.Address.properties.city]
        type = "string"

        [defs.Count]
        type = "number"

        [defs.Plain]
        type = "string"

        [defs.Untyped]
        description = "Nothing."
        """

    private static let aliases = """
        [defs.Labels]
        "$ref" = "schemas:common#/$defs/Tags"
        description = "Labels on a post."

        [defs.MoreLabels]
        ref = "Labels"

        [defs.LoopA]
        "$ref" = "#/$defs/LoopB"

        [defs.LoopB]
        "$ref" = "#/$defs/LoopA"
        """

    private static let threeKinds = #"a db3 field refs a def with type = "string" and a non-empty enum of distinct strings, a def with type = "object", or a def with type = "array"."#

    private static func shop(_ field: String, typed: Bool = true) -> String {
        """
        \(typed ? "[type]\nname = \"shop\"\n" : "")
        [models.posts]
        class_name = "Post"

        [models.posts.fields.tags]
        \(field)
        """
    }

    private func resolver() -> SharedEnums {
        SharedEnums(files: [("common", Self.common), ("shop", Self.aliases)], dir: "schemas/", objects: true)
    }

    private func parse(_ toml: String, _ shared: SharedEnums) throws -> ParsedSchema {
        let schemas = try TomlParser.parseAll(documents: [(sourceName: "shop.toml", source: toml)], sharedEnums: [shared], swiftNameSuffix: "Record")
        return try XCTUnwrap(schemas.first { $0.name == "posts" })
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

    func testAListRefResolvesInEachSpellingToAPlainStringFieldNamingTheDef() throws {
        for ref in ["Tags", "common.Tags", "schemas.common.Tags"] {
            let field = try XCTUnwrap(try parse(Self.shop("ref = \"\(ref)\"\nrequired = true"), resolver()).fields["tags"], ref)
            XCTAssertEqual(field.type, .string, ref)
            XCTAssertTrue(field.required, ref)
            XCTAssertNil(field.enumValues, ref)
            XCTAssertEqual(field.json, Db3JSONRef(file: "common", name: "Tags"), ref)
        }
    }

    func testARootRefAliasToAListDefIsOne() throws {
        for name in ["Labels", "MoreLabels"] {
            XCTAssertEqual(try parse(Self.shop("ref = \"\(name)\""), resolver()).fields["tags"]?.json, Db3JSONRef(file: "shop", name: name), name)
        }
    }

    func testADefThatIsNoneOfTheThreeKindsIsRefusedNamingThem() {
        for (file, name, what) in [("common", "Count", #"type = "number""#), ("common", "Plain", "no enum"), ("common", "Untyped", "no type"), ("shop", "LoopA", "no type")] {
            XCTAssertEqual(failure(Self.shop("ref = \"\(name)\""), resolver()),
                           "[models.posts.fields.tags]: ref \"\(name)\": schemas/\(file).toml#\(name) is neither a shared enum, an object def nor a list def: it declares \(what); \(Self.threeKinds)")
        }
        XCTAssertEqual(failure(Self.shop(#"ref = "a.b.c.d""#), resolver()),
                       #"[models.posts.fields.tags]: ref "a.b.c.d": a db3 field refs only a shared enum, an object def or a list def in schemas/; write "<Name>", "<file>.<Name>" or "schemas.<file>.<Name>"."#)
    }

    func testSentencesBesideAListRefNameAnObjectOrListDef() {
        XCTAssertEqual(failure(Self.shop("ref = \"Tags\"\nmax_length = 10"), resolver()),
                       #"[models.posts.fields.tags]: ref "Tags": max_length cannot sit beside a ref to an object or list def: bound the value in the def (maxLength, maxItems) instead, so remove it."#)
        XCTAssertEqual(failure(Self.shop(#"ref = "Tags""#, typed: false), resolver()),
                       #"[models.posts.fields.tags]: ref "Tags": a ref to an object or list def belongs to a db3 type file, one with a [type] table; add [type] to the file, or declare the field type = "string"."#)
    }

    func testOneModelWhoseFieldRefsAListDefInOneFileAndAnObjectDefInTheOtherDiffers() {
        let shared = resolver()
        do {
            _ = try TomlParser.parseAll(
                documents: [(sourceName: "a.toml", source: Self.shop(#"ref = "Tags""#)), (sourceName: "b.toml", source: Self.shop(#"ref = "Address""#))],
                sharedEnums: [shared, shared], swiftNameSuffix: "Record")
            XCTFail("expected a refusal")
        } catch let error as CodegenError {
            XCTAssertTrue(error.description.contains("field `tags` differs"), error.description)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAResolverThatDoesNotAskForObjectDefsRefusesAListDefAsNotASharedEnum() {
        let shared = SharedEnums(files: [("common", Self.common)], dir: "schemas/")
        XCTAssertEqual(failure(Self.shop(#"ref = "Tags""#), shared),
                       #"[models.posts.fields.tags]: ref "Tags": schemas/common.toml#Tags is not a shared enum: it declares type = "array"; a db3 field refs only a def with type = "string" and a non-empty enum of distinct strings."#)
    }
}
