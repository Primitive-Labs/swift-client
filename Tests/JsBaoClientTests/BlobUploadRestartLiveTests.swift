import XCTest
@testable import JsBaoClient

/// The upload queue survives a restart, against the dev server (#4592, plan
/// behaviors 22 and 23): a document upload a first client could not send is
/// completed by the next client over the same SQLite file, and a session
/// upload the server refused comes back `.failed` and lands once its user may
/// upload.
final class BlobUploadRestartLiveTests: XCTestCase {
    private static let harnessTask = LockedBox<Task<AgentSessionScenarioHarness, Error>?>(nil)
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients.reversed() { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
    }

    override class func tearDown() {
        guard let task = harnessTask.value else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if let harness = try? await task.value { await harness.cleanup() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        super.tearDown()
    }

    private func harness() async throws -> AgentSessionScenarioHarness {
        let task = Self.harnessTask.withValue { slot -> Task<AgentSessionScenarioHarness, Error> in
            if let slot { return slot }
            let created = Task { try await AgentSessionScenarioHarness.make("blob-upload-restart-swift-4592") }
            slot = created
            return created
        }
        return try await task.value
    }

    private func databasePath() throws -> String {
        let directory = NSTemporaryDirectory() + "jsbao-restart-live-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory + "/jsbao_storage.sqlite"
    }

    /// A client over the SQLite file at `path`; `apiUrl` defaults to the dev
    /// server.
    private func client(
        appId: String, token: String, path: String, apiUrl: String = TestConfig.httpUrl
    ) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: apiUrl,
            wsUrl: TestConfig.wsUrl,
            appId: appId,
            token: token,
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn,
            storageConfig: .sqlite(directory: path),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    // MARK: - Behavior 22: a document upload across a restart

    func testADocumentUploadQueuedByAClientThatCouldNotReachTheServerIsCompletedByTheNextClient() async throws {
        let ctx = TestContext()
        try await ctx.initialize()
        defer { Task { await ctx.cleanup() } }
        let app = try await ctx.createTestApp(name: "swift-blob-restart")
        let documentId = try await ctx.createDocument(appId: app.appId, jwt: app.ownerJWT)
        let path = try databasePath()
        let bytes = Data("written before the restart \(UUID().uuidString)".utf8)

        let unreachable = await client(appId: app.appId, token: app.ownerJWT, path: path, apiUrl: "http://127.0.0.1:9")
        let failure = await thrown {
            _ = try await unreachable.documents.blobs(documentId: documentId).upload(
                data: bytes, options: BlobUploadSourceOptions(filename: "restart.txt", contentType: "text/plain")
            )
        }
        XCTAssertNotNil(failure, "the first client cannot reach the server")
        let queuedValue = await unreachable.documents.uploadsAsync().first?.blobId
        let blobId = try XCTUnwrap(queuedValue, "the upload is queued")
        await unreachable.destroy()

        let next = await client(appId: app.appId, token: app.ownerJWT, path: path)
        try await eventually(timeout: 30, description: "the restored upload completes") {
            await next.documents.uploadsAsync().isEmpty
        }
        let blobs = next.documents.blobs(documentId: documentId)
        let info = try await blobs.get(blobId: blobId)
        XCTAssertEqual(info.blobId, blobId)
        XCTAssertEqual(info.filename, "restart.txt")
        XCTAssertEqual(info.numBytes, bytes.count)
        let served = try await blobs.read(blobId: blobId, force: true)
        XCTAssertEqual(served, bytes, "the server has the bytes")
    }

    // MARK: - Behavior 23: a refused session upload across a restart

    func testARefusedSessionUploadIsRestoredFailedAndLandsAfterItsUserBecomesAParticipant() async throws {
        let h = try await harness()
        let s = try await h.createSession(h.plain, viewers: [h.viewer])
        let path = try databasePath()
        let png = AgentSessionScenarioHarness.png
        let options = AgentSessionAttachmentUploadOptions(filename: "dot.png", contentType: "image/png")

        let first = await client(appId: h.appId, token: h.viewer.jwt, path: path)
        try await first.connect()
        try await waitForConnection(client: first, timeout: 15)
        let firstView = try await first.agents.sessions.open(sessionId: s.sessionId)
        let refusal = await thrown { _ = try await firstView.attachments.upload(png, options: options) }
        XCTAssertEqual((refusal as? HttpError)?.serverCode, "AGENT_SESSION_PARTICIPANT_ONLY")
        let refusedValue = await firstView.attachments.uploads().first?.blobId
        let blobId = try XCTUnwrap(refusedValue)
        await firstView.close()
        await first.destroy()

        let next = await client(appId: h.appId, token: h.viewer.jwt, path: path)
        try await next.connect()
        try await waitForConnection(client: next, timeout: 15)
        let view = try await next.agents.sessions.open(sessionId: s.sessionId)
        let restoredValue = await view.attachments.uploads().first
        let restored = try XCTUnwrap(restoredValue, "the refused upload is restored")
        XCTAssertEqual(restored.blobId, blobId)
        XCTAssertEqual(restored.state, .failed)
        XCTAssertEqual(restored.error?.code, "AGENT_SESSION_PARTICIPANT_ONLY")

        let ownerC = try await h.client(h.owner)
        _ = try await ownerC.agents.sessions.addMember(sessionId: s.sessionId, userId: h.viewer.userId, role: .participant)
        let resumed = await view.attachments.resume(blobId: blobId)
        XCTAssertTrue(resumed)
        let landed = try await within(60, "the resumed upload") { try await view.attachments.waitUntilUploaded(blobId: blobId) }
        XCTAssertEqual(landed.blobId, blobId)
        let downloaded = try await next.agents.sessions.downloadAttachment(sessionId: s.sessionId, blobId: blobId)
        XCTAssertEqual(downloaded, png, "the participant downloads it through the session")
        await view.close()
    }
}
