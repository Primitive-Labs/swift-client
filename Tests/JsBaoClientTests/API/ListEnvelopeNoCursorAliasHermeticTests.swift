import XCTest
@testable import JsBaoClient

/// Every page type reads the list envelope `{ items, hasMore, nextCursor? }`
/// and nothing else (#3985).
///
/// The server no longer sends a `cursor` alias of `nextCursor`, so a body that
/// carries only `cursor` has no continuation: it decodes to `nextCursor == nil`
/// and `hasMore == false`. `NotificationListResult` joined the same envelope.
///
/// Server-free: each case decodes a literal body.
final class ListEnvelopeNoCursorAliasHermeticTests: XCTestCase {
    private let envelope = #"{"items":[],"hasMore":true,"nextCursor":"next-token"}"#
    private let cursorOnly = #"{"items":[],"cursor":"old-token"}"#

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Asserts `T` decodes the envelope and ignores a lone `cursor`.
    private func assertEnvelope<T: Decodable>(
        _ type: T.Type,
        next: (T) -> String?,
        hasMore: (T) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let page = try decode(type, envelope)
        XCTAssertEqual(next(page), "next-token", "\(type) nextCursor", file: file, line: line)
        XCTAssertTrue(hasMore(page), "\(type) hasMore", file: file, line: line)

        let legacy = try decode(type, cursorOnly)
        XCTAssertNil(next(legacy), "\(type) must not read cursor", file: file, line: line)
        XCTAssertFalse(hasMore(legacy), "\(type) hasMore from cursor", file: file, line: line)
    }

    func testDocumentListPage() throws {
        try assertEnvelope(DocumentListPage.self, next: { $0.nextCursor }, hasMore: { $0.hasMore })
    }

    func testSharedDocumentListResult() throws {
        try assertEnvelope(SharedDocumentListResult.self, next: { $0.nextCursor }, hasMore: { $0.hasMore })
    }

    func testDocumentBlobListResult() throws {
        try assertEnvelope(DocumentBlobListResult.self, next: { $0.nextCursor }, hasMore: { $0.hasMore })
    }

    func testBucketBlobListResult() throws {
        try assertEnvelope(BucketBlobListResult.self, next: { $0.nextCursor }, hasMore: { $0.hasMore })
    }

    func testInvitationListResult() throws {
        try assertEnvelope(InvitationListResult.self, next: { $0.nextCursor }, hasMore: { $0.hasMore })
    }

    func testListWorkflowRunsResult() throws {
        try assertEnvelope(ListWorkflowRunsResult.self, next: { $0.nextCursor }, hasMore: { $0.hasMore })
    }

    func testPaginatedResultOfCollections() throws {
        try assertEnvelope(
            PaginatedResult<CollectionInfo>.self,
            next: { $0.nextCursor },
            hasMore: { $0.hasMore }
        )
    }

    func testDocumentListPageIgnoresLegacyDocumentsKey() throws {
        let page = try decode(DocumentListPage.self, #"{"documents":[{"documentId":"d1"}]}"#)
        XCTAssertEqual(page.items.count, 0)
    }

    func testNotificationListResultReadsTheEnvelope() throws {
        let page = try decode(
            NotificationListResult.self,
            #"{"items":[],"unreadCount":3,"hasMore":true,"nextCursor":"next-token"}"#
        )
        XCTAssertEqual(page.unreadCount, 3)
        XCTAssertEqual(page.nextCursor, "next-token")
        XCTAssertTrue(page.hasMore)

        let last = try decode(NotificationListResult.self, #"{"items":[],"unreadCount":0,"hasMore":false}"#)
        XCTAssertNil(last.nextCursor)
        XCTAssertFalse(last.hasMore)

        let legacy = try decode(NotificationListResult.self, #"{"items":[],"unreadCount":0,"cursor":"old-token"}"#)
        XCTAssertNil(legacy.nextCursor)
        XCTAssertFalse(legacy.hasMore)
    }
}
