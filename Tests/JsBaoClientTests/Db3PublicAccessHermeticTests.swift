import XCTest
@testable import JsBaoClient

/// #5842 behavior 21 (hermetic half) — `client.db3.permissions(id).setPublicAccess(_:)`
/// on the wire, project `public-access` phase 3.
///
/// `.reader` sends `PUT /db3/<id>/public-access` with `{"level":"reader"}` and
/// `nil` sends `{"level":null}`; the answer decodes as `Db3PublicAccessChange`.
/// `Db3Info` decodes the three `publicAccess*` fields `db3.get` answers to a
/// caller who manages the db3's sharing, and leaves them `nil` when absent.
final class Db3PublicAccessHermeticTests: XCTestCase {

    private func sharing(_ json: String) -> (Db3PermissionsAPI, RecordingTransport) {
        let transport = RecordingTransport(status: 200, json: json)
        let api = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport)
        return (api.permissions("d"), transport)
    }

    private func body(_ call: RecordedRequest?) -> [String: JSONValue]? {
        if case .object(let object)? = call?.jsonBody { return object }
        return nil
    }

    func testTheSurfaceIsTyped() {
        let (api, _) = sharing("{}")
        let _: (Db3PublicAccessLevel?) async throws -> Db3PublicAccessChange = api.setPublicAccess(_:)
        XCTAssertEqual(Db3PublicAccessLevel.reader.rawValue, "reader")
    }

    func testSetSendsReaderAndDecodesTheAnswer() async throws {
        let (api, transport) = sharing(#"{"id": "d", "level": "reader", "changed": true, "signedOutAccess": false}"#)
        let change = try await api.setPublicAccess(.reader)
        XCTAssertEqual(transport.lastCall?.method, .put)
        XCTAssertEqual(transport.lastCall?.path, "/db3/d/public-access")
        XCTAssertEqual(body(transport.lastCall), ["level": "reader"])
        XCTAssertEqual(change, Db3PublicAccessChange(id: "d", level: .reader, changed: true, signedOutAccess: false))
    }

    func testClearSendsNullAndDecodesTheAnswer() async throws {
        let (api, transport) = sharing(#"{"id": "d", "level": null, "changed": false, "signedOutAccess": true}"#)
        let change = try await api.setPublicAccess(nil)
        XCTAssertEqual(transport.lastCall?.method, .put)
        XCTAssertEqual(transport.lastCall?.path, "/db3/d/public-access")
        XCTAssertEqual(body(transport.lastCall), ["level": .null])
        XCTAssertEqual(change, Db3PublicAccessChange(id: "d", level: nil, changed: false, signedOutAccess: true))
    }

    func testDb3InfoDecodesThePublicAccessFieldsAndToleratesTheirAbsence() throws {
        let shown = try JSONDecoder().decode(Db3Info.self, from: Data("""
        {"id": "d", "title": "T", "createdBy": "u-1", "createdAt": "c", "modifiedAt": "m", "custodian": "app", "sync": true,
         "type": null, "tags": [], "publicAccess": "reader", "publicAccessUpdatedBy": "u-9",
         "publicAccessUpdatedAt": "2026-11-14T00:00:00.000Z"}
        """.utf8))
        XCTAssertEqual(shown.publicAccess, .reader)
        XCTAssertEqual(shown.publicAccessUpdatedBy, "u-9")
        XCTAssertEqual(shown.publicAccessUpdatedAt, "2026-11-14T00:00:00.000Z")

        let plain = try JSONDecoder().decode(Db3Info.self, from: Data("""
        {"id": "d", "title": "T", "createdBy": "u-1", "createdAt": "c", "modifiedAt": "m", "custodian": "app", "sync": true,
         "type": null, "tags": []}
        """.utf8))
        XCTAssertNil(plain.publicAccess)
        XCTAssertNil(plain.publicAccessUpdatedBy)
        XCTAssertNil(plain.publicAccessUpdatedAt)
    }
}
