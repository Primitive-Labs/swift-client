import XCTest
@testable import JsBaoClient

/// User properties on the Swift client's types (#5387, project
/// `user-index-properties` phase 2): `UserProfile`, `BasicUserInfo`,
/// `BatchUserProfile` and `UserLookupSummary` decode `properties` as
/// `[String: JSONValue]`, and an answer without the key — a profile cached
/// before the field existed — decodes to `[:]`. `UpdateMeParams.properties`
/// encodes beside `name` and `avatarUrl`, `.null` clearing a field; the
/// existing initializers and encodings are unchanged.
///
/// Server-free: these decode and encode fixed JSON.
final class UserPropertiesTypesHermeticTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encoded(_ params: UpdateMeParams) throws -> [String: Any] {
        let data = try JSONEncoder().encode(params)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any])
    }

    func testUserProfileDecodesPropertiesAndDefaultsToEmpty() throws {
        let withProperties = try decode(UserProfile.self, """
        {"userId":"u1","email":"a@b.c","name":"A","appRole":"member","appId":"app",
         "properties":{"theme":"dark","tags":["x","y"],"score":3,"verified":true}}
        """)
        XCTAssertEqual(withProperties.properties, [
            "theme": .string("dark"), "tags": .array([.string("x"), .string("y")]),
            "score": .number(3), "verified": .bool(true),
        ])
        let cached = try decode(UserProfile.self, """
        {"userId":"u1","email":"a@b.c","appRole":"member","appId":"app"}
        """)
        XCTAssertEqual(cached.properties, [:])
    }

    func testUsersTypesDecodePropertiesAndDefaultToEmpty() throws {
        let basic = try decode(BasicUserInfo.self, """
        {"userId":"u1","email":"a@b.c","appRole":"member","appId":"app","properties":{"shared":"s"}}
        """)
        XCTAssertEqual(basic.properties, ["shared": .string("s")])
        XCTAssertEqual(try decode(BasicUserInfo.self, #"{"userId":"u1","email":"a@b.c","appRole":"member","appId":"app"}"#).properties, [:])

        let profile = try decode(BatchUserProfile.self, #"{"userId":"u1","email":"a@b.c","name":null,"avatarUrl":null,"properties":{"shared":"s"}}"#)
        XCTAssertEqual(profile.properties, ["shared": .string("s")])
        XCTAssertEqual(try decode(BatchUserProfile.self, #"{"userId":"u1","email":"a@b.c"}"#).properties, [:])

        let lookup = try decode(UserLookupResult.self, #"{"exists":true,"user":{"userId":"u1","email":"a@b.c","properties":{"shared":"s"}}}"#)
        XCTAssertEqual(lookup.user?.properties, ["shared": .string("s")])
        XCTAssertEqual(try decode(UserLookupSummary.self, #"{"userId":"u1","email":"a@b.c"}"#).properties, [:])
    }

    func testUpdateMeParamsEncodesPropertiesWithNullClearing() throws {
        let body = try encoded(UpdateMeParams(properties: ["theme": .null, "pronouns": .string("they")]))
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertTrue(properties["theme"] is NSNull)
        XCTAssertEqual(properties["pronouns"] as? String, "they")
        XCTAssertNil(body["name"])
        XCTAssertNil(body["avatarUrl"])
    }

    func testExistingInitializersAndEncodingsAreUnchanged() throws {
        let basic = BasicUserInfo(userId: "u1", email: "a@b.c", appRole: "member", appId: "app")
        XCTAssertEqual(basic.properties, [:])
        let profile = BatchUserProfile(userId: "u1", email: "a@b.c")
        XCTAssertEqual(profile.properties, [:])
        XCTAssertEqual(BatchUserProfile(userId: "u1", email: "a@b.c", properties: ["k": .string("v")]).properties, ["k": .string("v")])

        XCTAssertEqual(try encoded(UpdateMeParams(name: "N")).keys.sorted(), ["name"])
        let cleared = try encoded(UpdateMeParams(avatarUrl: .clear))
        XCTAssertEqual(cleared.keys.sorted(), ["avatarUrl"])
        XCTAssertTrue(cleared["avatarUrl"] is NSNull)
    }
}
