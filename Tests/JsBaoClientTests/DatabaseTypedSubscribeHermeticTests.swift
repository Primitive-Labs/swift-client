import Foundation
import XCTest
@testable import JsBaoClient

/// #2805 — the typed `databases.subscribe` overload the CLI-generated Swift
/// subscriptions factory binds to.
///
/// The untyped `subscribe` hands back `DatabaseChangeEvent`, whose `data` /
/// `previousData` are `Any?`, so a Swift app casts by hand. The typed overload
/// decodes both into the caller's `Row` and threads the envelope through
/// unchanged.
///
/// The decode is deliberately *lenient*: a `db.change` frame carries only the
/// fields the write touched (`patch` / `increment` / set ops send just the
/// delta, and the subscription's `select` narrows further), so a row type must
/// declare its fields optional and a field the frame omitted decodes to `nil`
/// rather than failing the frame. That is the #1772 divergence from the JS
/// factory, which types the delta as the full record.
///
/// Server-free (`*HermeticTests`): the API is built on a stub transport and the
/// frames are dispatched straight through the subscription registry.
final class DatabaseTypedSubscribeHermeticTests: XCTestCase {

    // MARK: - Fixtures

    /// A generated-shape row: every field optional, so a delta frame decodes.
    private struct TaskRow: Codable, Equatable, Sendable {
        var id: String?
        var title: String?
        var done: Bool?
    }

    private struct StubTransportError: Error {}

    private struct StubTransport: Transport {
        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            throw StubTransportError()
        }
    }

    /// Collects the control frames the API would have sent over the WebSocket.
    private final class SentFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [String] = []
        func append(_ frame: String) { lock.withLock { frames.append(frame) } }
        var all: [String] { lock.withLock { frames } }
    }

    /// A `DatabasesAPI` wired to a live registry with the socket reported open,
    /// so `subscribe` registers and `registry.dispatch(...)` reaches the
    /// callback — the same path the WS message router drives in production.
    private func makeAPI(
        registry: DatabaseSubscriptionRegistry,
        sent: SentFrames = SentFrames()
    ) -> DatabasesAPI {
        DatabasesAPI(
            transport: StubTransport(),
            subscriptionRegistry: registry,
            sendWSMessage: { sent.append($0) },
            isWebSocketOpen: { true },
            connectWebSocket: {}
        )
    }

    /// One `db.change` wire frame, in the `[String: Any]` shape the router
    /// parses before handing it to the registry.
    private func frame(changes: [[String: Any]]) -> [String: Any] {
        [
            "type": "db.change",
            "databaseId": "db_1",
            "subscriptionKey": "myTasks",
            "changes": changes,
            "timestamp": "2026-08-19T00:00:00.000Z",
            "originUserId": "u_1",
        ]
    }

    // MARK: - Decoding

    func test_typedSubscribe_decodesAFullRow() throws {
        let registry = DatabaseSubscriptionRegistry()
        let api = makeAPI(registry: registry)
        let received = UncheckedBox<TypedDatabaseChangePayload<TaskRow>?>(nil)

        let handle = try api.subscribe(
            databaseId: "db_1",
            subscriptionKey: "myTasks",
            rowType: TaskRow.self
        ) { payload in received.value = payload }
        defer { handle.cancel() }

        registry.dispatch(frame(changes: [[
            "op": "save",
            "changeType": "enter",
            "modelName": "Task",
            "id": "t_1",
            "data": ["id": "t_1", "title": "Write it down", "done": false],
        ]]))

        let payload = try XCTUnwrap(received.value)
        XCTAssertEqual(payload.subscriptionKey, "myTasks")
        let change = try XCTUnwrap(payload.changes.first)
        XCTAssertEqual(change.op, "save")
        XCTAssertEqual(change.changeType, "enter")
        XCTAssertEqual(change.id, "t_1")
        XCTAssertEqual(change.data, TaskRow(id: "t_1", title: "Write it down", done: false))
        XCTAssertNil(change.previousData)
    }

    func test_typedSubscribe_deltaFrameLeavesUntouchedFieldsNil() throws {
        let registry = DatabaseSubscriptionRegistry()
        let api = makeAPI(registry: registry)
        let received = UncheckedBox<TypedDatabaseChangePayload<TaskRow>?>(nil)

        let handle = try api.subscribe(
            databaseId: "db_1",
            subscriptionKey: "myTasks",
            rowType: TaskRow.self
        ) { payload in received.value = payload }
        defer { handle.cancel() }

        // A `patch` frame carries ONLY the changed field, and `previousData` is
        // the pre-write row projected to the subscription's `select`.
        registry.dispatch(frame(changes: [[
            "op": "patch",
            "changeType": "update",
            "modelName": "Task",
            "id": "t_1",
            "data": ["done": true],
            "previousData": ["id": "t_1", "done": false],
        ]]))

        let change = try XCTUnwrap(received.value?.changes.first)
        XCTAssertEqual(change.data, TaskRow(id: nil, title: nil, done: true))
        XCTAssertEqual(change.previousData, TaskRow(id: "t_1", title: nil, done: false))
    }

    func test_typedSubscribe_undecodableBlobIsNilAndTheRawEventSurvives() throws {
        let registry = DatabaseSubscriptionRegistry()
        let api = makeAPI(registry: registry)
        let received = UncheckedBox<TypedDatabaseChangePayload<TaskRow>?>(nil)

        let handle = try api.subscribe(
            databaseId: "db_1",
            subscriptionKey: "myTasks",
            rowType: TaskRow.self
        ) { payload in received.value = payload }
        defer { handle.cancel() }

        // `done` arrives as a string — not a `TaskRow`. The frame must still be
        // delivered, with the raw blob reachable.
        registry.dispatch(frame(changes: [[
            "op": "save",
            "modelName": "Task",
            "id": "t_1",
            "data": ["done": "yes"],
        ]]))

        let change = try XCTUnwrap(received.value?.changes.first)
        XCTAssertNil(change.data, "a blob that is not a Row must not be forced into one")
        XCTAssertEqual((change.raw.data as? [String: Any])?["done"] as? String, "yes")
    }

    // MARK: - Envelope + options

    func test_typedSubscribe_threadsTheEnvelopeAndSendsTheParams() throws {
        let registry = DatabaseSubscriptionRegistry()
        let sent = SentFrames()
        let api = makeAPI(registry: registry, sent: sent)
        let received = UncheckedBox<TypedDatabaseChangePayload<TaskRow>?>(nil)

        let handle = try api.subscribe(
            databaseId: "db_1",
            subscriptionKey: "myTasks",
            rowType: TaskRow.self,
            options: DatabaseSubscribeOptions(params: ["ownerId": .string("u_1")])
        ) { payload in received.value = payload }
        defer { handle.cancel() }

        // The bound params rode the `db.subscribe` frame, exactly as the
        // untyped overload sends them.
        let subscribeFrame = try XCTUnwrap(sent.all.first)
        XCTAssertTrue(subscribeFrame.contains("\"db.subscribe\""))
        XCTAssertTrue(subscribeFrame.contains("\"ownerId\""))

        registry.dispatch(frame(changes: []))

        let payload = try XCTUnwrap(received.value)
        XCTAssertEqual(payload.databaseId, "db_1")
        XCTAssertEqual(payload.subscriptionKey, "myTasks")
        XCTAssertEqual(payload.timestamp, "2026-08-19T00:00:00.000Z")
        XCTAssertEqual(payload.originUserId, "u_1")
        XCTAssertNil(payload.originConnectionId)
        XCTAssertFalse(payload.isOrigin)
        XCTAssertTrue(payload.changes.isEmpty)
    }
}

/// Mutable capture box for the `@Sendable` change callbacks above. The test
/// body and the callback run on the same thread here (dispatch is synchronous),
/// so the unchecked conformance is confined to this file.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
