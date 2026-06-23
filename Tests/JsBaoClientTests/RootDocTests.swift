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
        // The root document may or may not exist depending on app config
        do {
            let result = try await client.documents.getRoot()
            // If it exists, it should have a documentId
            XCTAssertFalse(result.documentId.isEmpty)
        } catch {
            // Root doc not configured is acceptable
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("404") || msg.contains("not found") || msg.contains("null"),
                "Unexpected error: \(msg)"
            )
        }
    }

    func testGetRootDocIdViaClient() async throws {
        // After #849/#1109: getRootDocId is a synchronous cached read of
        // the parsed JWT payload (JS `getRootDocId(): string | null` —
        // no HTTP call, no async, no throws). The test-mint endpoint
        // stuffs rootDocId into `payload.user.rootDocId`, so
        // getRootDocId() must return that exact value.
        let rootDocId = client.getRootDocId()
        XCTAssertNotNil(rootDocId, "Test JWT should carry a rootDocId")

        let payload = client.getJwtPayload()
        let userClaims = payload?["user"] as? [String: Any]
        let expected = userClaims?["rootDocId"] as? String
            ?? payload?["rootDocId"] as? String
        XCTAssertEqual(rootDocId, expected,
                       "getRootDocId() must mirror the JWT payload's rootDocId")
    }

    func testListFiltersRootByDefault() async throws {
        // #848: the root doc is excluded from the default owned-documents
        // listing, but getRoot() still resolves it. This calls
        // `me.ownedDocuments()` with no `includeRoot` option (the default),
        // so we assert the faithful surviving contract: the root doc is
        // filtered out of the default listing, yet getRoot() resolves it
        // directly. (`includeRoot: true` would surface it, like JS.)
        guard let root = client.getRootDocId() else {
            return XCTFail("Test JWT must include rootDocId for this test")
        }
        // Make sure the root doc has been materialized server-side so
        // there's something to filter (mint-test-jwt + ensureRootDocAssigned
        // can race against the list's DynamoDB index — getRoot() forces
        // a server-side resolve that warms the permission row).
        _ = try? await client.documents.getRoot()

        let owned = try await client.me.ownedDocuments()
        XCTAssertFalse(
            owned.contains { $0.documentId == root },
            "root doc must be filtered from the default owned-documents listing"
        )

        // getRoot() resolves the root doc directly even though it's absent
        // from the default listing. The root doc may not be materialized in
        // every test app (see testGetRootDocument), so a 404 is acceptable —
        // but when it does resolve, it must be the JWT's rootDocId.
        do {
            let resolvedRoot = try await client.documents.getRoot()
            XCTAssertEqual(
                resolvedRoot.documentId, root,
                "getRoot() must resolve the JWT's rootDocId"
            )
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("404") || msg.contains("not found") || msg.contains("null"),
                "Unexpected getRoot() error: \(msg)"
            )
        }
    }

    func testIsRootDocumentMatchesJwt() async throws {
        // isRootDocument should also resolve from the JWT payload, not
        // a separate HTTP-backed cache that has to warm up first.
        guard let rootDocId = client.getRootDocId() else {
            return XCTFail("Test JWT should carry a rootDocId")
        }
        XCTAssertTrue(client.isRootDocument(rootDocId))
        XCTAssertFalse(client.isRootDocument("not-the-root-doc"))
    }
}
