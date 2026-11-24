import XCTest
@testable import JsBaoClient

/// Signing one user out and another in, in the same process, against the dev
/// server. The client starts with A's session (its storage is bound to A),
/// A logs out, and C signs in with an email code. Nothing else is called: the
/// app does not rebind anything itself. C's db3 must then open as it does
/// after a relaunch: `available()` resolves, the room lists the subscriber,
/// and C's rows are readable. A token cleared other than by `logout()`
/// (whatever cause the caller names) releases A's db3s too, and A signing back
/// in binds them again. A subscribe right after a signed-out client's
/// `updateToken` is the new user's, and an older rebind never binds its user
/// over a newer one's.
@available(*, deprecated)
final class Db3SignInAnotherUserLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private var baseEmail = ""

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-sign-in-another-user")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
        // The `+primitivetest` bypass (code `000000`): OTP on, base address listed.
        baseEmail = "switch-\(UUID().uuidString.prefix(8).lowercased())@test.local"
        try await ctx.updateAppSettings(
            appId: app.appId,
            settings: ["emailSignInEnabled": true, "testAccountBaseEmails": [baseEmail]]
        )
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func titles(_ client: JsBaoClient, _ id: String) throws -> [String] {
        try client.sharedModel(for: Self.note).query(nil, options: QueryOptions(db3: [id]))
            .compactMap { $0["title"]?.stringValue }.sorted()
    }

    /// A's client holding A's own db3, then A out and C in by email code; C's db3 opens.
    private func signInAnotherUserThenOpen(wipeLocal: Bool, name: String) async throws {
        let local = baseEmail.split(separator: "@")[0]
        let emailC = "\(local)+primitivetest-\(name)@test.local"
        let userC = try await ctx.signInWithTestOtp(appId: live.app.appId, email: emailC)

        let own = try await live.db3Written(1, model: "Note")
        let theirs = try await live.db3Written(2, model: "Note")

        // The process starts with A's session and A's db3 resident.
        let x = try await live.client(name, models: [Self.note], file: live.file(name))
        try await live.residentOn(x, own)
        _ = try await x.db3.permissions(theirs).set(.user(userC, permission: "read-write"))

        try await settles(within: 15, "A's logout()") { try await x.logout(wipeLocal: wipeLocal) }
        let signedIn = try await x.auth.otpVerify(email: emailC, code: "000000")
        XCTAssertEqual(signedIn.user.userId, userC)
        XCTAssertEqual(x.auth.userId, userC)

        let subscription = try x.db3.subscribe(theirs)
        try await settles(within: 15, "C's available()") { try await subscription.available() }
        try await settles(within: 30, "C's ready()") { try await subscription.ready() }
        XCTAssertEqual(try titles(x, theirs), ["row 1", "row 2"], "C reads the room's rows")
        try await live.subscribersBecome(theirs, 1)
        let ownState = try await x.db3.state(own)
        XCTAssertFalse(ownState.resident, "A's db3 is not C's")
        subscription.dispose()
    }

    func testAnotherUsersSignInAfterALogoutOpensTheirDb3() async throws {
        try await signInAnotherUserThenOpen(wipeLocal: false, name: "keep")
    }

    func testAnotherUsersSignInAfterAWipingLogoutOpensTheirDb3() async throws {
        try await signInAnotherUserThenOpen(wipeLocal: true, name: "wipe")
    }

    /// The switch overlaps startup: the client's storage is bound to A and not
    /// ready yet when A logs out and C signs in. The sign-in returns only once
    /// startup is done and the storage is C's, so a subscription made right
    /// after it is C's: it is not ended by a rebind and becomes available.
    func testASignInWhileStorageIsStartingReturnsOnceTheStorageIsTheNewUsers() async throws {
        let local = baseEmail.split(separator: "@")[0]
        let emailC = "\(local)+primitivetest-starting@test.local"
        let userC = try await ctx.signInWithTestOtp(appId: live.app.appId, email: emailC)

        let theirs = try await live.db3Written(2, model: "Note")
        let granter = try await live.client("granter", models: [Self.note])
        _ = try await granter.db3.permissions(theirs).set(.user(userC, permission: "read-write"))

        // Startup holds once A is bound, before storage is ready.
        let reached = LockedBox(false)
        let release = RecordLogReceiptHarness.Gate()
        defer { release.open() }
        let x = live.startingClient("starting", models: [Self.note]) {
            reached.value = true
            await release.wait()
        }
        try await eventually(timeout: 10, description: "startup to bind A") { reached.value }
        XCTAssertEqual(x.documentManager.userId, live.app.ownerUserId, "precondition: storage bound to A")

        try await settles(within: 15, "A's logout()") { try await x.logout() }
        // The app subscribes as soon as the sign-in returns.
        let signIn = Task { () throws -> (OtpVerifyResult, Db3Subscription) in
            let result = try await x.auth.otpVerify(email: emailC, code: "000000")
            return (result, try x.db3.subscribe(theirs))
        }
        try await eventually(timeout: 15, description: "C's token to be applied") { x.auth.userId == userC }
        try await Task.sleep(nanoseconds: 500_000_000)
        release.open()

        let (signedIn, subscription) = try await signIn.value
        XCTAssertEqual(signedIn.user.userId, userC)
        XCTAssertEqual(x.documentManager.userId, userC, "the sign-in returned with the storage C's")
        try await settles(within: 15, "C's available()") { try await subscription.available() }
        try await settles(within: 30, "C's ready()") { try await subscription.ready() }
        XCTAssertEqual(try titles(x, theirs), ["row 1", "row 2"], "C reads the room's rows")
        subscription.dispose()
    }

    /// A sign-out that is not a `logout()` (`updateToken(nil)`, as a rejected
    /// refresh does) releases A's db3s: the one A held open is unbound and not
    /// resident. A signing back in with nothing else called binds it again.
    func testATokenClearedOtherThanByLogoutReleasesThePreviousUsersDb3s() async throws {
        try await clearTokenThenSignBackIn(cause: nil, name: "cleared")
    }

    /// The same when the caller names the cause `"logout"`: only `logout()`
    /// itself releases A's db3s in its own cleanup, so a token cleared through
    /// `updateToken(nil, cause: "logout")` is released by the rebind.
    func testATokenClearedWithTheLogoutCauseOtherThanByLogoutReleasesThePreviousUsersDb3s() async throws {
        try await clearTokenThenSignBackIn(cause: "logout", name: "cleared-logout-cause")
    }

    /// A signed-out client: another user's token applied with `updateToken`
    /// and a subscribe made right after it. The subscription is the new
    /// user's: no rebind ends it, and it becomes available with their rows.
    func testASubscribeRightAfterASignedOutClientsTokenBelongsToTheNewUser() async throws {
        let id = try await live.db3Written(2, model: "Note")
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let granter = try await live.client("granter", models: [Self.note])
        _ = try await granter.db3.permissions(id).set(.user(member.userId, permission: "read-write"))

        let x = await live.signedOutClient("signed-out", models: [Self.note])
        XCTAssertEqual(x.documentManager.userId, "", "precondition: storage bound to nobody")
        x.updateToken(member.jwt)
        let subscription = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))

        try await settles(within: 15, "the rebind") { await x.rebindUserScopedStorage() }
        XCTAssertEqual(x.documentManager.userId, member.userId, "the storage is the new user's")
        try await settles(within: 15, "the new user's available()") { try await subscription.available() }
        try await settles(within: 30, "the new user's ready()") { try await subscription.ready() }
        XCTAssertEqual(try titles(x, id), ["row 1", "row 2"], "the new user reads the room's rows")
        subscription.dispose()
    }

    /// The same while startup is held after binding nobody, before storage is
    /// ready: the subscribe made right after `updateToken` still belongs to
    /// the new user once startup is done.
    func testASubscribeRightAfterATokenWhileSignedOutStartupIsHeldBelongsToTheNewUser() async throws {
        let id = try await live.db3Written(2, model: "Note")
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let granter = try await live.client("granter", models: [Self.note])
        _ = try await granter.db3.permissions(id).set(.user(member.userId, permission: "read-write"))

        let reached = LockedBox(false)
        let release = RecordLogReceiptHarness.Gate()
        defer { release.open() }
        let x = await live.signedOutClient("signed-out-starting", models: [Self.note]) {
            reached.value = true
            await release.wait()
        }
        try await eventually(timeout: 10, description: "startup to bind nobody") { reached.value }
        x.updateToken(member.jwt)
        let subscription = try x.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        release.open()

        _ = await x.waitForStorageReady()
        try await settles(within: 15, "the rebind") { await x.rebindUserScopedStorage() }
        XCTAssertEqual(x.documentManager.userId, member.userId, "the storage is the new user's")
        try await settles(within: 15, "the new user's available()") { try await subscription.available() }
        try await settles(within: 30, "the new user's ready()") { try await subscription.ready() }
        XCTAssertEqual(try titles(x, id), ["row 1", "row 2"], "the new user reads the room's rows")
        subscription.dispose()
    }

    /// A → B → C in quick succession: B's rebind is held once it has read B,
    /// and C's token lands meanwhile. Once both rebinds finished the storage
    /// is C's, never B's, and C's db3 opens.
    func testAnOlderRebindNeverBindsItsUserOverANewerOne() async throws {
        let theirs = try await live.db3Written(2, model: "Note")
        let userB = try await ctx.createTestUser(appId: live.app.appId)
        let userC = try await ctx.createTestUser(appId: live.app.appId)
        let x = try await live.client("a-b-c", models: [Self.note], file: live.file("a-b-c"))
        _ = try await x.db3.permissions(theirs).set(.user(userC.userId, permission: "read-write"))

        let reached = RecordLogReceiptHarness.Gate()
        let release = RecordLogReceiptHarness.Gate()
        defer { release.open() }
        x.userScopeRebindHoldForTest = { userId in
            guard userId == userB.userId else { return }
            reached.open()
            await release.wait()
        }
        x.updateToken(userB.jwt)
        try await settles(within: 15, "B's rebind to read B") { await reached.wait() }
        x.updateToken(userC.jwt)
        // Long enough for a rebind of C not queued behind B's to finish.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        release.open()

        try await settles(within: 15, "the rebinds") { await x.rebindUserScopedStorage() }
        XCTAssertEqual(x.documentManager.userId, userC.userId, "the storage is C's, the latest user")
        XCTAssertFalse(x.db3IdentityOutgoing, "the db3s are nobody else's")
        let subscription = try x.db3.subscribe(theirs)
        try await settles(within: 15, "C's available()") { try await subscription.available() }
        try await settles(within: 30, "C's ready()") { try await subscription.ready() }
        XCTAssertEqual(try titles(x, theirs), ["row 1", "row 2"], "C reads the room's rows")
        subscription.dispose()
    }

    private func clearTokenThenSignBackIn(cause: String?, name: String) async throws {
        let own = try await live.db3Written(1, model: "Note")
        let x = try await live.client(name, models: [Self.note], file: live.file(name))
        let held = try x.db3.subscribe(own)
        try await settles(within: 30, "A's ready()") { try await held.ready() }
        XCTAssertTrue(x.isRecordLogDocument(own), "precondition: A's db3 bound")

        x.updateToken(nil, cause: cause)
        try await eventually(timeout: 15, description: "A's db3 released") { !x.isRecordLogDocument(own) }
        let signedOut = try await x.db3.state(own)
        XCTAssertFalse(signedOut.resident, "nobody's db3 is resident while signed out")

        x.updateToken(live.app.ownerJWT)
        let again = try x.db3.subscribe(own)
        try await settles(within: 15, "A's available() after signing back in") { try await again.available() }
        XCTAssertEqual(try titles(x, own), ["row 1"])
        again.dispose()
        held.dispose()
    }
}
