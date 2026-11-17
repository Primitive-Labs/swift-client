import XCTest
@testable import JsBaoClient

/// #5899 behavior 28 — the Swift client's half of a db3 JSON field's stored
/// form: its canonical encoder and its validator.
///
/// `Fixtures/Db3Json/conformance.json` is a copy of the fixture js-bao, the
/// functions SDK and the server's validator are tested against
/// (`tests/fixtures/db3-json/conformance.json`); the two copies are held
/// equal here. Every `canonical` case gives the fixture's exact text or its
/// kind of refusal, and every `validation` case its verdict and first path.
/// A JSON file cannot hold 2^53 + 1 exactly, so the integer cases are built
/// here from Swift `Int` values: an integer is checked as an integer before
/// any conversion to `Double`, so ±(2^53 + 1) is refused, never rounded.
final class Db3JsonHermeticTests: XCTestCase {

    private static let fixtureURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/Db3Json/conformance.json")
    }()

    private static let sharedFixtureURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("tests/fixtures/db3-json/conformance.json")
    }()

    /// The fixture, lone surrogates read as U+FFFD with their paths kept: a
    /// Swift `String` cannot hold one.
    private func fixture() throws -> (node: Db3JSONNode, loneSurrogates: [String]) {
        try Db3JSONParser.parse(String(contentsOf: Self.fixtureURL, encoding: .utf8), substitutingLoneSurrogates: true)
    }

    private func cases(_ section: String) throws -> [(index: Int, name: String, node: Db3JSONNode)] {
        let items = try XCTUnwrap(fixture().node[section]?.array, section)
        return items.enumerated().map { ($0.offset, $0.element["name"]?.string ?? "", $0.element) }
    }

    /// The canonical text of a parsed value, through the encoder a model's value goes through.
    private func canonical(_ node: Db3JSONNode) throws -> String {
        Db3JSONCanonical.text(try Db3JSONTreeEncoder.encode(node))
    }

    func testTheSwiftCopyOfTheFixtureIsTheSharedFixture() throws {
        XCTAssertEqual(try Data(contentsOf: Self.fixtureURL), try Data(contentsOf: Self.sharedFixtureURL),
                       "copy tests/fixtures/db3-json/conformance.json into Fixtures/Db3Json/")
    }

    func testEveryCanonicalCaseGivesTheFixturesTextOrRefusal() throws {
        let surrogates = try fixture().loneSurrogates
        let canonicalCases = try cases("canonical")
        XCTAssertGreaterThanOrEqual(canonicalCases.count, 17)
        for (index, name, node) in canonicalCases {
            let value = try XCTUnwrap(node["value"], name)
            if let text = node["text"]?.string {
                XCTAssertEqual(try canonical(value), text, name)
                continue
            }
            let kind = try XCTUnwrap(node["refused"]?.string, name)
            if kind == "surrogate" {
                // The one door a lone surrogate can reach in Swift is JSON text.
                XCTAssertTrue(surrogates.contains { $0.hasPrefix("value.canonical[\(index)].value") }, name)
                XCTAssertThrowsError(try Db3JSONParser.parse(#"{"s":"\ud800"}"#), name) { error in
                    XCTAssertEqual(error as? Db3JSONRefusal, Db3JSONRefusal(
                        kind: .surrogate, path: "value.s", reason: "value.s holds a lone surrogate, which JSON text cannot carry"))
                }
                continue
            }
            XCTAssertThrowsError(try canonical(value), name) { error in
                XCTAssertEqual((error as? Db3JSONRefusal)?.kind.rawValue, kind, name)
            }
        }
    }

    func testEveryValidationCaseGivesTheFixturesVerdictAndPath() throws {
        let validationCases = try cases("validation")
        XCTAssertGreaterThanOrEqual(validationCases.count, 29)
        for (_, name, node) in validationCases {
            let schema = try XCTUnwrap(node["schema"], name)
            let value = try XCTUnwrap(node["value"], name)
            let issues = Db3JSONValidator.validate(schema: schema, value: value)
            if node["valid"] == .bool(true) {
                XCTAssertEqual(issues, [], name)
            } else {
                XCTAssertEqual(issues.first?.path, node["path"]?.string, name)
            }
        }
    }

    func testMessagesAreJsBaosSentences() throws {
        let schema = try Db3JSONParser.parse("""
        {"type":"object","properties":{"city":{"type":"string","minLength":1,"maxLength":3},"floor":{"type":"integer","minimum":-5,"maximum":2.5},\
        "zip":{"type":"string","pattern":"^[0-9]+$"},"size":{"enum":["s","m"]},"tags":{"type":"array","minItems":1,"maxItems":2}},\
        "required":["city"],"additionalProperties":false}
        """)
        let check = { (value: String) in Db3JSONValidator.validate(schema: schema, value: try Db3JSONParser.parse(value)).map(\.message) }
        XCTAssertEqual(try check(#"{"floor":-6}"#), ["value.city is required", "value.floor must be >= -5"])
        XCTAssertEqual(try check(#"{"city":"Faro","floor":3}"#), ["value.city must be at most 3 characters", "value.floor must be <= 2.5"])
        XCTAssertEqual(try check(#"{"city":"","zip":"x1"}"#), ["value.city must be at least 1 characters", "value.zip must match the pattern ^[0-9]+$"])
        XCTAssertEqual(try check(#"{"city":"a","size":"xl","tags":[]}"#), ["value.size must be one of s, m", "value.tags must have at least 1 items"])
        XCTAssertEqual(try check(#"{"city":"a","tags":[1,2,3],"extra":1}"#), ["value.tags must have at most 2 items", "value.extra is not allowed"])
        XCTAssertEqual(try check(#"{"city":7}"#), ["value.city must be string"])
        XCTAssertEqual(try check(#"[1]"#), ["value must be object"])
    }

    // MARK: - Swift sources

    private struct Counter: Codable, Equatable { var n: Int }
    private struct Nested: Codable, Equatable { var inner: Counter; var list: [Int] }
    private struct Doubles: Codable, Equatable { var n: Double }
    private struct Text: Codable, Equatable { var s: String }

    private enum CounterDef: Db3JSONDef {
        typealias Value = Counter
        static let id = "schemas.test.Counter"
        static let schema = #"{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}"#
    }

    private enum NestedDef: Db3JSONDef {
        typealias Value = Nested
        static let id = "schemas.test.Nested"
        static let schema = #"{"type":"object"}"#
    }

    private enum DoublesDef: Db3JSONDef {
        typealias Value = Doubles
        static let id = "schemas.test.Doubles"
        static let schema = #"{"type":"object","properties":{"n":{"type":"number"}}}"#
    }

    private enum ShortTextDef: Db3JSONDef {
        typealias Value = Text
        static let id = "schemas.test.ShortText"
        static let schema = #"{"type":"object","properties":{"s":{"type":"string","maxLength":2}}}"#
    }

    private func refusal(_ body: () throws -> String) -> Db3JSONValueError? {
        do {
            let text = try body()
            XCTFail("stored \(text)")
            return nil
        } catch {
            return error as? Db3JSONValueError
        }
    }

    func testAnIntegerAbove2To53IsRefusedAndNeverRounded() throws {
        let past = 9_007_199_254_740_993
        for n in [past, -past] {
            let error = refusal { try CounterDef.storedText(for: Counter(n: n), model: "orders", field: "counter") }
            XCTAssertEqual(error, Db3JSONValueError(
                model: "orders", field: "counter", def: "schemas.test.Counter", path: "value.n",
                reason: "value.n is \(n); a db3 JSON value holds numbers up to 2^53 in magnitude (store a larger one as a string)",
                kind: .number))
        }
        XCTAssertEqual(try CounterDef.storedText(for: Counter(n: 9_007_199_254_740_992), model: "orders", field: "counter"), #"{"n":9007199254740992}"#)
        XCTAssertEqual(try CounterDef.storedText(for: Counter(n: -9_007_199_254_740_992), model: "orders", field: "counter"), #"{"n":-9007199254740992}"#)
    }

    func testAnIntegerAbove2To53IsRefusedInsideANestedStructAndAnArray() throws {
        let past = 9_007_199_254_740_993
        let inner = refusal { try NestedDef.storedText(for: Nested(inner: Counter(n: -past), list: []), model: "m", field: "f") }
        XCTAssertEqual(inner?.path, "value.inner.n")
        XCTAssertEqual(inner?.kind, .number)
        let item = refusal { try NestedDef.storedText(for: Nested(inner: Counter(n: 1), list: [1, past]), model: "m", field: "f") }
        XCTAssertEqual(item?.path, "value.list[1]")
        XCTAssertEqual(item?.kind, .number)
        XCTAssertEqual(try NestedDef.storedText(for: Nested(inner: Counter(n: 2), list: [3, -1]), model: "m", field: "f"),
                       #"{"inner":{"n":2},"list":[3,-1]}"#)
    }

    func testDoubleSourcesAreWrittenInECMAScriptsShortestForm() throws {
        let text = { (n: Double) in try DoublesDef.storedText(for: Doubles(n: n), model: "m", field: "f") }
        XCTAssertEqual(try text(1.0), #"{"n":1}"#)
        XCTAssertEqual(try text(-0.0), #"{"n":0}"#)
        XCTAssertEqual(try text(0.1 + 0.2), #"{"n":0.30000000000000004}"#)
        XCTAssertEqual(try text(9_007_199_254_740_992), #"{"n":9007199254740992}"#)
        XCTAssertEqual(try text(1e-7), #"{"n":1e-7}"#)
        XCTAssertEqual(try text(0.00001), #"{"n":0.00001}"#)
        for n in [1e21, 9_007_199_254_740_994, .infinity, -.infinity, .nan] {
            XCTAssertEqual(refusal { try text(n) }?.kind, .number, "\(n)")
        }
    }

    func testAMultiScalarGraphemeCountsByItsScalars() throws {
        // A ZWJ sequence: one grapheme, three code points.
        let coder = "\u{1F469}\u{200D}\u{1F4BB}"
        XCTAssertEqual(coder.count, 1)
        let error = refusal { try ShortTextDef.storedText(for: Text(s: coder), model: "m", field: "f") }
        XCTAssertEqual(error?.kind, .schema)
        XCTAssertEqual(error?.reason, "value.s must be at most 2 characters")
        // A flag: one grapheme, two code points, four UTF-16 units.
        XCTAssertEqual(try ShortTextDef.storedText(for: Text(s: "\u{1F1F5}\u{1F1F9}"), model: "m", field: "f"), "{\"s\":\"\u{1F1F5}\u{1F1F9}\"}")
    }

    func testASchemaMismatchIsAValueErrorWithEveryIssue() throws {
        XCTAssertEqual(try CounterDef.storedText(for: Counter(n: 1), model: "orders", field: "counter"), #"{"n":1}"#)
        struct Loose: Codable, Equatable { var n: Double }
        enum LooseDef: Db3JSONDef {
            typealias Value = Loose
            static let id = "schemas.test.Loose"
            static let schema = #"{"type":"object","properties":{"n":{"type":"integer","maximum":1}}}"#
        }
        let mismatch = refusal { try LooseDef.storedText(for: Loose(n: 2.5), model: "orders", field: "loose") }
        XCTAssertEqual(mismatch, Db3JSONValueError(
            model: "orders", field: "loose", def: "schemas.test.Loose", path: "value.n", reason: "value.n must be integer", kind: .schema))
        XCTAssertEqual(mismatch?.errorDescription, "orders.loose is typed by schemas.test.Loose: value.n must be integer")
        XCTAssertEqual(mismatch?.code, "DB3_JSON_INVALID")
    }

    func testAnOpenObjectsJSONValueNumbersAreCheckedAsDoubles() throws {
        enum OpenDef: Db3JSONDef {
            typealias Value = [String: JSONValue]
            static let id = "schemas.test.Open"
            static let schema = #"{"type":"object"}"#
        }
        XCTAssertEqual(try OpenDef.storedText(for: ["b": .number(2), "a": .string("x"), "c": .null], model: "m", field: "f"),
                       #"{"a":"x","b":2,"c":null}"#)
        XCTAssertEqual(refusal { try OpenDef.storedText(for: ["n": .number(1e21)], model: "m", field: "f") }?.kind, .number)
    }

    // CSO-5899-008: a binding whose schema is not JSON text refuses every value instead of checking it against nothing.
    func testABindingWhoseSchemaDoesNotParseRefusesTheValue() throws {
        struct Note: Codable, Equatable { var code: String }
        enum BrokenDef: Db3JSONDef {
            typealias Value = Note
            static let id = "schemas.test.Broken"
            // What a one-`#` literal of `"\\#(1 + 1)"` reads as: `\2`, which is not a JSON escape.
            static let schema = #"{"type":"object","description":"\\#(1 + 1)","required":["code"]}"#
        }
        enum ArrayDef: Db3JSONDef {
            typealias Value = Note
            static let id = "schemas.test.ArrayRoot"
            static let schema = #"[]"#
        }
        for (error, def) in [
            (refusal { try BrokenDef.storedText(for: Note(code: "1"), model: "m", field: "f") }, "schemas.test.Broken"),
            (refusal { try ArrayDef.storedText(for: Note(code: "1"), model: "m", field: "f") }, "schemas.test.ArrayRoot"),
        ] {
            XCTAssertEqual(error?.kind, .schema, def)
            XCTAssertEqual(error?.def, def)
            XCTAssertEqual(error?.path, "value", def)
            XCTAssertEqual(error?.reason, Db3JSONSchemas.unreadable, def)
        }
    }

    // CSO-5899-008: the delimiter functions codegen picks for an annotation holding `\#(` keeps it text, so the def's
    // constraints still hold. This is the literal the CLI writes for that schema (two `#`s).
    func testAnAnnotationHoldingAnInterpolationStaysTextInTheBinding() throws {
        struct Note: Codable, Equatable { var code: String? }
        enum NoteDef: Db3JSONDef {
            typealias Value = Note
            static let id = "schemas.notes.Note"
            static let schema = ##"{"type":"object","additionalProperties":false,"required":["code"],"description":"\\#(1 + 1) is two","properties":{"code":{"type":"string","pattern":"^\\d+$","maxLength":4}}}"##
        }
        XCTAssertEqual(try Db3JSONParser.parse(NoteDef.schema)["description"], .string(##"\#(1 + 1) is two"##))
        XCTAssertEqual(try NoteDef.storedText(for: Note(code: "12"), model: "m", field: "f"), #"{"code":"12"}"#)
        XCTAssertEqual(refusal { try NoteDef.storedText(for: Note(code: nil), model: "m", field: "f") }?.path, "value.code")
        XCTAssertEqual(refusal { try NoteDef.storedText(for: Note(code: "\u{0661}"), model: "m", field: "f") }?.path, "value.code")
    }

    // CSO-5899-009: a pattern means what ECMAScript's `u`-flag RegExp means; the fixture holds the shared cases.
    func testPatternsAreRewrittenToECMAScriptsMeaning() throws {
        XCTAssertEqual(Db3JSONPattern.icu("^[0-9]{4}(-[0-9]{3})?$"), #"^[0-9]{4}(-[0-9]{3})?\z"#)
        XCTAssertEqual(Db3JSONPattern.icu(#"^\d[\d\W]\$[$]\.$"#), #"^[0-9][0-9[^A-Za-z0-9_]]\$[$]\.\z"#)
        XCTAssertEqual(Db3JSONPattern.icu(#"\u{1F600}A[\b][[&&]"#), #"\x{1F600}A[\x{08}][\[\&\&]"#)
        let matches = { (pattern: String, value: String) -> Bool in
            let regex = try! NSRegularExpression(pattern: Db3JSONPattern.icu(pattern))
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        XCTAssertFalse(matches("^a[]", "a"))
        XCTAssertTrue(matches("^a[^]b$", "a\nb"))
        XCTAssertTrue(matches("^[[a]+$", "[a["))
        XCTAssertTrue(matches(#"^\u{1F600}$"#, "\u{1F600}"))
        XCTAssertTrue(matches(#"\Bb"#, "ab"))
        XCTAssertFalse(matches(#"\Bé"#, "aé"))
        XCTAssertFalse(matches("^a.b$", "a\nb"))
        XCTAssertFalse(matches("^a.b$", "a\u{2028}b"))
    }

    // CSO-5899-010: member names and strings compare by code unit, so composed and decomposed text stay apart.
    func testComposedAndDecomposedTextStayApart() throws {
        let composed = "\u{E9}", decomposed = "e\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift's String equality is canonical equivalence")
        let node = try Db3JSONParser.parse(#"{"é":1,"é":2}"#)
        XCTAssertEqual(node.members?.keys.count, 2)
        XCTAssertEqual(node[composed], .int(1))
        XCTAssertEqual(node[decomposed], .int(2))
        XCTAssertNotEqual(Db3JSONNode.string(composed), .string(decomposed))
        XCTAssertEqual(try canonical(node), "{\"e\u{301}\":2,\"\u{E9}\":1}")
        enum MixedDef: Db3JSONDef {
            typealias Value = [String: JSONValue]
            static let id = "schemas.test.Mixed"
            static let schema = #"{"type":"object","required":["é"],"properties":{"v":{"enum":["é",1]}}}"#
        }
        XCTAssertEqual(refusal { try MixedDef.storedText(for: [decomposed: .number(1)], model: "m", field: "f") }?.path, "value.\u{E9}")
        XCTAssertEqual(refusal { try MixedDef.storedText(for: [composed: .number(1), "v": .string(decomposed)], model: "m", field: "f") }?.path, "value.v")
        XCTAssertEqual(try MixedDef.storedText(for: [composed: .number(1), "v": .string(composed)], model: "m", field: "f"), "{\"v\":\"\u{E9}\",\"\u{E9}\":1}")
    }
}
