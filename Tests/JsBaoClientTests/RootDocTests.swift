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
        // getRootDocId may return nil or throw 404 if no root doc exists
        do {
            let rootDocId = try await client.getRootDocId()
            // Just verify it doesn't crash -- value may be nil
            _ = rootDocId
        } catch {
            // 404 is expected for a freshly created app with no root doc
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("404") || msg.contains("not found"),
                "Unexpected error: \(msg)"
            )
        }
    }
}
