import XCTest
@testable import JsBaoClient

/// #4882 behavior 19 — a member of the resource that holds a db3 (an agent
/// session) reads it with `accessSource: "resource"` on the `db3/*` routes:
/// `DocumentAccessSource` has a `resource` case, `Db3Info` decodes it, and
/// every other field of the row decodes as before.
final class Db3ResourceAccessSourceHermeticTests: XCTestCase {

    private func db3Info(accessSource: String) throws -> Db3Info {
        let json = """
        {"id": "01JD4882DB30000000000000AA", "title": "Session", "createdBy": "sys:app-1",
         "createdAt": "2026-10-27T00:00:00.000Z", "modifiedAt": "2026-10-27T01:00:00.000Z",
         "custodian": "agentSession:01JD4882DB30000000000000AA", "sync": true, "type": null, "tags": [],
         "permission": "reader", "accessSource": "\(accessSource)", "grantedAt": "2026-10-27T00:00:00.000Z"}
        """
        return try JSONCoding.decodeData(Db3Info.self, from: Data(json.utf8))
    }

    func testDb3InfoDecodesResourceAsItsOwnCase() throws {
        let info = try db3Info(accessSource: "resource")
        XCTAssertEqual(info.accessSource?.rawValue, "resource")
        XCTAssertEqual(DocumentAccessSource(rawValue: "resource")?.rawValue, "resource")
        XCTAssertEqual(info.id, "01JD4882DB30000000000000AA")
        XCTAssertEqual(info.custodian, "agentSession:01JD4882DB30000000000000AA")
        XCTAssertEqual(info.createdBy, "sys:app-1")
        XCTAssertEqual(info.permission, .reader)
        XCTAssertTrue(info.sync)
        XCTAssertNil(info.type)
    }

    func testADocumentListPageDecodesResourceBesideTheOtherSources() throws {
        let json = """
        {"items": [
          {"documentId": "01JD4882DOC0000000000000AB", "title": "One", "permission": "reader", "accessSource": "resource"},
          {"documentId": "01JD4882DOC0000000000000AC", "title": "Two", "permission": "read-write", "accessSource": "app"}
        ], "hasMore": false}
        """
        let page = try JSONCoding.decodeData(DocumentListPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.map { $0.accessSource?.rawValue }, ["resource", "app"])
    }

    func testDb3InfoKeepsDecodingTheOtherSources() throws {
        for source in ["owner", "grant", "group", "link", "app"] {
            XCTAssertEqual(try db3Info(accessSource: source).accessSource?.rawValue, source)
        }
    }
}
