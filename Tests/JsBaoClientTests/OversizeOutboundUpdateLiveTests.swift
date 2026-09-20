import Foundation
import XCTest
@testable import JsBaoClient
import YSwift

/// The Swift client's outbound R2 path, against a real room (#3559).
///
/// `OversizeOutboundUpdateHermeticTests` pins the DECISION — which frame is
/// built at which size — over a stubbed offload. This pins the offload itself,
/// which no stub can: the `getUploadUrl` request travels a real socket to a
/// real Durable Object, the room mints the key and the URL, the PUT lands in a
/// real R2 bucket, and the room resolves the `uploadId` the frame names. A
/// `uploadId` the server cannot resolve is answered with an `error` frame and
/// the write is simply lost, which is the failure mode this whole issue is
/// about.
///
/// The spy on `uploadLargeUpdate` delegates to the client's own
/// `uploadOutboundUpdate`, so what runs is the shipping path; the spy only
/// says that it ran. Without it this case would pass on the inline path too
/// now that the server half of #3559 stores an oversize inline payload
/// durably — and then it would be evidence for the server, not for the client.
final class OversizeOutboundUpdateLiveTests: XCTestCase {
    private var ctx: TestContext!
    private var testApp: TestApp!
    private var clients: [JsBaoClient] = []
    private var directories: [String] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-oversize-outbound-3559")
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients.removeAll()
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories.removeAll()
        await ctx.cleanup()
    }

    /// A SQLite store two client lifetimes can share. The path is what
    /// `StorageConfig.sqlite(directory:)` takes — a FILE, as everywhere else
    /// in this suite's neighbours.
    private func newStorageDirectory() -> String {
        let directory = NSTemporaryDirectory() + "/swift-oversize-3559-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    /// Counts the offloads and forwards each to the real upload path.
    private final class UploadSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _sizes: [Int] = []
        func note(_ bytes: Int) { lock.withLock { _sizes.append(bytes) } }
        var sizes: [Int] { lock.withLock { _sizes } }
    }

    /// A high-entropy string, so the payload cannot be compressed back under
    /// the threshold by a future real `compressData`.
    private func noise(_ count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(alphabet.randomElement()!) }
        return out
    }

    /// POST one of the room's `__test__` document routes.
    @discardableResult
    private func testRoute(
        _ documentId: String,
        _ action: String,
        body: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let url = URL(
            string: "\(TestConfig.httpUrl)/__test__/document/\(testApp.appId)/\(documentId)/\(action)"
        )!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            ProcessInfo.processInfo.environment["TEST_ADMIN_TOKEN"] ?? "local-test-secret",
            forHTTPHeaderField: "X-Test-Auth"
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await NetworkSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        XCTAssertEqual(status, 200, "\(action) failed: \(json)")
        return json
    }

    func testAnOversizeSwiftWriteIsUploadedAndSurvivesTheRoomGoingCold() async throws {
        let documentId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Swift oversize outbound"
        )

        let writer = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(writer)
        let spy = UploadSpy()
        // Delegates to the shipping upload path; the spy only records that it
        // was the path taken.
        writer.documentManager.uploadLargeUpdate = { [weak writer] docId, payload in
            spy.note(payload.count)
            return await writer?.uploadOutboundUpdate(documentId: docId, payload: payload)
        }

        try await writer.connect()
        try await waitForConnection(client: writer)
        let doc = try await writer.openDocument(
            documentId, options: OpenDocumentOptions(waitForLoad: .network)
        )
        try await waitForSync(client: writer, documentId: documentId)

        let body = noise(122_000)
        let map: YMap<String> = doc.getOrCreateMap(named: "Note")
        doc.transactSync { txn in
            map.updateValue(body, forKey: "r1", transaction: txn)
        }

        // The room has taken exactly one update row for it.
        try await eventually(timeout: 30, description: "the room stores the write") {
            let state = try await self.testRoute(documentId, "state")
            let counters = state["counters"] as? [String: Any]
            return (counters?["totalUpdates"] as? Int ?? 0) >= 1
        }

        XCTAssertEqual(
            spy.sizes.count, 1,
            "the write went out through the offload, not inline — that is the parity this issue is about"
        )
        XCTAssertGreaterThan(spy.sizes.first ?? 0, DocumentManager.maxInlineUpdateBytes)

        // The row really is an R2 reference, and the room really resolved the
        // uploadId: an unresolvable one is answered with an `error` frame and
        // no row at all.
        let dump = try await testRoute(
            documentId, "dump-updates", body: ["includeData": false, "limit": 100]
        )
        let rows = dump["rows"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows.first?["r2Key"] as? String, "the payload is in R2, named by the row")

        // Cold, without reconstructing.
        try await testRoute(documentId, "evict")

        // A fresh client syncs the whole document back.
        let reader = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(reader)
        try await reader.connect()
        try await waitForConnection(client: reader)
        let readDoc = try await reader.openDocument(
            documentId, options: OpenDocumentOptions(waitForLoad: .network)
        )
        try await waitForSync(client: reader, documentId: documentId)

        let readMap: YMap<String> = readDoc.getOrCreateMap(named: "Note")
        let readBack: String? = readMap["r1"]
        XCTAssertEqual(readBack, body, "the oversize write survived the room going cold")

        let state = try await testRoute(documentId, "state")
        let counts = (state["lastReconstructMetrics"] as? [String: Any])?["counts"]
            as? [String: Any]
        XCTAssertEqual(
            counts?["skippedNoData"] as? Int, 0,
            "the reconstruct that fed the reader skipped nothing"
        )
    }

    /// A CACHED document owing an oversize diff answers the room's `syncStep1`
    /// with it, against a real room (finding 3559-SO-001).
    ///
    /// The other cases here go out through the update queue, which drains on a
    /// task of its own. This one cannot: the write belongs to a previous
    /// process, so this session has nothing queued and the only door its state
    /// can leave by is the answer to the room's `syncStep1` — built inside a
    /// frame handler, on the socket's receive loop.
    ///
    /// That is what makes it the live half of the deadlock
    /// `OversizeOutboundConcurrencyHermeticTests` pins: the answer's offload
    /// waits for a `getUploadUrlResponse` that arrives as a frame, and a
    /// handler that waits for it is the one thing stopping it from being read.
    /// Before the hand-off to the outbound lane this test hangs for the
    /// waiter's ten seconds and the cached write never reaches the room.
    func testACachedDocumentAnswersSyncStep1WithAnOversizeDiff() async throws {
        let documentId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Swift oversize cached diff"
        )
        let directory = newStorageDirectory()
        let body = noise(122_000)

        // Session one: synced, then taken offline, then written to. The write
        // is queued against a socket that is down and the process ends before
        // it can drain, so it survives only in this document's local store.
        do {
            let first = createTestClient(
                appId: testApp.appId, token: testApp.ownerJWT,
                storageConfig: .sqlite(directory: directory)
            )
            try await first.connect()
            try await waitForConnection(client: first)
            let doc = try await first.openDocument(
                documentId, options: OpenDocumentOptions(waitForLoad: .network)
            )
            try await waitForSync(client: first, documentId: documentId)

            await first.goOffline()
            try await eventually(timeout: 10, description: "the first session to go offline") {
                !first.isConnected
            }

            let map: YMap<String> = doc.getOrCreateMap(named: "Note")
            doc.transactSync { txn in
                map.updateValue(body, forKey: "r1", transaction: txn)
            }
            // Past the persistence debounce, so the local store really has it.
            try await delay(1.0)
            await first.destroy()
        }

        // Session two: the same store, connected. Nothing is queued here.
        let second = createTestClient(
            appId: testApp.appId, token: testApp.ownerJWT,
            storageConfig: .sqlite(directory: directory)
        )
        clients.append(second)
        let spy = UploadSpy()
        second.documentManager.uploadLargeUpdate = { [weak second] docId, payload in
            spy.note(payload.count)
            return await second?.uploadOutboundUpdate(documentId: docId, payload: payload)
        }
        try await second.connect()
        try await waitForConnection(client: second)
        let restored = try await second.openDocument(
            documentId, options: OpenDocumentOptions(waitForLoad: .local)
        )
        let restoredMap: YMap<String> = restored.getOrCreateMap(named: "Note")
        XCTAssertEqual(
            restoredMap["r1"], body,
            "precondition: this session opened the cached write, it did not make it"
        )
        XCTAssertEqual(
            second.pendingOutboundUpdateCountForTest(documentId), 0,
            "precondition: nothing is queued, so the syncStep1 answer is the only door"
        )

        try await waitForSync(client: second, documentId: documentId, timeout: 20)
        try await eventually(timeout: 30, description: "the room stores the cached diff") {
            !spy.sizes.isEmpty
        }
        XCTAssertGreaterThan(
            spy.sizes.first ?? 0, DocumentManager.maxInlineUpdateBytes,
            "the answer went out through the offload, which is the path that deadlocked"
        )

        // And a fresh reader really gets it: the room resolved the `uploadId`
        // the answer named.
        let reader = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(reader)
        try await reader.connect()
        try await waitForConnection(client: reader)
        let readDoc = try await reader.openDocument(
            documentId, options: OpenDocumentOptions(waitForLoad: .network)
        )
        try await waitForSync(client: reader, documentId: documentId)
        let readMap: YMap<String> = readDoc.getOrCreateMap(named: "Note")
        try await eventually(timeout: 30, description: "the cached write reaches a fresh reader") {
            readMap["r1"] == body
        }
    }

    /// A burst of small writes whose MERGE is oversize all reach the server.
    ///
    /// This is the shape the merge cap used to make unreachable and the one
    /// the upload path made fragile: a flush runs on the document's outbound
    /// debounce task, and the next local edit cancels that task. Once the
    /// flush contains a `URLSession` PUT, that cancellation kills the upload
    /// mid-flight; the send then fails and the flush owner retains the batch
    /// WITHOUT retrying, so everything after the first frame is stranded with
    /// nothing scheduled to carry it.
    ///
    /// Only a live case can see it: the cancellation is real task
    /// cancellation around a real `URLSession` request, and the loss is
    /// silent — the writer reports no error and its own document is complete.
    func testABurstOfWritesWhoseMergeIsOversizeAllReachTheServer() async throws {
        let documentId = try await ctx.createDocument(
            appId: testApp.appId,
            jwt: testApp.ownerJWT,
            title: "Swift burst past the old cap"
        )

        let writer = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(writer)
        try await writer.connect()
        try await waitForConnection(client: writer)
        let doc = try await writer.openDocument(
            documentId, options: OpenDocumentOptions(waitForLoad: .network)
        )
        try await waitForSync(client: writer, documentId: documentId)

        // Forty ~8 KB writes, back to back: each one well under the
        // threshold, their merge well over it several times over, and each one
        // cancelling the debounce task the previous flush is running on. Forty
        // rather than a handful because the loss needs a flush to still be
        // inside its PUT when the next edit lands, and a short burst finishes
        // before the first flush has anything oversize to upload.
        let chunkCount = 40
        let bodies = (0..<chunkCount).map { _ in noise(8_192) }
        let map: YMap<String> = doc.getOrCreateMap(named: "bulk")
        for (index, body) in bodies.enumerated() {
            try writer.transactAndSync(documentId) { txn in
                map.updateValue(body, forKey: "chunk-\(index)", transaction: txn)
            }
        }

        // A fresh reader sees every one of them.
        let reader = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        clients.append(reader)
        try await reader.connect()
        try await waitForConnection(client: reader)
        let readDoc = try await reader.openDocument(
            documentId, options: OpenDocumentOptions(waitForLoad: .network)
        )
        try await waitForSync(client: reader, documentId: documentId)
        let readMap: YMap<String> = readDoc.getOrCreateMap(named: "bulk")

        try await eventually(timeout: 30, description: "every chunk reaches the reader") {
            (0..<chunkCount).allSatisfy { readMap.containsKey("chunk-\($0)") }
        }
        var wrong: [String] = []
        for (index, body) in bodies.enumerated() {
            let value: String? = readMap["chunk-\(index)"]
            if value != body { wrong.append("chunk-\(index)") }
        }
        XCTAssertTrue(wrong.isEmpty, "writes stranded by a cancelled upload: \(wrong)")
    }
}
