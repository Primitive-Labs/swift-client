import Compression
import Foundation
import XCTest
import YSwift
@testable import JsBaoClient

/// #2661 (parity item C11) — an oversized update parked in R2 and served with
/// `X-Compressed: true` must be gunzipped and applied. The Swift client used to
/// drop it with a warning, which is silently lossy the moment the server turns
/// compression on. JS gunzips (`decompressGzip`, `JsBaoClient.ts` handleUpdate).
///
/// Server-free: `LoopbackHTTPServer` stands in for the R2 origin.
final class CompressedUpdateDownloadTests: XCTestCase {

    private func newDocId() -> String { "compressed-\(UUID().uuidString.prefix(8))" }

    private func makeClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: "compressed-update-test-app",
            token: "test-token",
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    /// A full-state Yjs update carrying `text` in the `content` root, the way
    /// the server would have encoded it before parking it in R2.
    private func encodedUpdate(text: String) -> Data {
        let source = YDocument()
        let content = source.getOrCreateText(named: "content")
        content.insert(text, at: 0)
        let update: [UInt8] = source.transactSync { txn in
            txn.transactionEncodeStateAsUpdate()
        }
        return Data(update)
    }

    func testCompressedUpdateIsGunzippedAndApplied() async throws {
        let payload = encodedUpdate(text: "compressed hello")
        let server = try LoopbackHTTPServer(
            body: GzipFixture.gzip(payload),
            headers: ["X-Compressed": "true", "Content-Type": "application/octet-stream"]
        )
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient()
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "compressed", localOnly: true
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        await client.handleWebSocketMessage("""
        {"type":"syncStep2","documentId":"\(docId)","updateUrl":"\(url.absoluteString)"}
        """)

        let doc = try XCTUnwrap(client.documentManager.getDocument(docId))
        let content = doc.getOrCreateText(named: "content")
        let applied = content.getString()
        XCTAssertEqual(applied, "compressed hello",
                       "a compressed R2 payload must reach the ydoc, not be dropped")
    }

    func testUncompressedUpdateStillApplies() async throws {
        let payload = encodedUpdate(text: "plain hello")
        let server = try LoopbackHTTPServer(
            body: payload,
            headers: ["X-Compressed": "false", "Content-Type": "application/octet-stream"]
        )
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient()
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "plain", localOnly: true
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        await client.handleWebSocketMessage("""
        {"type":"syncStep2","documentId":"\(docId)","updateUrl":"\(url.absoluteString)"}
        """)

        let doc = try XCTUnwrap(client.documentManager.getDocument(docId))
        let content = doc.getOrCreateText(named: "content")
        let applied = content.getString()
        XCTAssertEqual(applied, "plain hello")
    }

    func testCorruptCompressedBodyIsDroppedRatherThanApplied() async throws {
        var corrupt = GzipFixture.gzip(encodedUpdate(text: "never applied"))
        corrupt.removeLast(12)  // truncated mid-stream: no complete deflate block
        let server = try LoopbackHTTPServer(
            body: corrupt,
            headers: ["X-Compressed": "true", "Content-Type": "application/octet-stream"]
        )
        let url = try server.start()
        defer { server.stop() }

        let client = makeClient()
        defer { Task { await client.destroy() } }

        let docId = newDocId()
        client.documentManager.createRemoteDocument = { _ in ["documentId": docId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: docId, title: "corrupt", localOnly: true
        )
        _ = try await client.openDocument(
            docId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )

        await client.handleWebSocketMessage("""
        {"type":"syncStep2","documentId":"\(docId)","updateUrl":"\(url.absoluteString)"}
        """)

        let doc = try XCTUnwrap(client.documentManager.getDocument(docId))
        let content = doc.getOrCreateText(named: "content")
        let applied = content.getString()
        XCTAssertEqual(applied, "", "garbage bytes must never reach the ydoc")
    }
}

/// Builds a real gzip member (RFC 1952) around raw deflate output, so the test
/// fixture is what an R2 object compressed server-side would look like rather
/// than something shaped to whatever the decoder happens to accept.
enum GzipFixture {
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflate(data))
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static func deflate(_ data: Data) -> Data {
        let capacity = data.count + 64 * 1024
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return destination.prefix(written)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xffff_ffff
    }
}
