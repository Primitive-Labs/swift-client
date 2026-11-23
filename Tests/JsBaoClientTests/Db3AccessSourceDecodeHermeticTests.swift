import XCTest
@testable import JsBaoClient

/// #4806 behavior 19 and edge case 040 — `accessSource` decodes leniently.
///
/// The db3 routes answer `accessSource: "app"` for an app grant (the sponsor's
/// 2026-10-25 decision, intent R8a): `DocumentAccessSource` has an `app` case,
/// and a value this client does not know decodes as `nil` instead of failing
/// the whole document, so a later value cannot break a decode. An absent key
/// is `nil`, as before; a row missing what it must carry still throws.
final class Db3AccessSourceDecodeHermeticTests: XCTestCase {

    private func documentInfo(accessSource: String?) throws -> DocumentInfo {
        let source = accessSource.map { #", "accessSource": "\#($0)""# } ?? ""
        let json = """
        {"documentId": "01JD4806DOC0000000000000AA", "title": "Notes", "createdBy": "u-1", "createdAt": "2026-10-26T00:00:00.000Z",
         "modifiedAt": "2026-10-26T01:00:00.000Z", "permission": "read-write", "grantedAt": "2026-10-26T02:00:00.000Z",
         "tags": ["a"], "documentFormat": 3\(source)}
        """
        return try JSONCoding.decodeData(DocumentInfo.self, from: Data(json.utf8))
    }

    private func assertOtherFieldsIntact(_ info: DocumentInfo, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(info.documentId, "01JD4806DOC0000000000000AA", file: file, line: line)
        XCTAssertEqual(info.title, "Notes", file: file, line: line)
        XCTAssertEqual(info.createdBy, "u-1", file: file, line: line)
        XCTAssertEqual(info.lastModified, "2026-10-26T01:00:00.000Z", file: file, line: line)
        XCTAssertEqual(info.permission, .readWrite, file: file, line: line)
        XCTAssertEqual(info.grantedAt, "2026-10-26T02:00:00.000Z", file: file, line: line)
        XCTAssertEqual(info.tags, ["a"], file: file, line: line)
        XCTAssertEqual(info.documentFormat, 3, file: file, line: line)
    }

    func testDocumentInfoDecodesAppAsTheAppCase() throws {
        let info = try documentInfo(accessSource: "app")
        XCTAssertEqual(info.accessSource, .app)
        XCTAssertEqual(DocumentAccessSource.app.rawValue, "app")
        assertOtherFieldsIntact(info)
    }

    func testDocumentInfoDecodesAnUnknownValueAsNilWithEveryOtherFieldIntact() throws {
        let info = try documentInfo(accessSource: "something-later")
        XCTAssertNil(info.accessSource)
        assertOtherFieldsIntact(info)
    }

    func testDocumentInfoDecodesAnAbsentValueAsNilAndTheKnownOnesAsBefore() throws {
        XCTAssertNil(try documentInfo(accessSource: nil).accessSource)
        for source in [DocumentAccessSource.owner, .grant, .group, .link] {
            XCTAssertEqual(try documentInfo(accessSource: source.rawValue).accessSource, source)
        }
    }

    func testADocumentListPageHoldingAnUnknownValueDecodes() throws {
        let json = """
        {"items": [
          {"documentId": "01JD4806DOC0000000000000AB", "title": "One", "permission": "reader", "accessSource": "something-later"},
          {"documentId": "01JD4806DOC0000000000000AC", "title": "Two", "permission": "read-write", "accessSource": "app"}
        ], "hasMore": false}
        """
        let page = try JSONCoding.decodeData(DocumentListPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.map(\.documentId), ["01JD4806DOC0000000000000AB", "01JD4806DOC0000000000000AC"])
        XCTAssertEqual(page.items.map(\.accessSource), [nil, .app])
        XCTAssertEqual(page.items.map(\.title), ["One", "Two"])
    }

    /// Edge case 040: the lenient decode covers `accessSource` and nothing else.
    func testALenientAccessSourceNeverMasksAMalformedRow() {
        let json = #"{"title": "No id", "permission": "reader", "accessSource": "something-later"}"#
        XCTAssertThrowsError(try JSONCoding.decodeData(DocumentInfo.self, from: Data(json.utf8)))
    }
}
