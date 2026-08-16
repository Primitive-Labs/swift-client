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

        // Opening with waitForLoad: .network while offline fails with the
        // typed code JS throws. Until #2667 the open resolved with a
        // possibly-empty document instead, so this case tolerated either
        // outcome; it now pins the error.
        do {
            _ = try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true
            ))
            XCTFail("openDocument resolved while offline; expected DOCUMENT_UNAVAILABLE_OFFLINE")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentUnavailableOffline)
        }
    }

    /// The `documents.open` twin surface forwards the same typed errors —
    /// no wrapper swallows them (#2667, behavior 7). Uses the live server so
    /// the sub-API is exercised the way callers reach it, against a document
    /// that really exists.
    func testDocumentsOpenTwinSurfaceThrowsTypedErrors() async throws {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            offline: true
        )
        defer { Task { await client.destroy() } }

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)

        await client.goOffline()
        do {
            _ = try await client.documents.open(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true
            ))
            XCTFail("documents.open resolved while offline; expected DOCUMENT_UNAVAILABLE_OFFLINE")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentUnavailableOffline)
        }

        // And the connection-disabled path, online but unable to connect.
        await client.goOnline()
        await client.setShouldConnect(false)
        do {
            _ = try await client.documents.open(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true,
                availabilityWait: 1
            ))
            XCTFail("documents.open resolved with the connection disabled; expected CONNECTION_DISABLED")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .connectionDisabled)
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
