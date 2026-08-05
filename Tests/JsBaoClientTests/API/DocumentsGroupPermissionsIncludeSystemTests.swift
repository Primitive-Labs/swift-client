import XCTest
@testable import JsBaoClient

/// Wire-shape coverage for `documents.listGroupPermissions(includeSystem:)`
/// (#2360).
///
/// The flag used to be client-side only: Swift never sent
/// `?includeSystem=true`, so the server had already stripped the `_`-prefixed
/// system groups (`document-group-permissions-controller.ts`) before the
/// client could ask for them, and the option could not return a system group
/// at any input. JS has sent the param since #506.
final class DocumentsGroupPermissionsIncludeSystemTests: XCTestCase {

    private func makeAPI(_ transport: RecordingTransport) -> DocumentsAPI {
        DocumentsAPI(
            transport: transport,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
    }

    private static let systemRow = """
    {"documentId":"d1","groupType":"_col-reader","groupId":"g1",
     "permission":"reader","grantedAt":"2024-01-01T00:00:00Z","grantedBy":"u1"}
    """

    private static let appRow = """
    {"documentId":"d1","groupType":"class","groupId":"g2",
     "permission":"read-write","grantedAt":"2024-01-01T00:00:00Z","grantedBy":"u1"}
    """

    /// `includeSystem: true` sends the query param the server reads.
    func testIncludeSystemTrueSendsQueryParam() async throws {
        let transport = RecordingTransport(json: "[\(Self.appRow)]")
        let api = makeAPI(transport)

        _ = try await api.listGroupPermissions(documentId: "d1", includeSystem: true)

        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(
            transport.lastCall?.path,
            "/documents/d1/group-permissions?includeSystem=true"
        )
    }

    /// `includeSystem: true` must NOT re-filter the rows the server returned —
    /// that client-side filter is what made the flag unusable.
    func testIncludeSystemTrueKeepsSystemRows() async throws {
        let transport = RecordingTransport(json: "[\(Self.systemRow),\(Self.appRow)]")
        let api = makeAPI(transport)

        let entries = try await api.listGroupPermissions(documentId: "d1", includeSystem: true)

        XCTAssertEqual(entries.map { $0.groupType }, ["_col-reader", "class"])
    }

    /// The default sends no query param and still drops `_`-prefixed rows
    /// (defense against a server predating #506, which ignores the param).
    func testDefaultSendsNoParamAndFiltersSystemRows() async throws {
        let transport = RecordingTransport(json: "[\(Self.systemRow),\(Self.appRow)]")
        let api = makeAPI(transport)

        let entries = try await api.listGroupPermissions(documentId: "d1")

        XCTAssertEqual(transport.lastCall?.path, "/documents/d1/group-permissions")
        XCTAssertEqual(entries.map { $0.groupType }, ["class"])
    }
}
