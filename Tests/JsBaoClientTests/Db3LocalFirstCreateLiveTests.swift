import XCTest
@testable import JsBaoClient

/// #5000 behaviors 12 to 16 and 24 — `client.db3.create` returns at once
/// online, committing in the background, against the dev server.
///
/// A create of the caller's own synced db3 with no custodian is a pending
/// create with networking on too: it returns the db3 under the id this
/// client minted, usable at once, while its `POST db3` goes out through the
/// `createRemoteDb3` hook. The tests hold that real commit
/// (`heldDb3Commit(_:)` wraps the hook and forwards to it once opened), so
/// what happens before the server answers is not a matter of timing.
/// Refusals come from the server: a type the app never pushed is refused 404
/// `DB3_TYPE_NOT_FOUND`.
final class Db3LocalFirstCreateLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    private static let schema = """
    [models.Note]
    [models.Note.fields.id]
    type = "id"
    [models.Note.fields.title]
    type = "string"
    """

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-local-first-5000")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// The db3 events a client fires, from now on.
    private final class Heard: @unchecked Sendable {
        let created = LockedBox<[String]>([])
        let failed = LockedBox<[Db3CreateFailedEvent]>([])
        private var subscriptions: [EventSubscription] = []

        init(_ client: JsBaoClient) {
            subscriptions = [
                client.eventEmitter.subscribe(Db3CreatedEvent.self) { [created] event in created.withValue { $0.append(event.id) } },
                client.eventEmitter.subscribe(Db3CreateFailedEvent.self) { [failed] event in failed.withValue { $0.append(event) } },
            ]
        }

        deinit { subscriptions.forEach { $0.cancel() } }
    }

    /// A type name no app has pushed.
    private static func unpushedType() -> String { "swift-t5000-\(UUID().uuidString.prefix(8).lowercased())" }

    private func pushType(_ name: String) async throws {
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(name)", body: ["schema": Self.schema], jwt: live.app.ownerJWT
        )
    }

    /// `body`'s answer, or a failure naming `what` once `seconds` passed without one.
    private func within<T: Sendable>(
        _ seconds: TimeInterval, _ what: String, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let answer = first else {
                throw TestSetupError("\(what) did not finish within \(seconds) s")
            }
            return answer
        }
    }

    private func titles(_ client: JsBaoClient, _ db3Id: String) throws -> [String] {
        try XCTUnwrap(client.sharedModel("Note")?.member(docId: db3Id)).query().compactMap { $0["title"]?.stringValue }.sorted()
    }

    /// The db3 id a refusal thrown by a waiting call names in its body.
    private func refusedDb3Id(_ error: HttpError) -> String? {
        guard let body = error.body, let data = body.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (parsed["details"] as? [String: Any])?["db3Id"] as? String
    }

    // MARK: - Behavior 12

    func testAnOnlineCreateReturnsWhileItsCommitIsHeldAndCommitsOnceItIsReleased() async throws {
        let type = Self.unpushedType()
        try await pushType(type)
        let memberUser = try await ctx.createTestUser(appId: live.app.appId)
        let member = try await live.client("member", models: [Self.note], token: memberUser.jwt)
        let heard = Heard(member)
        let held = heldDb3Commit(member)
        let info = try await within(5, "create") {
            try await member.db3.create(title: "Held", type: type, tags: ["x"], metadata: .object(["k": .number(1)]))
        }
        XCTAssertNotNil(info.id.range(of: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$", options: .regularExpression), info.id)
        XCTAssertEqual(info.custodian, "user:\(memberUser.userId)")
        try await eventually(timeout: 5, description: "the commit to go out") { held.bodies.count == 1 }
        let body = try XCTUnwrap(held.bodies.first, "the commit went through the hook")
        XCTAssertEqual(body["id"]?.stringValue, info.id)
        XCTAssertEqual(body["title"]?.stringValue, "Held")
        XCTAssertEqual(body["type"]?.stringValue, type)
        XCTAssertEqual(body["tags"], .array([.string("x")]))
        XCTAssertEqual(body["metadata"], .object(["k": .number(1)]))
        XCTAssertTrue(heard.created.value.isEmpty)
        let pending = try await member.db3.state(info.id)
        XCTAssertTrue(pending.pendingCreate)
        XCTAssertTrue(try XCTUnwrap(member.recordLogBinding(info.id)).createdLocally)

        held.open()
        try await eventually(timeout: 15, description: "Db3CreatedEvent") { heard.created.value == [info.id] }
        try await eventually(timeout: 15, description: "pendingCreate false") { try await !member.db3.state(info.id).pendingCreate }
        let got = try await member.db3.get(info.id)
        XCTAssertEqual(got.id, info.id)
        XCTAssertEqual(got.permission, .owner)
        XCTAssertEqual(got.type, type)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(held.bodies.count, 1)
        XCTAssertEqual(heard.created.value, [info.id], "Db3CreatedEvent fired once")
    }

    // MARK: - Behavior 13

    func testTheNewDb3SavesAndQueriesBeforeTheServerAnswersAndItsRowReachesTheRoom() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let heard = Heard(owner)
        let held = heldDb3Commit(owner)
        let info = try await within(5, "create") { try await owner.db3.create(title: "Used at once") }
        try owner.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("early")], in: info.id)
        XCTAssertEqual(try titles(owner, info.id), ["early"])
        XCTAssertTrue(heard.created.value.isEmpty)

        held.open()
        let handle = try owner.db3.subscribe(info.id)
        try await handle.ready()
        try await live.settled(owner, info.id)
        let room = try await live.roomRows(info.id, "Note").values.compactMap { $0["title"] as? String }
        XCTAssertEqual(room, ["early"])
        handle.dispose()
    }

    // MARK: - Behavior 14

    func testAServerRefusalIsAnEventThatKeepsTheRowsAndIsNotRepeated() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let heard = Heard(owner)
        let held = heldDb3Commit(owner)
        let type = Self.unpushedType()
        let info = try await within(5, "create") { try await owner.db3.create(title: "No such type", type: type) }
        XCTAssertEqual(info.type, type)
        try owner.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("kept")], in: info.id)

        held.open()
        try await eventually(timeout: 15, description: "Db3CreateFailedEvent") { heard.failed.value.count == 1 }
        let failed = try XCTUnwrap(heard.failed.value.first)
        XCTAssertEqual(failed.id, info.id)
        XCTAssertEqual(failed.code, "DB3_TYPE_NOT_FOUND")
        XCTAssertEqual(failed.title, "No such type")
        XCTAssertEqual(failed.type, type)
        XCTAssertEqual(try titles(owner, info.id), ["kept"])
        try await eventually(timeout: 10, description: "the refusal in the state") {
            try await owner.db3.state(info.id).error?.code == "DB3_TYPE_NOT_FOUND"
        }
        let state = try await owner.db3.state(info.id)
        XCTAssertTrue(state.pendingCreate)
        let listed = try await owner.db3.listMine(options: PaginationOptions(limit: 100))
        XCTAssertFalse(listed.items.map(\.id).contains(info.id))

        let before = held.bodies.count
        await owner.goOffline()
        await owner.goOnline()
        try await waitForConnection(client: owner, timeout: 10)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(held.bodies.count, before, "a reconnect does not repeat a refused commit")
        XCTAssertEqual(heard.failed.value.count, 1)
        XCTAssertTrue(heard.created.value.isEmpty)
    }

    // MARK: - Behavior 15

    func testCommitOfflineCreateAnswersTheServersVerdictJoiningTheAttemptInFlight() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let heard = Heard(owner)
        let held = heldDb3Commit(owner)
        let info = try await within(5, "create") { try await owner.db3.create(title: "Awaited") }
        let verdict = Task { () -> Bool? in try await owner.commitOfflineCreate(documentId: info.id)["created"] as? Bool }
        try await Task.sleep(nanoseconds: 300_000_000)
        held.open()
        let created = try await verdict.value
        XCTAssertEqual(created, true)
        XCTAssertEqual(held.bodies.count, 1, "the call joined the attempt in flight")
        try await eventually(timeout: 10, description: "Db3CreatedEvent") { heard.created.value == [info.id] }

        // A call after the commit landed answers that it is not pending.
        let late = try await owner.commitOfflineCreate(documentId: info.id)
        XCTAssertEqual(late["created"] as? Bool, false)
        XCTAssertEqual(late["reason"] as? String, "not_pending")

        // A refused create is tried again by the call, which answers the refusal.
        let type = Self.unpushedType()
        let typed = try await owner.db3.create(title: "Typed later", type: type)
        try await eventually(timeout: 15, description: "the refusal") { heard.failed.value.contains { $0.id == typed.id } }
        let sentBefore = held.bodies.count
        let refused = try await owner.commitOfflineCreate(documentId: typed.id)
        XCTAssertEqual(refused["refused"] as? Bool, true)
        XCTAssertNotNil(refused["reason"] as? String)
        let viaDocuments = try await owner.documents.commitOfflineCreate(documentId: typed.id)
        XCTAssertEqual(viaDocuments.created, false)
        XCTAssertNotNil(viaDocuments.reason)
        XCTAssertEqual(viaDocuments, CommitOfflineCreateResult(created: false, refused: true, reason: viaDocuments.reason))
        XCTAssertEqual(held.bodies.count, sentBefore + 2)
        try await pushType(type)
        let committed = try await owner.documents.commitOfflineCreate(documentId: typed.id)
        XCTAssertEqual(committed, CommitOfflineCreateResult(created: true))
        try await eventually(timeout: 10, description: "Db3CreatedEvent for the typed create") { heard.created.value.contains(typed.id) }

        // A transient failure of the explicit attempt throws; the backoff commits it.
        let other = Self.unpushedType()
        let blip = try await owner.db3.create(title: "Blip", type: other)
        try await eventually(timeout: 15, description: "the second refusal") { heard.failed.value.contains { $0.id == blip.id } }
        try await pushType(other)
        held.failNext(HttpError(status: 503, message: "unavailable", serverCode: "UNAVAILABLE", serverMessage: "busy"))
        do {
            _ = try await owner.commitOfflineCreate(documentId: blip.id)
            XCTFail("a transient failure of the explicit attempt throws")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 503)
        }
        try await eventually(timeout: 15, description: "Db3CreatedEvent after the backoff") { heard.created.value.contains(blip.id) }
        XCTAssertFalse(owner.isPendingCreate(blip.id))
    }

    // MARK: - Behavior 16

    func testDocumentsCommitOfflineCreateWaitsForAHeldCommitAndTheDocumentPathIsUnchanged() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let heard = Heard(owner)
        let held = heldDb3Commit(owner)
        let info = try await within(5, "create") { try await owner.db3.create(title: "Saved first") }
        try owner.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("before the commit")], in: info.id)
        let verdict = Task { try await owner.documents.commitOfflineCreate(documentId: info.id) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(owner.isPendingCreate(info.id))
        held.open()
        let answer = try await verdict.value
        XCTAssertEqual(answer, CommitOfflineCreateResult(created: true))
        try await eventually(timeout: 10, description: "Db3CreatedEvent") { heard.created.value == [info.id] }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(heard.created.value, [info.id], "Db3CreatedEvent fired once")

        let plain = try await ctx.createDocument(appId: live.app.appId, jwt: live.app.ownerJWT, title: "format-1")
        do {
            _ = try await owner.documents.commitOfflineCreate(documentId: plain)
            XCTFail("a document that is not a pending create throws")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    // MARK: - Behavior 24

    func testServerCallsOnAPendingCreateWaitForItsCommit() async throws {
        let aliceUser = try await ctx.createTestUser(appId: live.app.appId)
        let bobUser = try await ctx.createTestUser(appId: live.app.appId)
        let alice = try await live.client("alice", models: [Self.note], token: aliceUser.jwt)
        let held = heldDb3Commit(alice)
        let opened = LockedBox<Date?>(nil)
        let info = try await within(5, "create") { try await alice.db3.create(title: "Shared at once") }
        let access = Task { () -> (DocumentAccessResult, Date) in
            (try await alice.documents.validateAccess(documentId: info.id), Date())
        }
        let grant = Task { () -> Date in
            _ = try await alice.db3.permissions(info.id).set(.user(bobUser.userId, permission: "reader"))
            return Date()
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        opened.value = Date()
        held.open()
        let (result, accessAt) = try await access.value
        let grantAt = try await grant.value
        let openedAt = try XCTUnwrap(opened.value)
        XCTAssertTrue(result.hasAccess)
        XCTAssertEqual(result.permission, .owner)
        XCTAssertGreaterThan(accessAt, openedAt, "validateAccess answered after the commit was released")
        XCTAssertGreaterThan(grantAt, openedAt, "the grant answered after the commit was released")
        XCTAssertEqual(held.bodies.count, 1, "one commit for both calls")
        let grants = try await alice.db3.permissions(info.id).list()
        XCTAssertTrue(grants.contains { $0.userId == bobUser.userId && $0.permission == .reader })

        // A refused create: the calls waiting on it throw its refusal.
        let type = Self.unpushedType()
        let refusedHeld = heldDb3Commit(alice)
        let refused = try await within(5, "the refused create") { try await alice.db3.create(title: "Refused under a wait", type: type) }
        let got = Task { () -> Error? in
            do { _ = try await alice.db3.get(refused.id); return nil } catch { return error }
        }
        let sync = Task { () -> Error? in
            do { _ = try await alice.db3.setSync(refused.id, sync: false); return nil } catch { return error }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        held.open()
        refusedHeld.open()
        for (name, outcome) in [("get", await got.value), ("setSync", await sync.value)] {
            let error = try XCTUnwrap(outcome as? HttpError, "\(name) throws the refusal, got \(String(describing: outcome))")
            XCTAssertEqual(error.status, 404, name)
            XCTAssertEqual(error.serverCode, "DB3_TYPE_NOT_FOUND", name)
            XCTAssertEqual(refusedDb3Id(error), refused.id, name)
        }

        // Offline, a call on a pending create throws `.pendingCreate` at once.
        await alice.goOffline()
        let offline = try await alice.db3.create(title: "Offline")
        do {
            _ = try await within(1, "the offline get") { try await alice.db3.get(offline.id) }
            XCTFail("an offline call on a pending create throws")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .pendingCreate)
            XCTAssertEqual(error.details?["db3Id"], .string(offline.id))
        }
    }

    // MARK: - Uploads right after the create

    /// An upload made while the create's commit is held waits in the queue
    /// for the commit, instead of reaching the db3 route first and being
    /// dropped by its 404, and goes once the server has the db3.
    func testAnUploadRightAfterTheCreateWaitsForItsCommit() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let heard = Heard(owner)
        let held = heldDb3Commit(owner)
        let info = try await within(5, "create") { try await owner.db3.create(title: "Files at once") }
        let blobs = owner.db3.blobs(info.id)
        let queued = try await blobs.upload(
            data: Data("uploaded at once".utf8), options: BlobUploadSourceOptions(filename: "early.txt", contentType: "text/plain")
        )
        XCTAssertEqual(queued.bytesTransferred, 0, "queued while the server does not have the db3")
        try await Task.sleep(nanoseconds: 500_000_000)
        let waiting = await blobs.uploadsAsync()
        XCTAssertEqual(waiting.map(\.blobId), [queued.blobId], "still queued, not dropped")
        XCTAssertEqual(held.bodies.count, 1)

        held.open()
        try await eventually(timeout: 15, description: "Db3CreatedEvent") { heard.created.value == [info.id] }
        try await eventually(timeout: 20, description: "the upload to leave the queue") { await blobs.uploadsAsync().isEmpty }
        let page = try await blobs.list()
        XCTAssertEqual(page.items.map(\.blobId), [queued.blobId])
        let bytes = try await blobs.read(blobId: queued.blobId, force: true)
        XCTAssertEqual(bytes, Data("uploaded at once".utf8))
    }
}
