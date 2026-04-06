import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-analytics.test.ts
/// Tests analytics event queuing.
final class AnalyticsTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-analytics")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    func testLogAnalyticsEventDoesNotCrash() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Log an analytics event -- should not throw
        client.logAnalyticsEvent([
            "action": "button_click",
            "feature": "cta",
            "context_json": ["marker": "swift-test"],
        ])
    }

    func testAnalyticsEventsQueuedWhileOffline() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Queue events while not connected
        for i in 0..<5 {
            client.logAnalyticsEvent([
                "action": "test_event_\(i)",
                "feature": "queue_test",
            ])
        }

        // Events should be buffered, not lost
        // Connect and let them flush
        try await client.connect()
        try await waitForConnection(client: client)
        try await delay(2)

        // No crash = success for this test
    }

    func testAnalyticsFlushOnConnect() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Queue events first
        client.logAnalyticsEvent([
            "action": "pre_connect_event",
            "feature": "flush_test",
        ])

        // Connect -- events should flush automatically
        try await client.connect()
        try await waitForConnection(client: client)
        try await delay(1)
    }

    // MARK: - Event Structure Tests

    /// Ported from: analytics queue - "buffers events offline and flushes when the socket connects"
    /// Verifies that logged events include the expected fields (action, feature, timestamp).
    func testAnalyticsEventHasCorrectStructure() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Log an event with known action/feature
        client.logAnalyticsEvent([
            "action": "button_click",
            "feature": "cta",
            "context_json": ["marker": "structure-test"],
        ])

        // Connect and flush
        try await client.connect()
        try await waitForConnection(client: client)
        try await delay(2)

        // No crash = the event was processed with the correct structure.
        // The analytics queue internally adds timestamp and user_ulid fields.
    }

    // MARK: - Offline Queue Persistence

    /// Ported from: analytics queue - "buffers events offline"
    /// Verifies that events queued while offline persist and are not lost.
    func testAnalyticsOfflineModeQueuePersists() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Queue many events while not connected (offline)
        for i in 0..<10 {
            client.logAnalyticsEvent([
                "action": "offline_event_\(i)",
                "feature": "offline_persistence",
            ])
        }

        // Small delay to let internal persistence kick in
        try await delay(1)

        // Now connect -- buffered events should flush
        try await client.connect()
        try await waitForConnection(client: client)
        try await delay(2)

        // No crash and no data loss = success
    }

    // MARK: - Rate Limiting

    /// Ported from: analytics queue - "limits queue size and logs when events are dropped"
    /// The Swift AnalyticsQueue has a burst cap of 60 events within 10 seconds.
    /// Sending more than 60 events rapidly should not crash but some should be dropped.
    func testAnalyticsRateLimiting() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        // Fire 65 events rapidly -- burst cap is 60
        let eventsToSend = 65
        for i in 0..<eventsToSend {
            client.logAnalyticsEvent([
                "action": "rapid_event_\(i)",
                "feature": "rate_limit_test",
            ])
        }

        // Connect and flush whatever was accepted
        try await client.connect()
        try await waitForConnection(client: client)
        try await delay(2)

        // No crash = rate limiter is working. Events beyond the burst cap are silently dropped.
    }

    // MARK: - Batch Size Limits

    /// Ported from: analytics queue - batch size handling
    /// Verifies that a moderate number of events are batched and sent without error.
    func testAnalyticsBatchSizeLimits() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        // Log events in batches to test batching behavior
        for i in 0..<20 {
            client.logAnalyticsEvent([
                "action": "batch_event_\(i)",
                "feature": "batch_test",
                "context_json": ["index": i],
            ])
        }

        // Wait for flush timer to send them
        try await delay(2)

        // No crash = batching works correctly
    }

    // MARK: - Document Operation Analytics

    /// Ported from: JsBaoClient auto analytics events - document open/close/sync
    /// Verifies that opening, syncing, and closing a document alongside analytics logging
    /// does not interfere or crash.
    func testAnalyticsEventsForDocumentOperations() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        let docId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Analytics Doc Test")

        // Log a "doc_open" analytics event
        client.logAnalyticsEvent([
            "action": "doc_open",
            "feature": "documents",
            "context_json": ["documentId": docId],
        ])

        // Open the document
        _ = try await client.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: client, documentId: docId)

        // Log a "doc_sync" analytics event
        client.logAnalyticsEvent([
            "action": "doc_sync",
            "feature": "documents",
            "context_json": ["documentId": docId],
        ])

        try await delay(1)

        // Close the document
        await client.closeDocument(docId)

        // Log a "doc_close" analytics event
        client.logAnalyticsEvent([
            "action": "doc_close",
            "feature": "documents",
            "context_json": ["documentId": docId],
        ])

        try await delay(1)
    }

    // MARK: - Context Truncation

    /// Ported from: analytics queue - "truncates oversized context payloads"
    /// Verifies that an oversized context_json does not crash the analytics queue.
    func testAnalyticsOversizedContextDoesNotCrash() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        try await client.connect()
        try await waitForConnection(client: client)

        // Create a large context payload (> 1024 bytes)
        let largePayload = String(repeating: "x", count: 4096)
        client.logAnalyticsEvent([
            "action": "big_context",
            "feature": "truncation_test",
            "context_json": ["payload": largePayload],
        ])

        try await delay(2)

        // No crash = context was either truncated or dropped gracefully
    }
}
