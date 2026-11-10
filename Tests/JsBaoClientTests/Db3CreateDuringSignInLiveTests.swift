import XCTest
@testable import JsBaoClient

/// #5204 — a db3 created right after a sign-in, while the sign-in's identity
/// release is still in progress, opens and goes live, against the dev server.
///
/// The release is held at `db3CloseHoldForTest` (the previous user's open
/// closing), the socket connects as the new user during the hold, and the
/// create is made during the hold too. Once the hold opens, the create's
/// `POST db3` reaches the server and the subscription's `ready()` resolves
/// well inside its 30 s bound, on every one of 20 runs. A local-only create
/// made during the hold is kept as the new user's and goes live too.
final class Db3CreateDuringSignInLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-create-sign-in-5204")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// The lifecycle's closes, held until `release` opens.
    private final class CloseHold: @unchecked Sendable {
        let reached = RecordLogReceiptHarness.Gate()
        let release = RecordLogReceiptHarness.Gate()

        func install(_ client: JsBaoClient) {
            client.db3CloseHoldForTest = { [self] _ in
                reached.open()
                await release.wait()
            }
        }
    }

    func testADb3CreatedDuringTheSignInsReleaseGoesLiveOnEveryRun() async throws {
        let member = try await ctx.createTestUser(appId: live.app.appId)
        for run in 1...20 {
            // The previous user's client, its socket down, holding a db3 open.
            let x = createTestClient(
                appId: live.app.appId, token: live.app.ownerJWT,
                storageConfig: .sqlite(directory: live.file("run-\(run)")), autoNetwork: false
            )
            _ = await x.waitForStorageReady()
            let previous = try await x.db3.create(title: "previous user's")
            let held = try x.db3.subscribe(previous.id)
            try await eventually(timeout: 10, description: "the previous user's open (run \(run))") {
                x.documentManager.isOpen(previous.id)
            }

            // The sign-in: its release holds at the previous user's close, and
            // the socket connects as the new user meanwhile.
            let hold = CloseHold()
            hold.install(x)
            x.updateToken(member.jwt, cause: "otpVerify")
            let rebind = Task { await x.rebindUserScopedStorage() }
            await hold.reached.wait()
            try await x.connect()
            try await waitForConnection(client: x, timeout: 10)

            let create = Task { try await x.db3.create(title: "probe \(run)") }
            try await Task.sleep(nanoseconds: 200_000_000)
            hold.release.open()
            x.db3CloseHoldForTest = nil
            try await settles(within: 15, "the rebind (run \(run))") { _ = await rebind.value }
            let info = try await create.value

            let subscription = try x.db3.subscribe(info.id)
            try await settles(within: 15, "ready() of the new db3 (run \(run))") { try await subscription.ready() }
            let state = try await x.db3.state(info.id)
            XCTAssertEqual(state.phase, .live, "run \(run)")
            XCTAssertFalse(state.pendingCreate, "run \(run)")
            let onServer = try await x.db3.get(info.id)
            XCTAssertEqual(onServer.id, info.id, "the server has the db3 (run \(run))")
            subscription.dispose()
            held.dispose()
            await x.destroy()
        }
    }

    func testALocalOnlyDb3CreatedDuringTheSignInsReleaseIsKeptForTheNewUser() async throws {
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let x = createTestClient(
            appId: live.app.appId, token: live.app.ownerJWT, storageConfig: .sqlite(directory: live.file("local-only")), autoNetwork: false
        )
        _ = await x.waitForStorageReady()
        let previous = try await x.db3.create(title: "previous user's")
        let held = try x.db3.subscribe(previous.id)
        try await eventually(timeout: 10, description: "the previous user's open") { x.documentManager.isOpen(previous.id) }

        let hold = CloseHold()
        hold.install(x)
        x.updateToken(member.jwt, cause: "otpVerify")
        let rebind = Task { await x.rebindUserScopedStorage() }
        await hold.reached.wait()
        let create = Task { try await x.db3.create(title: "scratch", localOnly: true) }
        try await Task.sleep(nanoseconds: 200_000_000)
        hold.release.open()
        x.db3CloseHoldForTest = nil
        try await settles(within: 15, "the rebind") { _ = await rebind.value }
        let info = try await create.value
        XCTAssertEqual(info.localOnly, true)

        let subscription = try x.db3.subscribe(info.id)
        try await settles(within: 15, "ready() of the local-only db3") { try await subscription.ready() }
        let state = try await x.db3.state(info.id)
        XCTAssertEqual(state.phase, .live)
        XCTAssertTrue(state.resident)
        XCTAssertTrue(x.isLocalOnlyDb3Row(info.id), "its row is the new user's")
        subscription.dispose()
        held.dispose()
    }

    /// A create made during one sign-in's held release while a further user
    /// signs in before it was kept: the create throws `identity-changed`,
    /// whatever its kind, and nothing of it is the further user's.
    private func createOvertakenByAnotherSignIn(
        _ name: String, localOnly: Bool
    ) async throws -> (client: JsBaoClient, error: Error?, held: Db3Subscription) {
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let further = try await ctx.createTestUser(appId: live.app.appId)
        let x = createTestClient(
            appId: live.app.appId, token: live.app.ownerJWT, storageConfig: .sqlite(directory: live.file(name)), autoNetwork: false
        )
        _ = await x.waitForStorageReady()
        let previous = try await x.db3.create(title: "previous user's")
        let held = try x.db3.subscribe(previous.id)
        try await eventually(timeout: 10, description: "the previous user's open") { x.documentManager.isOpen(previous.id) }

        let hold = CloseHold()
        hold.install(x)
        x.updateToken(member.jwt, cause: "otpVerify")
        let rebind = Task { await x.rebindUserScopedStorage() }
        await hold.reached.wait()
        let create = Task { try await x.db3.create(title: "member's \(name)", localOnly: localOnly) }
        try await eventually(timeout: 10, description: "the create waiting for the release") { x.db3IdentityRelease.waiting > 0 }

        x.updateToken(further.jwt, cause: "otpVerify")
        let furtherRebind = Task { await x.rebindUserScopedStorage() }
        hold.release.open()
        x.db3CloseHoldForTest = nil
        try await settles(within: 15, "the member's rebind") { _ = await rebind.value }
        try await settles(within: 15, "the further user's rebind") { _ = await furtherRebind.value }
        try await settles(within: 15, "the overtaken create") { _ = try? await create.value }
        let error: Error?
        do { _ = try await create.value; error = nil } catch let caught { error = caught }
        return (x, error, held)
    }

    private func assertIdentityChanged(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? JsBaoError else {
            return XCTFail("the create returned or threw \(String(describing: error)), not identity-changed", file: file, line: line)
        }
        XCTAssertEqual(error.code, .invalidArgument, file: file, line: line)
        XCTAssertEqual(error.details?["reason"], .string("identity-changed"), file: file, line: line)
    }

    func testADb3CreateOvertakenByAnotherSignInIsNeverTheFurtherUsers() async throws {
        let (x, error, held) = try await createOvertakenByAnotherSignIn("overtaken", localOnly: false)
        assertIdentityChanged(error)
        XCTAssertEqual(x.db3PendingCreates(), [], "no pending create is the further user's")
        try await x.connect()
        try await waitForConnection(client: x, timeout: 10)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let mine = try await x.db3.listMine()
        XCTAssertFalse(mine.items.contains { $0.title == "member's overtaken" }, "the server holds no such db3 for the further user")
        held.dispose()
        await x.destroy()
    }

    func testALocalOnlyDb3CreateOvertakenByAnotherSignInIsNeverTheFurtherUsers() async throws {
        let (x, error, held) = try await createOvertakenByAnotherSignIn("overtaken-local-only", localOnly: true)
        assertIdentityChanged(error)
        let stored = try await x.db3.stored()
        XCTAssertFalse(stored.contains { $0.localOnly }, "no local-only db3 is the further user's")
        held.dispose()
        await x.destroy()
    }
}
