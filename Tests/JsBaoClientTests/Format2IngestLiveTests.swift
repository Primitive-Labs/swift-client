import XCTest
@testable import JsBaoClient
import YSwift

/// A client that was CONNECTED through a bulk load, against a real room
/// (#3437, behavior 35; success criterion S7).
///
/// An operator replaces ranges of a document's rows wholesale. The room seals
/// the open epoch with `baseDiscontinuity`, which says the sum of the overlays
/// on either side of it is not the document — so a client that was writing
/// through it cannot carry its owed writes across, and cannot judge them by
/// recency either: the ingest's changes are in no overlay the conflict ledger
/// holds. What decides is PRESENCE, and presence is only a fact once the base
/// the ingest produced has landed.
///
/// The ingest is driven through the app API's own multipart routes (#3434),
/// which is the door a Swift test can reach: the CLI verb is the other, and
/// Swift ingest verbs are deferred under principle 11. The chunk bodies are
/// built by the node harness, in the `id<TAB>patch` shape the routes take —
/// and the server hashes and re-validates every field of them, so a wrong
/// fixture fails there rather than passing quietly.
final class Format2IngestLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var testApp: TestApp!
    private var directory: String!
    private var documentId: String!
    private var clients: [JsBaoClient] = []

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
            "body": FieldDescriptor(type: .string),
        ]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-f2-ingest")
        directory = NSTemporaryDirectory() + "f2-ingest-live-\(UUID().uuidString.prefix(8))"
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

    // MARK: - The app API

    private func appRequest(
        _ method: String, _ path: String, body: [String: Any]? = nil
    ) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: URL(string:
            "\(TestConfig.httpUrl)/app/\(testApp.appId)/api/\(path)"
        )!)
        request.httpMethod = method
        request.setValue("Bearer \(testApp.ownerJWT)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// Upload one chunk as the `multipart/form-data` body the route takes.
    ///
    /// Built by hand: `URLSession` has no multipart encoder, and the part
    /// order and the trailing boundary are exactly what the worker's own
    /// `FormData` parser reads.
    private func uploadChunk(
        sessionId: String, descriptor: [String: Any], body: Data
    ) async throws -> (status: Int, json: [String: Any]) {
        let boundary = "swift-ingest-\(UUID().uuidString)"
        var payload = Data()
        func append(_ text: String) { payload.append(text.data(using: .utf8)!) }
        for key in [
            "model", "index", "rows", "bytes", "rawBytes", "sha256",
            "firstId", "lastId",
        ] {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(descriptor[key] ?? "")\r\n")
        }
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"chunk\"; "
            + "filename=\"chunk.ndjson.gz\"\r\n"
        )
        append("Content-Type: application/gzip\r\n\r\n")
        payload.append(body)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string:
            "\(TestConfig.httpUrl)/app/\(testApp.appId)/api"
            + "/documents/\(documentId!)/ingest/\(sessionId)/chunks"
        )!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(testApp.ownerJWT)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = payload
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// One chunk's bytes and descriptor, from the node harness.
    private func encodeChunk(
        model: String, index: Int, lines: [(id: String, patch: [String: Any])]
    ) throws -> (descriptor: [String: Any], body: Data) {
        let response = try Format2Harness.run([
            "command": "encode-ingest-chunk",
            "model": model,
            "index": index,
            "lines": lines.map { ["id": $0.id, "patch": $0.patch] },
        ])
        let descriptor = try XCTUnwrap(response["descriptor"] as? [String: Any])
        let body = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(response["body"] as? String))
        )
        return (descriptor, body)
    }

    /// Run a whole bulk load and wait for it to land.
    private func ingest(
        _ chunks: [(model: String, lines: [(id: String, patch: [String: Any])])]
    ) async throws {
        let opened = try await appRequest("POST", "documents/\(documentId!)/ingest")
        XCTAssertEqual(opened.status, 201, "opening a session: \(opened.json)")
        let sessionId = try XCTUnwrap(opened.json["sessionId"] as? String
            ?? (opened.json["session"] as? [String: Any])?["sessionId"] as? String)

        for (index, chunk) in chunks.enumerated() {
            let encoded = try encodeChunk(
                model: chunk.model, index: index, lines: chunk.lines
            )
            let uploaded = try await uploadChunk(
                sessionId: sessionId, descriptor: encoded.descriptor, body: encoded.body
            )
            XCTAssertEqual(uploaded.status, 200, "uploading a chunk: \(uploaded.json)")
        }

        let committed = try await appRequest(
            "POST", "documents/\(documentId!)/ingest/\(sessionId)/commit"
        )
        XCTAssertEqual(committed.status, 200, "committing: \(committed.json)")

        // Driven by the room's OWN alarm and polled: the pipeline crosses
        // several ticks and a tick count would be a guess about this machine.
        try await eventually(timeout: 180, description: "the bulk load to land") {
            let state = try await self.appRequest(
                "GET", "documents/\(self.documentId!)/ingest/\(sessionId)"
            )
            let session = (state.json["session"] as? [String: Any]) ?? state.json
            let phase = session["state"] as? String
            if phase == "failed" {
                XCTFail("the bulk load failed: \(session)")
                return true
            }
            return phase == "complete"
        }
    }

    // MARK: - Driving the room and reading it

    @discardableResult
    private func testRoute(
        _ action: String, body: [String: Any] = [:]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string:
            "\(TestConfig.httpUrl)/__test__/document/\(testApp.appId)/\(documentId!)/\(action)"
        )!)
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

    private func serverRecords() async throws -> [String: [String: Any]] {
        let answer = try await appRequest(
            "GET", "documents/\(documentId!)/records/Note?limit=200"
        )
        let items = (answer.json["items"] as? [[String: Any]]) ?? []
        var out: [String: [String: Any]] = [:]
        for item in items {
            guard let id = item["id"] as? String ?? item["_id"] as? String else { continue }
            out[id] = item
        }
        return out
    }

    private var debugLogging = ProcessInfo.processInfo.environment["PL_F2_DEBUG"] == "1"

    private func makeClient(databasePath: String) async -> JsBaoClient {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            storageConfig: .sqlite(directory: databasePath),
            autoNetwork: true,
            logLevel: debugLogging ? .debug : .warn
        )
        client.registerModels([Self.schema])
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    private func createAndOpen(_ client: JsBaoClient) async throws -> Format2DocumentBinding {
        try await client.connect()
        try await waitForConnection(client: client, timeout: 30)
        let created = try await client.createDocument(options: CreateDocumentOptions(
            title: "swift ingest", documentFormat: 2
        ))
        documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try await eventually(timeout: 20, description: "the create to commit") {
            client.documentManager.getLocalMetadata(self.documentId)?.pendingCreate != true
        }
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .localIfAvailableElseNetwork, enableNetworkSync: true
        ))
        try await eventually(timeout: 30, description: "the handshake to release the hold") {
            client.format2?.hold.isHeld(self.documentId) == false
        }
        return try XCTUnwrap(client.format2?.binding(documentId))
    }

    private func model(_ client: JsBaoClient) throws -> DynamicModel {
        try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId))
    }

    // MARK: - Step 0d — is the vehicle real?

    /// The smoke the plan asks for before any behavior work rests on it: a
    /// bulk load driven from a Swift test, end to end, on a real room.
    func testABulkLoadCanBeDrivenFromSwift() async throws {
        let client = await makeClient(databasePath: directory + "/smoke.sqlite")
        let binding = try await createAndOpen(client)
        let note = try model(client)
        _ = try note.create(id: "r1", values: ["title": .string("before the ingest")])
        try await eventually(timeout: 20, description: "the seed to be acknowledged") {
            try binding.store.pendingOps().isEmpty
        }

        try await ingest([(
            model: "Note",
            lines: [(id: "r1", patch: ["title": "from the ingest"])]
        )])

        let server = try await serverRecords()
        XCTAssertEqual(
            server["r1"]?["title"] as? String, "from the ingest",
            "the bulk load really did replace the row: \(server)"
        )
    }

    // MARK: - Behavior 35 / S7 — a client that wrote through a bulk load

    func testAClientWritingThroughABulkLoadDefersJudgesByPresenceAndConverges()
        async throws
    {
        let client = await makeClient(databasePath: directory + "/through.sqlite")
        let binding = try await createAndOpen(client)
        let note = try model(client)

        // Three records the ingest will treat differently, all acknowledged
        // before anything happens to them.
        _ = try note.create(id: "kept", values: ["title": .string("seed")])
        _ = try note.create(id: "removed", values: ["title": .string("seed")])
        try await eventually(timeout: 20, description: "the seeds to be acknowledged") {
            try binding.store.pendingOps().isEmpty
        }

        // Offline, this client writes: onto a record the ingest keeps, onto one
        // it removes, and a create at an id the server has never held.
        await client.disconnect()
        try note.update(id: "kept", values: ["title": .string("my patch")])
        try note.update(id: "removed", values: ["title": .string("patch on a doomed row")])
        _ = try note.create(id: "brand-new", values: ["title": .string("offline create")])
        let owed = try binding.store.pendingOps().map(\.seq)
        XCTAssertEqual(owed.count, 3)

        // ---- The bulk load, while this client is away.
        try await ingest([(
            model: "Note",
            lines: [
                (id: "kept", patch: ["title": "from the ingest"]),
                (id: "removed", patch: ["_deleted": true]),
            ]
        )])

        // ---- The return. It converges on the ingest's base and judges what it
        // owes by PRESENCE.
        let notices = LockedBox<[DocumentOfflineWritesResolvedEvent]>([])
        let subscription = client.eventEmitter.subscribe(
            DocumentOfflineWritesResolvedEvent.self
        ) { event in notices.withValue { $0.append(event) } }
        await client.setShouldConnect(true)
        try await waitForConnection(client: client, timeout: 30)

        try await eventually(timeout: 180, description: "the owed writes to be judged") {
            notices.value.isEmpty == false
        }
        let event = try XCTUnwrap(notices.value.first)
        let byRecord = Dictionary(grouping: event.notices, by: { $0.recordId })
        XCTAssertEqual(
            byRecord["removed"]?.first?.outcome, .dropped,
            "a write onto a record the ingest removed is dropped: \(event.notices)"
        )
        XCTAssertEqual(byRecord["removed"]?.first?.reason, .bulkIngest)
        XCTAssertEqual(
            byRecord["kept"]?.first?.outcome, .keptAmbiguous,
            "one onto a record it kept is applied and surfaced: \(event.notices)"
        )
        XCTAssertEqual(
            byRecord["brand-new"]?.first?.outcome, .keptAmbiguous,
            "and an offline create at an id the server never held is kept — it "
                + "is absent because nobody wrote it, not because the ingest "
                + "took it: \(event.notices)"
        )

        try await eventually(timeout: 60, description: "the survivors to be acknowledged") {
            try binding.store.pendingOps().isEmpty
        }
        XCTAssertEqual(
            try binding.store.discontinuityEpochs(), [],
            "the document converged: the boundary is settled"
        )
        XCTAssertNil(try binding.store.deferredReplay())

        // The merged view is the server's records, through both doors.
        let server = try await serverRecords()
        XCTAssertNil(server["removed"], "server: \(Set(server.keys))")
        XCTAssertNil(
            note.find(id: "removed"),
            "and the client agrees rather than putting it back"
        )
        for id in server.keys {
            XCTAssertNotNil(note.find(id: id), "the view is short of `\(id)`")
        }
        XCTAssertEqual(try note.count(), server.count, "and `query` agrees with `find`")
        subscription.cancel()
    }
}
