import Foundation
import XCTest
@testable import JsBaoClient

/// #5897 behavior 25 — a Swift device judges a typed db3's enforced enums with
/// the room's code and words, as js-bao's `declared-types.ts` does.
///
/// The cases are `Fixtures/Db3Enums/room-parity.json`, which the JS suite
/// (`record-log-client-enum-types-5897`) checks against the room and js-bao's
/// device: quotes, a slash, a control character, non-ASCII, the 20-value and
/// 64-code-unit limits, the empty string and Object.prototype-like names. The
/// code is `.db3ValueNotInEnum`, handed back under itself, and the client
/// declares wire version 4. The store keeps `enums` with the declarations, and
/// an entry held from before this change makes the next open omit
/// `db3TypeHash` once.
final class RecordLogEnumDeclaredTypesHermeticTests: XCTestCase {

    private static let fixtureURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/Db3Enums/room-parity.json")
    }()

    private var directories: [String] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    func testTheCheckerAnswersTheRoomsWordsForEverySharedCase() throws {
        let fixture = try XCTUnwrap(JSONValue(jsonText: String(contentsOf: Self.fixtureURL, encoding: .utf8))?.objectValue)
        let typeJSON = try XCTUnwrap(fixture["type"]?.objectValue)
        let models = try XCTUnwrap(typeJSON["models"]?.objectValue).mapValues { ($0.objectValue ?? [:]).compactMapValues(\.stringValue) }
        let enums = try XCTUnwrap(typeJSON["enums"].flatMap(recordLogEnumDeclarations))
        XCTAssertEqual(enums["tasks"]?["many"]?.count, 25)
        let type = RecordLogDeclaredType(name: try XCTUnwrap(typeJSON["name"]?.stringValue), models: models, enums: enums)
        var refused = 0
        for item in try XCTUnwrap(fixture["cases"]?.arrayValue) {
            let object = try XCTUnwrap(item.objectValue)
            let label = object["label"]?.stringValue ?? "?"
            let mutations = try (object["mutations"]?.arrayValue ?? []).map { try XCTUnwrap(RecordLogMutation(json: $0), label) }
            let problem = recordLogDeclaredTypeProblem(mutations, type)
            if let expected = object["problem"]?.objectValue {
                refused += 1
                XCTAssertEqual(problem?.code, .db3ValueNotInEnum, label)
                XCTAssertEqual(problem?.code.rawValue, expected["code"]?.stringValue, label)
                XCTAssertEqual(problem?.message, expected["message"]?.stringValue, label)
            } else {
                XCTAssertNil(problem.map { "\($0.code.rawValue): \($0.message)" }, label)
            }
        }
        XCTAssertEqual(refused, 14)
        // Without enums nothing is judged by the rule.
        let unenforced = RecordLogDeclaredType(name: "workspace", models: models)
        for item in fixture["cases"]?.arrayValue ?? [] {
            let mutations = (item["mutations"]?.arrayValue ?? []).compactMap { RecordLogMutation(json: $0) }
            XCTAssertNil(recordLogDeclaredTypeProblem(mutations, unenforced))
        }
    }

    func testJSONStringifysQuotingIsReproduced() {
        XCTAssertEqual(recordLogJSONStringify(#"a "q" / b\c"#), #""a \"q\" / b\\c""#)
        XCTAssertEqual(recordLogJSONStringify("a\nb\u{01}\u{1F}\t"), #""a\nb\u0001\u001f\t""#)
        XCTAssertEqual(recordLogJSONStringify("café ✓ 😀"), "\"café ✓ 😀\"")
    }

    func testTheCodeIsHandedBackUnderItselfAndTheClientDeclaresWireVersionFour() {
        XCTAssertEqual(JsBaoErrorCode(rawValue: "DB3_VALUE_NOT_IN_ENUM"), .db3ValueNotInEnum)
        XCTAssertTrue(RecordLogHandBackCode.all.contains("DB3_VALUE_NOT_IN_ENUM"))
        XCTAssertEqual(recordLogWireVersion, 4)
    }

    func testAThrownRefusalIsLocalAndReportedOnce() throws {
        var heard: [DocumentWriteRefusedEvent] = []
        let type = RecordLogDeclaredType(name: "workspace", models: ["tasks": ["status": "string"]], enums: ["tasks": ["status": ["open"]]])
        let mutation = try XCTUnwrap(RecordLogMutation(json: ["model": "tasks", "id": "t1", "kind": "create", "fields": ["status": "closed"]]))
        XCTAssertThrowsError(
            try assertRecordLogDeclaredTypes(documentId: "d1", mutations: [mutation], type: type, report: { heard.append($0) })
        ) { error in
            let error = error as? JsBaoError
            XCTAssertEqual(error?.code, .db3ValueNotInEnum)
            XCTAssertEqual(error?.message, #"m: tasks id=t1: field "status" takes one of open; the write is "closed""#)
            XCTAssertEqual(error?.details?["scope"], "local")
        }
        XCTAssertEqual(heard.count, 1)
    }

    func testAModelFreeWriteOfAnOutsideValueIsRefusedLocallyAndCommitsNothing() async throws {
        let directory = NSTemporaryDirectory() + "/db3-enum-records-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let documentId = "rl-enum-\(UUID().uuidString.prefix(8))"
        let binding = try RecordLogDocumentBinding(host: provider, documentId: documentId, clientId: "client-1", logger: Logger(level: .none))
        try binding.setState(type: .typed(
            name: "workspace", hash: "h1", models: ["tasks": ["status": "string", "title": "string"]],
            enums: ["tasks": ["status": ["open", "caf\u{E9}"]]]
        ))
        let refused = LockedBox<[DocumentWriteRefusedEvent]>([])
        binding.setRefusalReporter { event in refused.withValue { $0.append(event) } }
        let records = DocumentRecords(documentId: documentId) { binding }
        _ = try records.put("tasks", ["id": "r1", "status": "open"])
        let pending = try binding.store.pendingOf(binding.writer).count
        let cases: [(String, () throws -> Void, String)] = [
            ("put", { _ = try records.put("tasks", ["id": "r2", "status": "archived"]) },
             #"m: tasks id=r2: field "status" takes one of open, café; the write is "archived""#),
            ("patch", { _ = try records.patch("tasks", id: "r1", ["status": "archived"]) },
             #"m: tasks id=r1: field "status" takes one of open, café; the write is "archived""#),
            // Canonically equivalent to a member, but not the same code units: the room refuses it.
            ("decomposed", { _ = try records.patch("tasks", id: "r1", ["status": "cafe\u{301}"]) },
             "m: tasks id=r1: field \"status\" takes one of open, café; the write is \"cafe\u{301}\""),
        ]
        for (label, write, message) in cases {
            XCTAssertThrowsError(try write(), label) { error in
                let error = error as? JsBaoError
                XCTAssertEqual(error?.code, .db3ValueNotInEnum, label)
                XCTAssertEqual(error?.message, message, label)
                XCTAssertEqual(error?.details?["scope"], "local", label)
            }
        }
        XCTAssertEqual(refused.value.count, cases.count)
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).count, pending)
        XCTAssertEqual(try records.get("tasks", id: "r1")?["status"], "open")
        XCTAssertNil(try records.get("tasks", id: "r2"))
        // In-set (code unit for code unit), null and a patch of another field still write.
        _ = try records.patch("tasks", id: "r1", ["status": "caf\u{E9}"])
        _ = try records.patch("tasks", id: "r1", ["title": "b"])
        _ = try records.put("tasks", ["id": "r3", "status": .null])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).count, pending + 3)
    }

    typealias H = RecordLogReceiptHarness

    func testTheStoreKeepsEnumsAndAnEntryHeldWithoutThemOmitsTheHashOnce() async throws {
        let directory = NSTemporaryDirectory() + "/db3-enum-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(host: provider, documentId: H.documentId, clientId: "client-a", logger: Logger(level: .none))
        try binding.registerModel(H.schema)
        let connection = H.Connection(fetches: false)
        let synced = LockedBox(0)
        let session = RecordLogSession(
            documentId: H.documentId, binding: binding,
            host: RecordLogSessionHost(
                connection: { connection }, declarations: { [:] }, synced: { _ in synced.withValue { $0 += 1 } },
                syncFailed: { _, _ in }, waitsForTypeBeforeDeclaring: true
            ),
            timings: H.timings, logger: Logger(level: .none)
        )
        await session.attach()
        func feed(_ frame: [String: JSONValue]) async {
            var frame = frame
            frame["documentId"] = .string(H.documentId)
            await session.receive(frame)
        }
        func until(_ what: String, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(condition(), "timed out waiting for \(what)")
        }
        func reopen() async -> [String: JSONValue]? {
            await session.disconnected()
            let at = connection.frames.count
            await session.start()
            await until("an open") { connection.frames.dropFirst(at).contains { $0["type"]?.stringValue == "record.open" } }
            return connection.frames.dropFirst(at).first { $0["type"]?.stringValue == "record.open" }
        }
        func held() throws -> [String: JSONValue]? {
            let text = try provider.withConnection {
                try $0.query("SELECT value FROM record_log_meta WHERE key = ?", [.text("db3_type:\(H.documentId)")]).first?["value"].stringValue
            }
            return text.flatMap { JSONValue(jsonText: $0) }?.objectValue
        }
        let models: JSONValue = ["Note": ["title": "string", "status": "string"]]
        let enums: JSONValue = ["Note": ["status": ["a", "b"]]]
        var opened = H.opened(lsn: 0)
        opened["db3Type"] = ["name": "notes", "hash": "h1", "models": models, "enums": enums]
        await session.start()
        await feed(opened)
        await until("the open") { synced.value == 1 }
        XCTAssertEqual(binding.declaredType?.enums, ["Note": ["status": ["a", "b"]]])
        XCTAssertEqual(try held()?["enums"], enums)
        let first = await reopen()
        XCTAssertEqual(first?["db3TypeHash"]?.stringValue, "h1")
        XCTAssertEqual(first?["wireVersion"], 4)

        // The entry as a client from before enforced enums wrote it: no `enums` key.
        try provider.withConnection { connection in
            try connection.execute(
                "UPDATE record_log_meta SET value = ? WHERE key = ?",
                [.text(#"{"typed":"yes","name":"notes","hash":"h1","models":{"Note":{"title":"string","status":"string"}},"vectors":null}"#),
                 .text("db3_type:\(H.documentId)")]
            )
        }
        let omitted = await reopen()
        XCTAssertNotNil(omitted)
        XCTAssertNil(omitted?["db3TypeHash"])
        await feed(opened)
        await until("the second opened") { synced.value == 2 }
        XCTAssertEqual(try held()?["enums"], enums)
        let rewritten = await reopen()
        XCTAssertEqual(rewritten?["db3TypeHash"]?.stringValue, "h1")

        // A type enforcing none is held as `enums: null`.
        var plain = H.opened(lsn: 0)
        plain["db3Type"] = ["name": "notes", "hash": "h2", "models": models]
        await feed(plain)
        await until("the plain opened") { synced.value == 3 }
        XCTAssertEqual(try held()?["enums"], .null)
        XCTAssertEqual(binding.declaredType?.enums, [:])
    }
}
