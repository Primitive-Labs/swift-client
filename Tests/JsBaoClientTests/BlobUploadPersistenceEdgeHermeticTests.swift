import XCTest
@testable import JsBaoClient

/// The edges of upload persistence (#4592, plan behaviors 19 and 20 and the
/// Edge cases): storage that binds late, a write that fails, a write after
/// shutdown, a change of user during a hydration read, a schedule restored
/// from the row, and the identity cases a restart meets.
///
/// The manager-level checks build a `BlobManager` over an `OfflineStore` and a
/// `RecordingTransport`; the rest run a real client over a SQLite file and a
/// `SessionUploadServer`, as `BlobUploadPersistenceHermeticTests` does.
final class BlobUploadPersistenceEdgeHermeticTests: XCTestCase {
    private typealias P = BlobUploadPersistence
    private static let bytes = Data("edge bytes".utf8)
    private static let busy: @Sendable (SessionUploadServer.Request) -> SessionUploadServer.Response = { request in
        if P.isDocumentPut(request) || SessionUploadServer.isAttachmentPut(request) { return .status(503, "busy") }
        return SessionUploadServer.acceptAll(request)
    }

    private var paths: [String] = []
    private var cleanups: [() async -> Void] = []

    override func tearDown() async throws {
        for cleanup in cleanups.reversed() { await cleanup() }
        cleanups = []
        for path in paths { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        paths = []
    }

    private func databasePath() throws -> String {
        let path = try P.databasePath()
        paths.append(path)
        return path
    }

    private func server(
        _ route: @escaping @Sendable (SessionUploadServer.Request) -> SessionUploadServer.Response = SessionUploadServer.acceptAll
    ) throws -> SessionUploadServer {
        let server = try SessionUploadServer(route)
        cleanups.append { server.stop() }
        return server
    }

    private func client(
        _ server: SessionUploadServer, path: String?, userId: String = "u-a", signedIn: Bool = true
    ) async -> JsBaoClient {
        let client = P.client(server, path: path, userId: userId, signedIn: signedIn)
        cleanups.append { await client.destroy() }
        _ = await client.waitForStorageReady()
        return client
    }

    private static func identity(_ userId: String, epoch: UInt64) -> UploadIdentity {
        UploadIdentity(token: "token-\(userId)", userId: userId, epoch: epoch)
    }

    private func manager(
        _ store: OfflineStore?, identity: LockedBox<UploadIdentity>, transport: RecordingTransport,
        backoffMs: Int? = nil
    ) -> BlobManager {
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            backoffBaseMs: backoffMs,
            backoffMaxMs: backoffMs.map { $0 * 2 },
            transport: transport,
            getAppId: { P.appId },
            currentIdentity: { identity.value },
            networkingAllowed: { true },
            offlineStore: store
        )
        cleanups.append { await manager.shutdown() }
        return manager
    }

    private static func answering(_ status: Int) -> RecordingTransport {
        RecordingTransport { _ in
            TransportResponse(status: status, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
    }

    private static func record(_ blobId: String, nextAttemptAt: Double, status: String = "pending") -> PersistedUploadRecord {
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        return PersistedUploadRecord(
            queueId: blobId, documentId: "doc-1", blobId: blobId, filename: "\(blobId).bin",
            contentType: "application/octet-stream", sha256Base64: BlobManager.sha256Base64(bytes),
            disposition: nil, retainLocal: nil, numBytes: bytes.count, status: status, attempts: 1,
            nextAttemptAt: nextAttemptAt, createdAt: now, updatedAt: now, lastError: "busy", lastErrorCode: nil,
            destination: nil
        )
    }

    // MARK: - Behavior 19: storage that binds after the upload is queued

    func testAnUploadQueuedBeforeStorageBindsIsWrittenWhenItBindsAndRestoredLater() async throws {
        let path = try databasePath()
        let store = OfflineStore()
        let identity = LockedBox(Self.identity("u-a", epoch: 1))
        let manager = manager(store, identity: identity, transport: Self.answering(503))
        _ = try? await manager.uploadFromSource(documentId: "doc-1", source: Self.bytes)
        let blobIdValue = await manager.listUploads().first?.blobId
        let blobId = try XCTUnwrap(blobIdValue)
        await manager.awaitPendingPersistence()

        await store.setStorageProvider(SQLiteStorageProvider(path: path))
        await manager.storageDidBecomeReady()
        await manager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertNotNil(rows.record(blobId), "written once storage is ready")
        XCTAssertEqual(rows.bytes["doc-1::\(blobId)"], Self.bytes)
        await manager.shutdown()
        await manager.awaitPendingPersistence()
        await store.closeStorage()

        let later = try server()
        let client = await client(later, path: path)
        try await eventually(timeout: 10, description: "a client started after restores and completes it") {
            P.documentPuts(later, blobId).count == 1
        }
        try await eventually(timeout: 5, description: "and it lands") { await client.documents.uploadsAsync().isEmpty }
    }

    // MARK: - Behavior 20: nothing is selected after shutdown

    func testNoAttemptIsSelectedAfterShutdown() async throws {
        // Retries every few milliseconds, so a selection after shutdown
        // would show at once.
        let transport = Self.answering(503)
        let manager = manager(
            nil, identity: LockedBox(Self.identity("u-a", epoch: 1)), transport: transport, backoffMs: 10
        )
        _ = try? await manager.uploadFromSource(documentId: "doc-1", source: Self.bytes)
        try await eventually(timeout: 5, description: "the queue retries") { transport.calls.count >= 3 }
        await manager.shutdown()
        // An attempt already in flight may still be recorded by the transport.
        try await Task.sleep(nanoseconds: 100_000_000)
        let attempts = transport.calls.count
        await manager.processQueue()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.calls.count, attempts, "no attempt is selected after shutdown")
        let armed = await manager.hasPendingQueueTimer
        XCTAssertFalse(armed, "the queue timer is cancelled")
    }

    // MARK: - Edge: a change of user during a hydration read

    func testRowsReadForAUserWhoSignedOutMeanwhileAreDiscardedAndReadAgainOnTheirSignIn() async throws {
        let path = try databasePath()
        try await UploadRows.seed(path, Self.record("B-A", nextAttemptAt: (Date().timeIntervalSince1970 + 3600) * 1000), bytes: Self.bytes)
        let gated = GatedStorageProvider(
            SQLiteStorageProvider(path: path), gating: OfflineStore.blobUploadsStore(appId: P.appId, userId: "u-a")
        )
        let store = OfflineStore()
        await store.setStorageProvider(gated)
        let identity = LockedBox(Self.identity("u-a", epoch: 1))
        let transport = Self.answering(503)
        let manager = manager(store, identity: identity, transport: transport)
        let ready = Task { await manager.storageDidBecomeReady() }
        try await eventually(timeout: 5, description: "A's rows are being read") { gated.reads.value >= 1 }

        identity.value = Self.identity("u-b", epoch: 2)
        await manager.syncIdentity()
        gated.release()
        await ready.value
        await manager.awaitPendingPersistence()
        let queuedForB = await manager.hasQueuedUpload("B-A")
        XCTAssertFalse(queuedForB, "the rows read for A are discarded")
        XCTAssertEqual(transport.calls.count, 0)

        identity.value = Self.identity("u-a", epoch: 3)
        await manager.syncIdentity()
        try await eventually(timeout: 5, description: "A's sign-in reads them again") {
            await manager.listUploads().map(\.blobId) == ["B-A"]
        }
        await manager.shutdown()
        await manager.awaitPendingPersistence()
        await store.closeStorage()
    }

    // MARK: - Edge: the same user out and in after a restore

    func testTheSameUserSigningOutAndInKeepsTheRestoredTaskInMemoryOnce() async throws {
        let path = try databasePath()
        try await UploadRows.seed(path, Self.record("B-R", nextAttemptAt: 0), bytes: Self.bytes)
        let second = try server(Self.busy)
        let client = await client(second, path: path)
        try await eventually(timeout: 5, description: "the restored upload is attempted") {
            P.documentPuts(second, "B-R").count == 1
        }
        try await eventually(timeout: 5, description: "and queued for retry") {
            await client.documents.uploadsAsync().first?.attempts == 2
        }
        client.updateToken(nil)
        client.updateToken(P.token("u-a"))
        try await Task.sleep(nanoseconds: 300_000_000)
        let listed = await client.documents.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), ["B-R"])
        XCTAssertGreaterThanOrEqual(listed.first?.attempts ?? 0, 2, "the in-memory task wins over the row")
        XCTAssertLessThanOrEqual(P.documentPuts(second, "B-R").count, 2, "not attempted twice over")
    }

    // MARK: - Edge: the restored schedule

    func testAPastAttemptTimeRunsAtOnceAndAFutureOneArmsTheTimerForIt() async throws {
        let path = try databasePath()
        let now = Date().timeIntervalSince1970 * 1000
        try await UploadRows.seed(path, Self.record("B-PAST", nextAttemptAt: now - 1000), bytes: Self.bytes)
        try await UploadRows.seed(path, Self.record("B-SOON", nextAttemptAt: now + 2500), bytes: Self.bytes)
        let second = try server()
        let client = await client(second, path: path)
        try await eventually(timeout: 1, description: "the past one is attempted at once") {
            P.documentPuts(second, "B-PAST").count == 1
        }
        XCTAssertEqual(P.documentPuts(second, "B-SOON").count, 0, "the future one waits")
        try await eventually(timeout: 2, description: "the timer is armed for it") {
            await client.blobManager.hasPendingQueueTimer
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(P.documentPuts(second, "B-SOON").count, 0, "not before its time")
        try await eventually(timeout: 5, description: "attempted when due") { P.documentPuts(second, "B-SOON").count == 1 }
    }

    // MARK: - Edge: nobody signed in

    func testAnUploadQueuedWithNobodySignedInIsNotPersisted() async throws {
        let path = try databasePath()
        let first = try server(Self.busy)
        let client = await client(first, path: path, signedIn: false)
        _ = try await P.queueDocumentUpload(client, data: Self.bytes)
        await client.blobManager.awaitPendingPersistence()
        let rows = try await UploadRows.countAll(path)
        XCTAssertEqual(rows, 0)
    }

    // MARK: - Edge: a failed write

    func testAFailedWriteIsLoggedAndLaterWritesStillApplyInOrder() async throws {
        let path = try databasePath()
        let flaky = GatedStorageProvider(SQLiteStorageProvider(path: path), failPuts: 1)
        let store = OfflineStore()
        await store.setStorageProvider(flaky)
        let identity = LockedBox(Self.identity("u-a", epoch: 1))
        let transport = Self.answering(503)
        let manager = manager(store, identity: identity, transport: transport)
        await manager.storageDidBecomeReady()

        let error = await thrown { _ = try await manager.uploadFromSource(documentId: "doc-1", source: Self.bytes) }
        XCTAssertEqual((error as? HttpError)?.status, 503)
        XCTAssertEqual(flaky.failPuts.value, 0, "the first write failed")
        XCTAssertGreaterThanOrEqual(transport.calls.count, 1, "the PUT still left")
        let blobIdValue = await manager.listUploads().first?.blobId
        let blobId = try XCTUnwrap(blobIdValue)
        _ = await manager.pauseUpload(blobId)
        await manager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(blobId)?.status, "paused", "later writes apply, in order")
        XCTAssertEqual(rows.bytes["doc-1::\(blobId)"], Self.bytes)
        await manager.shutdown()
        await manager.awaitPendingPersistence()
        await store.closeStorage()
    }

    // MARK: - Edge: pause then resume, back to back

    func testPauseThenResumeBackToBackStoresPending() async throws {
        let path = try databasePath()
        let first = try server(Self.busy)
        let client = await client(first, path: path)
        await client.documents.setUploadConcurrencyAsync(1)
        P.holdDocumentRetries(first)
        _ = try await P.queueDocumentUpload(client, data: Data("slot".utf8))
        try await eventually(timeout: 5, description: "the slot is taken") { first.heldRequests.count == 1 }
        let blobId = try await P.queueDocumentUpload(client, data: Self.bytes)
        _ = await client.documents.pauseUploadAsync(blobId: blobId)
        _ = await client.documents.resumeUploadAsync(blobId: blobId)
        await client.blobManager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertEqual(rows.record(blobId)?.status, "pending")
    }

    // MARK: - Edge: logout with a wipe

    func testLogoutWithAWipeLeavesThePersistedUploadsAndTheSameUserReadoptsThem() async throws {
        let path = try databasePath()
        let first = try server(Self.busy)
        P.holdDocumentRetries(first)
        let client = await client(first, path: path)
        let blobId = try await P.queueDocumentUpload(client, data: Self.bytes)
        try await eventually(timeout: 5, description: "the retry is in flight") { first.heldRequests.count == 1 }

        try await client.logout(wipeLocal: true)
        await client.blobManager.awaitPendingPersistence()
        let rows = try await UploadRows.read(path)
        XCTAssertNotNil(rows.record(blobId), "the wipe leaves the persisted upload")
        let listedSignedOut = await client.documents.uploadsAsync()
        XCTAssertEqual(listedSignedOut.map(\.blobId), [])

        client.updateToken(P.token("u-a"))
        try await eventually(timeout: 10, description: "the same user's sign-in re-adopts it") {
            first.heldRequests.count == 2
        }
        let listed = await client.documents.uploadsAsync()
        XCTAssertEqual(listed.map(\.blobId), [blobId])
    }

    // MARK: - Edge: completed before the restart

    func testWaitingForAnUploadCompletedBeforeTheRestartThrowsUnknown() async throws {
        let path = try databasePath()
        let first = try server()
        let client1 = await client(first, path: path)
        let landed = try await client1.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").upload(Self.bytes)
        XCTAssertEqual(first.puts(of: landed.blobId).count, 1)
        await client1.destroy()

        let second = try server()
        let client2 = await client(second, path: path)
        let error = await thrown {
            _ = try await client2.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
                .waitUntilUploaded(blobId: landed.blobId)
        }
        XCTAssertEqual((error as? JsBaoError)?.code, .agentSessionUploadUnknown)
    }

    // MARK: - Edge: the session gone after the restart

    func testASessionObservedGoneAfterTheRestartFailsEachRestoredUploadOnce() async throws {
        let path = try databasePath()
        let first = try server()
        let client1 = await client(first, path: path)
        client1.setNetworkMode(.offline)
        let attachments1 = client1.blobManager.forAgentSession(sessionId: "s1", documentId: "d1")
        let one = try await attachments1.upload(Self.bytes)
        let two = try await attachments1.upload(Self.bytes)
        await client1.destroy()

        let second = try server { request in
            SessionUploadServer.isAttachmentPut(request)
                ? SessionUploadServer.refused(404, "AGENT_SESSION_NOT_FOUND", "No such session")
                : SessionUploadServer.acceptAll(request)
        }
        let client2 = P.client(second, path: path)
        cleanups.append { await client2.destroy() }
        let events = OrderedBlobEvents(client2)
        defer { events.cancel() }
        _ = await client2.waitForStorageReady()
        try await eventually(timeout: 10, description: "both rows read failed") {
            await client2.blobManager.awaitPendingPersistence()
            let rows = try await UploadRows.read(path)
            return rows.records.count == 2 && rows.records.allSatisfy {
                $0.status == "failed" && $0.lastErrorCode == "AGENT_SESSION_NOT_FOUND"
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(events.failed(one.blobId).map(\.willRetry), [false])
        XCTAssertEqual(events.failed(two.blobId).map(\.willRetry), [false])
        let listed = await client2.blobManager.forAgentSession(sessionId: "s1", documentId: "d1").uploads()
        XCTAssertEqual(Set(listed.map(\.state)), [.failed])
    }

    // MARK: - Edge: a write after shutdown

    func testAWriteAfterShutdownIsRefusedAndTheDrainStillReturns() async throws {
        let path = try databasePath()
        let store = OfflineStore()
        await store.setStorageProvider(SQLiteStorageProvider(path: path))
        let manager = manager(store, identity: LockedBox(Self.identity("u-a", epoch: 1)), transport: Self.answering(503))
        await manager.storageDidBecomeReady()
        _ = try? await manager.uploadFromSource(documentId: "doc-1", source: Self.bytes)
        let blobIdValue = await manager.listUploads().first?.blobId
        let blobId = try XCTUnwrap(blobIdValue)
        await manager.awaitPendingPersistence()

        await manager.shutdown()
        _ = await manager.pauseUpload(blobId)
        try await within(5, "the drain after shutdown") { await manager.awaitPendingPersistence() }
        let rows = try await UploadRows.read(path)
        XCTAssertNotNil(rows.record(blobId))
        XCTAssertNotEqual(rows.record(blobId)?.status, "paused", "the write after shutdown is never applied")
        await store.closeStorage()
    }
}

/// The structural rules the actor keeps with persistence in it (#4592, plan
/// behavior 18): the write chain's task is built off the actor, the decision
/// regions stay `await`-free, every emit sits in `nonisolated` context, and
/// neither hydration nor the write before the first PUT emits.
final class BlobUploadPersistenceStructureHermeticTests: XCTestCase {
    private func code() throws -> String {
        try ClientSourceText.code("Internal/BlobManager.swift")
    }

    func testTheWriteChainTaskIsBuiltByANonisolatedFactory() throws {
        let source = try code()
        XCTAssertTrue(
            source.contains("private nonisolated func makePersistenceWrite("),
            "a Task made in isolated context inherits the actor's isolation"
        )
        let body = try ClientSourceText.slice(
            source, from: "private nonisolated func makePersistenceWrite(", to: "\n    }\n"
        )
        XCTAssertTrue(body.contains("Task"), body)
    }

    func testTheDecisionRegionsStayAwaitFree() throws {
        let source = try code()
        let regions = [
            ("func scheduleQueueProcessing(delayMs: Int = 0) {", "private nonisolated func makeQueueTimer("),
            ("private func selectDueTasks()", "private nonisolated func runUploadTask("),
            ("private func recordUploadFailure(", "private nonisolated func emitUploadProgress("),
        ]
        for (from, to) in regions {
            let region = try ClientSourceText.slice(source, from: from, to: to)
            XCTAssertFalse(region.isEmpty)
            XCTAssertFalse(region.contains("await"), "\(from) must not suspend:\n\(region)")
        }
    }

    func testEveryEmitSiteIsNonisolated() throws {
        let lines = try code().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var declaration: String?
        var sites = 0
        var isolated: [String] = []
        for line in lines {
            if line.hasPrefix("    ") && !line.hasPrefix("        ") && line.contains("func ") {
                declaration = line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.contains("emit?("), let declaration else { continue }
            sites += 1
            if !declaration.contains("nonisolated") { isolated.append(declaration) }
        }
        XCTAssertGreaterThanOrEqual(sites, 15, "the scan reads the source")
        XCTAssertEqual(isolated, [], "isolated members reach the emit closure")
    }

    func testNeitherHydrationNorThePreputWriteEmits() throws {
        let source = try code()
        let marked = try ClientSourceText.clientSource("Internal/BlobManager.swift")
        let hydration = ClientSourceText.stripComments(
            try ClientSourceText.slice(marked, from: "// MARK: - Hydration", to: "// MARK: - Shutdown")
        )
        XCTAssertTrue(hydration.contains("func storageDidBecomeReady("), "the slice covers hydration")
        XCTAssertFalse(hydration.contains("emit"), "hydration emits nothing:\n\(hydration)")
        let begin = try ClientSourceText.slice(source, from: "private func beginDocumentUpload(", to: "\n    }\n")
        XCTAssertTrue(begin.contains("persist"), "the slice covers the write before the first PUT:\n\(begin)")
        XCTAssertFalse(begin.contains("emit"), "the write before the first PUT emits nothing")
    }
}
