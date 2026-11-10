import XCTest
@testable import JsBaoClient

/// #5223 behavior 17 and edge case E9 — the public surface of a text index:
/// `Db3TextIndexOptions` on a registration (encoded only when given),
/// `Db3TextIndex` on a listed index (`nil` on a scalar or member index), and
/// the two refusal codes; the existing registration initializers encode
/// exactly what they encoded before.
final class Db3TextIndexSurfaceHermeticTests: XCTestCase {

    private func encoded(_ registration: Db3IndexRegistration) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(registration))
    }

    func testARegistrationEncodesItsTextOptionsOnlyWhenGiven() throws {
        XCTAssertEqual(
            try encoded(Db3IndexRegistration(
                model: "Note", fields: ["title", "body"], kind: .text, on: .device,
                text: Db3TextIndexOptions(tokenizer: .porter, weights: ["title": 3])
            )),
            ["model": "Note", "fields": ["title", "body"], "kind": "text", "on": "device", "text": ["tokenizer": "porter", "weights": ["title": 3]]]
        )
        XCTAssertEqual(
            try encoded(Db3IndexRegistration(model: "Note", field: "title", kind: .text, on: .device, text: Db3TextIndexOptions(prefix: [2, 3]))),
            ["model": "Note", "field": "title", "kind": "text", "on": "device", "text": ["prefix": [2, 3]]]
        )
        XCTAssertEqual(
            try encoded(Db3IndexRegistration(model: "Note", field: "title", kind: .text, on: .device)),
            ["model": "Note", "field": "title", "kind": "text", "on": "device"]
        )
    }

    /// E9 (pin): the existing initializers encode what they encoded before.
    func testTheExistingInitializersEncodeAsBefore() throws {
        XCTAssertEqual(try encoded(Db3IndexRegistration(model: "Note", field: "email")), ["model": "Note", "field": "email"])
        XCTAssertEqual(
            try encoded(Db3IndexRegistration(model: "Note", fields: ["ownerId", "slug"], unique: true, name: "owner_slug")),
            ["model": "Note", "fields": ["ownerId", "slug"], "unique": true, "name": "owner_slug"]
        )
        XCTAssertEqual(try encoded(Db3IndexRegistration(model: "Note", field: "tags", members: true)),
                       ["model": "Note", "field": "tags", "members": true])
        XCTAssertEqual(try encoded(Db3IndexRegistration(model: "Note", field: "status", on: .device)),
                       ["model": "Note", "field": "status", "on": "device"])
    }

    func testAListedIndexDecodesItsTextOptions() throws {
        let text = try JSONDecoder().decode(Db3Index.self, from: Data("""
            {"name":"idx_text_note","model":"Note","fields":["title","body"],"unique":false,"origins":[{"kind":"named","unique":false}],
             "kind":"text","on":"device","text":{"tokenizer":"porter","prefix":[2],"weights":{"title":3,"body":1}}}
            """.utf8))
        XCTAssertEqual(text.kind, .text)
        XCTAssertEqual(text.text, Db3TextIndex(tokenizer: .porter, prefix: [2], weights: ["title": 3, "body": 1]))
        let scalar = try JSONDecoder().decode(Db3Index.self, from: Data("""
            {"name":"idx_records_note_title","model":"Note","fields":["title"],"unique":false,"origins":[{"kind":"named","unique":false}]}
            """.utf8))
        XCTAssertNil(scalar.text)
        let member = try JSONDecoder().decode(Db3Index.self, from: Data("""
            {"name":"idx_members_note_tags","model":"Note","fields":["tags"],"unique":false,"members":true,"origins":[],"kind":"members","on":"server"}
            """.utf8))
        XCTAssertNil(member.text)
    }

    func testTheRefusalCodesResolve() {
        XCTAssertEqual(JsBaoErrorCode(rawValue: "QUERY_INDEX_NOT_ON_DEVICE"), .queryIndexNotOnDevice)
        XCTAssertEqual(JsBaoErrorCode(rawValue: "QUERY_INDEX_NOT_ON_SERVER"), .queryIndexNotOnServer)
        XCTAssertEqual(Db3TextTokenizer.allCases.map(\.rawValue), ["unicode61", "porter"])
    }
}
