import Foundation
import Network
import XCTest
@testable import JsBaoClient
import YSwift

/// What an offload put between building an outbound frame and sending it
/// (#3559, findings 3559-SO-001 and 3559-SO-002).
///
/// Before this issue every outbound frame was built from local state alone and
/// went out in the same turn it was built in. An oversize payload is not: it
/// asks the room for an upload URL, waits for the answer, PUTs the bytes, and
/// only then sends the frame that names them. Two things that were true by
/// construction stop being true across that gap.
///
/// 1. **The receive loop.** The `getUploadUrl` answer ARRIVES AS A FRAME. The
///    socket's receive loop takes one complete frame before it asks for the
///    next (`WebSocketManager.makeReceiveLoop`), so an upload awaited from a
///    frame handler is waiting for a frame that handler is preventing — a
///    deadlock that ends in the waiter's ten-second timeout with nothing sent.
///
/// 2. **The epoch.** A move discards every queued update, because each is a
///    delta against the overlay the room has just archived and the room parks
///    such a frame instead of integrating it. A payload already taken off that
///    queue and waiting on its upload is out of the discard's reach.
///
/// Server-free on both counts. (1) runs against a real `URLSessionWebSocketTask`
/// on a loopback socket, because a stub that answers in the caller's own turn
/// cannot show a receive loop blocking — the deadlock is in the transport, so
/// the transport is real. (2) runs at the `DocumentManager` seam, because what
/// it pins is which settlement one claim gets.
final class OversizeOutboundConcurrencyHermeticTests: XCTestCase {

    /// The threshold both clients switch at — the server's `MAX_UPDATE_SIZE`.
    private let maxInlineUpdateBytes = 102_400

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/oversize-concurrency-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    /// A high-entropy string, so the payload built from it cannot be
    /// compressed back under the threshold.
    private func noise(_ count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(alphabet.randomElement()!) }
        return out
    }

    private func wsBase(_ url: URL) -> String {
        let base = url.absoluteString
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// The room's half of the offload protocol: every `getUploadUrl` the
    /// loopback room receives is answered, each with a key of its own.
    ///
    /// A real room answers them all. It matters here because a document with
    /// local state to send has TWO offloads to make on one connection — the
    /// write's own `update` frame and the `syncStep2` answer — and answering
    /// only the first would leave the second indistinguishable from the
    /// deadlock under test.
    private final class UploadUrlResponder: @unchecked Sendable {
        private let room: LoopbackWebSocketServer
        private let origin: String
        private let lock = NSLock()
        private var answered: Set<String> = []
        private var task: Task<Void, Never>?

        init(room: LoopbackWebSocketServer, origin: String) {
            self.room = room
            self.origin = origin
        }

        func start() {
            task = Task { [self] in
                while !Task.isCancelled {
                    answerPending()
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }

        func stop() { task?.cancel() }

        private func answerPending() {
            for frame in room.receivedFrames {
                guard let data = frame.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                      json["type"] as? String == "getUploadUrl",
                      let requestId = json["requestId"] as? String
                else { continue }
                guard lock.withLock({ answered.insert(requestId).inserted }) else { continue }
                room.push("""
                {"type":"getUploadUrlResponse",\
                "requestId":"\(requestId)","uploadId":"upload-\(requestId)",\
                "url":"\(origin)/\(requestId)"}
                """)
            }
        }
    }

    /// Every frame of `type` the loopback room received, decoded.
    private func frames(
        _ server: LoopbackWebSocketServer, type: String
    ) -> [[String: Any]] {
        server.receivedFrames.compactMap { frame in
            guard let data = frame.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == type
            else { return nil }
            return json
        }
    }

    // MARK: - Finding 3559-SO-001 — the receive loop

    /// The R2 origin an offload PUTs to.
    ///
    /// `LoopbackHTTPServer` answers after the first chunk and closes at once,
    /// which a >100 KB body can still be mid-flight through; this one reads the
    /// whole request before it answers, so the upload either succeeds or fails
    /// for a reason the test is about.
    private final class LoopbackUploadServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "loopback-upload-server")
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private var _uploaded: [String: Int] = [:]

        /// How many body bytes landed at each path the client PUT to. Keyed by
        /// path because a test answers several upload requests and has to be
        /// able to say which object a given frame names.
        var uploaded: [String: Int] { lock.withLock { _uploaded } }

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() throws -> URL {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.read(connection, received: Data())
            }
            listener.start(queue: queue)
            if ready.wait(timeout: .now() + 5) == .timedOut {
                throw NSError(
                    domain: "LoopbackUploadServer", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"]
                )
            }
            return URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")!
        }

        /// Read until the headers name a `Content-Length` and that many body
        /// bytes have arrived, then answer.
        private func read(_ connection: NWConnection, received: Data) {
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 64 * 1024
            ) { [weak self] chunk, _, isComplete, error in
                guard let self else { return }
                var buffer = received
                if let chunk { buffer.append(chunk) }
                guard error == nil else { connection.cancel(); return }

                let separator = Data("\r\n\r\n".utf8)
                if let headerEnd = buffer.range(of: separator) {
                    let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                    let lines = head.split(separator: "\r\n")
                    let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let expected = lines
                        .first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
                        ?? 0
                    let bodyCount = buffer.count - headerEnd.upperBound
                    if bodyCount >= expected {
                        self.lock.withLock { self._uploaded[path] = bodyCount }
                        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        connection.send(
                            content: Data(response.utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                        return
                    }
                }
                guard !isComplete else { connection.cancel(); return }
                self.read(connection, received: buffer)
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

    private func makeClient(wsUrl: String) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "oversize-concurrency-test-app",
            token: makeTestJwt(userId: "oversize-concurrency-user"),
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: newDatabasePath()),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        return client
    }

    /// The room asks an ordinary document what it has, over the socket, and
    /// the answer is too big to travel inline.
    ///
    /// Red without the hand-off to the outbound lane: the `syncStep1` handler
    /// awaits the upload, the upload awaits `getUploadUrlResponse`, and that
    /// frame is behind the handler in the receive loop's single file. Nothing
    /// is sent, at any timeout — the waiter gives up after ten seconds and the
    /// answer is abandoned — and every other document on the connection is
    /// stopped for the whole of it.
    func testAnOversizeSyncStep2AnswerDoesNotWaitOnTheFrameItIsBlocking() async throws {
        let uploads = try LoopbackUploadServer()
        let uploadUrl = try uploads.start()
        defer { uploads.stop() }

        let room = try LoopbackWebSocketServer()
        let roomUrl = try room.start()
        defer { room.stop() }

        let responder = UploadUrlResponder(room: room, origin: uploadUrl.absoluteString)
        responder.start()
        defer { responder.stop() }

        let client = await makeClient(wsUrl: wsBase(roomUrl))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let documentId = "recv-loop-\(UUID().uuidString.prefix(8))"
        client.documentManager.createRemoteDocument = { (_: [String: Any]) in
            ["documentId": documentId]
        }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "oversize answer",
            localOnly: false, documentFormat: nil
        )
        client.documentManager.handlePendingCreateCommitted(documentId)
        let doc = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        // More local state than one inline frame can carry.
        let map: YMap<JSONValue> = doc.getOrCreateMap(named: "Note")
        let value = noise(122_000)
        doc.transactSync { transaction in
            map.updateValue(.string(value), forKey: "n1/title", transaction: transaction)
        }

        // The room asks. PUSHED, not handed to `handleWebSocketMessage`: what
        // is under test is the real receive loop's single file, which a direct
        // call would step around.
        let emptyStateVector = Data([0]).base64EncodedString()
        XCTAssertTrue(room.push("""
        {"type":"syncStep1","documentId":"\(documentId)","stateVector":"\(emptyStateVector)"}
        """))

        // The answer the room is owed. Its `getUploadUrl` is answered by the
        // responder above — as a FRAME, on the very loop the handler that
        // asked for it runs on. Well inside the ten seconds the waiter would
        // take to give up, so a pass here cannot be the timeout path
        // succeeding slowly; and in the deadlock the answer never goes out at
        // any timeout, because the upload it waits on returns nothing.
        try await waitFor("the offloaded syncStep2 answer to reach the room", timeout: 8) {
            !self.frames(room, type: "syncStep2").isEmpty
        }
        let answer = try XCTUnwrap(frames(room, type: "syncStep2").first)
        XCTAssertEqual(answer["documentId"] as? String, documentId)
        XCTAssertNil(answer["update"], "an offloaded answer carries no inline payload")
        let uploadId = try XCTUnwrap(answer["uploadId"] as? String)

        // And the object it names is one the client really wrote, with the
        // whole oversize diff in it.
        let key = String(uploadId.dropFirst("upload-".count))
        let uploadedBytes = try XCTUnwrap(
            uploads.uploaded["/\(key)"],
            "the frame names an object nobody wrote; uploads: \(uploads.uploaded.keys)"
        )
        XCTAssertGreaterThan(
            uploadedBytes, maxInlineUpdateBytes,
            "what went up is the oversize diff, not a truncation of it"
        )
    }

    // MARK: - Finding 3559-SO-002 — the epoch under the upload

    /// Stands in for the offload, and parks in it until the test says
    /// otherwise — which is the window an epoch move has to land in.
    private final class PausedUpload: @unchecked Sendable {
        private let started = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        let uploadId = "upload-3559"

        func run() async -> String? {
            started.signal()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.release.wait()
                    continuation.resume()
                }
            }
            return uploadId
        }

        func waitUntilStarted(file: StaticString = #filePath, line: UInt = #line) {
            if started.wait(timeout: .now() + 5) == .timedOut {
                XCTFail("the upload never started", file: file, line: line)
            }
        }

        func finish() { release.signal() }
    }

    private func manager() -> DocumentManager {
        DocumentManager(logger: Logger(level: .none, scope: "oversize-epoch"))
    }

    /// An oversize payload whose document moves epoch while the bytes are
    /// going up is not sent at all.
    ///
    /// Sending it is the exact frame the move's discard of the outbound queue
    /// exists to prevent: a delta against the overlay the room has just
    /// archived, which the room parks and then answers with a resync request
    /// for ever. The move carried its content onto the fresh overlay, so what
    /// it carried is not lost — the resync answer is the frame that now
    /// carries it.
    func testAnUploadWhoseEpochMovedUnderItIsNotSent() async throws {
        let manager = manager()
        let documentId = "epoch-moved-under-upload"
        let sent = LockedBox<[String]>([])
        let settlements = LockedBox<[DocumentManager.OutboundSettlement]>([])
        let generation = LockedBox<Int>(0)
        let upload = PausedUpload()

        manager.sendWebSocketMessage = { frame in sent.withValue { $0.append(frame) } }
        manager.uploadLargeUpdate = { _, _ in await upload.run() }
        manager.outboundGeneration = { _ in generation.value }
        manager.settleOutboundUpdate = { _, _, settlement in
            settlements.withValue { $0.append(settlement) }
        }

        let payload = [UInt8](repeating: 7, count: maxInlineUpdateBytes + 1)
        let send = Task { await manager.sendLocalUpdate(documentId: documentId, update: payload) }

        upload.waitUntilStarted()
        // The room seals this document's epoch while the bytes are in flight.
        generation.withValue { $0 += 1 }
        upload.finish()

        let drained = await send.value
        XCTAssertFalse(drained, "an update whose epoch moved under it has not drained")
        XCTAssertTrue(
            sent.value.isEmpty,
            "the stale delta must not reach the room; frames: \(sent.value)"
        )
        XCTAssertEqual(
            settlements.value.count, 1, "exactly one settlement per claim, always"
        )
        guard case .stale = settlements.value.first else {
            return XCTFail("the claim was settled \(String(describing: settlements.value.first))")
        }
    }

    /// The control, and the reason the check is a GENERATION rather than a
    /// cancellation: an upload the epoch did not move under still goes out,
    /// with the `uploadId` it was promised.
    func testAnUploadWhoseEpochHeldStillGoesOut() async throws {
        let manager = manager()
        let documentId = "epoch-held-under-upload"
        let sent = LockedBox<[String]>([])
        let settlements = LockedBox<[DocumentManager.OutboundSettlement]>([])
        let generation = LockedBox<Int>(0)
        let upload = PausedUpload()

        manager.sendWebSocketMessage = { frame in sent.withValue { $0.append(frame) } }
        manager.uploadLargeUpdate = { _, _ in await upload.run() }
        manager.outboundGeneration = { _ in generation.value }
        manager.settleOutboundUpdate = { _, _, settlement in
            settlements.withValue { $0.append(settlement) }
        }

        let payload = [UInt8](repeating: 7, count: maxInlineUpdateBytes + 1)
        let send = Task { await manager.sendLocalUpdate(documentId: documentId, update: payload) }

        upload.waitUntilStarted()
        upload.finish()

        let drained = await send.value
        XCTAssertTrue(drained)
        let frame = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(XCTUnwrap(sent.value.first).utf8))
                as? [String: Any]
        )
        XCTAssertEqual(frame["uploadId"] as? String, upload.uploadId)
        XCTAssertNil(frame["update"])
        guard case .sent = settlements.value.first else {
            return XCTFail("the claim was settled \(String(describing: settlements.value.first))")
        }
    }

    /// And the same rule on the other outbound path: an oversize `syncStep2`
    /// answer whose document moved epoch while it was going up is not
    /// answered. The room's own `syncStep1` follows every move, so the answer
    /// is owed afresh rather than lost.
    func testAnOversizeSyncStep2AnswerWhoseEpochMovedUnderItIsNotAnswered() async throws {
        let manager = manager()
        let documentId = "epoch-moved-under-syncstep2"
        let generation = LockedBox<Int>(0)
        let upload = PausedUpload()

        manager.uploadLargeUpdate = { _, _ in await upload.run() }
        manager.outboundGeneration = { _ in generation.value }

        let doc = try await manager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork, enableNetworkSync: false
            )
        )
        let map: YMap<JSONValue> = doc.getOrCreateMap(named: "Note")
        let value = noise(122_000)
        doc.transactSync { transaction in
            map.updateValue(.string(value), forKey: "n1/title", transaction: transaction)
        }

        let emptyStateVector = Data([0]).base64EncodedString()
        let answer = Task {
            await manager.buildSyncStep2Response(
                documentId: documentId, serverStateVectorBase64: emptyStateVector
            )
        }
        upload.waitUntilStarted()
        generation.withValue { $0 += 1 }
        upload.finish()

        let response = await answer.value
        XCTAssertNil(
            response,
            "a diff against an archived overlay is not the answer to the room's question"
        )
    }
}
