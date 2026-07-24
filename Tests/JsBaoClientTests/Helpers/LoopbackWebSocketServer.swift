import Foundation
import Network

/// Minimal in-process WebSocket accept server for server-free WebSocketManager
/// tests (issue #1910, Phase 4). Uses `NWListener` + `NWProtocolWebSocket` on a
/// loopback port so a real `URLSessionWebSocketTask` completes its handshake
/// (`didOpenWithProtocol` fires) without any external dev server and without
/// adding an injection seam to production code — the manager is driven through
/// its real public `connect()`/`disconnect()` API against a real socket.
///
/// It accepts connections, auto-replies to pings, and drains incoming frames
/// (including the client's close frame). It does not echo — the disconnect
/// atomicity tests only need a socket that opens and can be closed.
final class LoopbackWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-ws-server")
    private var connections: [NWConnection] = []
    private let lock = NSLock()

    /// The loopback port the server is listening on, valid after `start()`.
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        listener = try NWListener(using: params, on: .any)
    }

    /// Starts the listener and blocks until it is ready (bounded), returning the
    /// bound loopback URL (`ws://127.0.0.1:<port>/`).
    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.drain(connection)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "LoopbackWebSocketServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
        }
        port = listener.port?.rawValue ?? 0
        return URL(string: "ws://127.0.0.1:\(port)/")!
    }

    /// Recursively drains messages from a connection so the WebSocket close
    /// handshake completes when the client cancels its task.
    private func drain(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, isComplete, error in
            guard let self = self else { return }
            if error != nil || isComplete {
                // Peer closed or errored — let the connection tear down.
                if error != nil { connection.cancel() }
                return
            }
            self.drain(connection)
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
