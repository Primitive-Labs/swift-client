import XCTest
@testable import JsBaoClient
import YSwift

/// Swift↔JS parity on the outbound size decision (#3559).
///
/// The filing: the Swift client sent every payload inline, at any size, on
/// both outbound paths, while the JS client uploaded to R2 above
/// `MAX_UPDATE_SIZE` and sent `uploadId`. One write therefore produced a
/// different frame — and, until the server half of this issue, a different
/// stored result — depending on which client made it.
///
/// So: both clients switch at the SAME size, on BOTH paths, and one write
/// yields the same frame from either.
///
/// Server-free. The decision under test is a decision about a byte count and
/// the shape of one JSON frame, so it is decidable without a server: the
/// socket is intercepted at `DocumentManager.sendWebSocketMessage` and the
/// offload at `DocumentManager.uploadLargeUpdate`, which is the seam
/// `JsBaoClient` wires to the real `getUploadUrl` round trip and PUT. The
/// live half — that round trip against a real room — is the server suites'.
final class OversizeOutboundUpdateHermeticTests: XCTestCase {

    /// The threshold both clients switch at — the server's default
    /// `MAX_UPDATE_SIZE`. Written out rather than read off the client, because
    /// what this file pins is that the Swift number IS the JS one
    /// (`src/client/JsBaoClient.ts`, `this.env.MAX_UPDATE_SIZE`).
    private let maxInlineUpdateBytes = 102_400

    /// Collects outbound frames from whichever thread the flush runs on.
    private final class FrameSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [String] = []
        func append(_ frame: String) { lock.withLock { _frames.append(frame) } }
        var all: [String] { lock.withLock { _frames } }
    }

    /// Stands in for the R2 offload: records what it was handed and answers a
    /// fixed `uploadId`, or refuses when `succeeds` is false.
    private final class UploadSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _payloads: [(String, [UInt8])] = []
        let succeeds: Bool
        let uploadId: String

        init(succeeds: Bool = true, uploadId: String = "upload-3559") {
            self.succeeds = succeeds
            self.uploadId = uploadId
        }

        func take(_ documentId: String, _ payload: [UInt8]) -> String? {
            lock.withLock { _payloads.append((documentId, payload)) }
            return succeeds ? uploadId : nil
        }

        var payloads: [(String, [UInt8])] { lock.withLock { _payloads } }
    }

    private func decode(_ frame: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
        )
    }

    /// A client that never talks to a server, with zero outbound debounce so a
    /// queued update reaches the (intercepted) socket promptly.
    private func makeClient(appId: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
    }

    private func openLocalDoc(
        _ client: JsBaoClient,
        _ documentId: String
    ) async throws -> YDocument {
        try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )
    }

    /// Give a zero-debounce flush time to reach the intercepted socket.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// A high-entropy string of `count` characters, so the payload built from
    /// it cannot be compressed back under the threshold.
    private func noise(_ count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(alphabet.randomElement()!) }
        return out
    }

    private func manager(_ label: String) -> DocumentManager {
        DocumentManager(logger: Logger(level: .none, scope: label))
    }

    // MARK: - B5: the `update` path

    func testOversizeUpdateFrameCarriesAnUploadIdAndNoInlinePayload() async throws {
        let manager = manager("oversize-update")
        let frames = FrameSink()
        let uploads = UploadSink()
        manager.sendWebSocketMessage = { frames.append($0) }
        manager.uploadLargeUpdate = { documentId, payload in
            uploads.take(documentId, payload)
        }

        let payload = [UInt8](repeating: 7, count: maxInlineUpdateBytes + 1)
        let sent = await manager.sendLocalUpdate(documentId: "doc-big", update: payload)

        XCTAssertTrue(sent, "the frame went out, so the update has drained")
        XCTAssertEqual(frames.all.count, 1)
        let frame = try decode(try XCTUnwrap(frames.all.first))
        XCTAssertEqual(frame["type"] as? String, "update")
        XCTAssertEqual(frame["documentId"] as? String, "doc-big")
        XCTAssertEqual(
            frame["uploadId"] as? String, uploads.uploadId,
            "a payload over MAX_UPDATE_SIZE is named by its uploadId, as the JS client's is"
        )
        XCTAssertNil(
            frame["update"],
            "and does NOT travel inline — that is the frame the filing reports"
        )
        XCTAssertEqual(uploads.payloads.count, 1)
        XCTAssertEqual(uploads.payloads.first?.0, "doc-big")
        XCTAssertEqual(
            uploads.payloads.first?.1, payload,
            "the bytes uploaded are the bytes the frame stands for"
        )
    }

    func testPayloadAtTheThresholdStillTravelsInline() async throws {
        let manager = manager("threshold-update")
        let frames = FrameSink()
        let uploads = UploadSink()
        manager.sendWebSocketMessage = { frames.append($0) }
        manager.uploadLargeUpdate = { documentId, payload in
            uploads.take(documentId, payload)
        }

        // Exactly at the threshold: the switch is strictly greater-than on
        // both clients (`update.length > this.env.MAX_UPDATE_SIZE`).
        let payload = [UInt8](repeating: 7, count: maxInlineUpdateBytes)
        let sent = await manager.sendLocalUpdate(documentId: "doc-edge", update: payload)

        XCTAssertTrue(sent)
        let frame = try decode(try XCTUnwrap(frames.all.first))
        XCTAssertEqual(
            frame["update"] as? String, Data(payload).base64EncodedString(),
            "a payload at the threshold is inline, exactly as it always was"
        )
        XCTAssertNil(frame["uploadId"])
        XCTAssertTrue(uploads.payloads.isEmpty, "nothing was uploaded")
    }

    func testAnUploadThatFailsSendsNoFrameAndReportsTheUpdateUndrained() async throws {
        let manager = manager("failed-upload")
        let frames = FrameSink()
        let uploads = UploadSink(succeeds: false)
        manager.sendWebSocketMessage = { frames.append($0) }
        manager.uploadLargeUpdate = { documentId, payload in
            uploads.take(documentId, payload)
        }

        let payload = [UInt8](repeating: 7, count: maxInlineUpdateBytes + 1)
        let sent = await manager.sendLocalUpdate(documentId: "doc-fail", update: payload)

        XCTAssertFalse(
            sent,
            "an update that could not be offloaded has not drained; the caller keeps it queued"
        )
        XCTAssertTrue(
            frames.all.isEmpty,
            "and no frame goes out — a frame naming an object nobody wrote is the bug this issue is about"
        )
    }

    func testAManagerWithNoUploadSeamSendsNoOversizeFrame() async throws {
        let manager = manager("no-seam")
        let frames = FrameSink()
        manager.sendWebSocketMessage = { frames.append($0) }

        let payload = [UInt8](repeating: 7, count: maxInlineUpdateBytes + 1)
        let sent = await manager.sendLocalUpdate(documentId: "doc-no-seam", update: payload)

        XCTAssertFalse(sent)
        XCTAssertTrue(frames.all.isEmpty)
    }

    // MARK: - B6: the `syncStep2` path

    func testOversizeSyncStep2FrameCarriesAnUploadIdAndNoInlinePayload() async throws {
        let client = makeClient(appId: "oversize-syncstep2")
        defer { Task { await client.destroy() } }
        let uploads = UploadSink()
        client.documentManager.uploadLargeUpdate = { documentId, payload in
            uploads.take(documentId, payload)
        }

        let documentId = "syncstep2-big-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in
            map.updateValue(self.noise(150_000), forKey: "k", transaction: txn)
        }

        let emptyId = "empty-sv-source-\(documentId)"
        _ = try await openLocalDoc(client, emptyId)
        let emptyStateVector = try XCTUnwrap(
            client.documentManager.encodeStateVectorBase64(emptyId)
        )

        // The local write of that map also drains through the outbound path,
        // which offloads it for the same reason; count from here so this case
        // is about the syncStep2 diff alone.
        await settle()
        let uploadsBefore = uploads.payloads.count

        let built = await client.documentManager.buildSyncStep2Response(
            documentId: documentId,
            serverStateVectorBase64: emptyStateVector
        )
        let response = try XCTUnwrap(built)
        let frame = try decode(response)
        XCTAssertEqual(frame["type"] as? String, "syncStep2")
        XCTAssertEqual(frame["documentId"] as? String, documentId)
        XCTAssertEqual(
            frame["uploadId"] as? String, uploads.uploadId,
            "the syncStep2 diff switches to R2 at the same size the update path does"
        )
        XCTAssertNil(frame["update"])
        XCTAssertEqual(
            uploads.payloads.count, uploadsBefore + 1,
            "building the response uploaded the diff exactly once"
        )
        XCTAssertGreaterThan(
            uploads.payloads.last?.1.count ?? 0, maxInlineUpdateBytes
        )
    }

    func testSmallSyncStep2DiffStillTravelsInline() async throws {
        let client = makeClient(appId: "small-syncstep2")
        defer { Task { await client.destroy() } }
        let uploads = UploadSink()
        client.documentManager.uploadLargeUpdate = { documentId, payload in
            uploads.take(documentId, payload)
        }

        let documentId = "syncstep2-small-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }

        let emptyId = "empty-sv-source-\(documentId)"
        _ = try await openLocalDoc(client, emptyId)
        let emptyStateVector = try XCTUnwrap(
            client.documentManager.encodeStateVectorBase64(emptyId)
        )

        let built = await client.documentManager.buildSyncStep2Response(
            documentId: documentId,
            serverStateVectorBase64: emptyStateVector
        )
        let response = try XCTUnwrap(built)
        let frame = try decode(response)
        XCTAssertNotNil(frame["update"] as? String)
        XCTAssertNil(frame["uploadId"])
        XCTAssertTrue(uploads.payloads.isEmpty)
    }

    // MARK: - B7: the merge cap goes with the inline-only outbound path

    func testAFlushMergesTheWholeQueueEvenPastTheOldCap() async throws {
        // A debounce window, so the three writes below are all in the queue
        // when the flush takes it. With zero debounce each write drains on its
        // own and there is no batch to merge — which would say nothing either
        // way about a budget over the batch.
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "merge-cap-removed",
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 1.0),
            autoNetwork: false
        ))
        defer { Task { await client.destroy() } }
        let frames = FrameSink()
        let uploads = UploadSink()
        client.documentManager.sendWebSocketMessage = { frames.append($0) }
        client.documentManager.uploadLargeUpdate = { documentId, payload in
            uploads.take(documentId, payload)
        }

        let documentId = "merge-cap-doc"
        let doc = try await openLocalDoc(client, documentId)
        let map: YMap<String> = doc.getOrCreateMap(named: "m")

        // Three writes of ~50 KB each, back to back so they are all queued
        // before the debounced flush runs: over the 102400-byte cap that
        // existed only because inline was the sole outbound option. With the
        // cap in place this drained as two frames (a 2-update prefix, then the
        // rest); it is now one, and it is offloaded because the merge is
        // oversize.
        // Built before the writes: generating 50 KB of noise takes long enough
        // that doing it between transactions could let the debounce window
        // close mid-batch, which would make this case about timing rather than
        // about the budget.
        let bodies = (0..<3).map { _ in noise(50_000) }
        doc.transactSync { txn in
            for (index, body) in bodies.enumerated() {
                map.updateValue(body, forKey: "k\(index)", transaction: txn)
            }
        }
        await settle()
        await settle()
        await settle()

        XCTAssertEqual(
            frames.all.count, 1,
            "a flush merges the whole queue into ONE frame, whatever it weighs"
        )
        let frame = try decode(try XCTUnwrap(frames.all.first))
        XCTAssertEqual(frame["uploadId"] as? String, uploads.uploadId)
        XCTAssertNil(frame["update"])
        XCTAssertGreaterThan(
            uploads.payloads.first?.1.count ?? 0, maxInlineUpdateBytes,
            "the merged frame really is past the old cap"
        )
    }
}
