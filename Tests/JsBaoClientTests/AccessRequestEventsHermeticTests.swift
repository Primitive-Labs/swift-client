import XCTest
@testable import JsBaoClient

/// The access-request events on the Swift client (#5519). The server's four
/// frames — `document:access-request-created`, `document:access-request-resolved`
/// and their `db3:` twins — arrive as `DocumentAccessRequestCreatedEvent`,
/// `DocumentAccessRequestResolvedEvent`, `Db3AccessRequestCreatedEvent` and
/// `Db3AccessRequestResolvedEvent`, each under the `JsBaoEvent` case whose raw
/// value is the frame type. Mirrors the JS client's events of the same names.
///
/// Server-free: frames are handed to `handleWebSocketMessage` on a client
/// connected to the in-process `LoopbackWebSocketServer`.
final class AccessRequestEventsHermeticTests: XCTestCase {

    private func connectedClient() async throws -> (LoopbackWebSocketServer, JsBaoClient) {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        let base = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: base,
            appId: "access-requests-hermetic",
            token: makeTestJwt(userId: "user-owner"),
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        try await client.connect()
        XCTAssertTrue(client.isConnected)
        return (server, client)
    }

    private func deliver(_ frame: [String: Any], to client: JsBaoClient) async {
        let data = try! JSONSerialization.data(withJSONObject: frame)
        await client.handleWebSocketMessage(String(data: data, encoding: .utf8)!)
    }

    private static var summary: [String: Any] {
        [
            "documentId": "doc-5519", "title": "Trip plan", "tags": ["travel"],
            "createdAt": "2026-11-01T10:00:00.000Z", "lastModified": "2026-11-02T10:00:00.000Z",
            "createdBy": "user-owner",
        ]
    }

    private static func created(_ type: String) -> [String: Any] {
        [
            "type": type, "requestId": "req-5519", "documentId": "doc-5519",
            "requesterId": "user-requester", "requesterEmail": "requester@example.com",
            "requesterName": "Requester", "requestedPermission": "reader",
            "message": "May I read it?", "status": "pending",
            "createdAt": "2026-11-06T12:00:00.000Z", "title": "Trip plan", "document": summary,
        ]
    }

    private static func resolved(_ type: String) -> [String: Any] {
        [
            "type": type, "requestId": "req-5519", "documentId": "doc-5519",
            "requesterId": "user-requester", "requestedPermission": "reader",
            "status": "approved", "grantedPermission": "reader", "resolvedBy": "user-owner",
            "resolvedAt": "2026-11-06T12:05:00.000Z", "title": "Trip plan", "document": summary,
        ]
    }

    private func assertSummary(_ document: AccessRequestDocumentSummary?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(document?.documentId, "doc-5519", file: file, line: line)
        XCTAssertEqual(document?.title, "Trip plan", file: file, line: line)
        XCTAssertEqual(document?.tags, ["travel"], file: file, line: line)
        XCTAssertEqual(document?.createdAt, "2026-11-01T10:00:00.000Z", file: file, line: line)
        XCTAssertEqual(document?.lastModified, "2026-11-02T10:00:00.000Z", file: file, line: line)
        XCTAssertEqual(document?.createdBy, "user-owner", file: file, line: line)
    }

    // MARK: - Behavior 11

    func testACreatedFrameEmitsItsTypedEventWithEveryField() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let events = await collectEvents(from: client.eventEmitter, event: DocumentAccessRequestCreatedEvent.self) {
            await deliver(Self.created("document:access-request-created"), to: client)
        }
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.requestId, "req-5519")
        XCTAssertEqual(event.documentId, "doc-5519")
        XCTAssertEqual(event.requesterId, "user-requester")
        XCTAssertEqual(event.requesterEmail, "requester@example.com")
        XCTAssertEqual(event.requesterName, "Requester")
        XCTAssertEqual(event.requestedPermission, "reader")
        XCTAssertEqual(event.message, "May I read it?")
        XCTAssertEqual(event.status, "pending")
        XCTAssertEqual(event.createdAt, "2026-11-06T12:00:00.000Z")
        XCTAssertEqual(event.title, "Trip plan")
        assertSummary(event.document)
    }

    func testAResolvedFrameEmitsItsTypedEventWithEveryField() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let events = await collectEvents(from: client.eventEmitter, event: DocumentAccessRequestResolvedEvent.self) {
            await deliver(Self.resolved("document:access-request-resolved"), to: client)
        }
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.requestId, "req-5519")
        XCTAssertEqual(event.documentId, "doc-5519")
        XCTAssertEqual(event.requesterId, "user-requester")
        XCTAssertEqual(event.requestedPermission, "reader")
        XCTAssertEqual(event.status, "approved")
        XCTAssertEqual(event.grantedPermission, "reader")
        XCTAssertEqual(event.resolvedBy, "user-owner")
        XCTAssertEqual(event.resolvedAt, "2026-11-06T12:05:00.000Z")
        XCTAssertEqual(event.title, "Trip plan")
        assertSummary(event.document)
    }

    func testTheDb3FramesEmitTheirOwnEventsWithTheSameFields() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        var documentCreated: [DocumentAccessRequestCreatedEvent] = []
        var documentResolved: [DocumentAccessRequestResolvedEvent] = []
        var resolvedTwins: [Db3AccessRequestResolvedEvent] = []
        let createdTwins = await collectEvents(from: client.eventEmitter, event: Db3AccessRequestCreatedEvent.self) {
            resolvedTwins = await collectEvents(from: client.eventEmitter, event: Db3AccessRequestResolvedEvent.self) {
                documentCreated = await collectEvents(from: client.eventEmitter, event: DocumentAccessRequestCreatedEvent.self) {
                    documentResolved = await collectEvents(from: client.eventEmitter, event: DocumentAccessRequestResolvedEvent.self) {
                        await deliver(Self.created("db3:access-request-created"), to: client)
                        await deliver(Self.resolved("db3:access-request-resolved"), to: client)
                    }
                }
            }
        }
        XCTAssertEqual(documentCreated, [], "a db3 frame does not raise the document event")
        XCTAssertEqual(documentResolved, [], "a db3 frame does not raise the document event")

        let created = try XCTUnwrap(createdTwins.first)
        XCTAssertEqual(createdTwins.count, 1)
        XCTAssertEqual(created.requestId, "req-5519")
        XCTAssertEqual(created.documentId, "doc-5519")
        XCTAssertEqual(created.requesterId, "user-requester")
        XCTAssertEqual(created.requesterEmail, "requester@example.com")
        XCTAssertEqual(created.requesterName, "Requester")
        XCTAssertEqual(created.requestedPermission, "reader")
        XCTAssertEqual(created.message, "May I read it?")
        XCTAssertEqual(created.status, "pending")
        XCTAssertEqual(created.createdAt, "2026-11-06T12:00:00.000Z")
        XCTAssertEqual(created.title, "Trip plan")
        assertSummary(created.document)

        let resolved = try XCTUnwrap(resolvedTwins.first)
        XCTAssertEqual(resolvedTwins.count, 1)
        XCTAssertEqual(resolved.status, "approved")
        XCTAssertEqual(resolved.grantedPermission, "reader")
        XCTAssertEqual(resolved.resolvedBy, "user-owner")
        XCTAssertEqual(resolved.resolvedAt, "2026-11-06T12:05:00.000Z")
        XCTAssertEqual(resolved.requestedPermission, "reader")
        assertSummary(resolved.document)
    }

    func testOptionalFieldsAbsentFromTheFrameDecodeToNil() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let bare: [String: Any] = [
            "type": "db3:access-request-resolved", "requestId": "r1", "documentId": "d1",
            "requesterId": "u1", "requestedPermission": "read-write", "status": "denied",
        ]
        let events = await collectEvents(from: client.eventEmitter, event: Db3AccessRequestResolvedEvent.self) {
            await deliver(bare, to: client)
        }
        let event = try XCTUnwrap(events.first)
        XCTAssertNil(event.grantedPermission)
        XCTAssertNil(event.resolvedBy)
        XCTAssertNil(event.resolvedAt)
        XCTAssertNil(event.title)
        XCTAssertNil(event.document)

        let created = await collectEvents(from: client.eventEmitter, event: DocumentAccessRequestCreatedEvent.self) {
            await deliver([
                "type": "document:access-request-created", "requestId": "r2", "documentId": "d1",
                "requesterId": "u1", "requestedPermission": "reader", "status": "pending",
            ], to: client)
        }
        let first = try XCTUnwrap(created.first)
        XCTAssertNil(first.message)
        XCTAssertNil(first.document)
        XCTAssertNil(first.requesterEmail)
        XCTAssertNil(first.requesterName)
        XCTAssertNil(first.createdAt)
    }

    // MARK: - Edge case: a frame missing a required field is dropped

    func testAFrameMissingARequiredFieldIsDroppedAndTheSocketStaysUp() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        var frame = Self.created("db3:access-request-created")
        frame.removeValue(forKey: "requestId")
        let errors = await collectEvents(from: client.eventEmitter, event: ConnectionErrorEvent.self) {
            let dropped = await collectEvents(from: client.eventEmitter, event: Db3AccessRequestCreatedEvent.self) {
                await deliver(frame, to: client)
                for field in ["documentId", "requesterId", "requestedPermission", "status"] {
                    var missing = Self.resolved("document:access-request-resolved")
                    missing.removeValue(forKey: field)
                    await deliver(missing, to: client)
                }
            }
            XCTAssertEqual(dropped, [])
            let heard = await collectEvents(from: client.eventEmitter, event: Db3AccessRequestCreatedEvent.self) {
                await deliver(Self.created("db3:access-request-created"), to: client)
            }
            XCTAssertEqual(heard.count, 1, "the next well-formed frame is still delivered")
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(client.isConnected, "a malformed frame must not tear down the socket")
    }

    // MARK: - Documented pattern: created and resolved are applied in arrival order

    /// The docs example observes both db3 events with `observeOnMainActor`,
    /// which keeps emit order across event types. A created/resolved pair
    /// queued back to back must reach the pending list in that order, so the
    /// resolved request does not linger.
    func testMainActorObserversApplyAQueuedCreatedResolvedPairInOrder() async throws {
        let (server, client) = try await connectedClient()
        defer { server.stop(); Task { await client.destroy() } }

        let pairs = 20
        let seen = LockedBox<[String]>([])
        let pending = LockedBox<Set<String>>([])
        let done = expectation(description: "every hop ran")
        done.expectedFulfillmentCount = pairs * 2
        let created = client.observeOnMainActor(Db3AccessRequestCreatedEvent.self) { e in
            seen.withValue { $0.append("created:\(e.requestId)") }
            pending.withValue { _ = $0.insert(e.requestId) }
            done.fulfill()
        }
        let resolved = client.observeOnMainActor(Db3AccessRequestResolvedEvent.self) { e in
            seen.withValue { $0.append("resolved:\(e.requestId)") }
            pending.withValue { _ = $0.remove(e.requestId) }
            done.fulfill()
        }
        defer {
            created.cancel()
            resolved.cancel()
        }

        for index in 0..<pairs {
            var createdFrame = Self.created("db3:access-request-created")
            createdFrame["requestId"] = "req-\(index)"
            var resolvedFrame = Self.resolved("db3:access-request-resolved")
            resolvedFrame["requestId"] = "req-\(index)"
            await deliver(createdFrame, to: client)
            await deliver(resolvedFrame, to: client)
        }

        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(seen.value, (0..<pairs).flatMap { ["created:req-\($0)", "resolved:req-\($0)"] })
        XCTAssertEqual(pending.value, [], "every resolved request is gone from the pending list")
    }

    // MARK: - Behavior 12: the cases, the keys and the typed emit

    func testTheFourCasesCarryTheFrameTypesAndEachPayloadLandsOnItsKey() {
        XCTAssertEqual(JsBaoEvent.documentAccessRequestCreated.rawValue, "document:access-request-created")
        XCTAssertEqual(JsBaoEvent.documentAccessRequestResolved.rawValue, "document:access-request-resolved")
        XCTAssertEqual(JsBaoEvent.db3AccessRequestCreated.rawValue, "db3:access-request-created")
        XCTAssertEqual(JsBaoEvent.db3AccessRequestResolved.rawValue, "db3:access-request-resolved")
        XCTAssertEqual(DocumentAccessRequestCreatedEvent.eventKey, .documentAccessRequestCreated)
        XCTAssertEqual(DocumentAccessRequestResolvedEvent.eventKey, .documentAccessRequestResolved)
        XCTAssertEqual(Db3AccessRequestCreatedEvent.eventKey, .db3AccessRequestCreated)
        XCTAssertEqual(Db3AccessRequestResolvedEvent.eventKey, .db3AccessRequestResolved)

        let registered = Set(allJsBaoEventPayloadTypes.map { "\($0)" })
        for name in [
            "DocumentAccessRequestCreatedEvent", "DocumentAccessRequestResolvedEvent",
            "Db3AccessRequestCreatedEvent", "Db3AccessRequestResolvedEvent",
        ] {
            XCTAssertTrue(registered.contains(name), "\(name) is in allJsBaoEventPayloadTypes")
        }

        let emitter = EventEmitter()
        let hits = LockedBox<[String]>([])
        let subs = [
            emitter.subscribe(DocumentAccessRequestCreatedEvent.self) { _ in hits.withValue { $0.append("document:created") } },
            emitter.subscribe(DocumentAccessRequestResolvedEvent.self) { _ in hits.withValue { $0.append("document:resolved") } },
            emitter.subscribe(Db3AccessRequestCreatedEvent.self) { _ in hits.withValue { $0.append("db3:created") } },
            emitter.subscribe(Db3AccessRequestResolvedEvent.self) { _ in hits.withValue { $0.append("db3:resolved") } },
        ]
        defer { subs.forEach { $0.cancel() } }
        let created = DocumentAccessRequestCreatedEvent(
            requestId: "r1", documentId: "d1", requesterId: "u1", requestedPermission: "reader", status: "pending"
        )
        let resolved = DocumentAccessRequestResolvedEvent(
            requestId: "r1", documentId: "d1", requesterId: "u1", requestedPermission: "reader", status: "approved"
        )
        emitter.emit(created)
        emitter.emit(resolved)
        emitter.emit(Db3AccessRequestCreatedEvent(created))
        emitter.emit(Db3AccessRequestResolvedEvent(resolved))
        XCTAssertEqual(hits.value, ["document:created", "document:resolved", "db3:created", "db3:resolved"])
    }
}
