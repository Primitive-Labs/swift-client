import XCTest
@testable import JsBaoClient

/// #5020 behaviors 6, 14 and 19 — the Swift client applies what the room
/// allows, against the dev server.
///
/// - 6: a member downgraded to `reader` is refused a `codegen.save` and a
///   `documents.records(id).put` on the device (`.accessDenied`, nothing
///   pending, no row on the server); restored to `read-write`, a save with
///   `confirm: true` lands with no resubscribe.
/// - 14: a typed db3 created here, and the same db3 subscribed on a fresh
///   device, are ready with the binding's marks saying typed by the type's
///   name and the room's hash; both read each other's rows, and a dispose
///   and a second subscribe keep the marks.
/// - 19: on a typed db3 declaring `closedAt` a date, a save of `""` throws the
///   room's code and message before anything is sent, reported as a
///   `Db3WriteRefusedEvent`; an ISO date lands.
final class Db3PermissionLocalLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "closedAt": FieldDescriptor(type: .date)]
    )

    private static let schema = """
    [models.Note]
    [models.Note.fields.id]
    type = "id"
    [models.Note.fields.title]
    type = "string"
    [models.Note.fields.closedAt]
    type = "date"
    """

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-local-5020")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func pushType() async throws -> String {
        let name = "swift-local-\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(name)", body: ["schema": Self.schema], jwt: live.app.ownerJWT
        )
        return name
    }

    private func until(
        _ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    private func refused(_ body: () async throws -> Void) async -> JsBaoError? {
        do {
            try await body()
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("unexpected \(error)")
            return nil
        }
    }

    // MARK: - Behavior 6

    func testAReaderUpdateRefusesSavesOnTheDeviceAndAReadWriteUpdateSavesAgainWithNoResubscribe() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let info = try await createdOnServer(owner, title: "Permissions")
        let db3Id = info.id
        let bob = try await ctx.createTestUser(appId: live.app.appId)
        _ = try await owner.db3.permissions(db3Id).set(.user(bob.userId, permission: "read-write"))

        let bobClient = try await live.client("bob", models: [Self.note], token: bob.jwt)
        let handle = try bobClient.db3.subscribe(db3Id)
        try await handle.ready()
        _ = try await bobClient.codegen.save(
            Self.note, id: RecordLogLiveApp.ulid(), values: ["title": .string("allowed")], in: db3Id, options: Db3WriteOptions(confirm: true)
        )
        let binding = try live.binding(bobClient, db3Id)

        _ = try await owner.db3.permissions(db3Id).set(.user(bob.userId, permission: "reader"))
        try await until("the reader permission on the device") { binding.marks.permission == RecordLogPermission.read }
        let pending = try live.pending(bobClient, db3Id).count
        let refusedId = RecordLogLiveApp.ulid()
        let save = await refused {
            _ = try bobClient.codegen.save(Self.note, id: refusedId, values: ["title": .string("while reading")], in: db3Id)
        }
        XCTAssertEqual(save?.code, .accessDenied)
        let put = await refused {
            _ = try bobClient.documents.records(db3Id).put("Note", ["id": .string(RecordLogLiveApp.ulid()), "title": .string("model-free")])
        }
        XCTAssertEqual(put?.code, .accessDenied)
        XCTAssertEqual(try live.pending(bobClient, db3Id).count, pending)
        try await Task.sleep(nanoseconds: 300_000_000)
        let rows = try await live.roomRows(db3Id, "Note")
        XCTAssertNil(rows[refusedId])

        _ = try await owner.db3.permissions(db3Id).set(.user(bob.userId, permission: "read-write"))
        try await until("the write permission on the device") { binding.marks.permission == nil }
        let restoredId = RecordLogLiveApp.ulid()
        _ = try await bobClient.codegen.save(
            Self.note, id: restoredId, values: ["title": .string("allowed again")], in: db3Id, options: Db3WriteOptions(confirm: true)
        )
        let after = try await live.roomRows(db3Id, "Note")
        XCTAssertNotNil(after[restoredId])
        XCTAssertTrue(bobClient.recordLogBinding(db3Id) === binding, "the same binding, no resubscribe")
        handle.dispose()
    }

    // MARK: - Behavior 14

    func testATypedDb3IsMarkedTypedOnTheCreatingDeviceAndOnAFreshOne() async throws {
        let type = try await pushType()
        let owner = try await live.client("owner", models: [Self.note])
        let info = try await owner.db3.create(title: "Typed", type: type)
        let first = try owner.db3.subscribe(info.id)
        try await first.ready()
        let ownerMarks = try live.binding(owner, info.id).refreshMarks()
        XCTAssertEqual(ownerMarks.typed, .yes)
        XCTAssertEqual(ownerMarks.db3Type?.name, type)
        let hash = try XCTUnwrap(ownerMarks.db3Type?.hash, "the room's revision hash")
        let ownerNote = RecordLogLiveApp.ulid()
        try owner.codegen.save(Self.note, id: ownerNote, values: ["title": .string("from the creator")], in: info.id)
        try await live.settled(owner, info.id)

        let fresh = try await live.client("fresh", models: [Self.note], token: live.app.ownerJWT)
        let second = try fresh.db3.subscribe(info.id)
        try await second.ready()
        let freshMarks = try live.binding(fresh, info.id).refreshMarks()
        XCTAssertEqual(freshMarks.typed, .yes)
        XCTAssertEqual(freshMarks.db3Type, RecordLogDb3Type(name: type, hash: hash))
        let freshMember = try live.member(fresh, info.id, "Note")
        try await until("the creator's note on the fresh device") { freshMember.find(id: ownerNote)?["title"] == .string("from the creator") }
        let freshNote = RecordLogLiveApp.ulid()
        _ = try await fresh.codegen.save(
            Self.note, id: freshNote, values: ["title": .string("from the fresh device")], in: info.id, options: Db3WriteOptions(confirm: true)
        )
        let ownerMember = try live.member(owner, info.id, "Note")
        try await until("the fresh device's note on the creator") { ownerMember.find(id: freshNote) != nil }

        second.dispose()
        try await until("the fresh device's subscription to close") { try await fresh.db3.state(info.id).phase == .idle }
        let again = try fresh.db3.subscribe(info.id)
        try await again.ready()
        XCTAssertEqual(try live.binding(fresh, info.id).refreshMarks().db3Type, RecordLogDb3Type(name: type, hash: hash))
        again.dispose()
        first.dispose()
    }

    // MARK: - Behavior 19

    func testADeclaredDateKindIsRefusedOnTheDeviceInTheRoomsWordsAndAnIsoDateLands() async throws {
        let type = try await pushType()
        let owner = try await live.client("owner", models: [Self.note])
        let info = try await createdOnServer(owner, title: "Kinds", type: type)
        let handle = try owner.db3.subscribe(info.id)
        try await handle.ready()
        let heard = ThreadSafeBox<[Db3WriteRefusedEvent]>([])
        let subscription = owner.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in heard.mutate { $0.append(event) } }
        let refusedId = RecordLogLiveApp.ulid()
        let error = await refused {
            _ = try owner.codegen.save(Self.note, id: refusedId, values: ["title": .string("closed"), "closedAt": .string("")], in: info.id)
        }
        XCTAssertEqual(error?.code, .documentEntryInvalid)
        XCTAssertEqual(
            error?.message, "m: Note id=\(refusedId): field \"closedAt\" is declared date; the entry wrote a string that is not an ISO date"
        )
        XCTAssertEqual(error?.details?["scope"], "local")
        XCTAssertEqual(heard.value.map(\.error.code), [.documentEntryInvalid])
        XCTAssertEqual(try live.pending(owner, info.id).count, 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        let rows = try await live.roomRows(info.id, "Note")
        XCTAssertNil(rows[refusedId])

        let datedId = RecordLogLiveApp.ulid()
        _ = try await owner.codegen.save(
            Self.note, id: datedId, values: ["title": .string("dated"), "closedAt": .string("2026-10-29T12:00:00.000Z")], in: info.id,
            options: Db3WriteOptions(confirm: true)
        )
        let landed = try await live.roomRows(info.id, "Note")
        XCTAssertNotNil(landed[datedId])
        withExtendedLifetime(subscription) {}
        handle.dispose()
    }
}
