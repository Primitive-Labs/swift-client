import XCTest
@testable import JsBaoClient
import YSwift

/// Format-2 transport declarations and the upgrade refusal (#3436, behaviors
/// 1, 2 and 18).
///
/// Server-free: the client is built with unreachable URLs and never connects.
/// `syncStep1` is read straight off the real builder, and the refusal is
/// driven through the real message router (`handleWebSocketMessage`) and the
/// real reconnect policy (`webSocketManagerShouldReconnect`).
///
/// The room refuses any client whose `syncStep1` does not declare format 2
/// (`src/yjs-room-v2.ts`, `handleSyncStep1FromLayer`) with an `error` frame
/// and close 4426, so a Swift client that omitted the declaration could never
/// open a large document at all.
final class Format2TransportHermeticTests: XCTestCase {

    // MARK: - Fixtures

    private func makeClient(appId: String, token: String? = nil) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            token: token,
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
    }

    private func openLocalDoc(
        _ client: JsBaoClient,
        _ documentId: String
    ) async throws -> YDocument {
        try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false
            )
        )
    }

    private func syncStep1(
        _ client: JsBaoClient,
        _ documentId: String
    ) throws -> [String: Any] {
        let frame = try XCTUnwrap(
            client.documentManager.buildSyncStep1Message(documentId: documentId),
            "buildSyncStep1Message returned nil for an open document"
        )
        let data = try XCTUnwrap(frame.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - Behavior 1 — the declarations

    func testSyncStep1DeclaresBothFormatsAndTheManifestVersion() async throws {
        let client = makeClient(appId: "app_f2_b1")
        defer { Task { await client.destroy() } }
        _ = try await openLocalDoc(client, "doc_b1")

        let message = try syncStep1(client, "doc_b1")

        // The room reads `formats` for the capability check and
        // `manifestVersion` for the snapshot-shape check. Both go on EVERY
        // document: a client does not know a document's format before the
        // handshake answers.
        XCTAssertEqual(message["formats"] as? [Int], [1, 2])
        XCTAssertEqual(message["manifestVersion"] as? Int, 3)
        XCTAssertEqual(
            message["manifestVersion"] as? Int,
            Format2Transport.manifestVersion,
            "the frame must carry the constant, not a second copy of the number"
        )
    }

    func testSyncStep1KeepsEveryFieldItAlreadyCarried() async throws {
        let client = makeClient(appId: "app_f2_b1b")
        defer { Task { await client.destroy() } }
        _ = try await openLocalDoc(client, "doc_b1b")

        let message = try syncStep1(client, "doc_b1b")

        // Containment, not equality: the declarations are additive and the
        // pre-existing fields must all survive them.
        XCTAssertEqual(message["type"] as? String, "syncStep1")
        XCTAssertEqual(message["documentId"] as? String, "doc_b1b")
        XCTAssertNotNil(message["stateVector"] as? String)
        XCTAssertNotNil(
            Data(base64Encoded: (message["stateVector"] as? String) ?? "!"),
            "stateVector is still base64 of the encoded state vector"
        )
    }

    // MARK: - Behavior 2 — the refusal

    func testUpgradeRefusalEmitsAConnectionErrorNamingTheCodeAndTheMessageType() async throws {
        let client = makeClient(appId: "app_f2_b2")
        defer { Task { await client.destroy() } }
        _ = try await openLocalDoc(client, "doc_b2")

        let received = LockedBox<[ConnectionErrorEvent]>([])
        let subscription = client.eventEmitter.subscribe(ConnectionErrorEvent.self) { event in
            received.withValue { $0.append(event) }
        }
        defer { subscription.cancel() }

        // Exactly the frame the room sends before closing with 4426.
        await client.handleWebSocketMessage("""
        {"type":"error","code":"CLIENT_UPGRADE_REQUIRED","documentId":"doc_b2",\
        "messageType":"syncStep1","message":"Document doc_b2 is a large document (format 2); \
        this client is too old to read it. Upgrade the client library."}
        """)

        let event = try XCTUnwrap(received.value.first, "no ConnectionErrorEvent was emitted")
        XCTAssertEqual(event.documentId, "doc_b2")
        XCTAssertEqual(event.messageType, "syncStep1")
        // The server's frame carries `code` at the TOP LEVEL and no `detail`
        // object at all, so the code has to be surfaced deliberately — a
        // caller cannot tell an upgrade refusal from any other server error
        // without it.
        XCTAssertEqual(event.detail?["code"]?.stringValue, "CLIENT_UPGRADE_REQUIRED")
    }

    func testAServerSuppliedDetailObjectStillReachesTheCallerUntouched() async throws {
        // The pre-existing shape (#2661): when the room sends `detail`, that
        // object is what the caller sees. Surfacing the top-level `code` must
        // not displace it.
        let client = makeClient(appId: "app_f2_b2b")
        defer { Task { await client.destroy() } }

        let received = LockedBox<[ConnectionErrorEvent]>([])
        let subscription = client.eventEmitter.subscribe(ConnectionErrorEvent.self) { event in
            received.withValue { $0.append(event) }
        }
        defer { subscription.cancel() }

        await client.handleWebSocketMessage("""
        {"type":"error","message":"Permission denied","documentId":"doc_b2b",\
        "messageType":"syncStep1","detail":{"code":"FORBIDDEN","extra":"kept"}}
        """)

        let event = try XCTUnwrap(received.value.first)
        XCTAssertEqual(event.detail?["code"]?.stringValue, "FORBIDDEN")
        XCTAssertEqual(event.detail?["extra"]?.stringValue, "kept")
    }

    func testTheManagerDoesNotReconnectOnFourFourTwoSixButStillDoesOnTenOhSix() async throws {
        let client = makeClient(appId: "app_f2_b2c")
        defer { Task { await client.destroy() } }
        // `shouldReconnect` is gated on networking being allowed at all, so
        // the 1006 control is only meaningful with the mode set.
        client.setNetworkMode(.online)

        XCTAssertFalse(
            client.webSocketManagerShouldReconnect(code: 4426, reason: "CLIENT_UPGRADE_REQUIRED"),
            "a 4426 close is the room's permanent refusal — reconnecting loops forever"
        )
        XCTAssertTrue(
            client.webSocketManagerShouldReconnect(code: 1006, reason: nil),
            "an abnormal close is still reconnected on"
        )
    }

    func testAWaitingOpenFailsWithTheTypedUpgradeError() async throws {
        // A token and a wanted connection, so the open reaches its network
        // WAIT rather than the `CONNECTION_DISABLED` fast-fail. The socket
        // itself never comes up (the URL is unroutable) — the refusal is
        // injected through the router, which is the path the room's frame
        // takes.
        let client = makeClient(appId: "app_f2_b2d", token: "test-token")
        defer { Task { await client.destroy() } }
        client.setNetworkMode(.online)
        await client.setShouldConnect(true)

        // An open that needs the network, with a budget long enough that a
        // NETWORK_TIMEOUT cannot be mistaken for the refusal.
        let open = Task { () -> JsBaoError? in
            do {
                _ = try await client.openDocument(
                    "doc_b2d",
                    options: OpenDocumentOptions(
                        waitForLoad: .network,
                        availabilityWait: 30
                    )
                )
                return nil
            } catch let error as JsBaoError {
                return error
            } catch {
                XCTFail("not a JsBaoError: \(error)")
                return nil
            }
        }

        // Let the open reach its wait before the refusal lands.
        try await Task.sleep(nanoseconds: 300 * 1_000_000)
        await client.handleWebSocketMessage("""
        {"type":"error","code":"CLIENT_UPGRADE_REQUIRED","documentId":"doc_b2d",\
        "messageType":"syncStep1","message":"too old"}
        """)

        let outcome = await open.value
        let typed = try XCTUnwrap(
            outcome,
            "openDocument returned a document instead of failing"
        )
        XCTAssertEqual(typed.code, .clientUpgradeRequired)
        XCTAssertEqual(typed.details?["documentId"]?.stringValue, "doc_b2d")
    }

    // MARK: - Behavior 18 — the typed names

    func testTheNewErrorCodesCarryTheJavaScriptStringsVerbatim() {
        // Raw values, not Swift case names: a client that reports a different
        // string than the JS client for the same condition is a second
        // vocabulary for one platform behavior.
        XCTAssertEqual(JsBaoErrorCode.clientUpgradeRequired.rawValue, "CLIENT_UPGRADE_REQUIRED")
        XCTAssertEqual(JsBaoErrorCode.format2StorageUnavailable.rawValue, "FORMAT2_STORAGE_UNAVAILABLE")
        XCTAssertEqual(JsBaoErrorCode.format2ReloadRequired.rawValue, "FORMAT2_RELOAD_REQUIRED")
        XCTAssertEqual(JsBaoErrorCode.format2QueryScope.rawValue, "FORMAT2_QUERY_SCOPE")
        XCTAssertEqual(JsBaoErrorCode.format2ModelNotHydrated.rawValue, "FORMAT2_MODEL_NOT_HYDRATED")
        XCTAssertEqual(JsBaoErrorCode.format2FoldBroken.rawValue, "FORMAT2_FOLD_BROKEN")
        XCTAssertEqual(JsBaoErrorCode.snapshotManifestInvalid.rawValue, "SNAPSHOT_MANIFEST_INVALID")
        XCTAssertEqual(JsBaoErrorCode.snapshotManifestUnsupported.rawValue, "SNAPSHOT_MANIFEST_UNSUPPORTED")
        XCTAssertEqual(
            JsBaoErrorCode.format2SnapshotLoadIncomplete.rawValue,
            "FORMAT2_SNAPSHOT_LOAD_INCOMPLETE"
        )
    }

    func testStorageUnavailableCarriesTheJavaScriptDetailField() {
        // `Format2StorageUnavailableError` in JS carries `reason`, one of
        // `not-persistent` / `over-quota`.
        let error = JsBaoError(
            code: .format2StorageUnavailable,
            message: "no persistent storage",
            details: ["reason": .string("not-persistent")]
        )
        XCTAssertEqual(error.details?["reason"], .string("not-persistent"))
    }
}
