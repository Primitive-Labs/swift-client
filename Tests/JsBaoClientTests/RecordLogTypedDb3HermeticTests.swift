import XCTest
@testable import JsBaoClient

/// #4802 behavior 33 — a typed db3 in the Swift client: the twin of js-bao's
/// `record-log-client-typed-db3-4802` suite.
///
/// `JsBaoErrorCode.db3DeclarationRefusedTyped` and `.db3ModelNotDeclared` are
/// the JS client's strings verbatim, and a write is handed back under the
/// second. A typed db3's room answers `record.declare` with an `error`
/// `DB3_DECLARATION_REFUSED_TYPED`: the session takes it as the declaration
/// acknowledged (the `declared` hook told, nothing failed, nothing declared
/// again).
final class RecordLogTypedDb3HermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private struct Typed {
        let binding: RecordLogDocumentBinding
        let session: RecordLogSession
        let connection: H.Connection
        let declared: LockedBox<Int>
        let failed: LockedBox<[String]>
        let synced: LockedBox<Int>

        func feed(_ frame: [String: JSONValue]) async {
            var frame = frame
            frame["documentId"] = .string(H.documentId)
            await session.receive(frame)
        }
    }

    private func session() async throws -> Typed {
        let directory = NSTemporaryDirectory() + "/record-log-typed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(host: provider, documentId: H.documentId, clientId: "client-a", logger: Logger(level: .none))
        try binding.registerModel(H.schema)
        let connection = H.Connection(fetches: false)
        let declared = LockedBox(0)
        let failed = LockedBox<[String]>([])
        let synced = LockedBox(0)
        let session = RecordLogSession(
            documentId: H.documentId, binding: binding,
            host: RecordLogSessionHost(
                connection: { connection },
                declarations: { ["Note": .object(["fields": .object(["title": .object(["type": "string"])])])] },
                synced: { _ in synced.withValue { $0 += 1 } },
                syncFailed: { _, reason in failed.withValue { $0.append(reason) } },
                declared: { _ in declared.withValue { $0 += 1 } }
            ),
            timings: H.timings, logger: Logger(level: .verbose)
        )
        await session.attach()
        return Typed(binding: binding, session: session, connection: connection, declared: declared, failed: failed, synced: synced)
    }

    private func until(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    private let typedRefusal: [String: JSONValue] = [
        "type": "error", "messageType": "record.declare", "code": "DB3_DECLARATION_REFUSED_TYPED", "db3Type": "notes",
        "message": "This db3 is typed by notes: its type declares its models, and nothing was declared",
    ]

    func testTheCodesAreTheJsClientsStringsAndTheModelCodeIsAHandBackCode() {
        XCTAssertEqual(JsBaoErrorCode.db3DeclarationRefusedTyped.rawValue, "DB3_DECLARATION_REFUSED_TYPED")
        XCTAssertEqual(JsBaoErrorCode.db3ModelNotDeclared.rawValue, "DB3_MODEL_NOT_DECLARED")
        XCTAssertTrue(RecordLogHandBackCode.all.contains("DB3_MODEL_NOT_DECLARED"))
    }

    func testATypedDeclarationRefusalIsAnAcknowledgedDeclaration() async throws {
        let t = try await session()
        await t.session.start()
        await t.feed(H.opened(lsn: 0))
        await until("open") { t.synced.value == 1 }
        let declares = t.connection.all("record.declare").count
        XCTAssertGreaterThanOrEqual(declares, 1)
        await t.feed(typedRefusal)
        await until("declared") { t.declared.value == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(t.declared.value, 1)
        XCTAssertEqual(t.failed.value, [])
        XCTAssertEqual(t.connection.all("record.declare").count, declares)
    }

    func testATypedDeclarationRefusalDuringTheOpenDoesNotFailIt() async throws {
        let t = try await session()
        await t.session.start()
        await t.feed(typedRefusal)
        await t.feed(H.opened(lsn: 0))
        await until("open") { t.synced.value == 1 }
        XCTAssertEqual(t.failed.value, [])
        XCTAssertEqual(t.declared.value, 1)
    }

    func testAWriteToAnUndeclaredModelIsHandedBackUnderItsOwnCode() async throws {
        let t = try await session()
        await t.session.start()
        await t.feed(H.opened(lsn: 0))
        await until("open") { t.synced.value == 1 }
        let mutation = RecordLogMutation(model: "Note", id: "r1", kind: .create, fields: ["title": "x"])
        let seq = try t.binding.commit([RecordLogWrite(mutations: [mutation])])[0].seq
        async let acknowledged: Void = t.binding.whenAcknowledged(seq)
        await t.feed([
            "type": "record.refused", "seq": .number(Double(seq)), "code": "DB3_MODEL_NOT_DECLARED", "scope": "entry",
            "from": .number(Double(seq)), "records": [.object(["model": "Note", "id": "r1", "from": .number(Double(seq))])],
            "message": "m: Task is not a model of the db3's type notes; it declares Note",
        ])
        do {
            try await acknowledged
            XCTFail("the acknowledgement should throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3ModelNotDeclared)
        }
    }
}
