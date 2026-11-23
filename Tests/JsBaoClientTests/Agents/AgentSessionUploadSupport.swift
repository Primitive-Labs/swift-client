import Foundation
import XCTest
@testable import JsBaoClient

/// The loopback the session-upload suites script per test (#4588): every
/// request is answered by the current route at once, except one matching
/// `hold`, which waits until the test releases it.
final class SessionUploadServer: @unchecked Sendable {
    typealias Request = LoopbackAPIServer.Request
    typealias Response = LoopbackAPIServer.Response

    struct HeldRequest: Sendable {
        let request: Request
        let respond: @Sendable (Response) -> Void
    }

    let server: LoopbackAPIServer
    let baseUrl: String
    private let route: LockedBox<@Sendable (Request) -> Response>
    private let holding: LockedBox<(@Sendable (Request) -> Bool)?>
    private let held: LockedBox<[HeldRequest]>

    init(_ route: @escaping @Sendable (Request) -> Response = SessionUploadServer.acceptAll) throws {
        let routeBox = LockedBox(route)
        let holdingBox = LockedBox<(@Sendable (Request) -> Bool)?>(nil)
        let heldBox = LockedBox<[HeldRequest]>([])
        server = try LoopbackAPIServer(deferredResponder: { request, respond in
            if let hold = holdingBox.value, hold(request) {
                heldBox.withValue { $0.append(HeldRequest(request: request, respond: respond)) }
                return
            }
            respond(routeBox.value(request))
        })
        self.route = routeBox
        self.holding = holdingBox
        self.held = heldBox
        baseUrl = try server.start()
    }

    /// Answer every later request with `route`.
    func answer(_ route: @escaping @Sendable (Request) -> Response) {
        self.route.value = route
    }

    /// Hold every later request `predicate` matches; `nil` holds nothing more.
    func hold(_ predicate: (@Sendable (Request) -> Bool)?) {
        holding.value = predicate
    }

    var heldRequests: [Request] { held.value.map(\.request) }

    /// Answer the oldest held request with `response`.
    func release(_ response: Response) {
        let first: HeldRequest? = held.withValue { $0.isEmpty ? nil : $0.removeFirst() }
        first?.respond(response)
    }

    func stop() {
        hold(nil)
        while !held.value.isEmpty { release(.status(503, "stopped")) }
        server.stop()
    }

    var requests: [Request] { server.requests }

    /// Every PUT to a session attachment route.
    var attachmentPuts: [Request] {
        requests.filter { $0.method == "PUT" && $0.apiPathOnly.contains("/attachments/") }
    }

    /// The PUTs of one blob to a session attachment route.
    func puts(of blobId: String) -> [Request] {
        attachmentPuts.filter { $0.apiPathOnly.hasSuffix("/attachments/\(blobId)") }
    }

    /// Every GET of a session attachment's download route.
    var downloads: [Request] {
        requests.filter { $0.method == "GET" && $0.apiPathOnly.hasSuffix("/download") }
    }

    // MARK: - Responses

    static func isAttachmentPut(_ request: Request) -> Bool {
        request.method == "PUT" && request.apiPathOnly.contains("/attachments/")
    }

    /// The route's 201 for a PUT: the stored file.
    static func created(_ request: Request) -> Response {
        let blobId = request.apiPathOnly.split(separator: "/").last.map(String.init) ?? ""
        let size = request.body?.count ?? 0
        return Response(status: 201, body: """
        {"blobId":"\(blobId)","filename":"f","contentType":"application/octet-stream","numBytes":\(size),\
        "createdAt":"2026-10-20T00:00:00.000Z","bytesTransferred":\(size)}
        """)
    }

    static func refused(_ status: Int, _ code: String, _ message: String = "refused") -> Response {
        Response(status: status, body: #"{"error":"\#(message)","code":"\#(code)"}"#)
    }

    /// Attachment and document PUTs land; downloads answer the session's
    /// not-found; a logout is answered; everything else is not scripted.
    static let acceptAll: @Sendable (Request) -> Response = { request in
        if request.method == "PUT", request.apiPathOnly.contains("/attachments/") || request.apiPathOnly.contains("/blobs/") {
            return created(request)
        }
        if request.method == "GET", request.apiPathOnly.hasSuffix("/download") {
            return refused(404, "AGENT_SESSION_ATTACHMENT_NOT_FOUND", "No such attachment")
        }
        if request.apiPathOnly == "/auth/logout" { return .json("{}") }
        return .status(404, "not scripted")
    }
}

/// The JSON `get` answers for a session.
func sessionInfoJSON(_ sessionId: String, role: String = "owner") -> String {
    #"""
    {"sessionId":"\#(sessionId)","agentKey":"helper","ownerUserId":"u-a",
     "createdAt":"2026-10-13T00:00:00.000Z","title":null,"scope":null,"lastActivityAt":null,
     "members":{"viewers":[],"participants":[]},"role":"\#(role)","status":"idle","turn":null}
    """#
}

/// A client over `server` signed in with `token` (a test JWT for `userId`),
/// never connecting.
func makeSessionUploadClient(
    _ server: SessionUploadServer, userId: String = "u-a", token: String? = nil
) -> JsBaoClient {
    JsBaoClient(options: JsBaoClientOptions(
        apiUrl: server.baseUrl, wsUrl: "ws://127.0.0.1:1", appId: "agent-session-uploads",
        token: token ?? makeTestJwt(userId: userId), offline: false, logLevel: .none,
        storageConfig: .memory, autoNetwork: false
    ))
}

/// A session view over the session's db3 on this device (`SessionDb3`, a
/// real binding and lifecycle): the route answers `get` for `sessionId`,
/// everything else as `fallback` does. The caller cleans the db3 up.
func openLocalSessionView(
    _ client: JsBaoClient, _ server: SessionUploadServer, sessionId: String = "s1",
    fallback: @escaping @Sendable (SessionUploadServer.Request) -> SessionUploadServer.Response
        = SessionUploadServer.acceptAll
) async throws -> (view: AgentSessionView, db3: SessionDb3) {
    let db3 = try await SessionDb3.make(id: sessionId)
    server.answer { request in
        if request.method == "GET", request.apiPathOnly == "/agent-sessions/\(sessionId)" {
            return .json(sessionInfoJSON(sessionId))
        }
        return fallback(request)
    }
    let view = try await client.agents.sessions.open(sessionId: sessionId, db3: db3)
    return (view, db3)
}

struct BoundedWaitTimeout: Error, CustomStringConvertible {
    let description: String
}

/// `op`, failing with `BoundedWaitTimeout` when it takes longer than
/// `seconds`, so a red run ends rather than hanging.
func within<T: Sendable>(
    _ seconds: Double = 10, _ what: String, _ op: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await withTimeout(ms: Int(seconds * 1000), op)
    } catch is AsyncTimeoutError {
        throw BoundedWaitTimeout(description: "\(what) did not finish within \(seconds)s")
    }
}

/// The error `op` throws, or nil when it returns.
func thrown(_ op: () async throws -> Void) async -> Error? {
    do {
        try await op()
        return nil
    } catch {
        return error
    }
}

/// The `blobs:upload-*` events a client emits, collected in order.
final class BlobEventLog: @unchecked Sendable {
    private let failedBox = LockedBox([BlobUploadFailedEvent]())
    private let completedBox = LockedBox([BlobUploadCompletedEvent]())
    private let progressBox = LockedBox([BlobUploadProgressEvent]())
    private var subscriptions: [EventSubscription] = []

    init(_ client: JsBaoClient) {
        let failedBox = self.failedBox
        let completedBox = self.completedBox
        let progressBox = self.progressBox
        subscriptions = [
            client.eventEmitter.subscribe(BlobUploadFailedEvent.self) { event in failedBox.withValue { $0.append(event) } },
            client.eventEmitter.subscribe(BlobUploadCompletedEvent.self) { event in
                completedBox.withValue { $0.append(event) }
            },
            client.eventEmitter.subscribe(BlobUploadProgressEvent.self) { event in
                progressBox.withValue { $0.append(event) }
            },
        ]
    }

    func failed(_ blobId: String) -> [BlobUploadFailedEvent] { failedBox.value.filter { $0.blobId == blobId } }
    func completed(_ blobId: String) -> [BlobUploadCompletedEvent] { completedBox.value.filter { $0.blobId == blobId } }
    func progress(_ blobId: String) -> [BlobUploadProgressEvent] { progressBox.value.filter { $0.blobId == blobId } }

    func cancel() {
        subscriptions.forEach { $0.cancel() }
    }
}
