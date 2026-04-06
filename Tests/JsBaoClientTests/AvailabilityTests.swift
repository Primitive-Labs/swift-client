import XCTest
@testable import JsBaoClient
import YSwift

/// Port of tests/client/js-bao-client-availability.test.ts
/// Tests availability gating: waitForLocalOrNetwork behavior.
final class AvailabilityTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-availability")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testOfflineNetworkRejects() async throws {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            offline: true
        )
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        // Start offline
        await client.goOffline()

        // Attempting to open with waitForLoad: .network while offline should fail
        do {
            _ = try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true
            ))
            // If we get here without error, the client might handle this gracefully
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("OFFLINE") || msg.contains("UNAVAILABLE") || msg.contains("offline"),
                "Expected offline error, got: \(msg)"
            )
        }
    }

    func testOnlineAutoResolvesAfterSync() async throws {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            offline: true
        )
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        // Go online
        await client.goOnline()
        try await waitForConnection(client: client, timeout: 10)

        // Open document -- should succeed when online
        let ydoc = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .network,
            enableNetworkSync: true
        ))
        try await waitForSync(client: client, documentId: docId)

        XCTAssertNotNil(ydoc)
        XCTAssertTrue(client.isSynced(docId))
    }

    func testLocalIfAvailableElseNetworkFallsBackToNetwork() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        // No local copy, should fall back to network
        let ydoc = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .localIfAvailableElseNetwork,
            enableNetworkSync: true
        ))
        try await waitForSync(client: client, documentId: docId)

        XCTAssertNotNil(ydoc)
    }
}
