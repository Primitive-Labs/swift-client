import Foundation
import Network

/// Minimal in-process HTTP/1.1 server that answers a real `JsBaoClient`'s API
/// requests from a per-test script.
///
/// `LoopbackHTTPServer` answers every request with one canned body, which is
/// enough for a single blob download; this one routes on method and path and
/// records what was asked, so a client-level test can script "the server still
/// has this document" against "the server 404s it" without a dev server
/// (#3079).
///
/// Each request is answered on its own connection (`Connection: close`), the
/// same shape `LoopbackHTTPServer` uses.
final class LoopbackAPIServer: @unchecked Sendable {
    /// One request as the server saw it.
    struct Request: Sendable {
        let method: String
        /// Path as it arrived on the wire, e.g.
        /// `/app/test-app/api/documents?payloadType=full`.
        let path: String

        /// The path a caller asked `HttpClient` for, with the deployment
        /// prefix (`/app/<appId>/api`) removed — `/documents?payloadType=full`
        /// above. Tests script against this.
        var apiPath: String {
            guard let range = path.range(of: "/api/") else { return path }
            return String(path[range.lowerBound...].dropFirst("/api".count))
        }

        /// The path without its query string.
        var apiPathOnly: String {
            String(apiPath.prefix(while: { $0 != "?" }))
        }

        /// The request body, when the request declared a `Content-Length`
        /// (#3344). A test that only cares about routing ignores it; a test
        /// that has to say what a generated invoker PUT ON THE WIRE reads it.
        var body: Data? = nil

        /// The body parsed as a JSON object, for a wire-shape assertion.
        var jsonBody: [String: Any]? {
            guard let body else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    /// What to answer with: an HTTP status and a JSON body.
    struct Response: Sendable {
        let status: Int
        let body: String

        init(status: Int = 200, body: String = "{}") {
            self.status = status
            self.body = body
        }

        static func json(_ body: String) -> Response { Response(status: 200, body: body) }
        static func status(_ status: Int, _ message: String = "") -> Response {
            Response(status: status, body: #"{"error":"\#(message)"}"#)
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-api-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var _requests: [Request] = []
    private let responder: @Sendable (Request) -> Response

    /// Every request the server answered, in order.
    var requests: [Request] { lock.withLock { _requests } }

    /// The client-facing paths of every request the server answered, in order.
    var paths: [String] { requests.map(\.apiPath) }

    private(set) var port: UInt16 = 0

    init(responder: @escaping @Sendable (Request) -> Response) throws {
        self.responder = responder
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Starts the listener and blocks until it is ready (bounded), returning
    /// the base URL a client should be pointed at.
    func start() throws -> String {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.answer(connection, received: Data())
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(
                domain: "LoopbackAPIServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"]
            )
        }
        port = listener.port?.rawValue ?? 0
        return "http://127.0.0.1:\(port)"
    }

    /// Reads until the request head is complete, answers it, and closes.
    private func answer(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buffer = received
            if let chunk { buffer.append(chunk) }
            guard let request = Self.parseRequestLine(buffer) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.answer(connection, received: buffer)
                }
                return
            }
            // A declared body that has not fully arrived yet: keep reading
            // rather than answering a half-read request (#3344). A request with
            // no `Content-Length` is answered as soon as its head is complete,
            // exactly as before.
            if !Self.bodyIsComplete(buffer) {
                if isComplete {
                    connection.cancel()
                } else {
                    self.answer(connection, received: buffer)
                }
                return
            }
            self.lock.withLock { self._requests.append(request) }

            let response = self.responder(request)
            let body = Data(response.body.utf8)
            var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"

            var out = Data(head.utf8)
            out.append(body)
            connection.send(content: out, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// `GET /documents/abc HTTP/1.1` → `Request(method: "GET", path: "/documents/abc")`,
    /// once the whole head has arrived.
    private static func parseRequestLine(_ buffer: Data) -> Request? {
        guard let head = headEnd(buffer),
              let text = String(data: buffer.prefix(head.headerEnd), encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var request = Request(method: String(parts[0]), path: String(parts[1]))
        if head.contentLength > 0 {
            let bodyBytes = buffer.dropFirst(head.bodyStart)
            if bodyBytes.count >= head.contentLength {
                request.body = Data(bodyBytes.prefix(head.contentLength))
            }
        }
        return request
    }

    /// Where the head ends, where the body starts, and how long the body is.
    private static func headEnd(
        _ buffer: Data
    ) -> (headerEnd: Int, bodyStart: Int, contentLength: Int)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }
        let headerEnd = range.lowerBound - buffer.startIndex
        let bodyStart = range.upperBound - buffer.startIndex
        var contentLength = 0
        if let text = String(data: buffer.prefix(headerEnd), encoding: .utf8) {
            for header in text.components(separatedBy: "\r\n").dropFirst() {
                let pieces = header.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2,
                      pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
                        == "content-length"
                else { continue }
                contentLength = Int(pieces[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return (headerEnd, bodyStart, contentLength)
    }

    /// True when the buffer holds the whole declared body (or declares none).
    private static func bodyIsComplete(_ buffer: Data) -> Bool {
        guard let head = headEnd(buffer) else { return false }
        return buffer.count - head.bodyStart >= head.contentLength
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}
