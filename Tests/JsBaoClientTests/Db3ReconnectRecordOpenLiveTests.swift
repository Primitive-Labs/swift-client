import XCTest
@testable import JsBaoClient

/// #5044 — a db3 opened through `client.db3` reconnects with `record.open`
/// only, against the dev server:
///
/// - 12: `getOrCreateWithAlias` on an alias that already exists (made on
///   another device) marks the db3 a db3 at once, before any subscribe.
/// - 13 (pin): after the connection drops and comes back, a db3 got by an
///   existing alias, one created here and one plainly subscribed each reopen
///   with `record.open`, no Yjs `syncStep1` goes out for any of them, and a
///   confirmed save lands in each.
final class Db3ReconnectRecordOpenLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-reconnect-5044")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func newAlias() -> AliasRef {
        AliasRef(scope: .user, aliasKey: "home-\(UUID().uuidString.prefix(6).lowercased())", userId: live.app.ownerUserId)
    }

    /// An alias another device created, got here.
    private func aliasGot(_ client: JsBaoClient) async throws -> String {
        let alias = newAlias()
        let elsewhere = try await live.client("elsewhere-\(RecordLogLiveApp.ulid().suffix(4))", models: [Self.note])
        let first = try await elsewhere.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(alias: alias, title: "Home"))
        XCTAssertTrue(first.created)
        await elsewhere.destroy()
        let got = try await client.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(alias: alias, title: "Home"))
        XCTAssertFalse(got.created)
        return got.id
    }

    // MARK: - Behaviour 12

    func testAnExistingAliasIsKnownAsADb3AtOnce() async throws {
        let x = try await live.client("x", models: [Self.note])
        let id = try await aliasGot(x)
        XCTAssertEqual(x.recordLogState.resolvedFormat(id), 3, "noted as a db3 before any subscribe")
        if x.documentManager.getLocalMetadata(id) != nil {
            XCTAssertEqual(x.documentManager.documentFormat(id), 3, "and on its row")
        }
        XCTAssertFalse(x._db3Lifecycle.isSubscribed(id))
    }

    // MARK: - Behaviour 13 (pin)

    func testEveryDb3OpenedThroughClientDb3ReconnectsWithRecordOpenOnly() async throws {
        let x = try await live.client("x", models: [Self.note])
        let aliased = try await aliasGot(x)
        let created = try await x.db3.create(title: "Created").id
        let plain = try await live.db3Written(1, model: "Note")
        let ids = [aliased, created, plain]
        var handles: [Db3Subscription] = []
        for id in ids {
            let handle = try x.db3.subscribe(id)
            try await settles(within: 30, "ready() of \(id)") { try await handle.ready() }
            handles.append(handle)
        }

        let opens = LockedBox<[String]>([])
        let handshakes = LockedBox<[String]>([])
        x.recordLogFrameSentForTest = { text in
            guard let frame = RecordLogJSON.parse(text)?.objectValue, frame["type"]?.stringValue == "record.open",
                  let id = frame["documentId"]?.stringValue else { return }
            opens.withValue { $0.append(id) }
        }
        x.onSyncStep1SendForTest = { id in handshakes.withValue { $0.append(id) } }

        await x.goOffline()
        XCTAssertFalse(x.isConnected)
        await x.goOnline()
        try await waitForConnection(client: x, timeout: 15)
        try await eventually(timeout: 30, description: "every db3 reopened") {
            Set(opens.value).isSuperset(of: ids)
        }
        for (index, id) in ids.enumerated() {
            try await eventually(timeout: 30, description: "\(id) live again") { handles[index].state.phase == .live }
            let notes = try live.member(x, id, "Note")
            try await settles(within: 15, "a confirmed save in \(id)") {
                _ = try await notes.save(id: "after", values: ["title": .string("reconnected")], confirm: true)
            }
            let room = try await live.roomRows(id, "Note")
            XCTAssertEqual(room["after"]?["title"] as? String, "reconnected")
        }
        XCTAssertEqual(handshakes.value.filter { ids.contains($0) }, [], "no Yjs handshake for a db3")
        for handle in handles { handle.dispose() }
    }
}
