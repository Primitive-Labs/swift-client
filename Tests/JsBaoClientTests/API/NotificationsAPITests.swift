import XCTest
@testable import JsBaoClient

/// Wire-shape and decode tests for `NotificationsAPI` plus the `.notification`
/// WS event (parity with the JS client's `client.notifications.*` sub-API and
/// `notification` event — #1601, mirroring #779 / PR #1602).
///
/// The API tests instantiate the sub-API with a stub `makeRequest` closure
/// that records the `(method, path, body)` triple, invokes each public method,
/// and asserts the HTTP shape matches the js-bao counterpart
/// (`src/client/api/notificationsApi.ts`). They don't hit the network.
///
/// The WS test constructs a non-connecting client and feeds a raw
/// `type:"notification"` frame straight into `handleWebSocketMessage`,
/// asserting it decodes to a typed `NotificationEvent` and reaches
/// `.notification` subscribers.
final class NotificationsAPITests: XCTestCase {

    // MARK: - Recorder

    /// Captures the most recent HTTP request the stub closure was asked to
    /// make and returns a canned response. Mirrors the recorder used in
    /// `ApiParityTests`.
    final class CallRecorder: @unchecked Sendable {
        var method: String?
        var path: String?
        var body: Any?
        var response: Any = [String: Any]()

        func make(_ method: String, _ path: String, _ data: Any?) async throws -> Any {
            self.method = method
            self.path = path
            self.body = data
            return response
        }
    }

    /// A fully-populated `NotificationInfo` wire payload — every required
    /// field present so a strict decode succeeds.
    private func notificationJSON() -> [String: Any] {
        [
            "notificationId": "ntf1", "title": "Hello", "body": "World",
            "read": false, "createdAt": "2024-01-01T00:00:00Z",
        ]
    }

    /// A fully-populated `PushDeviceInfo` wire payload.
    private func deviceJSON() -> [String: Any] {
        [
            "tokenId": "tok1", "platform": "ios", "environment": "sandbox",
            "createdAt": "2024-01-01T00:00:00Z",
        ]
    }

    // MARK: - Inbox routes

    func test_list_GET_noParams() async throws {
        let r = CallRecorder()
        let api = NotificationsAPI(makeRequest: r.make)
        r.response = ["items": [notificationJSON()], "unreadCount": 1]
        let result = try await api.list()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/notifications")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.notificationId, "ntf1")
        XCTAssertEqual(result.unreadCount, 1)
    }

    func test_list_buildsCursorAndLimitQS() async throws {
        let r = CallRecorder()
        let api = NotificationsAPI(makeRequest: r.make)
        r.response = ["items": [[String: Any]](), "unreadCount": 0]
        _ = try await api.list(limit: 25, cursor: "abc def")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/notifications?limit=25&cursor=abc%20def")
    }

    func test_unreadCount_GET() async throws {
        let r = CallRecorder()
        let api = NotificationsAPI(makeRequest: r.make)
        r.response = ["unreadCount": 7]
        let result = try await api.unreadCount()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/notifications/unread-count")
        XCTAssertEqual(result.unreadCount, 7)
    }

    func test_markRead_PATCH_toReadPath() async throws {
        let r = CallRecorder()
        let api = NotificationsAPI(makeRequest: r.make)
        r.response = notificationJSON()
        let info = try await api.markRead(notificationId: "ntf1")
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.path, "/notifications/ntf1/read")
        XCTAssertEqual(info.notificationId, "ntf1")
    }

    func test_markAllRead_POST() async throws {
        let r = CallRecorder()
        let api = NotificationsAPI(makeRequest: r.make)
        r.response = ["updated": 3]
        let result = try await api.markAllRead()
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/notifications/read-all")
        XCTAssertEqual(result.updated, 3)
    }

    func test_send_POSTsParams_andDecodesResults() async throws {
        let r = CallRecorder()
        let api = NotificationsAPI(makeRequest: r.make)
        r.response = [
            "results": [
                ["channel": "in-app", "status": "delivered", "notificationId": "ntf9"],
            ],
            "deduplicated": false,
        ]
        let params = SendNotificationParams(
            title: "Hi",
            body: "There",
            target: .init(userId: "u1"),
            channels: ["in-app", "ios"],
            idempotencyKey: "k1"
        )
        let result = try await api.send(params: params)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/notifications/send")
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["title"] as? String, "Hi")
        XCTAssertEqual(body?["body"] as? String, "There")
        XCTAssertEqual((body?["target"] as? [String: Any])?["userId"] as? String, "u1")
        XCTAssertEqual(body?["channels"] as? [String], ["in-app", "ios"])
        XCTAssertEqual(body?["idempotencyKey"] as? String, "k1")
        XCTAssertEqual(result.results.count, 1)
        XCTAssertEqual(result.results.first?.channel, "in-app")
        XCTAssertEqual(result.results.first?.status, "delivered")
        XCTAssertEqual(result.results.first?.notificationId, "ntf9")
        XCTAssertEqual(result.deduplicated, false)
    }

    // MARK: - Push device routes

    func test_registerDevice_POST_toPushTokens() async throws {
        let r = CallRecorder()
        let api = NotificationsAPI(makeRequest: r.make)
        r.response = deviceJSON()
        let params = RegisterPushDeviceParams(
            token: "abcdef",
            platform: .ios,
            environment: .sandbox,
            bundleId: "com.example.app"
        )
        let info = try await api.registerDevice(params: params)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/me/push-tokens")
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["token"] as? String, "abcdef")
        XCTAssertEqual(body?["platform"] as? String, "ios")
        XCTAssertEqual(body?["environment"] as? String, "sandbox")
        XCTAssertEqual(body?["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(info.tokenId, "tok1")
        XCTAssertEqual(info.platform, .ios)
        XCTAssertEqual(info.environment, .sandbox)
    }

    func test_listDevices_GET_unwrapsItems() async throws {
        let r = CallRecorder()
        let api = NotificationsAPI(makeRequest: r.make)
        r.response = ["items": [deviceJSON()]]
        let result = try await api.listDevices()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/me/push-tokens")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.tokenId, "tok1")
    }

    func test_unregisterDevice_DELETE_encodesToken() async throws {
        let r = CallRecorder()
        let api = NotificationsAPI(makeRequest: r.make)
        r.response = ["deleted": true]
        let result = try await api.unregisterDevice(token: "tok with space")
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(r.path, "/me/push-tokens/tok%20with%20space")
        XCTAssertTrue(result.deleted)
    }

    // MARK: - WS event dispatch

    /// A raw `type:"notification"` frame must decode to a typed
    /// `NotificationEvent` and reach `.notification` subscribers — mirroring
    /// the JS client's `handleNotificationMessage`.
    func test_notificationFrame_emitsTypedEvent() async throws {
        let client = createTestClient(appId: "test-app", token: "test-token")
        defer { Task { await client.destroy() } }

        let lock = NSLock()
        var received: [NotificationEvent] = []
        let sub = client.eventEmitter.subscribe(NotificationEvent.self) { e in
            lock.withLock { received.append(e) }
        }
        defer { sub.cancel() }

        let frame = """
        {"type":"notification","notificationId":"ntf42","title":"Ping",\
        "body":"You have mail","iconUrl":"https://x/i.png",\
        "deepLink":"app://inbox","sourceRef":"api:u1",\
        "createdAt":"2024-05-01T12:00:00Z"}
        """
        await client.handleWebSocketMessage(frame)

        let events = lock.withLock { received }
        XCTAssertEqual(events.count, 1, "Expected exactly one notification event")
        let e = try XCTUnwrap(events.first)
        XCTAssertEqual(e.notificationId, "ntf42")
        XCTAssertEqual(e.title, "Ping")
        XCTAssertEqual(e.body, "You have mail")
        XCTAssertEqual(e.iconUrl, "https://x/i.png")
        XCTAssertEqual(e.deepLink, "app://inbox")
        XCTAssertEqual(e.sourceRef, "api:u1")
        XCTAssertEqual(e.createdAt, "2024-05-01T12:00:00Z")
    }
}
