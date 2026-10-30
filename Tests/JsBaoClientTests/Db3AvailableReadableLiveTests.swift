import XCTest
@testable import JsBaoClient

/// #5044 — once `available()` returns, a model query scoped to the db3
/// answers its rows, against the dev server:
///
/// - 1: a relaunch over the same file, subscribed at once while the start-up
///   bind is held: at `available()` the store is bound, the query answers the
///   stored rows and the state reads resident; the binding at `available()` is
///   the one at `ready()`, and the start-up bind mints no second writer.
/// - 2 (pin): right after `client.db3.create` with its `POST db3` held, and
///   right after an alias create, the query answers the row saved before at
///   `available()` and every 20 ms until `ready()`.
/// - 3: a sign-in on the running client (`logout()`, then the same user's
///   `updateToken` and `rebindUserScopedStorage()` with its bind held),
///   subscribed at once: at `available()` the query answers the kept rows.
/// - 6: a stored copy with no metadata row, subscribed with networking
///   stopped, is a db3 by its store: the open binds it, `available()` returns
///   and its format is recorded as 3.
final class Db3AvailableReadableLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-available-5044")
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

    /// A start-up (or sign-in) bind held at `db3BindHoldForTest` until `release` opens.
    private final class BindHold: @unchecked Sendable {
        let reached = RecordLogReceiptHarness.Gate()
        let release = RecordLogReceiptHarness.Gate()

        func install(_ client: JsBaoClient) {
            client.db3BindHoldForTest = { [self] _ in
                reached.open()
                await release.wait()
            }
        }
    }

    /// A client over `file` whose start-up bind of the stored db3s is held.
    private func relaunched(_ file: String, hold: BindHold) async throws -> JsBaoClient {
        let client = createTestClient(
            appId: live.app.appId, token: live.app.ownerJWT, storageConfig: .sqlite(directory: file), autoNetwork: true
        )
        hold.install(client)
        client.registerModels([Self.note])
        await hold.reached.wait()
        return client
    }

    // MARK: - Behaviour 1

    func testARelaunchSubscribedWhileTheStartUpBindIsHeldAnswersAtAvailable() async throws {
        let id = try await live.db3Written(3, model: "Note")
        let file = live.file("relaunch")
        let x = try await live.client("x", models: [Self.note], file: file)
        try await live.residentOn(x, id)
        await x.destroy()

        let hold = BindHold()
        let x2 = try await relaunched(file, hold: hold)
        XCTAssertFalse(x2.isRecordLogDocument(id), "the start-up bind is held")
        let handle = try x2.db3.subscribe(id)
        try await handle.available()
        XCTAssertTrue(x2.isRecordLogDocument(id), "bound at available()")
        XCTAssertEqual(try titles(x2, id), ["row 1", "row 2", "row 3"])
        let state = try await x2.db3.state(id)
        XCTAssertTrue(state.resident)
        let atAvailable = try live.binding(x2, id)
        let writers = try atAvailable.store.storedState().writers.count

        hold.release.open()
        x2.db3BindHoldForTest = nil
        _ = await x2.waitForStorageReady(timeout: 15)
        try await handle.ready()
        XCTAssertTrue(try live.binding(x2, id) === atAvailable, "one binding from available() to ready()")
        XCTAssertEqual(try atAvailable.store.storedState().writers.count, writers, "the start-up bind minted no second writer")
        handle.dispose()
    }

    // MARK: - Behaviour 2 (pin)

    /// The query answers `expected` now and every 20 ms until `handle` is ready.
    private func answersUntilReady(_ client: JsBaoClient, _ id: String, _ handle: Db3Subscription, _ expected: [String]) async throws {
        let deadline = Date().addingTimeInterval(30)
        while handle.readyResult == nil {
            XCTAssertEqual(try titles(client, id), expected)
            guard Date() < deadline else { return XCTFail("ready() did not settle") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await handle.ready()
        XCTAssertEqual(try titles(client, id), expected)
    }

    func testRightAfterACreateAndAnAliasCreateTheQueryAnswersAtAvailable() async throws {
        let owner = try await live.client("owner", models: [Self.note])

        let held = heldDb3Commit(owner)
        let info = try await owner.db3.create(title: "Held")
        _ = try live.member(owner, info.id, "Note").save(id: "n1", values: ["title": .string("saved first")])
        let created = try owner.db3.subscribe(info.id)
        try await created.available()
        XCTAssertEqual(try titles(owner, info.id), ["saved first"])
        held.open()
        try await answersUntilReady(owner, info.id, created, ["saved first"])
        created.dispose()

        let alias = AliasRef(scope: .user, aliasKey: "home-\(UUID().uuidString.prefix(6).lowercased())", userId: live.app.ownerUserId)
        let got = try await owner.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(alias: alias, title: "Home"))
        XCTAssertTrue(got.created)
        let aliasId = try XCTUnwrap(got.db3?.id)
        _ = try live.member(owner, aliasId, "Note").save(id: "n1", values: ["title": .string("alias first")])
        let aliased = try owner.db3.subscribe(aliasId)
        try await aliased.available()
        try await answersUntilReady(owner, aliasId, aliased, ["alias first"])
        aliased.dispose()
    }

    // MARK: - Behaviour 3

    func testASignInOnTheRunningClientSubscribedWhileItsBindIsHeldAnswersAtAvailable() async throws {
        let id = try await live.db3Written(2, model: "Note")
        let x = try await live.client("x", models: [Self.note], file: live.file("sign-in"))
        try await live.residentOn(x, id)
        try await x.logout()
        XCTAssertFalse(x.isRecordLogDocument(id))

        let hold = BindHold()
        hold.install(x)
        let ownerJWT = live.app.ownerJWT
        let signIn = Task {
            x.updateToken(ownerJWT)
            await x.rebindUserScopedStorage()
        }
        await hold.reached.wait()
        let handle = try x.db3.subscribe(id)
        try await handle.available()
        XCTAssertTrue(x.isRecordLogDocument(id), "bound at available()")
        XCTAssertEqual(try titles(x, id), ["row 1", "row 2"])
        let state = try await x.db3.state(id)
        XCTAssertTrue(state.resident)

        hold.release.open()
        x.db3BindHoldForTest = nil
        await signIn.value
        try await handle.ready()
        XCTAssertEqual(try titles(x, id), ["row 1", "row 2"])
        handle.dispose()
    }

    // MARK: - Behaviour 6

    func testAStoredCopyWithNoRowSubscribedOfflineIsADb3ByItsStore() async throws {
        let id = try await live.db3Written(2, model: "Note")
        let file = live.file("no-row")
        let x = try await live.client("x", models: [Self.note], file: file)
        try await live.residentOn(x, id)
        await x.destroy()

        // The metadata row goes; the record-log store keeps the copy.
        let hold = BindHold()
        let x2 = try await relaunched(file, hold: hold)
        x2.setNetworkMode(.offline)
        try await x2.offlineStore.deleteMetadata(appId: live.app.appId, userId: live.app.ownerUserId, documentId: id)
        await x2.documentManager.resetInMemoryUserState(userId: live.app.ownerUserId)
        await x2.documentManager.loadLocalMetadata()
        XCTAssertNil(x2.documentManager.getLocalMetadata(id), "no metadata row for the db3")
        XCTAssertNil(x2.documentManager.documentFormat(id))

        let handle = try x2.db3.subscribe(id)
        try await within(15, "available() over the stored copy") { try await handle.available() }
        XCTAssertTrue(x2.isRecordLogDocument(id))
        XCTAssertEqual(try titles(x2, id), ["row 1", "row 2"])
        XCTAssertEqual(x2.documentManager.documentFormat(id) ?? x2.recordLogState.resolvedFormat(id), 3)
        XCTAssertEqual(x2.recordLogState.resolvedFormat(id), 3, "noted as a db3")

        hold.release.open()
        x2.db3BindHoldForTest = nil
        handle.dispose()
    }
}
