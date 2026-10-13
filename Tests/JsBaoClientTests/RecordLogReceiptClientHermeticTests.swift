import XCTest
@testable import JsBaoClient

/// The client's side of a receipt without a server: the socket connection
/// fetches artifacts (so its opens declare `accepts`), a test hook sees and
/// can fail each artifact read before it goes out, and a `record.load` frame
/// for a document with no session is dropped at debug.
final class RecordLogReceiptClientHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func makeClient() async -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/rl-receipt-client-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:9",
            wsUrl: "ws://127.0.0.1:1",
            appId: "record-log-receipt-client-app",
            token: makeTestJwt(userId: "record-log-receipt-user"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .debug,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        return client
    }

    func testARecordLoadFrameForADocumentWithNoSessionIsDroppedAtDebug() async throws {
        let heard = LockedBox<[(LogLevel, String)]>([])
        Logger.lineForTest = { level, _, message in
            if message.contains("record.load") { heard.withValue { $0.append((level, message)) } }
        }
        let client = await makeClient()
        await client.routeRecordLogFrame([
            "type": "record.load", "phase": "complete", "documentId": "01JD4312N0SESS10NXXXXXXXXX", "sessionId": "S1",
        ])
        XCTAssertEqual(heard.value.map(\.0), [.debug])
        XCTAssertEqual(heard.value.first?.1, "[record-log] dropped record.load for a document with no session")
    }

    func testTheSocketConnectionFetchesArtifactsThroughTheClientAndOneWithoutAFetchDoesNot() async throws {
        let plain = RecordLogSocketConnection(send: { _ in }, isOpen: { true })
        XCTAssertFalse(plain.fetchesArtifacts)
        let fetching = RecordLogSocketConnection(send: { _ in }, isOpen: { true }, fetch: { path in Data(path.utf8) })
        XCTAssertTrue(fetching.fetchesArtifacts)
        let bytes = try await fetching.fetchArtifact("/doc-artifact/t/manifest")
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "/doc-artifact/t/manifest")
    }

    func testTheClientsArtifactReadPassesTheGrantPathToItsTestHookFirst() async throws {
        let client = await makeClient()
        let seen = LockedBox<[String]>([])
        client.recordLogArtifactFetchForTest = { path in
            seen.withValue { $0.append(path) }
            throw RecordLogArtifactError(status: 403, path: path)
        }
        do {
            _ = try await client.fetchRecordLogArtifact("/doc-artifact/tok3n/Note/0.A")
            XCTFail("the hook's refusal is the read's")
        } catch let error as RecordLogArtifactError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.description, "GET /doc-artifact/…/Note/0.A answered 403", "the grant token is never shown")
        }
        XCTAssertEqual(seen.value, ["/doc-artifact/tok3n/Note/0.A"])
        XCTAssertEqual(recordLogShownPath("/doc-artifact/tok3n"), "/doc-artifact/…")
        XCTAssertEqual(recordLogShownPath("/other/path"), "/other/path")
    }
}
