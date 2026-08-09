import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-root-doc.test.ts
/// Tests root document support.
final class RootDocTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-root-doc")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    func testGetRootDocument() async throws {
        // #2358: getRoot() must resolve the JWT's rootDocId locally and then
        // fetch that document, matching js-bao (documentsApi.ts getRoot()).
        // There is no `GET /documents/root` route on the server.
        guard let rootDocId = client.rootDocId else {
            return XCTFail("Test JWT should carry a rootDocId")
        }
        let result = try await client.documents.getRoot()
        XCTAssertEqual(
            result.documentId, rootDocId,
            "getRoot() must return the document identified by rootDocId"
        )
    }

    func testGetRootDocIdViaClient() async throws {
        // After #849/#1109: rootDocId is a synchronous cached read of
        // the parsed JWT payload (JS `getRootDocId(): string | null` —
        // no HTTP call, no async, no throws). The test-mint endpoint
        // stuffs rootDocId into `payload.user.rootDocId`, so
        // rootDocId must return that exact value.
        let rootDocId = client.rootDocId
        XCTAssertNotNil(rootDocId, "Test JWT should carry a rootDocId")

        let payload = client.jwtPayload
        let expected = payload?["user"]?["rootDocId"]?.stringValue
            ?? payload?["rootDocId"]?.stringValue
        XCTAssertEqual(rootDocId, expected,
                       "rootDocId must mirror the JWT payload's rootDocId")
    }

    func testListFiltersRootByDefault() async throws {
        // #848: the root doc is excluded from the default owned-documents
        // listing, but getRoot() still resolves it. This calls
        // `me.ownedDocuments()` with no `includeRoot` option (the default),
        // so we assert the faithful surviving contract: the root doc is
        // filtered out of the default listing, yet getRoot() resolves it
        // directly. (`includeRoot: true` would surface it, like JS.)
        guard let root = client.rootDocId else {
            return XCTFail("Test JWT must include rootDocId for this test")
        }
        // Make sure the root doc has been materialized server-side so
        // there's something to filter (mint-test-jwt + ensureRootDocAssigned
        // can race against the list's DynamoDB index — getRoot() forces
        // a server-side resolve that warms the permission row).
        let rootInfo = try await client.documents.getRoot()

        // Warm the local metadata cache WITH the root row. After #2360 the
        // default `waitForLoad` is local-first, so a warm cache is the branch
        // that actually answers a default call — an empty cache would take the
        // cold-cache network branch and never exercise the local filter.
        var rootRow: [String: Any] = [
            "documentId": rootInfo.documentId,
            "title": rootInfo.title,
            "permission": rootInfo.permission.rawValue,
        ]
        if let tags = rootInfo.tags { rootRow["tags"] = tags }
        await client.documentManager.handleServerDocuments([rootRow])
        XCTAssertNotNil(
            client.documentManager.getMetadataIndex()[root],
            "the local cache must hold the root row for this test to mean anything"
        )

        let owned = try await client.me.ownedDocuments()
        XCTAssertFalse(
            owned.contains { $0.documentId == root },
            "root doc must be filtered from the default owned-documents listing"
        )

        // Mirror direction: `includeRoot: true` surfaces the cached root
        // rather than silently omitting it (js-bao parity, #2360).
        let withRoot = try await client.me.ownedDocuments(
            options: MeOwnedDocumentsOptions(includeRoot: true)
        )
        XCTAssertTrue(
            withRoot.contains { $0.documentId == root },
            "includeRoot: true must surface the root doc"
        )

        // getRoot() resolves the root doc directly even though it's absent
        // from the default listing, but getRoot() must still resolve it.
        let resolvedRoot = try await client.documents.getRoot()
        XCTAssertEqual(
            resolvedRoot.documentId, root,
            "getRoot() must resolve the JWT's rootDocId"
        )
    }

    func testIsRootDocumentMatchesJwt() async throws {
        // isRootDocument should also resolve from the JWT payload, not
        // a separate HTTP-backed cache that has to warm up first.
        guard let rootDocId = client.rootDocId else {
            return XCTFail("Test JWT should carry a rootDocId")
        }
        XCTAssertTrue(client.isRootDocument(rootDocId))
        XCTAssertFalse(client.isRootDocument("not-the-root-doc"))
    }
}
