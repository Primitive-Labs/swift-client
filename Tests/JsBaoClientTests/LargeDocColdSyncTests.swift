import XCTest
@testable import JsBaoClient
import YSwift

/// Regression guard for #2474: a fresh client cold-loading a document whose
/// full state exceeds the server's `MAX_UPDATE_SIZE` (100KB) must receive the
/// data.
///
/// For oversized diffs the server parks the payload in R2 and sends
/// `{type: "syncStep2", updateUrl}` instead of an inline `update`. The Swift
/// router used to guard on `json["update"]` and silently drop that frame; the
/// trailing `syncComplete` then reported the doc synced with zero records,
/// and later incremental deltas parked in Yjs pendingStructs forever. Clients
/// that built the doc incrementally from small inline updates never hit this,
/// which is why it only surfaced on fresh installs.
final class LargeDocColdSyncTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var clients: [JsBaoClient] = []

    /// Server-side MAX_UPDATE_SIZE is 100KB in every environment; total doc
    /// state must comfortably exceed it while each individual write stays
    /// well under it (so the writes themselves go inline).
    static let chunkCount = 40
    static let chunkSize = 8_192

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-large-doc-cold-sync")
    }

    override func tearDown() async throws {
        for client in clients {
            await client.destroy()
        }
        clients.removeAll()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    private static func chunkValue(_ i: Int) -> String {
        "chunk-\(i)-" + String(repeating: "x", count: chunkSize)
    }

    func testFreshClientColdLoadsDocLargerThanMaxUpdateSize() async throws {
        let docId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Large Doc Cold Sync"
        )

        // Writer: build up ~320KB of state through small inline updates, the
        // same way a long-lived install accretes a large document.
        let writer = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(writer)
        try await writer.connect()
        try await waitForConnection(client: writer)

        let writerDoc = try await writer.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: writer, documentId: docId)

        let writerMap: YMap<String> = writerDoc.getOrCreateMap(named: "bulk")
        for i in 0..<Self.chunkCount {
            try writer.transactAndSync(docId) { txn in
                writerMap.updateValue(Self.chunkValue(i), forKey: "chunk-\(i)", transaction: txn)
            }
        }

        // Let the writes land server-side before the cold reader connects.
        try await delay(3)

        // Reader: a fresh client with no local state — its empty state vector
        // makes the server's syncStep2 diff the full document, which is over
        // MAX_UPDATE_SIZE and therefore arrives as an R2 updateUrl frame.
        let reader = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(reader)
        try await reader.connect()
        try await waitForConnection(client: reader)

        let readerDoc = try await reader.openDocument(docId, options: OpenDocumentOptions(waitForLoad: .network))
        try await waitForSync(client: reader, documentId: docId)

        let readerMap: YMap<String> = readerDoc.getOrCreateMap(named: "bulk")
        try await eventually(timeout: 15, description: "all chunks visible on cold-loaded client") {
            (0..<Self.chunkCount).allSatisfy { readerMap.containsKey("chunk-\($0)") }
        }

        var wrongValues: [String] = []
        readerDoc.transactSync { txn in
            for i in 0..<Self.chunkCount {
                if readerMap.get(key: "chunk-\(i)", transaction: txn) != Self.chunkValue(i) {
                    wrongValues.append("chunk-\(i)")
                }
            }
        }
        XCTAssertTrue(wrongValues.isEmpty, "Cold-loaded doc has missing or wrong chunks: \(wrongValues)")
    }
}
