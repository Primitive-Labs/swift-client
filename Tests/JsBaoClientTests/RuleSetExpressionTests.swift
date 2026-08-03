import XCTest
@testable import JsBaoClient

/// Round-trip coverage for the #1525 `RuleExpression { expr, loads }` rule-set
/// shape ported to the Swift client (issue #1989). A rule-set operation value
/// may now be either a bare CEL string (legacy form) or an object carrying the
/// expression plus its declared per-rule `loads`. These tests pin that:
///
///  * a bare string decodes to `.string` and re-encodes verbatim as a JSON
///    string (never rewritten to the object form);
///  * the object form decodes to `.object`, preserving `loads.paths`, and
///    round-trips back to an equivalent object — i.e. per-rule `loads` is NOT
///    dropped by the Swift encoder/decoder, which is the drift this issue fixes;
///  * `RuleSetInfo` and `CreateRuleSetParams` carry the `category → operation →
///    RuleExpression` shape end to end.
final class RuleSetExpressionTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    /// Re-encode a value and parse it back into a loosely-typed JSON graph so
    /// tests can assert on the exact wire shape.
    private func encodedJSON<T: Encodable>(_ value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: Bare-string form

    /// A bare CEL string decodes to `.string` and re-encodes as a plain JSON
    /// string — never promoted to the `{ expr }` object form.
    func testBareStringDecodesAndReEncodesVerbatim() throws {
        let expr = try decode(RuleExpression.self, #""user.id == resource.ownerId""#)
        XCTAssertEqual(expr, .string("user.id == resource.ownerId"))
        XCTAssertEqual(expr.expr, "user.id == resource.ownerId")
        XCTAssertNil(expr.loads)

        let reencoded = try encodedJSON(expr)
        XCTAssertEqual(reencoded as? String, "user.id == resource.ownerId")
    }

    // MARK: Object form — the #1525 shape

    /// The object form `{ expr, loads: { paths } }` decodes with its per-rule
    /// `loads` intact, and survives a full encode → decode round-trip.
    func testObjectFormPreservesPerRuleLoads() throws {
        let json = #"""
        {
          "expr": "md.owner.userId == user.id",
          "loads": {
            "paths": {
              "owner": {
                "rootFrom": "resource.ownerId",
                "type": "user",
                "categories": ["profile"]
              }
            }
          }
        }
        """#

        let expr = try decode(RuleExpression.self, json)

        // Decoded into the object case with loads preserved.
        guard case let .object(decodedExpr, decodedLoads) = expr else {
            return XCTFail("expected .object, got \(expr)")
        }
        XCTAssertEqual(decodedExpr, "md.owner.userId == user.id")
        let path = try XCTUnwrap(decodedLoads?.paths?["owner"])
        XCTAssertEqual(path.rootFrom, "resource.ownerId")
        XCTAssertNil(path.from)
        XCTAssertEqual(path.type, "user")
        XCTAssertEqual(path.categories, ["profile"])

        // Full round-trip: encode → decode yields an equal value (loads intact).
        let reencoded = try encoder.encode(expr)
        let roundTripped = try decoder.decode(RuleExpression.self, from: reencoded)
        XCTAssertEqual(roundTripped, expr)

        // And the encoded wire shape still nests loads.paths (not dropped).
        let wire = try encodedJSON(expr) as? [String: Any]
        XCTAssertEqual(wire?["expr"] as? String, "md.owner.userId == user.id")
        let paths = (wire?["loads"] as? [String: Any])?["paths"] as? [String: Any]
        XCTAssertNotNil(paths?["owner"], "per-rule loads.paths must survive encoding")
    }

    /// The object form with no `loads` encodes without a `loads` key (optional
    /// omitted), matching the JS `loads?` optionality.
    func testObjectFormWithoutLoadsOmitsLoadsKey() throws {
        let expr = RuleExpression.object(expr: "true", loads: nil)
        let wire = try encodedJSON(expr) as? [String: Any]
        XCTAssertEqual(wire?["expr"] as? String, "true")
        XCTAssertFalse(wire?.keys.contains("loads") ?? false, "loads must be omitted when nil")
    }

    // MARK: End-to-end on RuleSetInfo

    /// `RuleSetInfo` decodes the `category → operation → RuleExpression` map,
    /// mixing bare-string and object-form entries, and round-trips both.
    func testRuleSetInfoDecodesMixedRuleExpressions() throws {
        let json = #"""
        {
          "ruleSetId": "rs_1",
          "appId": "app_1",
          "name": "docs",
          "description": null,
          "resourceType": "document",
          "rules": {
            "documents": {
              "read": "true",
              "write": {
                "expr": "md.owner.userId == user.id",
                "loads": {
                  "paths": {
                    "owner": {
                      "from": "resource.ownerId",
                      "type": "user",
                      "categories": ["profile"]
                    }
                  }
                }
              }
            }
          },
          "version": 3,
          "createdAt": "2026-07-20T00:00:00.000Z",
          "modifiedAt": "2026-07-20T00:00:00.000Z",
          "createdBy": "user_1"
        }
        """#

        let info = try decode(RuleSetInfo.self, json)
        let documents = try XCTUnwrap(info.rules["documents"])

        XCTAssertEqual(documents["read"], .string("true"))

        let write = try XCTUnwrap(documents["write"])
        XCTAssertEqual(write.expr, "md.owner.userId == user.id")
        XCTAssertEqual(write.loads?.paths?["owner"]?.from, "resource.ownerId")

        // The decoded rules map round-trips: re-encode → decode is unchanged,
        // so the per-rule loads on the `write` entry is not lost through Swift.
        // (`RuleSetInfo` itself is a decode-only response type; its `rules`
        // value is the `Codable` `[String: CategoryRules]` carrying the shape.)
        let reencoded = try encoder.encode(info.rules)
        let roundTripped = try decoder.decode([String: CategoryRules].self, from: reencoded)
        XCTAssertEqual(roundTripped, info.rules)
    }

    // MARK: End-to-end on CreateRuleSetParams (request body)

    /// `CreateRuleSetParams` encodes per-rule `loads` into the outgoing request
    /// body — the write path that previously would have dropped it.
    func testCreateRuleSetParamsEncodesPerRuleLoads() throws {
        let params = CreateRuleSetParams(
            name: "docs",
            resourceType: "document",
            rules: [
                "documents": [
                    "read": .string("true"),
                    "write": .object(
                        expr: "md.owner.userId == user.id",
                        loads: RuleLoads(paths: [
                            "owner": PathDeclaration(
                                rootFrom: "resource.ownerId",
                                type: "user",
                                categories: ["profile"]
                            )
                        ])
                    ),
                ]
            ]
        )

        let wire = try encodedJSON(params) as? [String: Any]
        let rules = wire?["rules"] as? [String: Any]
        let documents = rules?["documents"] as? [String: Any]

        // Bare string entry stays a JSON string.
        XCTAssertEqual(documents?["read"] as? String, "true")

        // Object entry keeps expr + nested loads.paths.
        let write = documents?["write"] as? [String: Any]
        XCTAssertEqual(write?["expr"] as? String, "md.owner.userId == user.id")
        let ownerPath = ((write?["loads"] as? [String: Any])?["paths"] as? [String: Any])?["owner"] as? [String: Any]
        XCTAssertEqual(ownerPath?["rootFrom"] as? String, "resource.ownerId")
        XCTAssertEqual(ownerPath?["type"] as? String, "user")
        XCTAssertEqual(ownerPath?["categories"] as? [String], ["profile"])

        // And it decodes back into an equal params.rules map.
        let roundTripped = try decoder.decode(
            [String: CategoryRules].self,
            from: encoder.encode(params.rules)
        )
        XCTAssertEqual(roundTripped, params.rules)
    }
}
