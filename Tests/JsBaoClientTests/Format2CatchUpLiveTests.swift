import XCTest
@testable import JsBaoClient
import YSwift

/// A client that was AWAY, against a real room (#3437, behaviors 23 to 26;
/// success criteria S2, S3, S5 and S6).
///
/// Every decision these behaviors take is pinned hermetically — the plan, the
/// chain, the resolution, the window — and none of those tests can say what a
/// Durable Object does with the frames the decision produces. That is the half
/// here: whether the room accepts a whole-state frame from a client that
/// jumped two epochs, whether it acknowledges sequences that were judged
/// rather than replayed, and whether its own retention really does leave a
/// chain a client cannot apply.
///
/// Rotations and retention are driven through the dev server's local-only
/// document test routes and waited on by POLLING: the room arms its own alarm,
/// so a tick count would be a guess about this machine rather than a statement
/// about the behavior (#3432's lesson).
final class Format2CatchUpLiveTests: XCTestCase {

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
        testApp = try await ctx.createTestApp(name: "swift-f2-catchup")
        directory = NSTemporaryDirectory() + "f2-catchup-live-\(UUID().uuidString.prefix(8))"
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
        try await waitForConnection(client: client)
        let created = try await client.createDocument(options: CreateDocumentOptions(
            title: "swift catch-up", documentFormat: 2
        ))
        documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try await eventually(timeout: 20, description: "the create to commit") {
            client.documentManager.getLocalMetadata(self.documentId)?.pendingCreate != true
        }
        return try await open(client)
    }

    @discardableResult
    private func open(_ client: JsBaoClient) async throws -> Format2DocumentBinding {
        try await client.connect()
        // Generously, because this is also the RECONNECT of a client that was
        // deliberately taken offline: the socket is rebuilt and re-authorized,
        // and the default five seconds is a guess about a machine.
        try await waitForConnection(client: client, timeout: 30)
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

    /// The records the ROOM holds for the model — the authoritative table,
    /// read through the app API rather than through any client's view.
    private func serverRecords() async throws -> [String: [String: Any]] {
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
        var out: [String: [String: Any]] = [:]
        for item in items {
            guard let id = item["id"] as? String ?? item["_id"] as? String else { continue }
            out[id] = item
        }
        return out
    }

    // MARK: - Behavior 23 / S2 — a relaunch across two seals

    /// The client writes and closes; two seals and a peer's writes happen
    /// while it is away; it comes back and fast-forwards over the sealed chain
    /// with NO base download.
    ///
    /// The "no base download" half is what makes this the catch-up rather than
    /// a cold start: the archives are rotation-sized, and the whole point of
    /// the chain is that a client one or two epochs behind never pays for the
    /// document again. It is asserted on `DocumentSnapshotLoadEvent`, which a
    /// base load emits and a chain does not.
    func testARelaunchAcrossTwoSealsAppliesTheChainWithNoBaseDownload() async throws {
        let mine = directory + "/mine.sqlite"
        let author = await makeClient(databasePath: mine)
        let binding = try await createAndOpen(author)
        let note = try model(author)

        _ = try note.create(id: "seed", values: ["title": .string("seed")])
        try await eventually(timeout: 20, description: "the seed to be acknowledged") {
            try binding.store.pendingOps().isEmpty
        }
        let heldWhenItLeft = try binding.store.epoch()

        // A write still OWED when this client goes away, on a key a peer will
        // also touch while it is gone.
        await author.disconnect()
        _ = try note.create(id: "mine", values: [
            "title": .string("written before the close"),
        ])
        XCTAssertEqual(try binding.store.pendingOps().count, 1)
        await author.destroy()
        clients.removeAll { $0 === author }

        // ---- Away: two seals, with a peer writing in between.
        let peer = await makeClient(databasePath: directory + "/peer.sqlite")
        _ = try await open(peer)
        let peerModel = try model(peer)
        _ = try await testRoute("seal-epoch", body: ["reason": "swift-catchup-1"])
        _ = try peerModel.create(id: "peer-1", values: ["title": .string("from the peer")])
        try await eventually(timeout: 30, description: "the peer's first write") {
            try await self.serverRecords()["peer-1"] != nil
        }
        _ = try await testRoute("seal-epoch", body: ["reason": "swift-catchup-2"])
        _ = try peerModel.create(id: "peer-2", values: ["title": .string("and another")])
        try await eventually(timeout: 30, description: "the peer's second write") {
            try await self.serverRecords()["peer-2"] != nil
        }

        // ---- The relaunch, over the same database.
        let returning = await makeClient(databasePath: mine)
        let loads = LockedBox<[DocumentSnapshotLoadEvent]>([])
        let subscription = returning.eventEmitter.subscribe(
            DocumentSnapshotLoadEvent.self
        ) { event in loads.withValue { $0.append(event) } }
        let back = try await open(returning)
        let backModel = try model(returning)

        try await eventually(timeout: 60, description: "the chain to land") {
            try back.store.epoch() > heldWhenItLeft
        }
        XCTAssertTrue(
            loads.value.isEmpty,
            "a catch-up downloads no base: the sealed archives ARE the "
                + "difference, and paying for the document again is what the "
                + "chain exists to avoid. Events: \(loads.value.map(\.phase))"
        )
        XCTAssertFalse(back.reloadRequired)

        // Its own pending write is delivered and acknowledged.
        try await eventually(
            timeout: 60, description: "the owed write to be acknowledged"
        ) {
            try back.store.pendingOps().isEmpty
        }

        // And the merged view equals the server's records for the model.
        let server = try await serverRecords()
        XCTAssertEqual(
            Set(server.keys), ["seed", "mine", "peer-1", "peer-2"],
            "server ids: \(Set(server.keys))"
        )
        for id in server.keys {
            XCTAssertNotNil(
                backModel.find(id: id),
                "the merged view is short of `\(id)`, which the server holds"
            )
        }
        XCTAssertEqual(
            backModel.find(id: "mine")?["title"],
            .string("written before the close"),
            "and the value it carried across the chain is its own"
        )
        subscription.cancel()
    }

    // MARK: - Behavior 24 / S3 — offline writes judged against the chain

    /// A client writes offline, the world moves on, and the reconnect DECIDES
    /// what of it survives — with the app told exactly what did not.
    ///
    /// Every verdict here is pinned hermetically. What is live is that the
    /// room's own seal times are the windows the verdicts are read against,
    /// that the surviving write really is acknowledged, and that the dropped
    /// one never reaches the server at all.
    func testOfflineWritesAreJudgedAgainstTheChainAndSurfaced() async throws {
        let mine = directory + "/offline.sqlite"
        let author = await makeClient(databasePath: mine)
        let binding = try await createAndOpen(author)
        let note = try model(author)

        // Two records both sides know about, acknowledged before anyone goes
        // anywhere: `contested` is the one a peer will also write, `doomed` is
        // the one a peer will delete.
        _ = try note.create(id: "contested", values: [
            "title": .string("seed"), "body": .string("untouched by anyone else"),
        ])
        _ = try note.create(id: "doomed", values: ["title": .string("seed")])
        try await eventually(timeout: 20, description: "the seeds to be acknowledged") {
            try binding.store.pendingOps().isEmpty
        }

        // ---- Offline, at t0: one write to a field a peer will beat, and one
        // to a field nobody else touches — the control that says the drop is
        // about recency rather than about being offline.
        await author.disconnect()
        try note.update(id: "contested", values: [
            "title": .string("mine, written offline"),
            "body": .string("mine, and nobody else's"),
        ])
        try note.update(id: "doomed", values: ["title": .string("patch on a dead record")])
        XCTAssertEqual(try binding.store.pendingOps().count, 2)
        await author.destroy()
        clients.removeAll { $0 === author }

        // ---- The seal AFTER t0. Everything a peer writes from here falls in
        // a window that starts after the offline writes were made, which is
        // what makes them "clearly older" rather than ambiguous.
        _ = try await testRoute("seal-epoch", body: ["reason": "swift-replay-seal"])

        let peer = await makeClient(databasePath: directory + "/peer.sqlite")
        _ = try await open(peer)
        let peerModel = try model(peer)
        try peerModel.update(id: "contested", values: [
            "title": .string("the peer got there first"),
        ])
        peerModel.delete(id: "doomed")
        try await eventually(timeout: 30, description: "the peer's writes to land") {
            let server = try await self.serverRecords()
            return server["doomed"] == nil
                && (server["contested"]?["title"] as? String) == "the peer got there first"
        }
        _ = try await testRoute("seal-epoch", body: ["reason": "swift-replay-seal-2"])

        // ---- The return.
        let returning = await makeClient(databasePath: mine)
        let notices = LockedBox<[DocumentOfflineWritesResolvedEvent]>([])
        let subscription = returning.eventEmitter.subscribe(
            DocumentOfflineWritesResolvedEvent.self
        ) { event in notices.withValue { $0.append(event) } }
        let back = try await open(returning)
        let backModel = try model(returning)

        try await eventually(timeout: 60, description: "the offline writes to be judged") {
            notices.value.isEmpty == false
        }
        XCTAssertEqual(
            notices.value.count, 1,
            "one event per judgement, carrying everything that did not simply "
                + "apply: \(notices.value)"
        )
        let event = try XCTUnwrap(notices.value.first)
        XCTAssertEqual(event.documentId, documentId)

        let dropped = event.notices.filter { $0.outcome == .dropped }
        XCTAssertTrue(
            dropped.contains { $0.recordId == "contested" && $0.field == "title" },
            "the field the peer wrote after the seal is dropped as outdated: "
                + "\(event.notices)"
        )
        XCTAssertTrue(
            dropped.contains { $0.recordId == "doomed" },
            "and the patch onto a record deleted meanwhile is dropped whatever "
                + "the clock says: \(event.notices)"
        )
        XCTAssertFalse(
            event.notices.contains { $0.recordId == "contested" && $0.field == "body" },
            "the field nobody contested is not a notice at all — it simply "
                + "applied: \(event.notices)"
        )

        // The survivors are stated and acknowledged; the drops never happen.
        try await eventually(timeout: 60, description: "the survivors to be acknowledged") {
            try back.store.pendingOps().isEmpty
        }
        let server = try await serverRecords()
        XCTAssertEqual(
            server["contested"]?["title"] as? String, "the peer got there first",
            "the outdated write never reached the room"
        )
        XCTAssertEqual(
            server["contested"]?["body"] as? String, "mine, and nobody else's",
            "and the uncontested one did"
        )
        XCTAssertNil(server["doomed"], "the deleted record stays deleted")
        XCTAssertNil(
            backModel.find(id: "doomed"),
            "and the client agrees rather than resurrecting it locally"
        )
        subscription.cancel()
    }

    // MARK: - Behavior 25 / S6 — a chain retention has taken

    /// With the archives of the epochs this client held pruned by the REAL
    /// retention path, the relaunch reloads from the latest base instead of
    /// stopping, reaches the room's epoch, and replays its owed writes as
    /// `unverifiable` — kept, and said to be unchecked.
    func testAPrunedChainReloadsFromTheLatestBaseAndKeepsItsWrites() async throws {
        let mine = directory + "/pruned.sqlite"
        let author = await makeClient(databasePath: mine)
        let binding = try await createAndOpen(author)
        let note = try model(author)
        _ = try note.create(id: "seed", values: ["title": .string("seed")])
        try await eventually(timeout: 20, description: "the seed to be acknowledged") {
            try binding.store.pendingOps().isEmpty
        }

        await author.disconnect()
        _ = try note.create(id: "owed", values: ["title": .string("owed while away")])
        XCTAssertEqual(try binding.store.pendingOps().count, 1)
        await author.destroy()
        clients.removeAll { $0 === author }

        // ---- Two rotations, a base built over them, and then retention takes
        // the archives this client would have needed.
        _ = try await testRoute("seal-epoch", body: ["reason": "swift-prune-1"])
        _ = try await testRoute("seal-epoch", body: ["reason": "swift-prune-2"])
        try await eventually(timeout: 120, description: "a base to be built") {
            let state = try await self.testRoute("snapshot-state")
            let builds = (state["builds"] as? [[String: Any]]) ?? []
            return builds.contains { ($0["state"] as? String) == "complete" }
        }
        _ = try await testRoute("age-epochs", body: ["days": 30])
        let pruned = try await testRoute("prune-overlays")
        let epochs = (pruned["epochs"] as? [[String: Any]]) ?? []
        // The positive control, and it has two halves: retention really has
        // taken the archives of every SEALED epoch (so no chain is applicable
        // — `forgetArchive` nulls the key and leaves the state alone), and
        // there really is a base to reload from instead. Without the second
        // half this case would pass for "the document is unreachable".
        let sealed = epochs.filter { ($0["state"] as? String) == "sealed" }
        XCTAssertFalse(sealed.isEmpty, "epochs: \(epochs)")
        XCTAssertTrue(
            sealed.allSatisfy { $0["archiveKey"] is NSNull || $0["archiveKey"] == nil },
            "retention did not take the archives this client would have "
                + "needed: \(epochs)"
        )
        XCTAssertTrue(
            epochs.contains { !($0["snapshotManifestKey"] is NSNull) },
            "and no base is on offer to reload from: \(epochs)"
        )

        // ---- The relaunch. No chain to apply, so the base is the only way up.
        let returning = await makeClient(databasePath: mine)
        let loads = LockedBox<[DocumentSnapshotLoadEvent]>([])
        let notices = LockedBox<[DocumentOfflineWritesResolvedEvent]>([])
        let loadSubscription = returning.eventEmitter.subscribe(
            DocumentSnapshotLoadEvent.self
        ) { event in loads.withValue { $0.append(event) } }
        let noticeSubscription = returning.eventEmitter.subscribe(
            DocumentOfflineWritesResolvedEvent.self
        ) { event in notices.withValue { $0.append(event) } }
        let back = try await open(returning)
        let backModel = try model(returning)

        try await eventually(timeout: 120, description: "the reload to finish") {
            loads.value.contains { $0.phase == .loaded }
        }
        XCTAssertFalse(
            back.reloadRequired,
            "a pruned chain with a base on offer is a RELOAD, not a stop: "
                + "\(String(describing: back.reloadRefusal?.code))"
        )
        XCTAssertTrue(
            loads.value.allSatisfy { $0.mode == "load" },
            "and it is a whole load, never a range replacement — the intent's "
                + "rule for this client"
        )

        // Its owed write survives, unchecked and said to be.
        try await eventually(timeout: 60, description: "the owed write to be judged") {
            notices.value.isEmpty == false
        }
        XCTAssertTrue(
            try XCTUnwrap(notices.value.first).notices.allSatisfy {
                $0.reason == .unverifiable && $0.outcome == .keptAmbiguous
            },
            "the chain that would have weighed it is the chain retention took: "
                + "\(notices.value.first?.notices ?? [])"
        )
        try await eventually(timeout: 60, description: "the owed write to be acknowledged") {
            try back.store.pendingOps().isEmpty
        }

        let server = try await serverRecords()
        XCTAssertEqual(Set(server.keys), ["seed", "owed"], "server: \(Set(server.keys))")
        for id in server.keys {
            XCTAssertNotNil(backModel.find(id: id), "the view is short of `\(id)`")
        }
        // And the two doors agree after a reload, which is what the projections
        // going with the merged view is for (finding 3437-SO-05).
        XCTAssertEqual(try backModel.count(), server.count)
        loadSubscription.cancel()
        noticeSubscription.cancel()
    }

    // MARK: - Behavior 26 / S5 — the read-only window, live

    /// A client whose stored sync mark is back-dated past the window refuses
    /// every door offline, leaves nothing on the server, and accepts all three
    /// again once it has synced.
    ///
    /// The live half is the LAST clause. A refusal is hermetic; that a real
    /// handshake earns the mark back, and that nothing the refused writes
    /// touched reached the room, are not.
    func testAClientPastItsWindowRefusesOfflineAndWritesAgainAfterASync()
        async throws
    {
        let path = directory + "/window.sqlite"
        let client = await makeClient(databasePath: path)
        let binding = try await createAndOpen(client)
        let note = try model(client)
        _ = try note.create(id: "before", values: ["title": .string("before")])
        try await eventually(timeout: 20, description: "the first write") {
            try binding.store.pendingOps().isEmpty
        }

        // Offline, and back-dated past the window the server reported.
        await client.disconnect()
        let windowDays = try binding.store.offlineWindowDays()
        let stale = Int(Date().timeIntervalSince1970 * 1000)
            - (windowDays + 3) * 24 * 60 * 60 * 1_000
        try binding.store.noteSync(at: stale)

        let refusals = LockedBox<[DocumentWriteRefusedEvent]>([])
        let subscription = client.eventEmitter.subscribe(
            DocumentWriteRefusedEvent.self
        ) { event in refusals.withValue { $0.append(event) } }

        // A throwing door.
        XCTAssertThrowsError(
            try note.create(id: "refused", values: ["title": .string("past the window")])
        ) { error in
            XCTAssertEqual(
                (error as? JsBaoError)?.code, .documentOfflineWindowExpired,
                "a create past the window throws the typed error"
            )
        }
        // And a non-throwing one, which reports through the event instead.
        note.delete(id: "before")
        XCTAssertEqual(refusals.value.count, 1, "refusals: \(refusals.value)")
        XCTAssertEqual(refusals.value.first?.recordId, "before")
        XCTAssertEqual(
            refusals.value.first?.error.code, .documentOfflineWindowExpired
        )
        XCTAssertNotNil(
            note.find(id: "before"),
            "a refused delete leaves the record where it was"
        )
        XCTAssertTrue(
            try binding.store.pendingOps().isEmpty,
            "and neither refusal left a pending op to publish later"
        )

        // ---- A sync restores writes, and nothing refused ever reached the room.
        // `connect()` is a no-op while an explicit disconnect stands (#2663);
        // `setShouldConnect(true)` is how it is undone.
        await client.setShouldConnect(true)
        try await waitForConnection(client: client, timeout: 30)
        try await eventually(timeout: 30, description: "the handshake to release the hold") {
            client.format2?.hold.isHeld(self.documentId) == false
        }
        try await eventually(timeout: 30, description: "the mark to be earned back") {
            binding.store.offlineWindowStatus(
                now: Int(Date().timeIntervalSince1970 * 1000)
            ).writable
        }
        _ = try note.create(id: "after", values: ["title": .string("after the sync")])
        try await eventually(timeout: 30, description: "the write after the sync") {
            try binding.store.pendingOps().isEmpty
        }

        let server = try await serverRecords()
        XCTAssertNil(server["refused"], "server ids: \(Set(server.keys))")
        XCTAssertNotNil(
            server["before"], "the refused delete never reached the room either"
        )
        XCTAssertNotNil(server["after"])
        subscription.cancel()
    }
}
