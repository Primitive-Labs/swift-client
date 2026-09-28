import XCTest
@testable import JsBaoClient

/// #3658 — `validateAccess(documentId:userId:)` names a subject.
///
/// Server-free, because what is client-side here is exactly what can drift:
/// whether the subject reaches the wire as a `{ userId }` body, whether the
/// bodyless call stays bodyless, and whether the two additive response fields
/// decode. The answer itself is the platform's, and the live suites in
/// `tests/api/http/` pin that.
final class DocumentAccessSubjectHermeticTests: XCTestCase {

    private func makeAPI(_ transport: RecordingTransport) -> DocumentsAPI {
        DocumentsAPI(
            transport: transport,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
    }

    private static let subjectAnswer = """
    {
      "success": true,
      "hasAccess": true,
      "permission": "read-write",
      "accessSource": "group",
      "appRole": "member"
    }
    """

    /// The subject travels as the body of the same route, and the two
    /// additive fields come back decoded.
    func testNamedSubjectSendsUserIdAndDecodesTheAddedFields() async throws {
        let transport = RecordingTransport(json: Self.subjectAnswer)
        let api = makeAPI(transport)

        let result = try await api.validateAccess(
            documentId: "doc-1",
            userId: "user-7"
        )

        let call = try XCTUnwrap(transport.lastCall(to: "/documents/doc-1/validate-access"))
        XCTAssertEqual(call.method, .post)
        XCTAssertEqual(call.jsonBody?["userId"]?.stringValue, "user-7")

        XCTAssertTrue(result.hasAccess)
        XCTAssertEqual(result.permission, .readWrite)
        XCTAssertEqual(result.accessSource, "group")
        XCTAssertEqual(result.appRole, "member")
    }

    /// Naming nobody keeps the call exactly as it was: no body at all, and an
    /// answer that carries neither added field.
    func testBodylessCallStaysBodylessAndDecodesWithoutTheAddedFields() async throws {
        let transport = RecordingTransport(json: """
        { "success": true, "hasAccess": false }
        """)
        let api = makeAPI(transport)

        let result = try await api.validateAccess(documentId: "doc-1")

        let call = try XCTUnwrap(transport.lastCall(to: "/documents/doc-1/validate-access"))
        XCTAssertNil(call.body)
        XCTAssertFalse(result.hasAccess)
        XCTAssertNil(result.accessSource)
        XCTAssertNil(result.appRole)
    }
}
