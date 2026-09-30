import XCTest
@testable import JsBaoClient
import YSwift

/// A fresh Swift client streams in a real large document's base snapshot
/// (#3436, behaviors 27, 28, 29 and 31; criterion 12's resume half).
///
/// The hermetic loader suite drives every rule of the format over bytes the
/// real encoder wrote. What it cannot say is whether a REAL room offers a
/// grant a Swift client can read, whether the manifest a real builder writes
/// is one this client accepts, and whether a client that has never seen the
/// document ends up holding all of it. Those need a real Durable Object, a
/// real R2 object per chunk and a real signed download path.
///
/// Builds are driven by polling `snapshot-state` under a bound, never by a
/// tick count: a build crosses alarms by design and the room's own alarm runs
/// ticks between the ones a suite forces, so a tick count is a statement about
/// one server's speed rather than about the behavior (#3432's lesson).
final class Format2ColdLoadLiveTests: XCTestCase {

    /// Events collected off an emitter that delivers on another thread.
    private final class LoadEventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DocumentSnapshotLoadEvent] = []
        func append(_ event: DocumentSnapshotLoadEvent) {
            lock.withLock { events.append(event) }
        }
        var all: [DocumentSnapshotLoadEvent] { lock.withLock { events } }
    }

    private var ctx: TestContext!
    private var testApp: TestApp!
    private var directory: String!
    private var clients: [JsBaoClient] = []
    private var documentId: String!

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
            "views": FieldDescriptor(type: .number, indexed: true),
        ]
    )

    /// A SECOND model, because a chunk never spans one: a base of one model is
    /// one chunk however many rows it holds at this size, and a one-chunk base
    /// cannot say anything about resuming (behavior 28) or about a load
    /// reporting per-model readiness.
    private static let otherSchema = PrimitiveSchema(
        name: "Task",
        fields: [
            "id": FieldDescriptor(type: .id),
            "label": FieldDescriptor(type: .string, required: true),
        ]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-f2-cold")
        directory = NSTemporaryDirectory() + "f2-cold-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        try? FileManager.default.removeItem(atPath: directory)
        await ctx?.cleanup()
    }

    // MARK: - Driving a real room

    /// One of the dev server's local-only document test routes.
    @discardableResult
    private func testRoute(
        _ action: String, body: [String: Any] = [:]
    ) async throws -> [String: Any] {
        var request = URLRequest(
            url: URL(string:
                "\(TestConfig.httpUrl)/__test__/document/\(testApp.appId)/\(documentId!)/\(action)"
            )!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TestConfig.testAdminToken, forHTTPHeaderField: "X-Test-Auth")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw JsBaoError(
                code: .unavailable,
                message: "\(action) answered \(status): "
                    + (String(data: data, encoding: .utf8) ?? "")
            )
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Seal the open epoch and drive the builder until a base is registered.
    ///
    /// Bounded by TIME. The alarm the suite forces is not the only one that
    /// runs — the room arms its own — so "five ticks" would be a guess about
    /// this machine rather than a statement about the builder.
    @discardableResult
    private func buildABase(after previous: String? = nil) async throws -> [String: Any] {
        _ = try await testRoute("seal-epoch", body: ["reason": "cold-load-test"])
        let deadline = Date().addingTimeInterval(120)
        var seen = "none"
        repeat {
            _ = try await testRoute("run-alarm", body: ["ticks": 5])
            let state = try await testRoute("snapshot-state")
            seen = String(describing: state["builds"] ?? "none")
            if let latest = state["latestComplete"] as? [String: Any],
               let buildId = latest["buildId"] as? String,
               buildId != previous {
                return latest
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        throw JsBaoError(
            code: .unavailable,
            message: "no base completed within 120s; builds: \(seen)"
        )
    }

    /// `PL_F2_DEBUG=1` turns the client's own `[format2]` lines on. A live
    /// failure in this suite is usually a frame the room refused, and the
    /// frame log is the only place that says so.
    private var debugLogging = ProcessInfo.processInfo.environment["PL_F2_DEBUG"] == "1"

    private func makeClient(
        databasePath: String, autoNetwork: Bool = true
    ) async -> JsBaoClient {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            storageConfig: .sqlite(directory: databasePath),
            autoNetwork: autoNetwork,
            logLevel: debugLogging ? .debug : .warn
        )
        client.registerModels([Self.schema, Self.otherSchema])
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    /// Create a large document, seed it, and get a base built for it.
    ///
    /// - Returns: the seeded record ids, and the build the room registered.
    private func seedAndBuild(records: Int) async throws -> (
        ids: [String], build: [String: Any]
    ) {
        let author = await makeClient(databasePath: directory + "/author.sqlite")
        try await author.connect()
        try await waitForConnection(client: author)

        let created = try await author.createDocument(options: CreateDocumentOptions(
            title: "swift cold load", documentFormat: 2
        ))
        documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try await eventually(timeout: 20, description: "the create to commit") {
            author.documentManager.getLocalMetadata(self.documentId)?.pendingCreate != true
        }
        _ = try await author.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .localIfAvailableElseNetwork, enableNetworkSync: true
        ))
        try await eventually(timeout: 20, description: "the handshake to release the hold") {
            author.format2?.hold.isHeld(self.documentId) == false
        }

        // Written back to back, deliberately. A burst is what an app seeding a
        // document does, and it is the shape that makes the room refuse a
        // frame and ask for a resync (finding 3436-B01): the recovery is part
        // of what this suite is here to prove.
        let model = try XCTUnwrap(author.sharedModel("Note")?.member(docId: documentId))
        var ids: [String] = []
        for index in 0..<records {
            let id = String(format: "note-%04d", index)
            _ = try model.create(id: id, values: [
                "title": .string("seeded \(index)"), "views": .number(Double(index)),
            ])
            ids.append(id)
        }
        let tasks = try XCTUnwrap(author.sharedModel("Task")?.member(docId: documentId))
        for index in 0..<2 {
            _ = try tasks.create(
                id: String(format: "task-%04d", index),
                values: ["label": .string("task \(index)")]
            )
        }

        let binding = try XCTUnwrap(author.format2?.binding(documentId))
        try await eventually(
            timeout: 60, description: "the room to acknowledge the seed"
        ) {
            try binding.store.pendingOps().isEmpty
        }
        // A seed that was never acknowledged makes every assertion below
        // vacuous, so it says what was still owed rather than failing later as
        // "no base completed".
        let owed = try binding.store.pendingOps().count
        let acked = try binding.store.ackedSeq()
        let highest = try binding.store.highestLocalSeq()
        XCTAssertEqual(
            owed, 0,
            "the seed was not acknowledged: acked \(acked) of \(highest)"
        )

        let build = try await buildABase()
        await author.destroy()
        clients.removeAll { $0 === author }
        return (ids, build)
    }

    // MARK: - Behavior 27 — the cold load

    func testAFreshClientStreamsInTheWholeBaseAndEndsWithEveryRecord() async throws {
        let seeded = try await seedAndBuild(records: 12)
        XCTAssertEqual(seeded.build["state"] as? String, "complete")

        let events = LoadEventLog()
        let cold = await makeClient(databasePath: directory + "/cold.sqlite")
        let subscription = cold.eventEmitter.subscribe(DocumentSnapshotLoadEvent.self) {
            events.append($0)
        }
        defer { subscription.cancel() }
        try await cold.connect()
        try await waitForConnection(client: cold)
        _ = try await cold.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .network, enableNetworkSync: true
        ))

        let binding = try XCTUnwrap(cold.format2?.binding(documentId))
        try await eventually(timeout: 120, description: "the cold load to finish") {
            (try? binding.store.baseState())??.complete == true
        }

        // Every record the author seeded is in this client's own merged view,
        // out of the base rather than out of a replayed history.
        XCTAssertEqual(try binding.store.recordIds(model: "Note"), seeded.ids)
        let state = try XCTUnwrap(try binding.store.baseState())
        XCTAssertTrue(state.complete, "_snapshot_base.complete")
        XCTAssertEqual(
            state.buildId, seeded.build["buildId"] as? String,
            "it loaded the base the room registered"
        )
        XCTAssertGreaterThan(try binding.store.epoch(), 0, "the epoch mark moved")
        XCTAssertFalse(binding.reloadRequired)
        XCTAssertFalse(cold.format2?.hold.isHeld(documentId) ?? true, "the hold released")

        // Every chunk the manifest named is marked, which is what a resume
        // reads and what makes the load complete rather than merely finished.
        let loaded = try XCTUnwrap(events.all.last(where: { $0.phase == .loaded }))
        XCTAssertEqual(loaded.chunks, loaded.totalChunks, "chunks == totalChunks")
        XCTAssertEqual(loaded.rows, loaded.totalRows)
        XCTAssertEqual(loaded.mode, "load")
        XCTAssertEqual(
            try binding.store.completedChunks(buildId: state.buildId).count,
            loaded.totalChunks
        )
        XCTAssertTrue(events.all.contains { $0.phase == .started })
        XCTAssertTrue(events.all.contains { $0.phase == .model && $0.model == "Note" })

        // And the facade answers from it, which is what the app does.
        let model = try XCTUnwrap(cold.sharedModel("Note")?.member(docId: documentId))
        XCTAssertEqual(model.find(id: seeded.ids[0])?["title"], .string("seeded 0"))
        XCTAssertEqual(try model.count(["views": .number(3)]), 1)
    }

    // MARK: - Behavior 28 — resume

    /// A load interrupted part-way leaves every committed chunk marked, and
    /// the next attempt fetches only what is missing. On a real base that is
    /// the difference between a load that finishes and one that starts over on
    /// every dropped connection.
    func testALoadInterruptedPartWayResumesWithoutRefetchingACommittedChunk() async throws {
        let seeded = try await seedAndBuild(records: 12)
        let buildId = try XCTUnwrap(seeded.build["buildId"] as? String)

        // A client opened on this document for its grant: the artifacts are
        // read through the signed path the room minted for it, which is the
        // only way a client may reach them.
        let cold = await makeClient(databasePath: directory + "/resume.sqlite")
        try await cold.connect()
        try await waitForConnection(client: cold)
        _ = try await cold.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .network, enableNetworkSync: true
        ))
        let binding = try XCTUnwrap(cold.format2?.binding(documentId))
        try await eventually(timeout: 120, description: "the cold load to finish") {
            (try? binding.store.baseState())??.complete == true
        }

        let manifest = try await readManifest(for: cold, documentId: documentId)
        XCTAssertGreaterThan(
            manifest.chunks.count, 1,
            "a one-chunk base cannot say anything about resuming — seed a second model"
        )

        // The interrupted load runs over a store of this test's own, so the
        // drop is deterministic rather than whatever the network does. The
        // STORE is a real `SQLiteStorageProvider` and the bytes are the real
        // base's.
        let provider = SQLiteStorageProvider(path: directory + "/interrupted.sqlite")
        try await provider.initialize(namespace: "test")
        let store = Format2RecordStore(
            host: provider, documentId: documentId, clientId: "resume-client"
        )
        try store.initialize()

        struct Dropped: Error {}
        var fetched = 0
        XCTAssertThrowsError(
            try Format2SnapshotLoader.load(
                store: store, manifest: manifest,
                fetchChunk: { chunk in
                    guard fetched == 0 else { throw Dropped() }
                    fetched += 1
                    return try self.readChunk(for: cold, chunk: chunk)
                }
            ),
            "the interrupted load must not report success"
        )
        let marked = try store.completedChunks(buildId: buildId)
        XCTAssertEqual(marked.count, 1, "the chunk that landed is marked, and only it")
        XCTAssertFalse(
            try XCTUnwrap(store.baseState()).complete,
            "an interrupted load must read as incomplete"
        )

        var refetched: [Int] = []
        let resumed = try Format2SnapshotLoader.load(
            store: store, manifest: manifest,
            fetchChunk: { chunk in
                refetched.append(chunk.ordinal ?? -1)
                return try self.readChunk(for: cold, chunk: chunk)
            }
        )
        XCTAssertFalse(
            refetched.contains(marked[0]),
            "a committed chunk was fetched again on the resume"
        )
        XCTAssertEqual(refetched.count, manifest.chunks.count - 1)
        XCTAssertEqual(resumed.resumed, 1)
        XCTAssertEqual(resumed.chunks, manifest.chunks.count)
        XCTAssertTrue(try XCTUnwrap(store.baseState()).complete)
        // And the resumed view is the whole document, not the part that was
        // fetched the second time.
        XCTAssertEqual(try store.recordIds(model: "Note"), seeded.ids)
        XCTAssertEqual(try store.recordIds(model: "Task"), ["task-0000", "task-0001"])
    }

    // MARK: - Behavior 29 — a real manifest, read by this client

    /// The manifest a REAL builder writes is one this client accepts, and its
    /// chunks are addressed by the path form the download route resolves.
    ///
    /// The sourced (`{epoch}-{buildId}/…`) form only appears once a build
    /// carries a chunk forward from an earlier one, which needs a document far
    /// larger than a live suite may seed; the hermetic loader suite covers
    /// that half over bytes the real encoder wrote, as the plan allows. What
    /// is live here is that the version a real builder stamps is one this
    /// client reads, and that every path it wrote parses.
    func testARealManifestIsReadAndEveryChunkPathIsAddressable() async throws {
        let seeded = try await seedAndBuild(records: 8)
        let cold = await makeClient(databasePath: directory + "/manifest.sqlite")
        try await cold.connect()
        try await waitForConnection(client: cold)
        _ = try await cold.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .network, enableNetworkSync: true
        ))
        let binding = try XCTUnwrap(cold.format2?.binding(documentId))
        try await eventually(timeout: 120, description: "the cold load to finish") {
            (try? binding.store.baseState())??.complete == true
        }

        let manifest = try await readManifest(for: cold, documentId: documentId)
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertGreaterThanOrEqual(manifest.version, SnapshotManifest.minimumVersion)
        XCTAssertLessThanOrEqual(manifest.version, SnapshotManifest.currentVersion)
        XCTAssertEqual(manifest.buildId, seeded.build["buildId"] as? String)
        // Every record the seed wrote, across both models.
        XCTAssertEqual(manifest.totalRows, seeded.ids.count + 2)
        XCTAssertEqual(Set(manifest.chunks.map(\.model)), ["Note", "Task"])
        for chunk in manifest.chunks {
            let path = try snapshotChunkPath(chunk)
            XCTAssertNotNil(
                parseSnapshotChunkPath(path),
                "the builder wrote a chunk path this client cannot address: \(path)"
            )
        }
    }

    // MARK: - Behavior 31 — the old-client refusal, with a positive control

    /// A client that does not declare format 2 is closed with 4426, and the
    /// Swift client's OWN open of the same document succeeds. Without the
    /// positive control the negative proves nothing: a document that does not
    /// exist would also refuse.
    func testAClientThatDoesNotDeclareFormatTwoIsRefusedWhileThisClientOpens() async throws {
        _ = try await seedAndBuild(records: 2)

        let refusal = try await openRawSocket(declaringFormats: false)
        XCTAssertEqual(
            refusal.closeCode, Format2Transport.upgradeRequiredCloseCode,
            "the room did not refuse a client that reads only format 1"
        )
        XCTAssertEqual(refusal.errorCode, "CLIENT_UPGRADE_REQUIRED")

        // The positive control: the same document, this client, no refusal.
        let ours = await makeClient(databasePath: directory + "/control.sqlite")
        try await ours.connect()
        try await waitForConnection(client: ours)
        _ = try await ours.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .network, enableNetworkSync: true
        ))
        let binding = try XCTUnwrap(ours.format2?.binding(documentId))
        try await eventually(timeout: 120, description: "this client's own open") {
            (try? binding.store.baseState())??.complete == true
        }
        XCTAssertFalse(binding.reloadRequired)
    }

    // MARK: - Reading a base through the client's own grant

    private func snapshotSource(
        for client: JsBaoClient, documentId: String
    ) throws -> Format2SnapshotSource {
        let snapshot = try XCTUnwrap(
            client.format2?.snapshotInfo(documentId),
            "the handshake offered no snapshot for this document"
        )
        let path = try XCTUnwrap(snapshot.downloadPath)
        return Format2SnapshotSource(
            apiUrl: TestConfig.httpUrl,
            documentId: documentId,
            grantPath: path,
            read: Format2SnapshotSource.urlSessionReader()
        )
    }

    private func readManifest(
        for client: JsBaoClient, documentId: String
    ) async throws -> SnapshotManifest {
        try snapshotSource(for: client, documentId: documentId).manifest()
    }

    private func readChunk(
        for client: JsBaoClient, chunk: SnapshotChunkEntry
    ) throws -> Data {
        try snapshotSource(for: client, documentId: documentId).fetchChunk(chunk)
    }

    // MARK: - A raw socket that declares what it likes

    private struct RawHandshake {
        let closeCode: Int?
        let errorCode: String?
    }

    /// Open a socket to the room by hand and answer the handshake the way an
    /// OLDER client build would: `syncStep1` with no `formats`.
    private func openRawSocket(declaringFormats: Bool) async throws -> RawHandshake {
        // The same socket the client opens: one per app, not one per document
        // (`JsBaoClient.webSocketManagerURL`).
        var components = URLComponents(
            string: "\(TestConfig.wsUrl)/app/\(testApp.appId)/ws"
        )!
        components.queryItems = [
            URLQueryItem(name: "connectionId", value: UUID().uuidString),
            URLQueryItem(name: "token", value: testApp.ownerJWT),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(
            TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id"
        )
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel() }

        var frame: [String: Any] = [
            "type": "syncStep1",
            "documentId": documentId!,
            "stateVector": [Int](),
        ]
        if declaringFormats {
            frame["formats"] = Format2Transport.formats
            frame["manifestVersion"] = Format2Transport.manifestVersion
        }
        try await task.send(.string(String(
            data: try JSONSerialization.data(withJSONObject: frame), encoding: .utf8
        )!))

        var errorCode: String?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            do {
                let message = try await task.receive()
                guard case .string(let text) = message,
                      let json = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                        as? [String: Any]
                else { continue }
                if json["type"] as? String == "error" {
                    errorCode = (json["detail"] as? [String: Any])?["code"] as? String
                        ?? json["code"] as? String
                }
            } catch {
                // The receive fails when the room closes the socket, which is
                // the refusal this case is about.
                return RawHandshake(
                    closeCode: task.closeCode.rawValue == 0
                        ? nil : task.closeCode.rawValue,
                    errorCode: errorCode
                )
            }
        }
        return RawHandshake(closeCode: nil, errorCode: errorCode)
    }
}
