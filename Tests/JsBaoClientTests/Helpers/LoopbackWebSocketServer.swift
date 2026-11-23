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
///
/// Like the real server it sends `{"type":"ready"}` on each connection once
/// the upgrade completes (#5578), unless `sendsReady` is off; a test about the
/// window between the open and `ready` turns it off and pushes `ready` itself.
final class LoopbackWebSocketServer: @unchecked Sendable {
    /// The frame the real server sends once the user's events reach a socket.
    static let readyFrame = #"{"type":"ready"}"#

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-ws-server")
    private var connections: [NWConnection] = []
    private let lock = NSLock()

    /// The loopback port the server is listening on, valid after `start()`.
    private(set) var port: UInt16 = 0

    private var _acceptedCount = 0
    private var _receivedFrames: [String] = []
    private var _framesByConnection: [Int: [String]] = [:]
    private var _closedConnections: Set<Int> = []
    private var _sendsReady: Bool

    /// Whether each connection is sent `ready` once its upgrade completes.
    /// Settable, so a test can let one connection come up and hold the next.
    var sendsReady: Bool {
        get { lock.withLock { _sendsReady } }
        set { lock.withLock { _sendsReady = newValue } }
    }

    /// The text frames one connection received, by acceptance order (0 first).
    func receivedFrames(onConnection index: Int) -> [String] {
        lock.withLock { _framesByConnection[index] ?? [] }
    }

    /// Whether the connection at `index` has been closed by its peer, or by
    /// `close(connection:)`.
    func isClosed(connection index: Int) -> Bool {
        lock.withLock { _closedConnections.contains(index) }
    }

    /// Every text frame the server has received, in arrival order. Lets a test
    /// assert on what the client actually put on the wire (e.g. that no
    /// syncStep1 went out) without reaching into the client's internals.
    var receivedFrames: [String] { lock.withLock { _receivedFrames } }

    /// How many connections the listener has accepted since it started. It is
    /// the server-side view of "a fresh socket was built", which is what a test
    /// driving the client facade can observe without reaching into the client's
    /// private `WebSocketManager` (#2171 behavior 15).
    var acceptedCount: Int { lock.withLock { _acceptedCount } }

    /// - Parameter completesHandshake: when `false` the listener speaks plain
    ///   TCP and never answers the WebSocket upgrade, so a client's `connect()`
    ///   stays in flight indefinitely. #2171's ordering tests need that: they
    ///   have to inject a constructed `didOpen` / `didCloseWith` pair *while* a
    ///   connect is pending, which is impossible against a server that
    ///   completes the handshake on its own.
    ///
    /// - Parameter sendsReady: whether each connection is sent `ready` once
    ///   its upgrade completes, as the real server does (#5578).
    init(completesHandshake: Bool = true, sendsReady: Bool = true) throws {
        _sendsReady = sendsReady
        let params = NWParameters.tcp
        if completesHandshake {
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        }
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
            let index = self.lock.withLock { () -> Int in
                self.connections.append(connection)
                self._acceptedCount += 1
                return self._acceptedCount - 1
            }
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state, self.sendsReady else { return }
                // On the server's own queue, where the send completes: not
                // waited for, or the queue would wait on itself.
                connection.send(
                    content: Data(Self.readyFrame.utf8),
                    contentContext: Self.textContext,
                    isComplete: true,
                    completion: .contentProcessed { _ in }
                )
            }
            connection.start(queue: self.queue)
            self.drain(connection, index: index)
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
    ///
    /// It re-arms on **every** delivery, including a complete one. `isComplete`
    /// marks the end of one WebSocket *message*, not the end of the connection,
    /// so stopping there left the drain armed exactly once: the client's frames
    /// then piled up in the receive buffer until TCP backpressure stalled its
    /// `send` for good, which is what a sustained send loop hits (#2171
    /// behavior 23). Only an error — which a peer close produces — ends it.
    private func drain(_ connection: NWConnection, index: Int) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                self.lock.withLock { _ = self._closedConnections.insert(index) }
            } else if let data, let text = String(data: data, encoding: .utf8) {
                self.lock.withLock {
                    self._receivedFrames.append(text)
                    self._framesByConnection[index, default: []].append(text)
                }
            }
            if error != nil {
                // Peer closed or errored — let the connection tear down.
                self.lock.withLock { _ = self._closedConnections.insert(index) }
                connection.cancel()
                return
            }
            self.drain(connection, index: index)
        }
    }

    private static let textContext = NWConnection.ContentContext(
        identifier: "loopback-push", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]
    )

    /// Send one text frame on one connection and wait for it; whether it was
    /// delivered. Never call it on the server's queue.
    @discardableResult
    private func send(_ text: String, on connection: NWConnection, timeout: TimeInterval = 10) -> Bool {
        let context = Self.textContext
        let delivered = LockedBox(false)
        let done = DispatchSemaphore(value: 0)
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if error == nil { delivered.value = true }
                done.signal()
            }
        )
        _ = done.wait(timeout: .now() + timeout)
        return delivered.value
    }

    /// Push one text frame to the connection at `index` (acceptance order), the
    /// way the server answers one socket rather than all of them.
    ///
    /// - Returns: `false` when there is no such connection or it is gone.
    @discardableResult
    func push(_ text: String, toConnection index: Int) -> Bool {
        let target = lock.withLock { () -> NWConnection? in
            guard index < connections.count, !_closedConnections.contains(index) else { return nil }
            return connections[index]
        }
        guard let target else { return false }
        return send(text, on: target)
    }

    /// Close the connection at `index` from the server's side with a close
    /// frame carrying `code`, as the real server closes a socket.
    func close(connection index: Int, code: NWProtocolWebSocket.CloseCode = .protocolCode(.internalServerError)) {
        guard let target = lock.withLock({ index < connections.count ? connections[index] : nil }) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "loopback-close", metadata: [metadata])
        let done = DispatchSemaphore(value: 0)
        target.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            done.signal()
        })
        _ = done.wait(timeout: .now() + 5)
        lock.withLock { _ = _closedConnections.insert(index) }
    }

    /// Push one text frame to every connected client.
    ///
    /// The drain above only reads; this is the other direction, and #3436
    /// needs it: the claim that a client's receive limit was raised in time is
    /// only testable against a frame big enough to have failed without it, and
    /// `URLSessionWebSocketTask` fails an oversized message at the RECEIVE —
    /// nothing reaches the handler to observe.
    ///
    /// - Returns: `false` when the frame reached no client at all. A client
    ///   that has since gone away is not a failure — a test that made the
    ///   client reconnect still has a live connection in the list.
    @discardableResult
    func push(_ text: String, timeout: TimeInterval = 10) -> Bool {
        let targets = lock.withLock { connections }
        guard !targets.isEmpty else { return false }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "loopback-push", metadata: [metadata]
        )
        // Network.framework runs the completion on its own queue, so the flag
        // it sets needs an owner that serialises access rather than a captured
        // local `var` ("mutation of captured var 'delivered' in
        // concurrently-executing code"). The semaphore below does make each
        // send's completion happen-before the next iteration, but that is an
        // argument about this loop, not one the compiler can check.
        let delivered = LockedBox(false)
        for connection in targets {
            let done = DispatchSemaphore(value: 0)
            connection.send(
                content: Data(text.utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if error == nil { delivered.value = true }
                    done.signal()
                }
            )
            _ = done.wait(timeout: .now() + timeout)
        }
        return delivered.value
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }
}
