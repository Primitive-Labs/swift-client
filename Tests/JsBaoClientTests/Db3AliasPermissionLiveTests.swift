import XCTest
@testable import JsBaoClient

/// #5054 behaviors 8 to 12 — `client.db3.getOrCreateWithAlias` with
/// `permission` against the dev server, the Swift twin of the JS client's
/// #5022 suite.
///
/// - 8: an app owner's own `reader` create is resident at `reader`: before a
///   subscribe a save is refused on the device and nothing is sent; after one
///   it is still refused and nothing lands.
/// - 9: an app owner's `reader` create for a member is the member's: the
///   owner's device adopts nothing, and the member reads rows the owner seeds
///   once granted `read-write`, and cannot write.
/// - 10: a member's `reader` create is refused 403 and creates nothing.
/// - 11: a member's default create is adopted as owner and writable.
/// - 12: an unknown level is 400 (a raw request; the Swift enum has no such case).
final class Db3AliasPermissionLiveTests: XCTestCase {

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
        let app = try await ctx.createTestApp(name: "swift-db3-alias-permission-5054")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// Push a db3 type of the Note schema, and answer its name.
    private func pushType() async throws -> String {
        let name = "swift-inbox-\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(name)", body: ["schema": Self.schema], jwt: live.app.ownerJWT
        )
        return name
    }

    private func aliasKey(_ base: String) -> String {
        "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// The HTTP status a raw app request answered (`nil` for a 2xx).
    private func rawStatus(_ method: String, _ path: String, _ body: [String: Any]?, jwt: String) async -> Int? {
        do {
            _ = try await ctx.appRequest(method: method, appId: live.app.appId, path: path, body: body, jwt: jwt)
            return nil
        } catch let error as TestSetupError {
            let words = error.message.split(separator: " ")
            return words.count > 1 && words[0] == "HTTP" ? Int(words[1]) : -1
        } catch {
            return -1
        }
    }

    private func titles(_ client: JsBaoClient, _ db3Id: String) throws -> [String] {
        try XCTUnwrap(client.sharedModel("Note")?.member(docId: db3Id)).query().compactMap { $0["title"]?.stringValue }.sorted()
    }

    private func roomTitles(_ db3Id: String, jwt: String) async throws -> [String] {
        try await ctx.roomRows(appId: live.app.appId, documentId: db3Id, model: "Note", jwt: jwt)
            .values.compactMap { $0["title"] as? String }.sorted()
    }

    /// A subscribed reader's save: refused on the device (`.accessDenied`),
    /// or handed back by the room (`WRITE_ACCESS_DENIED`). Answers which.
    private func refusedSave(_ client: JsBaoClient, _ db3Id: String) async throws -> String {
        let refusals = LockedBox<[Db3WriteRefusedEvent]>([])
        let heard = client.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in refusals.withValue { $0.append(event) } }
        defer { heard.cancel() }
        do {
            try client.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("still?")], in: db3Id)
        } catch let error as JsBaoError {
            return error.code.rawValue
        }
        try await eventually(timeout: 20, description: "the room's refusal") { !refusals.value.isEmpty }
        return refusals.value[0].error.code.rawValue
    }

    // MARK: - Behavior 8

    func testAnOwnersOwnReaderCreateRefusesASaveOnTheDeviceAndAfterASubscribe() async throws {
        let type = try await pushType()
        let owner = try await live.client("owner", models: [Self.note])
        let result = try await owner.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(
            alias: AliasRef(scope: .user, aliasKey: aliasKey("own-reader")), title: "Read-only for me", type: type, permission: .reader
        ))
        XCTAssertTrue(result.created)
        XCTAssertEqual(result.db3?.custodian, "user:\(live.app.ownerUserId)")
        let db3Id = result.id
        let state = try await owner.db3.state(db3Id)
        XCTAssertTrue(state.resident)
        XCTAssertFalse(state.subscribed)
        XCTAssertEqual(state.permission, .reader)

        let frames = LockedBox<[String]>([])
        owner.recordLogFrameSentForTest = { text in
            guard let frame = RecordLogJSON.parse(text)?.objectValue, frame["documentId"]?.stringValue == db3Id,
                  let kind = frame["type"]?.stringValue, kind.hasPrefix("record.") else { return }
            frames.withValue { $0.append(kind) }
        }
        XCTAssertThrowsError(
            try owner.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("mine?")], in: db3Id)
        ) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .accessDenied)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(frames.value, [], "no record frame for a refused save")
        owner.recordLogFrameSentForTest = nil
        let pending = try await owner.db3.state(db3Id).pendingWrites
        XCTAssertEqual(pending, 0)
        let read = try await owner.db3.get(db3Id)
        XCTAssertEqual(read.permission, .reader)
        let roomBefore = try await roomTitles(db3Id, jwt: live.app.ownerJWT)
        XCTAssertEqual(roomBefore, [])

        let handle = try owner.db3.subscribe(db3Id)
        try await handle.ready()
        let after = try await refusedSave(owner, db3Id)
        XCTAssertTrue(["ACCESS_DENIED", "WRITE_ACCESS_DENIED"].contains(after), after)
        let subscribed = try await owner.db3.state(db3Id)
        XCTAssertEqual(subscribed.permission, .reader)
        try await Task.sleep(nanoseconds: 500_000_000)
        let roomAfter = try await roomTitles(db3Id, jwt: live.app.ownerJWT)
        XCTAssertEqual(roomAfter, [])
        handle.dispose()
    }

    // MARK: - Behavior 9

    func testAnOwnersReaderCreateForAMemberIsTheMembersAndTheOwnersDeviceAdoptsNothing() async throws {
        let type = try await pushType()
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let owner = try await live.client("owner", models: [Self.note])
        let result = try await owner.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(
            alias: AliasRef(scope: .user, aliasKey: aliasKey("member-inbox"), userId: member.userId),
            title: "Member's inbox", type: type, permission: .reader
        ))
        XCTAssertTrue(result.created)
        let created = try XCTUnwrap(result.db3)
        XCTAssertEqual(created.custodian, "user:\(member.userId)")
        XCTAssertEqual(created.createdBy, member.userId)
        let db3Id = result.id
        let stored = try await owner.db3.stored()
        XCTAssertFalse(stored.map(\.id).contains(db3Id), "the owner's device does not keep it")
        let ownerState = try await owner.db3.state(db3Id)
        XCTAssertFalse(ownerState.resident)

        // The owner holds no grant on the member's synced db3 until they take one.
        let seed: [String: Any] = ["id": RecordLogLiveApp.ulid(), "data": ["title": "seeded"]]
        let refused = await rawStatus("POST", "/db3/\(db3Id)/records/Note", seed, jwt: live.app.ownerJWT)
        XCTAssertEqual(refused, 403)
        _ = try await owner.db3.permissions(db3Id).set(UpdatePermissionsData(userId: live.app.ownerUserId, permission: "read-write"))
        let seeded = await rawStatus("POST", "/db3/\(db3Id)/records/Note", seed, jwt: live.app.ownerJWT)
        XCTAssertNil(seeded, "seeded once granted read-write")

        let reader = try await live.client("member", models: [Self.note], token: member.jwt)
        let read = try await reader.db3.get(db3Id)
        XCTAssertEqual(read.permission, .reader)
        let handle = try reader.db3.subscribe(db3Id)
        try await handle.ready()
        try await eventually(timeout: 20, description: "the seeded row on the member's device") {
            try self.titles(reader, db3Id) == ["seeded"]
        }
        let outcome = try await refusedSave(reader, db3Id)
        XCTAssertTrue(["ACCESS_DENIED", "WRITE_ACCESS_DENIED"].contains(outcome), outcome)
        try await Task.sleep(nanoseconds: 500_000_000)
        let room = try await roomTitles(db3Id, jwt: live.app.ownerJWT)
        XCTAssertEqual(room, ["seeded"], "nothing the member wrote landed")
        handle.dispose()
    }

    // MARK: - Behavior 10

    func testAMembersReaderCreateIsRefusedAndCreatesNothing() async throws {
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        let failures = LockedBox<[Db3CreateFailedEvent]>([])
        let heard = client.eventEmitter.subscribe(Db3CreateFailedEvent.self) { event in failures.withValue { $0.append(event) } }
        defer { heard.cancel() }
        let before = try await client.db3.listMine().items.count
        do {
            _ = try await client.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: aliasKey("mine")), title: "Mine", permission: .reader
            ))
            XCTFail("a member's reader create should be refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
        try await eventually(description: "the refusal event") { !failures.value.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(failures.value.count, 1)
        let after = try await client.db3.listMine().items.count
        XCTAssertEqual(after, before, "no db3 created")
        let stored = try await client.db3.stored()
        XCTAssertEqual(stored, [])
    }

    // MARK: - Behavior 11

    func testAMembersDefaultCreateIsAdoptedAsOwnerAndWritable() async throws {
        let type = try await pushType()
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let client = try await live.client("member", models: [Self.note], token: member.jwt)
        let result = try await client.db3.getOrCreateWithAlias(Db3GetOrCreateWithAliasOptions(
            alias: AliasRef(scope: .user, aliasKey: aliasKey("mine")), title: "Mine", type: type
        ))
        XCTAssertTrue(result.created)
        XCTAssertEqual(result.db3?.custodian, "user:\(member.userId)")
        let state = try await client.db3.state(result.id)
        XCTAssertTrue(state.resident)
        XCTAssertEqual(state.permission, .owner)
        try client.codegen.save(Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("writable")], in: result.id)
        XCTAssertEqual(try titles(client, result.id), ["writable"])
        let handle = try client.db3.subscribe(result.id)
        try await handle.ready()
        try await live.settled(client, result.id)
        let room = try await roomTitles(result.id, jwt: member.jwt)
        XCTAssertEqual(room, ["writable"])
        handle.dispose()
    }

    // MARK: - Behavior 12

    func testAnUnknownLevelIsRefused400() async throws {
        let status = await rawStatus(
            "POST", "/db3/get-or-create-with-alias",
            ["alias": ["scope": "user", "aliasKey": aliasKey("admin-level")], "title": "Admin?", "permission": "admin"],
            jwt: live.app.ownerJWT
        )
        XCTAssertEqual(status, 400)
    }
}
