import XCTest
@testable import JsBaoClient

/// #6307 behaviors 14, 15 and 17 — a db3 JSON field whose def is a list, in
/// the Swift runtime. The root kind follows the def's compiled schema: a
/// `type = "array"` def's field stores an array's canonical text and refuses
/// any other root; an object def's field refuses an array, as it always has.
/// Reads decode the def's root kind and nothing else.
///
/// Every `canonicalList` case of the shared fixture (the copy in
/// `Fixtures/Db3Json/`) gives its text or its kind of refusal, as js-bao's
/// `canonicalDb3Json(value, "array")` does.
final class Db3JsonListHermeticTests: XCTestCase {

    private static let fixtureURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/Db3Json/conformance.json")
    }()

    /// Any JSON, under a list def: the root rule is the binding's.
    private enum AnyListDef: Db3JSONDef {
        typealias Value = JSONValue
        static let id = "schemas.test.AnyList"
        static let schema = #"{"type":"array"}"#
    }

    /// Any JSON, under an object def.
    private enum AnyObjectDef: Db3JSONDef {
        typealias Value = JSONValue
        static let id = "schemas.test.AnyObject"
        static let schema = #"{"type":"object"}"#
    }

    private enum TagsDef: Db3JSONDef {
        typealias Value = [String]
        static let id = "schemas.common.Tags"
        static let schema = #"{"type":"array","items":{"type":"string","minLength":1},"minItems":1,"maxItems":3}"#
    }

    private struct City: Codable, Equatable { var city: String }

    private enum CitiesDef: Db3JSONDef {
        typealias Value = [City]
        static let id = "schemas.common.Cities"
        static let schema = #"{"type":"array","items":{"type":"object","properties":{"city":{"type":"string","minLength":1}},"required":["city"]}}"#
    }

    private enum CityDef: Db3JSONDef {
        typealias Value = City
        static let id = "schemas.common.City"
        static let schema = #"{"type":"object","properties":{"city":{"type":"string"}}}"#
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

    /// A parsed fixture value as a `JSONValue`.
    private func jsonValue(_ node: Db3JSONNode) -> JSONValue {
        switch node {
        case .null: return .null
        case let .bool(value): return .bool(value)
        case let .int(value): return .number(Double(value))
        case let .double(value): return .number(value)
        case let .string(value): return .string(value)
        case let .array(items): return .array(items.map(jsonValue))
        case let .object(keys, values): return .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, jsonValue(values[Db3JSONKey($0)]!)) }))
        }
    }

    // MARK: - Behavior 17

    func testEveryCanonicalListCaseGivesTheFixturesTextOrRefusal() throws {
        let parsed = try Db3JSONParser.parse(String(contentsOf: Self.fixtureURL, encoding: .utf8), substitutingLoneSurrogates: true)
        let cases = try XCTUnwrap(parsed.node["canonicalList"]?.array)
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        for (index, node) in cases.enumerated() {
            let name = node["name"]?.string ?? ""
            let value = try XCTUnwrap(node["value"], name)
            if let text = node["text"]?.string {
                XCTAssertEqual(try AnyListDef.storedText(for: jsonValue(value), model: "m", field: "f"), text, name)
                XCTAssertEqual(AnyListDef.canonicalText(jsonValue(value)), text, name)
                continue
            }
            let kind = try XCTUnwrap(node["refused"]?.string, name)
            if kind == "surrogate" {
                // A Swift `String` cannot hold a lone surrogate; JSON text is the one door it can reach.
                XCTAssertTrue(parsed.loneSurrogates.contains { $0.hasPrefix("value.canonicalList[\(index)].value") }, name)
                continue
            }
            XCTAssertEqual(refusal { try AnyListDef.storedText(for: jsonValue(value), model: "m", field: "f") }?.kind.rawValue, kind, name)
            XCTAssertNil(AnyListDef.canonicalText(jsonValue(value)), name)
        }
    }

    // MARK: - Behavior 14

    func testAListDefsFieldStoresTheArraysCanonicalTextAfterValidatingIt() throws {
        XCTAssertEqual(try TagsDef.storedText(for: ["b", "a"], model: "posts", field: "tags"), #"["b","a"]"#)
        XCTAssertEqual(try CitiesDef.storedText(for: [City(city: "Porto")], model: "posts", field: "cities"), #"[{"city":"Porto"}]"#)
        XCTAssertEqual(try AnyListDef.storedText(for: .array([]), model: "posts", field: "any"), "[]")
        XCTAssertEqual(refusal { try TagsDef.storedText(for: ["a", ""], model: "posts", field: "tags") },
                       Db3JSONValueError(model: "posts", field: "tags", def: "schemas.common.Tags", path: "value[1]",
                                         reason: "value[1] must be at least 1 characters", kind: .schema))
        XCTAssertEqual(refusal { try TagsDef.storedText(for: [], model: "posts", field: "tags") }?.reason, "value must have at least 1 items")
        XCTAssertEqual(refusal { try TagsDef.storedText(for: ["a", "b", "c", "d"], model: "posts", field: "tags") }?.reason, "value must have at most 3 items")
        XCTAssertEqual(refusal { try CitiesDef.storedText(for: [City(city: "")], model: "posts", field: "cities") }?.path, "value[0].city")
    }

    func testAListDefsFieldRefusesAnotherRootAndAnObjectDefsFieldRefusesAnArray() throws {
        for (value, what) in [(JSONValue.object(["a": .number(1)]), "an object"), (.null, "null"), (.string("x"), "string"), (.number(1), "number"), (.bool(true), "boolean")] {
            XCTAssertEqual(refusal { try AnyListDef.storedText(for: value, model: "posts", field: "tags") },
                           Db3JSONValueError(model: "posts", field: "tags", def: "schemas.test.AnyList", path: "value",
                                             reason: "the value is \(what); this db3 JSON field holds an array", kind: .root), what)
            XCTAssertNil(AnyListDef.canonicalText(value), what)
        }
        XCTAssertEqual(refusal { try AnyObjectDef.storedText(for: .array([.number(1)]), model: "orders", field: "address") },
                       Db3JSONValueError(model: "orders", field: "address", def: "schemas.test.AnyObject", path: "value",
                                         reason: "the value is an array; a db3 JSON field holds an object", kind: .root))
        XCTAssertEqual(AnyObjectDef.canonicalText(.object(["b": .number(1)])), #"{"b":1}"#)
    }

    // MARK: - Behavior 15

    func testAListFieldReadsArrayTextAndAnotherRootReadsNilLoggedOnce() throws {
        XCTAssertEqual(TagsDef.value(fromStored: #"["a","b"]"#, model: "Post6307", field: "tags"), ["a", "b"])
        XCTAssertEqual(TagsDef.value(fromStored: "[]", model: "Post6307", field: "tags"), [])
        XCTAssertNil(AnyListDef.value(fromStored: #"{"a":1}"#, model: "Post6307", field: "any"))
        XCTAssertTrue(Db3JSONMisreads.wasReported(model: "Post6307", field: "any"))
        XCTAssertNil(AnyObjectDef.value(fromStored: #"[1]"#, model: "Order6307", field: "any"))
        XCTAssertTrue(Db3JSONMisreads.wasReported(model: "Order6307", field: "any"))
        XCTAssertEqual(AnyObjectDef.value(fromStored: #"{"a":1}"#, model: "Order6307", field: "ok"), .object(["a": .number(1)]))
        XCTAssertNil(CityDef.value(fromStored: #"[{"city":"Porto"}]"#, model: "Order6307", field: "city"))
    }
}
