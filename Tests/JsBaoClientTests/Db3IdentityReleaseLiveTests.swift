import XCTest
@testable import JsBaoClient

/// #5044 — a sign-out or a user switch releases the previous user's db3s,
/// against the dev server. The lifecycle's close of an outgoing open is held
/// at `db3CloseHoldForTest`, so "during the release" is a fixed point:
///
/// - 4 (and 10): another account's session. B subscribes to a db3 both users
///   share while A's close is held: B's `available()` waits and the state is
///   not resident; once released, B's open runs under B after the store
///   reset, `ready()` settles, and the query answers exactly the room's rows,
///   never a row only A held. A's own db3 is not resident.
/// - 11 (pin): `client.destroy()` during the release returns within 15 s.
/// - 14: across the switch, no Yjs handshake goes out for A's db3s, and no
///   record frame for them under B but B's own `record.open` of the shared
///   one, after the release; B's confirmed save lands; nothing is left
///   marked releasing.
/// - 18: a `logout()` while B's open waits at the identity gate returns, B's
///   `ready()` throws `identity-changed`, and `destroy()` returns.
/// - E12: a subscribe made after `updateToken(B)` but before
///   `rebindUserScopedStorage()` belongs to A: it never reads A's binding as
///   available and ends with `identity-changed` at the rebind.
final class Db3IdentityReleaseLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-identity-5044")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func titles(_ client: JsBaoClient, _ id: String) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil, options: QueryOptions(db3: [id]))
            .compactMap { $0["title"]?.stringValue }.sorted()
    }

    private func reason(_ subscription: Db3Subscription) async -> String {
        do {
            try await subscription.ready()
            return "resolved"
        } catch {
            return (error as? JsBaoError)?.details?["reason"]?.stringValue ?? "\(error)"
        }
    }

    /// The lifecycle's closes, held until `release` opens.
    private final class CloseHold: @unchecked Sendable {
        let reached = RecordLogReceiptHarness.Gate()
        let release = RecordLogReceiptHarness.Gate()
        let closes = LockedBox<[String]>([])

        func install(_ client: JsBaoClient) {
            client.db3CloseHoldForTest = { [self] id in
                closes.withValue { $0.append(id) }
                reached.open()
                await release.wait()
            }
        }
    }

    /// The owner's client over its own file, subscribed live to `ids`.
    private func ownerSubscribed(_ name: String, _ ids: [String]) async throws -> (JsBaoClient, [Db3Subscription]) {
        let x = try await live.client(name, models: [Self.note], file: live.file(name))
        var handles: [Db3Subscription] = []
        for id in ids {
            let handle = try x.db3.subscribe(id)
            try await settles(within: 30, "ready() of \(id)") { try await handle.ready() }
            handles.append(handle)
        }
        return (x, handles)
    }

    // MARK: - Behaviour 4 (and 10)

    func testAnotherAccountsSessionReadsExactlyItsRowsOnceThePreviousUsersCloseRan() async throws {
        let shared = try await live.db3Written(2, model: "Note")
        let own = try await live.db3Written(1, model: "Note")
        let (x, _) = try await ownerSubscribed("x", [shared, own])
        let member = try await ctx.createTestUser(appId: live.app.appId)
        _ = try await x.db3.permissions(shared).set(.user(member.userId, permission: "read-write"))

        // A row only A wrote, still pending in A's store.
        x.setNetworkMode(.offline)
        _ = try live.member(x, shared, "Note").save(id: "a-only", values: ["title": .string("only A")])
        XCTAssertEqual(try titles(x, shared), ["only A", "row 1", "row 2"])

        let hold = CloseHold()
        hold.install(x)
        x.updateToken(member.jwt)
        let rebind = Task { await x.rebindUserScopedStorage() }
        await hold.reached.wait()

        let b = try x.db3.subscribe(shared)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(b.availableResult, "B waits while A's close is held")
        let during = try await x.db3.state(shared)
        XCTAssertFalse(during.resident, "A's binding is not B's to read")

        hold.release.open()
        x.db3CloseHoldForTest = nil
        try await settles(within: 15, "the rebind") { _ = await rebind.value }
        x.setNetworkMode(.auto)
        try await settles(within: 30, "B's available()") { try await b.available() }
        XCTAssertTrue(x.isRecordLogDocument(shared), "bound at available()")
        XCTAssertEqual(try titles(x, shared), ["row 1", "row 2"], "the room's rows, never A's pending row")
        try await settles(within: 30, "B's ready()") { try await b.ready() }
        XCTAssertEqual(try titles(x, shared), ["row 1", "row 2"])
        let room = try await live.roomRows(shared, "Note")
        XCTAssertEqual(Set(room.keys), ["p000001", "p000002"])
        let ownState = try await x.db3.state(own)
        XCTAssertFalse(ownState.resident, "A's own db3 is not B's")
        b.dispose()
    }

    // MARK: - Behaviour 11 (pin)

    func testADestroyDuringTheReleaseReturns() async throws {
        let id = try await live.db3Written(1, model: "Note")
        let x = try await live.client("x", models: [Self.note], file: live.file("destroy"))
        let gate = Db3FrameGate(x)
        gate.drop(Db3FrameGate.of(id))
        let pending = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 15, description: "the db3 open") { x.documentManager.isOpen(id) }

        let hold = CloseHold()
        hold.install(x)
        let member = try await ctx.createTestUser(appId: live.app.appId)
        x.updateToken(member.jwt)
        let rebind = Task { await x.rebindUserScopedStorage() }
        await hold.reached.wait()
        let release = hold.release
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            release.open()
        }
        try await settles(within: 15, "destroy() during the release") { await x.destroy() }
        let why = await reason(pending)
        XCTAssertTrue(["identity-changed", "destroyed"].contains(why), why)
        _ = await rebind.value
    }

    // MARK: - Behaviour 14

    /// Every record frame and Yjs handshake `client` sends, with whether it
    /// went out after the token change and after the close was released.
    private final class Sends: @unchecked Sendable {
        struct Frame { let type: String; let documentId: String; let afterToken: Bool; let afterRelease: Bool }
        let tokenChanged = LockedBox(false)
        let released = LockedBox(false)
        let frames = LockedBox<[Frame]>([])
        let handshakes = LockedBox<[String]>([])

        init(_ client: JsBaoClient) {
            client.recordLogFrameSentForTest = { [self] text in
                guard let frame = RecordLogJSON.parse(text)?.objectValue,
                      let type = frame["type"]?.stringValue, let id = frame["documentId"]?.stringValue else { return }
                let entry = Frame(type: type, documentId: id, afterToken: tokenChanged.value, afterRelease: released.value)
                frames.withValue { $0.append(entry) }
            }
            client.onSyncStep1SendForTest = { [self] id in handshakes.withValue { $0.append(id) } }
        }
    }

    func testAUserSwitchSendsNothingForThePreviousUsersDb3sUnderTheNewUser() async throws {
        let shared = try await live.db3Written(2, model: "Note")
        let own = try await live.db3Written(1, model: "Note")
        let (x, _) = try await ownerSubscribed("x", [shared, own])
        let member = try await ctx.createTestUser(appId: live.app.appId)
        _ = try await x.db3.permissions(shared).set(.user(member.userId, permission: "read-write"))
        let sends = Sends(x)

        // A's close is held until B's socket is up.
        let connected = LockedBox(0)
        let watch = x.eventEmitter.subscribe(StatusChangedEvent.self) { event in
            if event.status == .connected { connected.withValue { $0 += 1 } }
        }
        defer { watch.cancel() }
        let hold = CloseHold()
        hold.install(x)
        sends.tokenChanged.value = true
        x.updateToken(member.jwt)
        let rebind = Task { await x.rebindUserScopedStorage() }
        await hold.reached.wait()
        try await eventually(timeout: 15, description: "B's socket") { connected.value >= 1 && x.isConnected }
        try await Task.sleep(nanoseconds: 500_000_000)
        sends.released.value = true
        hold.release.open()
        x.db3CloseHoldForTest = nil
        try await settles(within: 15, "the rebind") { _ = await rebind.value }

        let b = try x.db3.subscribe(shared)
        try await settles(within: 30, "B's ready()") { try await b.ready() }
        let notes = try live.member(x, shared, "Note")
        try await settles(within: 15, "B's confirmed save") {
            _ = try await notes.save(id: "b1", values: ["title": .string("from B")], confirm: true)
        }
        let room = try await live.roomRows(shared, "Note")
        XCTAssertEqual(room["b1"]?["title"] as? String, "from B")

        XCTAssertEqual(sends.handshakes.value.filter { [shared, own].contains($0) }, [], "no Yjs handshake for a db3")
        let afterToken = sends.frames.value.filter(\.afterToken)
        XCTAssertEqual(afterToken.filter { $0.documentId == own }.map(\.type), [], "nothing for A's own db3 under B")
        let sharedFrames = afterToken.filter { $0.documentId == shared }
        XCTAssertEqual(sharedFrames.first?.type, "record.open")
        XCTAssertTrue(sharedFrames.allSatisfy(\.afterRelease), "nothing for the shared db3 before the release: \(sharedFrames.map(\.type))")
        XCTAssertEqual(sharedFrames.filter { $0.type == "record.open" }.count, 1, "one record.open, B's")
        XCTAssertTrue(x.db3IdentityRelease.releasing.isEmpty, "nothing left releasing")
        b.dispose()
    }

    // MARK: - Behaviour 18

    func testALogoutWhileTheNewUsersOpenWaitsAtTheGateSettles() async throws {
        let outgoing = try await live.db3Written(1, model: "Note")
        let incoming = try await live.db3Written(1, model: "Note")
        let (x, _) = try await ownerSubscribed("x", [outgoing])
        let member = try await ctx.createTestUser(appId: live.app.appId)
        _ = try await x.db3.permissions(incoming).set(.user(member.userId, permission: "read-write"))

        let hold = CloseHold()
        hold.install(x)
        x.updateToken(member.jwt)
        let rebind = Task { await x.rebindUserScopedStorage() }
        await hold.reached.wait()

        // B's open of another db3 waits at the identity gate.
        let b = try x.db3.subscribe(incoming)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(x.isRecordLogDocument(incoming), "B's open waits for the release")

        try await settles(within: 15, "logout()") { try await x.logout() }
        let why = await reason(b)
        XCTAssertEqual(why, "identity-changed")
        hold.release.open()
        x.db3CloseHoldForTest = nil
        try await settles(within: 15, "the rebind") { _ = await rebind.value }
        XCTAssertTrue(x.db3IdentityRelease.releasing.isEmpty, "nothing left releasing")
        try await settles(within: 15, "destroy()") { await x.destroy() }
    }

    // MARK: - E12

    func testASubscribeAfterTheTokenChangeBelongsToThePreviousUser() async throws {
        let id = try await live.db3Written(1, model: "Note")
        let (x, handles) = try await ownerSubscribed("x", [id])
        let member = try await ctx.createTestUser(appId: live.app.appId)
        x.updateToken(member.jwt)
        let late = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(late.availableResult, "A's binding is not available to the new identity")
        let state = try await x.db3.state(id)
        XCTAssertFalse(state.resident)

        try await settles(within: 15, "the rebind") { await x.rebindUserScopedStorage() }
        let lateReason = await reason(late)
        XCTAssertEqual(lateReason, "identity-changed")
        let earlyReason = await reason(handles[0])
        XCTAssertEqual(earlyReason, "resolved", "the earlier handle had settled ready")
    }
}
