import XCTest
@testable import JsBaoClient

/// A declared format the room disagrees with, on a real Durable Object (#3764,
/// behavior 21).
///
/// The hermetic suite beside this shows the declaration reaching the wire and
/// the teardown the refusal frame drives. What only a real room can say is that
/// the room refuses the declaration at all, answers the frame this client knows
/// how to read, and — decision D1 — does NOT close the socket over one
/// document's disagreement.
///
/// Shaped like `Format2ColdLoadLiveTests`' behavior-31 row, with its positive
/// control: the same document opened by this client's own front door, which must
/// still work after the raw socket has been refused.
final class Format2FormatMismatchLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var testApp: TestApp!
    private var directory: String!
    private var clients: [JsBaoClient] = []
    private var documentId: String!

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
        ]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-f2-mismatch")
        directory = NSTemporaryDirectory() + "f2-mismatch-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        try? FileManager.default.removeItem(atPath: directory)
        await ctx?.cleanup()
    }

    private func makeClient(databasePath: String) async -> JsBaoClient {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            storageConfig: .sqlite(directory: databasePath),
            autoNetwork: true,
            logLevel: .warn
        )
        client.registerModels([Self.schema])
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    private struct RawHandshake {
        let closed: Bool
        let errorCode: String?
        let declared: Int?
        let actual: Int?
        let sawEpochInfo: Bool
    }

    /// Answer the handshake by hand, declaring `documentFormat`.
    private func openRawSocket(declaring documentFormat: Int) async throws -> RawHandshake {
        var components = URLComponents(
            string: "\(TestConfig.wsUrl)/app/\(testApp.appId)/ws"
        )!
        components.queryItems = [
            URLQueryItem(name: "connectionId", value: UUID().uuidString),
            URLQueryItem(name: "token", value: testApp.ownerJWT),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(
            TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id"
        )
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel() }

        let frame: [String: Any] = [
            "type": "syncStep1",
            "documentId": documentId!,
            "stateVector": [Int](),
            "formats": Format2Transport.formats,
            "manifestVersion": Format2Transport.manifestVersion,
            "documentFormat": documentFormat,
        ]
        try await task.send(.string(String(
            data: try JSONSerialization.data(withJSONObject: frame), encoding: .utf8
        )!))

        var errorCode: String?
        var declared: Int?
        var actual: Int?
        var sawEpochInfo = false
        // Bounded: the refusal is the room's answer to this one frame, and
        // nothing follows it. A few seconds of listening afterwards is what
        // makes "the socket stayed open" a fact rather than an assumption.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            do {
                let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                    group.addTask { try await task.receive() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        throw CancellationError()
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                guard case .string(let text) = message,
                      let json = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                        as? [String: Any]
                else { continue }
                if json["type"] as? String == "epoch.info" { sawEpochInfo = true }
                if json["type"] as? String == "error" {
                    let detail = json["detail"] as? [String: Any]
                    errorCode = detail?["code"] as? String ?? json["code"] as? String
                    declared = (detail?["declared"] as? NSNumber)?.intValue
                    actual = (detail?["actual"] as? NSNumber)?.intValue
                    break
                }
            } catch is CancellationError {
                // Nothing more is coming, and the socket is still open — which
                // is the claim D1 makes.
                break
            } catch {
                return RawHandshake(
                    closed: true, errorCode: errorCode, declared: declared,
                    actual: actual, sawEpochInfo: sawEpochInfo
                )
            }
        }
        return RawHandshake(
            closed: task.closeCode.rawValue != 0,
            errorCode: errorCode,
            declared: declared,
            actual: actual,
            sawEpochInfo: sawEpochInfo
        )
    }

    func testARawSocketDeclaringTheWrongFormatIsRefusedWithoutClosingTheSocket() async throws {
        let author = await makeClient(databasePath: directory + "/author.sqlite")
        try await author.connect()
        try await waitForConnection(client: author)
        let created = try await author.createDocument(options: CreateDocumentOptions(
            title: "swift format mismatch", documentFormat: 2
        ))
        documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try await eventually(timeout: 20, description: "the create to commit") {
            author.documentManager.getLocalMetadata(self.documentId)?.pendingCreate != true
        }
        _ = try await author.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .network, enableNetworkSync: true
        ))

        let refusal = try await openRawSocket(declaring: 1)
        XCTAssertEqual(
            refusal.errorCode, "DOCUMENT_FORMAT_MISMATCH",
            "the room did not refuse a client that declared the wrong format"
        )
        XCTAssertEqual(refusal.declared, 1)
        XCTAssertEqual(refusal.actual, 2)
        // D1 — a disagreement is about ONE document, so the connection lives.
        XCTAssertFalse(refusal.closed, "the room closed the socket over one document")
        XCTAssertFalse(
            refusal.sawEpochInfo,
            "the refused handshake was served the document anyway"
        )

        // The positive control: the same document, declared correctly, through
        // this client's own front door.
        let ours = await makeClient(databasePath: directory + "/control.sqlite")
        try await ours.connect()
        try await waitForConnection(client: ours)
        _ = try await ours.openDocument(documentId, options: OpenDocumentOptions(
            waitForLoad: .network, enableNetworkSync: true
        ))
        XCTAssertNotNil(
            ours.format2?.binding(documentId),
            "this client's own open of the same document did not bind it"
        )
    }
}
