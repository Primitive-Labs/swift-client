import XCTest
@testable import JsBaoClient

/// #4943 behavior 9 and edge cases E6 and E12 — `client.db3.blobs(id)` sends
/// what `client.documents.blobs(documentId:)` sends, to the db3 routes.
///
/// Over two recording transports the upload PUT carries the documents
/// context's headers to `/db3/<id>/blobs/<blobId>`; `list`, `get` and
/// `delete` use `/db3/<id>/blobs…` with the twin's query; `downloadUrl` is
/// the db3 download route with the twin's query; ids are encoded once. A
/// queued db3 upload's record names its destination; an unknown destination
/// still reads as a document upload. Request serialization only: the live
/// suites prove what the server answers.
final class Db3BlobsHermeticTests: XCTestCase {

    private func transport() -> RecordingTransport {
        RecordingTransport(responder: { call in
            let json: String
            if call.method == .put {
                json = "{}"
            } else if call.method == .delete {
                json = #"{"deleted":true}"#
            } else if call.path.contains("/blobs?") || call.path.hasSuffix("/blobs") {
                json = #"{"items":[{"blobId":"B1"}],"hasMore":false}"#
            } else {
                json = #"{"blobId":"B1","filename":"a.txt"}"#
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        })
    }

    private func manager(_ transport: RecordingTransport) -> BlobManager {
        BlobManager(
            logger: createLogger(level: .error, scope: "test"), transport: transport,
            getApiUrl: { "https://api.test" }, getAppId: { "app1" }
        )
    }

    private func db3(_ transport: RecordingTransport, _ db3Id: String = "D1") -> Db3BlobContext {
        Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport, blobManager: manager(transport)).blobs(db3Id)
    }

    private func documents(_ transport: RecordingTransport, _ documentId: String = "D1") -> DocumentBlobContext {
        DocumentBlobContext(documentId: documentId, transport: transport, blobManager: manager(transport))
    }

    // MARK: - Behavior 9

    @available(*, deprecated)
    func testEachRequestIsTheDocumentsRequestOnTheDb3Route() async throws {
        let ours = transport()
        let theirs = transport()
        let blobs = db3(ours)
        let twin = documents(theirs)
        let data = Data("hello, db3".utf8)
        let options = BlobUploadSourceOptions(filename: "hello world.txt", contentType: "text/plain", disposition: .attachment)

        let uploaded = try await blobs.upload(data: data, options: options)
        let twinUploaded = try await twin.upload(data: data, options: options)
        XCTAssertEqual(uploaded.bytesTransferred, data.count)
        XCTAssertEqual(uploaded.numBytes, twinUploaded.numBytes)
        XCTAssertEqual(uploaded.contentType, twinUploaded.contentType)
        _ = try await blobs.list(limit: 5, cursor: "c 1")
        _ = try await twin.list(limit: 5, cursor: "c 1")
        _ = try await blobs.get(blobId: "B1")
        _ = try await twin.get(blobId: "B1")
        let deleted = try await blobs.delete(blobId: "B1")
        _ = try await twin.delete(blobId: "B1")
        XCTAssertTrue(deleted.deleted)

        XCTAssertEqual(ours.calls.count, 4)
        XCTAssertEqual(ours.calls.count, theirs.calls.count)
        let put = ours.calls[0]
        let twinPut = theirs.calls[0]
        XCTAssertEqual(put.method, .put)
        XCTAssertEqual(put.path, "/db3/D1/blobs/\(uploaded.blobId)")
        XCTAssertEqual(twinPut.path, "/documents/D1/blobs/\(twinUploaded.blobId)")
        XCTAssertEqual(put.body, data)
        XCTAssertEqual(put.options?.customHeaders, twinPut.options?.customHeaders, "the same X-Blob-* headers")
        XCTAssertEqual(put.options?.customHeaders["X-Blob-Disposition"], "attachment")
        XCTAssertEqual(put.options?.customHeaders["Content-Type"], "text/plain")
        for (mine, other) in zip(ours.calls.dropFirst(), theirs.calls.dropFirst()) {
            XCTAssertEqual(mine.method, other.method)
            XCTAssertEqual(mine.path, other.path.replacingOccurrences(of: "/documents/", with: "/db3/"))
        }
        XCTAssertEqual(ours.calls.map(\.path).dropFirst(), ["/db3/D1/blobs?limit=5&cursor=c%201", "/db3/D1/blobs/B1", "/db3/D1/blobs/B1"])
    }

    @available(*, deprecated)
    func testTheDownloadUrlIsTheDb3Route() {
        let blobs = db3(transport())
        let twin = documents(transport())
        XCTAssertEqual(blobs.downloadUrl(blobId: "B1"), "https://api.test/app/app1/api/db3/D1/blobs/B1/download")
        let full = blobs.downloadUrl(blobId: "B1", disposition: .attachment, attachmentFilename: "résumé 1.pdf")
        XCTAssertEqual(
            full,
            twin.downloadUrl(blobId: "B1", disposition: .attachment, attachmentFilename: "résumé 1.pdf")
                .replacingOccurrences(of: "/api/documents/", with: "/api/db3/")
        )
        XCTAssertEqual(
            full,
            "https://api.test/app/app1/api/db3/D1/blobs/B1/download?disposition=attachment&attachmentFilename=UTF-8''r%C3%A9sum%C3%A9%201.pdf"
        )
    }

    func testEveryIdIsEncodedOnce() async throws {
        let ours = transport()
        let blobs = db3(ours, "D/1?x")
        _ = try await blobs.get(blobId: "B/1")
        _ = try await blobs.list()
        let uploaded = try await blobs.upload(data: Data("x".utf8))
        XCTAssertEqual(ours.calls.map(\.path), ["/db3/D%2F1%3Fx/blobs/B%2F1", "/db3/D%2F1%3Fx/blobs", "/db3/D%2F1%3Fx/blobs/\(uploaded.blobId)"])
        XCTAssertEqual(blobs.downloadUrl(blobId: "B/1"), "https://api.test/app/app1/api/db3/D%2F1%3Fx/blobs/B%2F1/download")
    }

    // MARK: - E12

    func testADb3ApiWithoutAManagerStillUploadsThroughItsTransport() async throws {
        let ours = transport()
        let api = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: ours)
        let uploaded = try await api.blobs("D1").upload(data: Data("bytes".utf8))
        XCTAssertEqual(ours.lastCall?.method, .put)
        XCTAssertEqual(ours.lastCall?.path, "/db3/D1/blobs/\(uploaded.blobId)")
    }

    // MARK: - The persisted destination (behavior 13's record, E6)

    func testADb3UploadRecordNamesItsDestinationAndADocumentOneNamesNone() throws {
        let db3Task = UploadTask(
            blobId: "B1", documentId: "D1", data: Data("x".utf8), options: BlobUploadSourceOptions(), sha256: "s",
            attempts: 0, lastError: nil, destination: .db3("D1")
        )
        let documentTask = UploadTask(
            blobId: "B2", documentId: "D1", data: Data("x".utf8), options: BlobUploadSourceOptions(), sha256: "s",
            attempts: 0, lastError: nil
        )
        let encoded = try JSONCoding.decodeData(JSONValue.self, from: JSONEncoder().encode(db3Task.persistedRecord))
        XCTAssertEqual(encoded["destination"], ["kind": "db3", "documentId": "D1"])
        let documentEncoded = try JSONCoding.decodeData(JSONValue.self, from: JSONEncoder().encode(documentTask.persistedRecord))
        XCTAssertNil(documentEncoded["destination"], "a document upload's record is unchanged")

        let restored = UploadTask(restoring: db3Task.persistedRecord, data: Data("x".utf8), userId: "u", generation: 0)
        XCTAssertEqual(restored.destination, .db3("D1"))
    }

    func testAStoredDestinationDecodesByItsKind() throws {
        func decode(_ json: String) throws -> UploadDestination {
            try JSONDecoder().decode(UploadDestination.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"kind":"db3","documentId":"D1"}"#), .db3("D1"))
        XCTAssertEqual(try decode(#"{"kind":"agent-session","sessionId":"S1"}"#), .agentSession("S1"))
        XCTAssertEqual(try decode(#"{"kind":"document","documentId":"D1"}"#), .document)
        XCTAssertEqual(try decode(#"{"kind":"something-later"}"#), .document, "an unknown kind reads as a document upload")
    }

    // MARK: - #6245 behavior 30 and E9

    /// A batch from db3 A that names an upload queued for db3 B leaves it queued
    /// with its bytes (the server skipped that id); an upload of a named id
    /// queued for A is cancelled and A's copy of it goes.
    func testABatchCancelsOnlyTheTargetDb3sQueuedUploads() async throws {
        let transport = RecordingTransport { call in
            if call.method == .post, call.path == "/db3/A/blobs/delete" {
                let body = (try? JSONSerialization.jsonObject(with: call.body ?? Data())) as? [String: Any]
                let ids = body?["blobIds"] as? [String] ?? []
                let answer: [String: Any] = ["deleted": ids.count, "blobIds": ids, "db3Id": "A"]
                return TransportResponse(
                    status: 200, headers: ["Content-Type": "application/json"],
                    body: try! JSONSerialization.data(withJSONObject: answer)
                )
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        let networking = LockedBox(false)
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            transport: transport,
            getApiUrl: { "https://api.test" },
            getAppId: { "app1" },
            currentIdentity: { UploadIdentity(token: "token-u-a", userId: "u-a") },
            networkingAllowed: { networking.value }
        )
        defer { Task { await manager.shutdown() } }
        let forA = try await manager.uploadFromSource(documentId: "A", source: Data("for A".utf8), options: BlobUploadSourceOptions(), family: .db3)
        let forB = try await manager.uploadFromSource(documentId: "B", source: Data("for B".utf8), options: BlobUploadSourceOptions(), family: .db3)
        XCTAssertEqual(forA.bytesTransferred, 0)
        XCTAssertEqual(forB.bytesTransferred, 0)

        let blobs = Db3BlobContext(db3Id: "A", transport: transport, blobManager: manager)
        let result = try await blobs.deleteBatch(blobIds: [forB.blobId, forA.blobId])
        XCTAssertEqual(result.deleted, 2)
        XCTAssertEqual(result.blobIds, [forB.blobId, forA.blobId])
        XCTAssertEqual(result.db3Id, "A")
        XCTAssertEqual(transport.calls.map(\.path), ["/db3/A/blobs/delete"])

        let queuedForB = await manager.listUploads(documentId: "B", family: .db3)
        XCTAssertEqual(queuedForB.map(\.blobId), [forB.blobId], "db3 B's upload stays queued")
        let bytesForB = await manager.hasCachedBytes(documentId: "B", blobId: forB.blobId, family: .db3)
        XCTAssertTrue(bytesForB, "with its bytes")
        let queuedForA = await manager.listUploads(documentId: "A", family: .db3)
        XCTAssertEqual(queuedForA.map(\.blobId), [], "db3 A's upload is cancelled")
        let bytesForA = await manager.hasCachedBytes(documentId: "A", blobId: forA.blobId, family: .db3)
        XCTAssertFalse(bytesForA, "and its copy goes")
    }

    /// CSO-6245-009: the cleanup is the requesting user's. When another user
    /// signs in while the batch is out, the requester's queued upload of a
    /// named id is still cancelled (it must not be sent on their next
    /// sign-in), and the user signed in now keeps their own uploads.
    func testABatchCleansTheRequestersQueueWhenAnotherUserSignsInMeanwhile() async throws {
        let user = LockedBox("u-a")
        let transport = RecordingTransport { call in
            if call.method == .post, call.path == "/db3/A/blobs/delete" {
                // Another user signs in while the request is out.
                user.value = "u-b"
                let body = (try? JSONSerialization.jsonObject(with: call.body ?? Data())) as? [String: Any]
                let ids = body?["blobIds"] as? [String] ?? []
                let answer: [String: Any] = ["deleted": ids.count, "blobIds": ids, "db3Id": "A"]
                return TransportResponse(
                    status: 200, headers: ["Content-Type": "application/json"],
                    body: try! JSONSerialization.data(withJSONObject: answer)
                )
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        let networking = LockedBox(false)
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            transport: transport,
            getApiUrl: { "https://api.test" },
            getAppId: { "app1" },
            currentIdentity: { UploadIdentity(token: "token-\(user.value)", userId: user.value) },
            networkingAllowed: { networking.value }
        )
        defer { Task { await manager.shutdown() } }
        let mine = try await manager.uploadFromSource(documentId: "A", source: Data("u-a's".utf8), options: BlobUploadSourceOptions(), family: .db3)
        user.value = "u-b"
        let theirs = try await manager.uploadFromSource(documentId: "A", source: Data("u-b's".utf8), options: BlobUploadSourceOptions(), family: .db3)
        user.value = "u-a"

        let blobs = Db3BlobContext(db3Id: "A", transport: transport, blobManager: manager)
        _ = try await blobs.deleteBatch(blobIds: [mine.blobId])
        XCTAssertEqual(user.value, "u-b", "the answer arrived with u-b signed in")

        let mineQueued = await manager.hasQueuedUpload(mine.blobId)
        XCTAssertFalse(mineQueued, "u-a's queued upload of the deleted id is cancelled")
        let theirsQueued = await manager.listUploads(documentId: "A", family: .db3)
        XCTAssertEqual(theirsQueued.map(\.blobId), [theirs.blobId], "u-b's own upload stays queued")
        user.value = "u-a"
        let afterSignIn = await manager.listUploads(documentId: "A", family: .db3)
        XCTAssertEqual(afterSignIn.map(\.blobId), [], "nothing of u-a's is left to send")
    }

    /// CSO-6245-011: a queued upload of the target db3 whose PUT is in flight
    /// when the batch succeeds has its transfer cancelled, so the PUT cannot
    /// finish afterwards and bring the blob back, and nothing completes.
    func testABatchCancelsTheTransferOfAQueuedUploadInFlight() async throws {
        let putStarted = LockedBox(false)
        let putCancelled = LockedBox(false)
        let transport = RecordingTransport { call in
            if call.method == .put {
                putStarted.value = true
                // Held until cancelled; answers 201 after 3 s if it never is.
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    if Task.isCancelled {
                        putCancelled.value = true
                        throw CancellationError()
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return TransportResponse(status: 201, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
            }
            if call.method == .post, call.path == "/db3/A/blobs/delete" {
                let body = (try? JSONSerialization.jsonObject(with: call.body ?? Data())) as? [String: Any]
                let ids = body?["blobIds"] as? [String] ?? []
                let answer: [String: Any] = ["deleted": ids.count, "blobIds": ids, "db3Id": "A"]
                return TransportResponse(
                    status: 200, headers: ["Content-Type": "application/json"],
                    body: try! JSONSerialization.data(withJSONObject: answer)
                )
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
        let networking = LockedBox(false)
        let completed = LockedBox(false)
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            transport: transport,
            getApiUrl: { "https://api.test" },
            getAppId: { "app1" },
            emit: { event in
                if event is BlobUploadCompletedEvent { completed.value = true }
            },
            currentIdentity: { UploadIdentity(token: "token-u-a", userId: "u-a") },
            networkingAllowed: { networking.value }
        )
        defer { Task { await manager.shutdown() } }
        // Queued offline, then sent by the queue.
        let queued = try await manager.uploadFromSource(documentId: "A", source: Data("for A".utf8), options: BlobUploadSourceOptions(), family: .db3)
        networking.value = true
        let run = Task { await manager.processQueue() }
        let started = Date().addingTimeInterval(5)
        while !putStarted.value, Date() < started { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(putStarted.value, "the queued PUT is in flight")

        let blobs = Db3BlobContext(db3Id: "A", transport: transport, blobManager: manager)
        _ = try await blobs.deleteBatch(blobIds: [queued.blobId])
        let cancelledBy = Date().addingTimeInterval(2)
        while !putCancelled.value, Date() < cancelledBy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(putCancelled.value, "the PUT in flight is cancelled")

        await run.value
        XCTAssertFalse(completed.value, "the cancelled upload completes nothing")
        let queuedForA = await manager.listUploads(documentId: "A", family: .db3)
        XCTAssertEqual(queuedForA.map(\.blobId), [], "and is not queued again")
    }

    // MARK: - CSO-6245-013: a batch that answers while stored uploads are restored

    private static let storedBytes = Data("stored db3 bytes".utf8)

    /// A row another launch left for `db3Id`, due now.
    private static func storedDb3Upload(_ blobId: String, db3Id: String) -> PersistedUploadRecord {
        let now = (Date().timeIntervalSince1970 * 1000).rounded()
        return PersistedUploadRecord(
            queueId: blobId, documentId: db3Id, blobId: blobId, filename: "\(blobId).bin",
            contentType: "application/octet-stream", sha256Base64: BlobManager.sha256Base64(storedBytes),
            disposition: nil, retainLocal: nil, numBytes: storedBytes.count, status: "pending", attempts: 1,
            nextAttemptAt: 0, createdAt: now, updatedAt: now, lastError: "busy", lastErrorCode: nil,
            destination: .db3(db3Id)
        )
    }

    /// Answers the batch for db3 A (running `onBatch` first) and refuses every
    /// PUT 503, so an upload that is sent stays queued and is seen.
    private static func restoringTransport(onBatch: @escaping @Sendable () -> Void = {}) -> RecordingTransport {
        RecordingTransport { call in
            if call.method == .post, call.path == "/db3/A/blobs/delete" {
                onBatch()
                let body = (try? JSONSerialization.jsonObject(with: call.body ?? Data())) as? [String: Any]
                let ids = body?["blobIds"] as? [String] ?? []
                let answer: [String: Any] = ["deleted": ids.count, "blobIds": ids, "db3Id": "A"]
                return TransportResponse(
                    status: 200, headers: ["Content-Type": "application/json"],
                    body: try! JSONSerialization.data(withJSONObject: answer)
                )
            }
            if call.method == .put {
                return TransportResponse(status: 503, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
    }

    private static func sentPut(_ transport: RecordingTransport, _ blobId: String) -> Bool {
        transport.calls.contains { $0.method == .put && $0.path.hasSuffix("/blobs/\(blobId)") }
    }

    /// The batch answers while the requester's stored uploads are still being
    /// read. The named upload of db3 A, restored after the answer, is neither
    /// queued nor sent and its row goes; db3 B's restored upload is queued
    /// and sent as before.
    func testABatchAnsweredDuringTheRequestersRestoreLeavesTheNamedUploadNeitherQueuedNorSent() async throws {
        let path = try BlobUploadPersistence.databasePath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try await UploadRows.seed(path, Self.storedDb3Upload("B-A", db3Id: "A"), bytes: Self.storedBytes, appId: "app1")
        try await UploadRows.seed(path, Self.storedDb3Upload("B-B", db3Id: "B"), bytes: Self.storedBytes, appId: "app1")
        let gated = GatedStorageProvider(
            SQLiteStorageProvider(path: path), gating: OfflineStore.blobUploadsStore(appId: "app1", userId: "u-a")
        )
        let store = OfflineStore()
        await store.setStorageProvider(gated)
        let transport = Self.restoringTransport()
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            transport: transport,
            getApiUrl: { "https://api.test" },
            getAppId: { "app1" },
            currentIdentity: { UploadIdentity(token: "token-u-a", userId: "u-a", epoch: 1) },
            networkingAllowed: { true },
            offlineStore: store
        )
        // The requester's stored uploads are being read, and held there.
        let ready = Task { await manager.storageDidBecomeReady() }
        try await eventually(description: "the restore is reading") { gated.reads.value >= 1 }

        let blobs = Db3BlobContext(db3Id: "A", transport: transport, blobManager: manager)
        let batch = Task { try await blobs.deleteBatch(blobIds: ["B-A"]) }
        try await eventually(description: "the batch was sent") { transport.calls.contains { $0.method == .post } }
        // The answer is in; then the restore finishes.
        try await Task.sleep(nanoseconds: 100_000_000)
        gated.release()
        await ready.value
        let result = try await batch.value
        XCTAssertEqual(result.deleted, 1)

        try await eventually(description: "db3 B's restored upload is sent") { Self.sentPut(transport, "B-B") }
        try await Task.sleep(nanoseconds: 200_000_000)
        let namedQueued = await manager.hasQueuedUpload("B-A")
        XCTAssertFalse(namedQueued, "the named upload restored after the answer is not queued")
        XCTAssertFalse(Self.sentPut(transport, "B-A"), "nor sent")
        let queuedForB = await manager.listUploads(documentId: "B", family: .db3)
        XCTAssertEqual(queuedForB.map(\.blobId), ["B-B"], "db3 B's upload stays queued")

        await manager.shutdown()
        await manager.awaitPendingPersistence()
        await store.closeStorage()
        let rows = try await UploadRows.read(path, appId: "app1", userId: "u-a")
        XCTAssertNil(rows.record("B-A"), "the named upload's row goes")
        XCTAssertNotNil(rows.record("B-B"), "db3 B's row stays")
    }

    /// The batch answers after another user signed in, while the requester's
    /// stored uploads were still being read (so they were not restored). The
    /// named upload's row goes before the batch returns, and the requester's
    /// next sign-in restores only what the batch did not name.
    func testABatchRemovesTheRequestersStoredRowItsRestoreNeverQueued() async throws {
        let path = try BlobUploadPersistence.databasePath()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try await UploadRows.seed(path, Self.storedDb3Upload("B-A", db3Id: "A"), bytes: Self.storedBytes, appId: "app1")
        try await UploadRows.seed(path, Self.storedDb3Upload("B-B", db3Id: "B"), bytes: Self.storedBytes, appId: "app1")
        let gated = GatedStorageProvider(
            SQLiteStorageProvider(path: path), gating: OfflineStore.blobUploadsStore(appId: "app1", userId: "u-a")
        )
        let store = OfflineStore()
        await store.setStorageProvider(gated)
        let identity = LockedBox(UploadIdentity(token: "token-u-a", userId: "u-a", epoch: 1))
        // Another user signs in while the request is out.
        let transport = Self.restoringTransport { identity.value = UploadIdentity(token: "token-u-b", userId: "u-b", epoch: 2) }
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            transport: transport,
            getApiUrl: { "https://api.test" },
            getAppId: { "app1" },
            currentIdentity: { identity.value },
            networkingAllowed: { true },
            offlineStore: store
        )
        let ready = Task { await manager.storageDidBecomeReady() }
        try await eventually(description: "the restore is reading") { gated.reads.value >= 1 }

        let blobs = Db3BlobContext(db3Id: "A", transport: transport, blobManager: manager)
        let batch = Task { try await blobs.deleteBatch(blobIds: ["B-A"]) }
        try await eventually(description: "the batch was sent") { transport.calls.contains { $0.method == .post } }
        try await Task.sleep(nanoseconds: 100_000_000)
        gated.release()
        await ready.value
        _ = try await batch.value
        await manager.awaitPendingPersistence()
        let afterBatch = try await UploadRows.read(path, appId: "app1", userId: "u-a")
        XCTAssertNil(afterBatch.record("B-A"), "the requester's stored row of the named upload is gone")
        XCTAssertNotNil(afterBatch.record("B-B"))

        identity.value = UploadIdentity(token: "token-u-a", userId: "u-a", epoch: 3)
        await manager.syncIdentity()
        try await eventually(description: "the requester's sign-in restores db3 B's upload") {
            await manager.listUploads(documentId: "B", family: .db3).map(\.blobId) == ["B-B"]
        }
        // Time for a restore of the named upload, and its send, to show.
        try await Task.sleep(nanoseconds: 300_000_000)
        let namedQueued = await manager.hasQueuedUpload("B-A")
        XCTAssertFalse(namedQueued, "the named upload is not restored")
        XCTAssertFalse(Self.sentPut(transport, "B-A"), "nor sent")

        await manager.shutdown()
        await manager.awaitPendingPersistence()
        await store.closeStorage()
    }

    // MARK: - #6245 R4a: the single delete matches the batch delete

    /// A transport that answers each single `DELETE` with `status`, after
    /// `during` has looked at the device while the request is out.
    private func singleDeleteTransport(
        status: Int = 200, during: @escaping @Sendable (RecordedRequest) async -> Void = { _ in }
    ) -> RecordingTransport {
        RecordingTransport { call in
            if call.method == .delete {
                await during(call)
                let json = status == 200 ? #"{"deleted":true}"# : #"{"error":"Access denied","code":"DOC_ACCESS_DENIED"}"#
                return TransportResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
            }
            // A document upload's first PUT is sent at once; it fails, so the upload stays queued.
            return TransportResponse(status: 503, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"unavailable"}"#.utf8))
        }
    }

    private func offlineManager(_ transport: RecordingTransport) -> BlobManager {
        BlobManager(
            logger: Logger(level: .error, scope: "test"),
            transport: transport,
            getApiUrl: { "https://api.test" },
            getAppId: { "app1" },
            currentIdentity: { UploadIdentity(token: "token-u-a", userId: "u-a") },
            networkingAllowed: { false }
        )
    }

    /// A single delete from db3 A of an id queued for db3 B or for a document
    /// leaves that upload queued with its bytes; an upload of the id queued
    /// for A is cancelled and A's copy of it goes.
    func testASingleDeleteCancelsOnlyAnUploadQueuedForItsDb3() async throws {
        let transport = singleDeleteTransport()
        let manager = offlineManager(transport)
        defer { Task { await manager.shutdown() } }
        let forA = try await manager.uploadFromSource(documentId: "A", source: Data("for A".utf8), options: BlobUploadSourceOptions(), family: .db3)
        let forB = try await manager.uploadFromSource(documentId: "B", source: Data("for B".utf8), options: BlobUploadSourceOptions(), family: .db3)
        // A document upload's failed first PUT throws and leaves it queued for retry.
        _ = try? await manager.uploadFromSource(documentId: "D", source: Data("for D".utf8), options: BlobUploadSourceOptions(), family: .documents)
        let queuedBefore = await manager.listUploads(documentId: "D", family: .documents)
        XCTAssertEqual(queuedBefore.count, 1, "document D's upload is queued")
        let forD = try XCTUnwrap(queuedBefore.first)

        let blobs = Db3BlobContext(db3Id: "A", transport: transport, blobManager: manager)
        _ = try await blobs.delete(blobId: forB.blobId)
        _ = try await blobs.delete(blobId: forD.blobId)
        let queuedForB = await manager.listUploads(documentId: "B", family: .db3)
        XCTAssertEqual(queuedForB.map(\.blobId), [forB.blobId], "db3 B's upload stays queued")
        let bytesForB = await manager.hasCachedBytes(documentId: "B", blobId: forB.blobId, family: .db3)
        XCTAssertTrue(bytesForB, "with its bytes")
        let queuedForD = await manager.listUploads(documentId: "D", family: .documents)
        XCTAssertEqual(queuedForD.map(\.blobId), [forD.blobId], "document D's upload stays queued")
        let bytesForD = await manager.hasCachedBytes(documentId: "D", blobId: forD.blobId, family: .documents)
        XCTAssertTrue(bytesForD, "with its bytes")

        _ = try await blobs.delete(blobId: forA.blobId)
        XCTAssertEqual(
            transport.calls.filter { $0.method == .delete }.map(\.path),
            ["/db3/A/blobs/\(forB.blobId)", "/db3/A/blobs/\(forD.blobId)", "/db3/A/blobs/\(forA.blobId)"]
        )
        let queuedForA = await manager.listUploads(documentId: "A", family: .db3)
        XCTAssertEqual(queuedForA.map(\.blobId), [], "db3 A's upload is cancelled")
        let bytesForA = await manager.hasCachedBytes(documentId: "A", blobId: forA.blobId, family: .db3)
        XCTAssertFalse(bytesForA, "and its copy goes")
    }

    /// A single delete keeps the queued upload while its request is out and
    /// removes it once the server accepted; a refused delete throws and
    /// leaves the upload queued with its bytes.
    func testASingleDeleteCleansUpOnlyOnceTheServerAccepted() async throws {
        let holder = LockedBox<BlobManager?>(nil)
        let queuedDuring = LockedBox<Bool?>(nil)
        let transport = singleDeleteTransport(during: { call in
            guard let manager = holder.value, let blobId = call.path.split(separator: "/").last else { return }
            queuedDuring.value = await manager.hasQueuedUpload(String(blobId))
        })
        let manager = offlineManager(transport)
        holder.value = manager
        defer { Task { await manager.shutdown() } }
        let forA = try await manager.uploadFromSource(documentId: "A", source: Data("for A".utf8), options: BlobUploadSourceOptions(), family: .db3)

        _ = try await Db3BlobContext(db3Id: "A", transport: transport, blobManager: manager).delete(blobId: forA.blobId)
        XCTAssertEqual(queuedDuring.value, true, "queued while the request is out")
        let queuedAfter = await manager.hasQueuedUpload(forA.blobId)
        XCTAssertFalse(queuedAfter, "cancelled once the server accepted")

        let refusing = singleDeleteTransport(status: 403)
        let refusedManager = offlineManager(refusing)
        defer { Task { await refusedManager.shutdown() } }
        let kept = try await refusedManager.uploadFromSource(documentId: "A", source: Data("kept".utf8), options: BlobUploadSourceOptions(), family: .db3)
        do {
            _ = try await Db3BlobContext(db3Id: "A", transport: refusing, blobManager: refusedManager).delete(blobId: kept.blobId)
            XCTFail("a refused delete throws")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
        let keptQueued = await refusedManager.listUploads(documentId: "A", family: .db3)
        XCTAssertEqual(keptQueued.map(\.blobId), [kept.blobId], "a refused delete leaves the upload queued")
        let keptBytes = await refusedManager.hasCachedBytes(documentId: "A", blobId: kept.blobId, family: .db3)
        XCTAssertTrue(keptBytes, "with its bytes")
    }

    /// A document blob's answer decodes with no `createdBy` or `etag`, `status`
    /// as the route sends it, and every other field as before.
    func testADocumentBlobAnswerDecodesWithNoUploaderOrEtag() throws {
        let documentAnswer = #"{"blobId":"B1","filename":"a.txt","contentType":"text/plain","numBytes":3,"status":"uploaded","createdAt":"2026-11-18T00:00:00.000Z"}"#
        let info = try JSONDecoder().decode(BlobInfo.self, from: Data(documentAnswer.utf8))
        XCTAssertNil(info.createdBy)
        XCTAssertNil(info.etag)
        XCTAssertEqual(info.status, "uploaded")
        XCTAssertEqual(info.blobId, "B1")
        XCTAssertEqual(info.filename, "a.txt")
        XCTAssertEqual(info.contentType, "text/plain")
        XCTAssertEqual(info.numBytes, 3)
        XCTAssertEqual(info.createdAt, "2026-11-18T00:00:00.000Z")
        XCTAssertNil(info.sha256)

        let db3Answer = #"{"blobId":"B2","filename":"b.txt","contentType":"text/plain","numBytes":1,"sha256":"c2hh","createdBy":null,"createdAt":"2026-11-18T00:00:00.000Z","etag":"\"tag\"","status":"uploaded"}"#
        let db3Info = try JSONDecoder().decode(BlobInfo.self, from: Data(db3Answer.utf8))
        XCTAssertNil(db3Info.createdBy, "an app upload's uploader is null")
        XCTAssertEqual(db3Info.etag, "\"tag\"")
    }
}
