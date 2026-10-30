import XCTest
@testable import JsBaoClient

/// #5020 behavior 5 and E8 — a permission the Swift client hears for a bound
/// db3 reaches its store: the twin of js-bao's `permissionChanged`.
///
/// `RecordLogDocumentBinding.applyPermissionChange` marks the store `read` on
/// `.reader` (a commit then throws `.accessDenied` and commits nothing) and
/// lifts it on `.readWrite`, `.admin` and `.owner`. A `refused` mark (a
/// revoked grant) is the room's to lift and never changes. The client applies
/// a `permission` frame, and a `docMetadata` frame carrying one, to the bound
/// db3 before the `PermissionEvent` is heard.
final class RecordLogPermissionChangeHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private func binding() async throws -> RecordLogDocumentBinding {
        let directory = NSTemporaryDirectory() + "/record-log-permission-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(host: provider, documentId: H.documentId, clientId: "client-a", logger: Logger(level: .none))
        try binding.registerModel(H.schema)
        return binding
    }

    private func save(_ binding: RecordLogDocumentBinding, _ id: String) throws -> Int {
        try binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: id, kind: .create, fields: ["title": "t"]),
        ])])[0].seq
    }

    func testAReaderUpdateMarksTheStoreReadAndACommitThrowsAccessDeniedCommittingNothing() async throws {
        let binding = try await binding()
        _ = try save(binding, "kept")
        let pending = try binding.refreshMarks().pending
        try binding.applyPermissionChange(.reader)
        XCTAssertEqual(try binding.refreshMarks().permission, RecordLogPermission.read)
        XCTAssertTrue(binding.isReadOnly)
        XCTAssertThrowsError(try save(binding, "refused")) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .accessDenied)
        }
        // E1's twin: what was committed before stays for the room to judge.
        XCTAssertEqual(try binding.refreshMarks().pending, pending)
        XCTAssertNil(try binding.store.read(model: "Note", id: "refused"))
    }

    func testAWriteCapableUpdateLiftsTheReadMarkAndTheNextCommitLands() async throws {
        for permission in [DocumentPermission.readWrite, .admin, .owner] {
            let binding = try await binding()
            try binding.applyPermissionChange(.reader)
            try binding.applyPermissionChange(permission)
            XCTAssertNil(try binding.refreshMarks().permission, "\(permission)")
            XCTAssertFalse(binding.isReadOnly)
            _ = try save(binding, "after")
            XCTAssertNotNil(try binding.store.read(model: "Note", id: "after"))
        }
    }

    func testNoUpdateChangesARefusedMark() async throws {
        let binding = try await binding()
        try binding.setState(permission: .some(RecordLogPermission.refused))
        for permission in [DocumentPermission.reader, .readWrite, .owner] {
            try binding.applyPermissionChange(permission)
            XCTAssertEqual(try binding.refreshMarks().permission, RecordLogPermission.refused, "\(permission)")
        }
    }

    func testAReaderUpdateOnABindingNeverOpenedStillMarksIt() async throws {
        let binding = try await binding()
        XCTAssertNil(try binding.refreshMarks().permission)
        try binding.applyPermissionChange(.reader)
        XCTAssertEqual(try binding.refreshMarks().permission, RecordLogPermission.read)
    }

    // MARK: - The client applies what it hears before the event

    private static let db3Id = "01JD5020PERMSW1FTXXXXXXXXX"

    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/db3-permission-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-permission-5020",
            token: makeTestJwt(userId: "user-a"), logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([H.schema])
        return client
    }

    func testTheClientAppliesAPermissionToABoundDb3BeforeThePermissionEvent() async throws {
        let client = try await client()
        try await client.bindStoredDb3(Self.db3Id)
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        let heard = LockedBox<[String?]>([])
        let subscription = client.eventEmitter.subscribe(PermissionEvent.self) { event in
            guard event.documentId == Self.db3Id else { return }
            heard.withValue { $0.append(binding.marks.permission) }
        }
        client.documentManager.setPermission(Self.db3Id, permission: .reader)
        XCTAssertEqual(binding.marks.permission, RecordLogPermission.read)
        client.documentManager.setPermission(Self.db3Id, permission: .readWrite)
        XCTAssertNil(binding.marks.permission)
        await client.documentManager.applyDocumentMetadataUpdate(
            documentId: Self.db3Id, metadata: ["permission": "reader"], changedFields: ["permission"], action: "updated", source: "server"
        )
        XCTAssertEqual(binding.marks.permission, RecordLogPermission.read)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(heard.value, [RecordLogPermission.read, nil, RecordLogPermission.read])
        withExtendedLifetime(subscription) {}
    }
}
