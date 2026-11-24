import XCTest
@testable import JsBaoClient

/// #6307 behavior 25 — the Swift validator checks a map's values as js-bao
/// and the server do: each key `properties` does not declare is validated
/// against a schema-valued `additionalProperties`, after the declared
/// properties and in JavaScript's own-key order (array indices ascending
/// first). A declared property is checked by its own schema only.
///
/// Every `validationMap` case of the shared fixture (the copy in
/// `Fixtures/Db3Json/`) gives its verdict, its first path and the server's
/// sentences in order.
final class Db3JsonMapHermeticTests: XCTestCase {

    private static let fixtureURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/Db3Json/conformance.json")
    }()

    private enum WeightsDef: Db3JSONDef {
        typealias Value = [String: Double]
        static let id = "schemas.common.Weights"
        static let schema = #"{"type":"object","additionalProperties":{"type":"number","minimum":0}}"#
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

    func testEveryValidationMapCaseGivesTheServersVerdictPathAndSentences() throws {
        let parsed = try Db3JSONParser.parse(String(contentsOf: Self.fixtureURL, encoding: .utf8), substitutingLoneSurrogates: true)
        let cases = try XCTUnwrap(parsed.node["validationMap"]?.array)
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for node in cases {
            let name = node["name"]?.string ?? ""
            let schema = try XCTUnwrap(node["schema"], name)
            let value = try XCTUnwrap(node["value"], name)
            let issues = Db3JSONValidator.validate(schema: schema, value: value)
            if node["valid"] == .bool(true) {
                XCTAssertEqual(issues, [], name)
                continue
            }
            XCTAssertEqual(issues.first?.path, node["path"]?.string, name)
            let expected = try XCTUnwrap(node["errors"]?.array, name).compactMap(\.string)
            XCTAssertEqual(issues.map(\.message), expected, name)
        }
    }

    func testAMapValueTheDefExcludesIsAValueErrorAtItsKey() throws {
        XCTAssertEqual(try WeightsDef.storedText(for: ["b": 2, "a": 1], model: "posts", field: "weights"), #"{"a":1,"b":2}"#)
        XCTAssertEqual(try WeightsDef.storedText(for: [:], model: "posts", field: "weights"), "{}")
        XCTAssertEqual(refusal { try WeightsDef.storedText(for: ["a": 1, "b": -1], model: "posts", field: "weights") },
                       Db3JSONValueError(model: "posts", field: "weights", def: "schemas.common.Weights", path: "value.b",
                                         reason: "value.b must be >= 0", kind: .schema))
        XCTAssertEqual(WeightsDef.value(fromStored: #"{"a":1,"b":2}"#, model: "Post6307", field: "weights"), ["a": 1, "b": 2])
    }

    func testANumberAbove2To53InsideAMapValueIsRefusedAtItsPath() throws {
        XCTAssertEqual(refusal { try WeightsDef.storedText(for: ["a": 9_007_199_254_740_994], model: "posts", field: "weights") }?.kind, .number)
        XCTAssertEqual(refusal { try WeightsDef.storedText(for: ["a": 9_007_199_254_740_994], model: "posts", field: "weights") }?.path, "value.a")
    }
}
