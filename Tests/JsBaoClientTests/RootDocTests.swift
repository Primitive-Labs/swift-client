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
            if let docId = result["documentId"] as? String {
                XCTAssertFalse(docId.isEmpty)
            }
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
        // After #849: getRootDocId reads from the parsed JWT payload
        // (no HTTP call). The test-mint endpoint stuffs rootDocId into
        // `payload.user.rootDocId`, so getRootDocId() must return that
        // exact value without throwing.
        let rootDocId = try await client.getRootDocId()
        XCTAssertNotNil(rootDocId, "Test JWT should carry a rootDocId")

        let payload = client.getJwtPayload()
        let userClaims = payload?["user"] as? [String: Any]
        let expected = userClaims?["rootDocId"] as? String
            ?? payload?["rootDocId"] as? String
        XCTAssertEqual(rootDocId, expected,
                       "getRootDocId() must mirror the JWT payload's rootDocId")
    }

    @available(*, deprecated, message: "exercises deprecated documents.list intentionally")
    func testListFiltersRootByDefault() async throws {
        // #848: documents.list() defaults to includeRoot=false. We
        // assert the filtering contract directly — the items returned
        // with includeRoot:false are exactly the includeRoot:true set
        // minus any entry whose documentId equals the JWT's rootDocId.
        guard let root = try await client.getRootDocId() else {
            return XCTFail("Test JWT must include rootDocId for this test")
        }
        // Make sure the root doc has been materialized server-side so
        // there's something to filter (mint-test-jwt + ensureRootDocAssigned
        // can race against the list's DynamoDB index — getRoot() forces
        // a server-side resolve that warms the permission row).
        _ = try? await client.documents.getRoot()

        let withRoot = try await client.documents.list(includeRoot: true)
        let withRootItems = (withRoot["items"] ?? withRoot["documents"]) as? [[String: Any]] ?? []
        let withoutRoot = try await client.documents.list()
        let withoutRootItems = (withoutRoot["items"] ?? withoutRoot["documents"]) as? [[String: Any]] ?? []

        let expectedAfterFilter = withRootItems.filter { ($0["documentId"] as? String) != root }
        XCTAssertEqual(
            withoutRootItems.count,
            expectedAfterFilter.count,
            "includeRoot:false should drop exactly the root doc"
        )
        XCTAssertFalse(
            withoutRootItems.contains { ($0["documentId"] as? String) == root },
            "Root doc \(root) must be filtered when includeRoot is false"
        )
    }

    func testIsRootDocumentMatchesJwt() async throws {
        // isRootDocument should also resolve from the JWT payload, not
        // a separate HTTP-backed cache that has to warm up first.
        guard let rootDocId = try await client.getRootDocId() else {
            return XCTFail("Test JWT should carry a rootDocId")
        }
        XCTAssertTrue(client.isRootDocument(rootDocId))
        XCTAssertFalse(client.isRootDocument("not-the-root-doc"))
    }
}
