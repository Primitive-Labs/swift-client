import XCTest
@testable import JsBaoClient

/// Pure-decode coverage for issue #1819: `DatabaseInfo.celContext` is now a
/// deprecated *computed accessor* over the non-deprecated `celContextStorage`
/// stored property, and `init(from:)` decodes the wire `celContext` key into
/// that storage (so the custom decoder no longer references the deprecated
/// declaration and the target compiles clean under `-warnings-as-errors`).
///
/// These tests pin that the storage split did not change decode behavior: the
/// wire `celContext` key still surfaces through the public accessor, and its
/// absence leaves the value `nil`.
///
/// The test methods are marked `@available(*, deprecated)` only so that reading
/// the intentionally-deprecated `celContext` accessor here does not itself emit
/// a deprecation warning — the reference sits inside a deprecated context.
final class DatabaseInfoCelContextDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> DatabaseInfo {
        try JSONDecoder().decode(DatabaseInfo.self, from: Data(json.utf8))
    }

    /// `celContext` present on the wire → surfaced through the deprecated
    /// accessor (proves the decoder writes the non-deprecated storage the
    /// accessor reads).
    @available(*, deprecated)
    func testDecodesCelContextWhenPresent() throws {
        let info = try decode(#"""
        {
            "databaseId": "db_1",
            "title": "Roster",
            "celContext": { "tenantId": "t1", "classId": "c9" },
            "createdBy": "user_1",
            "createdAt": "2026-07-24T00:00:00.000Z",
            "modifiedAt": "2026-07-24T00:00:00.000Z"
        }
        """#)

        XCTAssertEqual(info.databaseId, "db_1")
        XCTAssertEqual(info.celContext, .object(["tenantId": .string("t1"), "classId": .string("c9")]))
    }

    /// No `celContext` key → accessor returns `nil` (legacy payloads still
    /// decode).
    @available(*, deprecated)
    func testDecodesNilCelContextWhenAbsent() throws {
        let info = try decode(#"""
        {
            "databaseId": "db_2",
            "title": "Empty",
            "createdBy": "user_1",
            "createdAt": "2026-07-24T00:00:00.000Z",
            "modifiedAt": "2026-07-24T00:00:00.000Z"
        }
        """#)

        XCTAssertEqual(info.databaseId, "db_2")
        XCTAssertNil(info.celContext)
    }
}
