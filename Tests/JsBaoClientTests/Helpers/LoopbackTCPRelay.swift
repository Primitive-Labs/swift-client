import Foundation
import Network

/// A local URL in front of another server (#6185): every connection to the
/// relay's loopback port is piped byte for byte to the target's host and port,
/// and the relay records each HTTP request head it sees on the client's side,
/// so a test can say which requests and socket upgrades reached this URL.
///
/// Request heads are read one after another on a kept-alive connection, a
/// body skipped by its `Content-Length`. Once a connection upgrades (a
/// WebSocket), or sends a body framed any other way, the rest of it is piped
/// without reading.
final class LoopbackTCPRelay: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        /// The path as it arrived, query included.
        let path: String
        /// Header names lower-cased.
        let headers: [String: String]

        var pathOnly: String { String(path.prefix(while: { $0 != "?" })) }
        func header(_ name: String) -> String? { headers[name.lowercased()] }
        var isUpgrade: Bool { header("upgrade")?.lowercased() == "websocket" }
    }

    private let targetHost: NWEndpoint.Host
    private let targetPort: NWEndpoint.Port
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-tcp-relay")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var _requests: [Request] = []
    private(set) var port: UInt16 = 0

    /// Every request head seen, upgrades included, in order.
    var requests: [Request] { lock.withLock { _requests } }
    /// The socket upgrades among them.
    var upgrades: [Request] { requests.filter(\.isUpgrade) }
    var baseUrl: String { "http://127.0.0.1:\(port)" }
    var wsUrl: String { "ws://127.0.0.1:\(port)" }

    /// A relay to `target` (`http://host:port`).
    init(target: String) throws {
        guard let url = URL(string: target), let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else {
            throw NSError(domain: "LoopbackTCPRelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad target \(target)"])
        }
        targetHost = NWEndpoint.Host(host)
        targetPort = port
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Start listening; returns the base URL.
    @discardableResult
    func start() throws -> String {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] inbound in self?.relay(inbound) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "LoopbackTCPRelay", code: 2, userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
        }
        port = listener.port?.rawValue ?? 0
        return baseUrl
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            defer { connections.removeAll() }
            return connections
        }
        open.forEach { $0.cancel() }
    }

    private func relay(_ inbound: NWConnection) {
        let outbound = NWConnection(host: targetHost, port: targetPort, using: .tcp)
        lock.withLock { connections += [inbound, outbound] }
        let reader = HeadReader()
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pipe(from: inbound, to: outbound) { [weak self] chunk in
            let heads = reader.feed(chunk)
            guard !heads.isEmpty else { return }
            self?.lock.withLock { self?._requests += heads }
        }
        pipe(from: outbound, to: inbound, observe: nil)
    }

    private func pipe(from source: NWConnection, to sink: NWConnection, observe: (@Sendable (Data) -> Void)?) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                observe?(data)
                sink.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    sink.cancel()
                })
                source.cancel()
                return
            }
            self?.pipe(from: source, to: sink, observe: observe)
        }
    }

    /// Reads request heads out of one connection's client-side bytes.
    private final class HeadReader: @unchecked Sendable {
        private var buffer = Data()
        private var skipping = 0
        private var reading = true

        func feed(_ chunk: Data) -> [Request] {
            guard reading else { return [] }
            buffer.append(chunk)
            var found: [Request] = []
            while reading {
                if skipping > 0 {
                    let drop = min(skipping, buffer.count)
                    buffer.removeFirst(drop)
                    skipping -= drop
                    if skipping > 0 { break }
                }
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { break }
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                let lines = head.components(separatedBy: "\r\n")
                let parts = lines.first?.split(separator: " ") ?? []
                guard parts.count >= 2 else { reading = false; break }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pieces = line.split(separator: ":", maxSplits: 1)
                    guard pieces.count == 2 else { continue }
                    headers[pieces[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                        pieces[1].trimmingCharacters(in: .whitespaces)
                }
                let request = Request(method: String(parts[0]), path: String(parts[1]), headers: headers)
                found.append(request)
                if request.isUpgrade || headers["transfer-encoding"] != nil {
                    reading = false
                } else {
                    skipping = Int(headers["content-length"] ?? "0") ?? 0
                }
            }
            return found
        }
    }
}
