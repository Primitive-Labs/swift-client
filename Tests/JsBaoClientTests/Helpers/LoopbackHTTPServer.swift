import Foundation
import Network

/// Minimal in-process HTTP/1.1 server that answers every request with one
/// canned response. It stands in for the R2 origin an oversized `syncStep2` /
/// `update` frame points at (`updateUrl`), so the client's real download path —
/// including the `X-Compressed` header contract — runs against a real socket
/// without a dev server (#2661).
///
/// Same shape as `LoopbackWebSocketServer`: `NWListener` on a loopback port,
/// started and stopped by the test.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-http-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private let body: Data
    private let headers: [String: String]

    /// The loopback port the server is listening on, valid after `start()`.
    private(set) var port: UInt16 = 0

    private var _requestCount = 0

    /// How many requests the server has answered.
    var requestCount: Int { lock.withLock { _requestCount } }

    init(body: Data, headers: [String: String] = [:]) throws {
        self.body = body
        self.headers = headers
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Starts the listener and blocks until it is ready (bounded), returning
    /// the bound loopback URL.
    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.answer(connection)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "LoopbackHTTPServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
        }
        port = listener.port?.rawValue ?? 0
        return URL(string: "http://127.0.0.1:\(port)/update")!
    }

    /// Reads the request (enough of it to know one arrived) and writes the
    /// canned response, then closes — `Connection: close` is what tells
    /// URLSession the body is complete.
    private func answer(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, _, error in
            guard let self = self, error == nil else {
                connection.cancel()
                return
            }
            self.lock.withLock { self._requestCount += 1 }

            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Length: \(self.body.count)\r\n"
            head += "Connection: close\r\n"
            for (name, value) in self.headers {
                head += "\(name): \(value)\r\n"
            }
            head += "\r\n"

            var response = Data(head.utf8)
            response.append(self.body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
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
