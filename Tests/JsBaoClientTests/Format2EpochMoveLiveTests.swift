import XCTest
@testable import JsBaoClient
import YSwift

/// Following a real room's seal, and getting an adopted write acknowledged
/// (#3437, behaviors 7 and 11; success criteria S1 and S4).
///
/// Every other case for these behaviors is hermetic: frames driven by hand
/// into the coordinator, a real SQLite, a real Yjs document. None of them can
/// say whether the ROOM accepts what the move puts on the wire — and that is
/// the whole question. The move sends the fresh overlay as self-contained
/// state claiming the sequences it carries, and if the room disagrees about
/// the span, or refuses the frame, or acknowledges a sequence whose content
/// never arrived, the write is gone with nothing left to say so.
///
/// Builds and rotations are driven through the dev server's local-only
/// document test routes, and waited on by POLLING rather than by a tick count:
/// the room arms its own alarm, so "five ticks" would be a guess about this
/// machine rather than a statement about the behavior (#3432's lesson).
final class Format2EpochMoveLiveTests: XCTestCase {

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
            "views": FieldDescriptor(type: .number, indexed: true),
        ]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-f2-move")
        directory = NSTemporaryDirectory() + "f2-move-live-\(UUID().uuidString.prefix(8))"
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

    /// `PL_F2_DEBUG=1` turns the client's own `[format2]` lines on. A live
    /// failure here is usually a frame the room refused, and the frame log is
    /// the only place that says so.
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
        client.registerModels([Self.schema])
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    /// Create a large document and open it on `client`, joined.
    private func createAndOpen(_ client: JsBaoClient) async throws -> Format2DocumentBinding {
        try await client.connect()
        try await waitForConnection(client: client)
        let created = try await client.createDocument(options: CreateDocumentOptions(
            title: "swift epoch move", documentFormat: 2
        ))
        documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try await eventually(timeout: 20, description: "the create to commit") {
            client.documentManager.getLocalMetadata(self.documentId)?.pendingCreate != true
        }
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .localIfAvailableElseNetwork, enableNetworkSync: true
        ))
        try await eventually(timeout: 20, description: "the handshake to release the hold") {
            client.format2?.hold.isHeld(self.documentId) == false
        }
        return try XCTUnwrap(client.format2?.binding(documentId))
    }

    /// Reopen a large document on a client that already has its row, joined.
    private func reopen(_ client: JsBaoClient) async throws -> Format2DocumentBinding {
        try await client.connect()
        try await waitForConnection(client: client)
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .localIfAvailableElseNetwork, enableNetworkSync: true
        ))
        return try XCTUnwrap(client.format2?.binding(documentId))
    }

    private func model(_ client: JsBaoClient) throws -> DynamicModel {
        try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId))
    }

    /// Everything that decides whether this document can still speak to the
    /// room, in one line.
    ///
    /// A live wait that times out here says only "not acknowledged", and the
    /// states that produce that are all silent: a hold nobody released, a
    /// document still marked behind the room, a refusal raised after the last
    /// assertion read it. Each of them is a different defect, and a failure
    /// that does not name which cost a grind to diagnose (#3437).
    private func state(of client: JsBaoClient) -> String {
        guard let coordinator = client.format2,
              let binding = coordinator.binding(documentId)
        else { return "no format-2 binding" }
        let epoch = (try? binding.store.epoch()).map(String.init) ?? "?"
        let acked = (try? binding.store.ackedSeq()).map(String.init) ?? "?"
        let highest = (try? binding.store.highestLocalSeq()).map(String.init) ?? "?"
        let pending = (try? binding.store.pendingOps().map(\.seq)) ?? []
        return [
            "connected: \(client.isConnected)",
            "epoch: \(epoch)",
            "hold: \(coordinator.hold.reason(documentId!) ?? "none")",
            "acceptsInbound: \(coordinator.acceptsInbound(documentId))",
            "droppedInbound: \(coordinator.droppedInboundFrameCount(documentId))",
            "reloadRequired: \(binding.reloadRequired)",
            "refusal: \(binding.reloadRefusal?.code.rawValue ?? "none")",
            "acked: \(acked)", "highest: \(highest)", "pending: \(pending)",
        ].joined(separator: ", ")
    }

    /// ``eventually(timeout:interval:description:check:)`` with that line in
    /// the failure message.
    private func eventuallyOn(
        _ client: JsBaoClient,
        timeout: TimeInterval,
        _ description: String,
        check: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timeout waiting for \(description) — \(state(of: client))")
    }

    /// The record ids the ROOM holds for the model — the authoritative table,
    /// read through the app API rather than through any client's view.
    ///
    /// This is what makes "exactly once" a claim about the SERVER: a client's
    /// own merged view would agree with itself whatever the carry sent.
    private func serverRecordIds() async throws -> [String] {
        var request = URLRequest(url: URL(string:
            "\(TestConfig.httpUrl)/app/\(testApp.appId)/api"
            + "/documents/\(documentId!)/records/Note?limit=200"
        )!)
        request.setValue("Bearer \(testApp.ownerJWT)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw JsBaoError(
                code: .unavailable,
                message: "records answered \(status): "
                    + (String(data: data, encoding: .utf8) ?? "")
            )
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let items = (body["items"] as? [[String: Any]]) ?? []
        return items.compactMap { $0["id"] as? String ?? $0["_id"] as? String }
    }

    // MARK: - Behavior 11 / S1 — a write pending at a seal

    /// The whole of S1 on a real room: the client stays CONNECTED across the
    /// seal, follows it with no reload, its pending write reaches the server
    /// exactly once, and a later write is acknowledged on the new epoch.
    ///
    /// Held: the outbound queue is held across the rotation, which makes
    /// "pending AT the seal" a fact rather than a coin flip, so this row
    /// grades the CARRY every time it runs.
    func testAConnectedClientFollowsASealAndItsPendingWriteLandsOnce() async throws {
        try await followASeal(holdingTheOutboundQueue: true)
    }

    /// S1 again with nothing held — the race as a user runs it (#3628).
    ///
    /// The debounce and the seal's round trip are the same order of magnitude,
    /// so left to itself the delta is already on the wire about a third of the
    /// time, and the room receives it AFTER it has sealed. Both ways must end
    /// here: whichever way the race falls, the write is acknowledged, exactly
    /// once, and the document stays live.
    ///
    /// That is new. The room used to read `hasUnintegratedStructs` over the
    /// WHOLE document, and Yjs never drops a delta it could not integrate, so
    /// one late frame had the room answer EVERY later frame from that
    /// connection with a resync request instead of an acknowledgement until
    /// the Durable Object was evicted — reproduced here at 25 answered
    /// resyncs a second, with the write that provoked it still pending when
    /// the row gave up. The hold above was this suite's way around it. #3628
    /// attributes the parked structs to the frame that produced them, so the
    /// workaround is no longer what makes S1 pass; the row above keeps it for
    /// the coverage it buys, and this one runs without it.
    func testAConnectedClientFollowsASealWithItsOutboundQueueUnheld() async throws {
        try await followASeal(holdingTheOutboundQueue: false)
    }

    private func followASeal(holdingTheOutboundQueue holdQueue: Bool) async throws {
        let author = await makeClient(databasePath: directory + "/author.sqlite")
        let binding = try await createAndOpen(author)
        let note = try model(author)
        let joined = try binding.store.epoch()

        // A write the room has acknowledged, so it is NOT owed across the
        // seal — the control for the one that is.
        _ = try note.create(id: "acked", values: [
            "title": .string("before the seal"), "views": .number(1),
        ])
        try await eventually(timeout: 20, description: "the first write to be acknowledged") {
            try binding.store.pendingOps().isEmpty
        }

        // Now a write that is still owed when the epoch is sealed. The socket
        // is deliberately left up: this is the CONNECTED case.
        //
        // The hold is the client's own mechanism and the move's own release —
        // from the moment `handleEpochSeal` reads the frame the document is
        // held exactly like this and the move lets everything go
        // (`Format2EpochMoveHermeticTests` pins both); taking it one beat
        // earlier is what makes the held row grade the carry every time.
        // Unheld, the delta races the seal and may reach the room after it,
        // which is the case #3628 made survivable.
        if holdQueue {
            author.format2?.hold.hold(documentId, reason: "the seal this row is about")
        }
        _ = try note.create(id: "pending", values: [
            "title": .string("owed at the seal"), "views": .number(2),
        ])
        if holdQueue {
            XCTAssertEqual(
                try binding.store.pendingOps().map(\.seq), [2],
                "owed, and — since the queue is held — owed with nothing of it on "
                    + "the wire: what reaches the room is the carry"
            )
        }
        _ = try await testRoute("seal-epoch", body: ["reason": "swift-move-test"])

        // The client follows it: the mark moves, and nothing is stopped.
        try await eventually(timeout: 30, description: "the client to follow the seal") {
            try binding.store.epoch() > joined
        }
        XCTAssertFalse(
            binding.reloadRequired,
            "S1: following a seal must not raise FORMAT2_RELOAD_REQUIRED — "
            + "refusal: \(String(describing: binding.reloadRefusal?.code))"
        )
        XCTAssertFalse(author.format2?.hold.isHeld(documentId) ?? true)

        // The owed write is acknowledged on the NEW epoch — carried there by
        // the move, or re-stated after a resync the room asked for.
        try await eventuallyOn(
            author, timeout: 30, "the owed write to be acknowledged"
        ) {
            try binding.store.pendingOps().isEmpty
        }

        // And a write made AFTER the move is acknowledged too, which is what
        // says the document is live rather than merely unstopped.
        _ = try note.create(id: "after", values: [
            "title": .string("after the move"), "views": .number(3),
        ])
        try await eventuallyOn(author, timeout: 30, "a write on the new epoch") {
            try binding.store.pendingOps().isEmpty
        }

        // The facade reads unchanged across the move.
        XCTAssertEqual(note.find(id: "acked")?["title"], .string("before the seal"))
        XCTAssertEqual(note.find(id: "pending")?["title"], .string("owed at the seal"))
        XCTAssertEqual(note.find(id: "after")?["title"], .string("after the move"))

        // EXACTLY ONCE on the server: the carry is not a re-send of the epoch,
        // so a record must not appear twice and a peer's view must agree.
        let ids = try await serverRecordIds()
        XCTAssertEqual(
            ids.filter { $0 == "pending" }.count, 1,
            "the write pending at the seal is on the server exactly once; ids: \(ids)"
        )
        XCTAssertEqual(Set(ids), ["acked", "pending", "after"], "ids: \(ids)")
    }

    // MARK: - Behavior 7 / S4 — an adopted write, acknowledged

    /// A relaunched instance's adopted write is delivered and acknowledged by
    /// a real room, and `pendingOps()` reaches zero.
    ///
    /// This is the half no hermetic test can reach. Swift mints its client id
    /// per instance, so the previous instance's unacknowledged write is a row
    /// the new one cannot even see until it adopts it — and once adopted it
    /// has a sequence THIS instance never sent, so whether the room
    /// acknowledges it depends on the frame the join puts on the wire.
    func testARelaunchedInstanceGetsThePreviousInstancesWriteAcknowledged()
        async throws
    {
        let databasePath = directory + "/relaunch.sqlite"

        // ---- The first instance writes and goes away with the write OWED.
        // The socket is dropped before the flush can carry it, which is what
        // a process that dies mid-write leaves behind.
        let first = await makeClient(databasePath: databasePath)
        let firstBinding = try await createAndOpen(first)
        let firstModel = try model(first)

        await first.disconnect()
        _ = try firstModel.create(id: "orphan", values: [
            "title": .string("owed by the instance that went away"),
            "views": .number(9),
        ])
        XCTAssertEqual(
            try firstBinding.store.pendingOps().count, 1,
            "precondition: the write is owed when the instance goes away"
        )
        let orphanedClientId = try XCTUnwrap(
            try firstBinding.store.pendingOps().first
        ).seq
        XCTAssertEqual(orphanedClientId, 1)
        await first.destroy()
        clients.removeAll { $0 === first }

        // ---- The relaunch: a NEW instance over the same database, with a
        // client id of its own, so the row above is somebody else's.
        let second = await makeClient(databasePath: databasePath)
        let secondBinding = try await reopen(second)
        let secondModel = try model(second)

        // Adopted, so it is this instance's to deliver.
        try await eventually(
            timeout: 20, description: "the relaunched instance to adopt the write"
        ) {
            try !secondBinding.store.pendingOps().isEmpty
        }
        let adopted = try XCTUnwrap(try secondBinding.store.pendingOps().first)
        XCTAssertEqual(adopted.recordId, "orphan")

        // ---- And the ROOM acknowledges it: `pendingOps()` reaches zero,
        // which is S4's claim and the one only a real Durable Object can make.
        try await eventually(
            timeout: 30,
            description: "the room to acknowledge the adopted write"
        ) {
            try secondBinding.store.pendingOps().isEmpty
        }

        // It is on the server, once, and readable by a third client that has
        // never held this database.
        let ids = try await serverRecordIds()
        XCTAssertEqual(
            ids.filter { $0 == "orphan" }.count, 1,
            "the adopted write is on the server exactly once; ids: \(ids)"
        )
        XCTAssertEqual(
            secondModel.find(id: "orphan")?["title"],
            .string("owed by the instance that went away")
        )

        let reader = await makeClient(databasePath: directory + "/reader.sqlite")
        try await reader.connect()
        try await waitForConnection(client: reader)
        _ = try await reader.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .network, enableNetworkSync: true
        ))
        let readerModel = try model(reader)
        try await eventually(timeout: 30, description: "the adopted write to reach a peer") {
            readerModel.find(id: "orphan") != nil
        }
    }
}
