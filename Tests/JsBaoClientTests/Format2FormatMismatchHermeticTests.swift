import XCTest
@testable import JsBaoClient

/// The format this client BELIEVES a document has, and the room's refusal
/// (#3764, behaviors 19, 20, 20a, edges E6 and E9).
///
/// The Swift client already records `documentFormat` on its local row at create
/// time and binds by it; it never told the room. So when the two disagreed the
/// client was served the wrong document and nothing raised an error: a
/// believed-large document fed ordinary frames recorded
/// `noteHandshakeWithoutEpochInfo` and carried on.
///
/// Three claims live here:
///
///   - the declaration rides every `syncStep1`, read off the row and asserted on
///     the BYTES the loopback server received;
///   - a refusal fails the awaiting open with the typed error AND tears the
///     document down when no open is waiting (D7 — the JS client's rule, by the
///     same name and the same code);
///   - the awaiting open's refusal callback is registered BEFORE the handshake
///     can leave (D9), so a refusal answered while the initial send is still
///     suspended fails that open rather than letting it time out.
///
/// Server-free: an in-process loopback WebSocket server for the bytes, and
/// frames fed straight into `handleWebSocketMessage` for the answers.
final class Format2FormatMismatchHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-mismatch-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func newDocId() -> String { "f2-mismatch-\(UUID().uuidString.prefix(8))" }

    private func sqliteClient(
        databasePath: String? = nil,
        wsUrl: String = "ws://127.0.0.1:1"
    ) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "format2-mismatch-test-app",
            token: makeTestJwt(userId: "format2-mismatch-user"),
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: databasePath ?? newDatabasePath()),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        return client
    }

    private func createLocal(
        _ client: JsBaoClient, _ documentId: String, format: Int?
    ) async throws {
        client.documentManager.createRemoteDocument = { _ in ["documentId": documentId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId,
            title: "mismatch",
            localOnly: false,
            documentFormat: format
        )
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// Every `syncStep1` frame the loopback server received for `documentId`.
    private func syncStep1Frames(
        _ server: LoopbackWebSocketServer, _ documentId: String
    ) -> [String] {
        server.receivedFrames.filter {
            $0.contains("\"syncStep1\"") && $0.contains(documentId)
        }
    }

    /// The room's refusal frame, as the client receives it.
    private func mismatchFrame(
        _ documentId: String, declared: Int, actual: Int
    ) -> String {
        """
        {"type":"error","code":"DOCUMENT_FORMAT_MISMATCH","documentId":"\(documentId)",\
        "messageType":"syncStep1",\
        "message":"Document \(documentId) is format \(actual); this client opened it as format \(declared).",\
        "detail":{"code":"DOCUMENT_FORMAT_MISMATCH","declared":\(declared),"actual":\(actual)}}
        """
    }

    // MARK: - Behavior 19 — the declaration on the wire

    func testTheDeclaredFormatRidesEverySyncStep1AndIsOmittedWhenUnknown() async throws {
        for stored in [1, 2, nil] as [Int?] {
            let server = try LoopbackWebSocketServer()
            let url = try server.start()
            defer { server.stop() }

            let client = await sqliteClient(wsUrl: wsBase(url))
            defer { Task { await client.destroy() } }
            try await client.connect()

            let documentId = newDocId()
            try await createLocal(client, documentId, format: stored)
            _ = try await client.openDocument(
                documentId,
                options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
            )
            await client.startNetworkSync(documentId: documentId)
            try await waitFor("the syncStep1 frame to reach the socket") {
                !self.syncStep1Frames(server, documentId).isEmpty
            }

            let frame = syncStep1Frames(server, documentId)[0]
            if let stored {
                XCTAssertTrue(
                    frame.contains("\"documentFormat\":\(stored)"),
                    "a row naming format \(stored) declares it: \(frame)"
                )
            } else {
                // A first open of somebody else's document declares NOTHING and
                // is served exactly as it was before this field existed.
                XCTAssertFalse(
                    frame.contains("\"documentFormat\""),
                    "a document whose format nothing knows declares none: \(frame)"
                )
            }
        }
    }

    // MARK: - Edge E9 — the declaration does not move the receive limit

    func testAnAllFormat1SessionDeclaresOneAndKeepsFoundationsDefault() async throws {
        let databasePath = newDatabasePath()
        let documentId = newDocId()

        let first = await sqliteClient(databasePath: databasePath)
        try await createLocal(first, documentId, format: 1)
        await first.destroy()

        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let second = await sqliteClient(databasePath: databasePath, wsUrl: wsBase(url))
        defer { Task { await second.destroy() } }
        try await second.connect()
        _ = try await second.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        await second.startNetworkSync(documentId: documentId)
        try await waitFor("the syncStep1 frame to reach the socket") {
            !self.syncStep1Frames(server, documentId).isEmpty
        }

        XCTAssertTrue(
            self.syncStep1Frames(server, documentId)[0].contains("\"documentFormat\":1"),
            "the ordinary document still declares its format"
        )
        let limit = await second.wsManager.configuredMaximumMessageSize
        XCTAssertNil(
            limit,
            "declaring a format is not asking for a bigger frame: the limit is "
                + "decided by `needsRaisedMessageSize` and nothing here touches it"
        )
    }

    // MARK: - Behavior 20 — the code, and the teardown

    func testTheErrorCodeIsTheJsClientsStringVerbatim() {
        XCTAssertEqual(
            JsBaoErrorCode.documentFormatMismatch.rawValue, "DOCUMENT_FORMAT_MISMATCH"
        )
    }

    func testARefusalWithNoAwaitingOpenClosesTheDocumentUnderTheApp() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        XCTAssertTrue(
            client.documentManager.getDocument(documentId) != nil,
            "precondition: the document is open"
        )

        let heard = LockedBox<[DocumentFormatMismatchEvent]>([])
        let connectionErrors = LockedBox<[ConnectionErrorEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentFormatMismatchEvent.self) {
            event in heard.withValue { $0.append(event) }
        }
        let errorSubscription = client.eventEmitter.subscribe(ConnectionErrorEvent.self) {
            event in connectionErrors.withValue { $0.append(event) }
        }
        defer {
            subscription.cancel()
            errorSubscription.cancel()
        }

        // No open is awaiting: the refusal has to tear the document down anyway
        // (D7), and it must not throw.
        await client.handleWebSocketMessage(
            mismatchFrame(documentId, declared: 2, actual: 1)
        )

        try await waitFor("the mismatch event") { heard.value.count == 1 }
        XCTAssertEqual(heard.value[0].documentId, documentId)
        XCTAssertEqual(heard.value[0].declared, 2)
        XCTAssertEqual(heard.value[0].actual, 1)
        XCTAssertEqual(heard.value[0].error.code, .documentFormatMismatch)
        XCTAssertTrue(
            connectionErrors.value.contains {
                if case .object(let fields) = $0.detail,
                   case .string("DOCUMENT_FORMAT_MISMATCH") = fields["code"] { return true }
                return false
            },
            "the connection error carries the code in its detail"
        )
        // 3764-CR-04 — ONE notification per refusal. The generic error arm used
        // to emit its own before handing the frame to the teardown, which emits
        // again, so an app's error handling ran twice for one refusal.
        XCTAssertEqual(
            connectionErrors.value.count, 1,
            "a handled refusal is one connection error, not two"
        )
        try await waitFor("the document to be closed under the app") {
            client.documentManager.getDocument(documentId) == nil
        }
        // Its store is kept: a corrected open reads the rows and replays the
        // writes the server has not acknowledged.
        XCTAssertEqual(
            client.documentManager.getLocalMetadata(documentId)?.documentFormat, 2,
            "the local row survives the refusal"
        )
    }

    func testARefusalForADocumentWeDoNotHoldIsDropped() async throws {
        // E6 — the room answers the CONNECTION, and a document closed while the
        // frame was in flight has nothing left to tear down.
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let heard = LockedBox<[DocumentFormatMismatchEvent]>([])
        let connectionErrors = LockedBox<[ConnectionErrorEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentFormatMismatchEvent.self) {
            event in heard.withValue { $0.append(event) }
        }
        let errorSubscription = client.eventEmitter.subscribe(ConnectionErrorEvent.self) {
            event in connectionErrors.withValue { $0.append(event) }
        }
        defer {
            subscription.cancel()
            errorSubscription.cancel()
        }

        await client.handleWebSocketMessage(
            mismatchFrame("f2-mismatch-never-opened", declared: 1, actual: 2)
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(heard.value.count, 0, "nothing to tear down, nothing emitted")
        // 3764-CR-04 — nor a connection error: the frame is dropped whole, as
        // the JS client drops it.
        XCTAssertEqual(
            connectionErrors.value.count, 0,
            "a refusal for a document this client does not hold notifies nobody"
        )
    }

    func testARefusedDocumentIsNotHandshakenAgainOnThisConnection() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = await sqliteClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        await client.handleWebSocketMessage(
            mismatchFrame(documentId, declared: 2, actual: 1)
        )
        try await waitFor("the document to be closed under the app") {
            client.documentManager.getDocument(documentId) == nil
        }

        let before = syncStep1Frames(server, documentId).count
        await client.startNetworkSync(documentId: documentId)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            syncStep1Frames(server, documentId).count, before,
            "a refused document sends no further handshake on this connection"
        )
    }

    /// A refusal keeps the local data even when the open said not to keep it.
    ///
    /// `retainLocal: false` means "do not keep this document on this device", and
    /// `closeDocument` honours it exactly like an explicit `evictLocal` — which
    /// is right for a close the app asked for and wrong for one the client
    /// performs on the app's behalf. The store, the rows and the writes the
    /// server has not acknowledged are the whole reason the teardown promises to
    /// evict nothing.
    func testARefusalKeepsTheLocalDataEvenWhenTheOpenSaidNotToRetainIt() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(
                enableNetworkSync: false, retainLocal: false, deferNetworkSync: true
            )
        )
        XCTAssertEqual(
            client.documentManager.retainLocalSetting(documentId), false,
            "precondition: this open asked not to keep the document"
        )

        await client.handleWebSocketMessage(
            mismatchFrame(documentId, declared: 2, actual: 1)
        )
        try await waitFor("the document to be closed under the app") {
            client.documentManager.getDocument(documentId) == nil
        }

        // The row is what a corrected open reads its belief from, and the store
        // behind it is what carries the unacknowledged writes.
        XCTAssertEqual(
            client.documentManager.getLocalMetadata(documentId)?.documentFormat, 2,
            "the local row survived a refusal of a retainLocal: false open"
        )
        XCTAssertTrue(
            client.hasLocalCopy(documentId),
            "the local copy survived a refusal of a retainLocal: false open"
        )
    }

    /// The mark is per open cycle, not for the life of the client.
    ///
    /// Held forever, it refuses every later handshake for the document AND turns
    /// a second genuine refusal into a silent no-op — no teardown, no event, the
    /// reopened document left bound and retrying.
    func testASecondRefusalAfterACloseIsAnsweredInFull() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }

        let heard = LockedBox<[DocumentFormatMismatchEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentFormatMismatchEvent.self) {
            event in heard.withValue { $0.append(event) }
        }
        defer { subscription.cancel() }

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)

        for cycle in 1...2 {
            _ = try await client.openDocument(
                documentId,
                options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
            )
            await client.handleWebSocketMessage(
                mismatchFrame(documentId, declared: 2, actual: 1)
            )
            try await waitFor("the mismatch event of cycle \(cycle)") {
                heard.value.count == cycle
            }
            try await waitFor("the document to be closed under the app in cycle \(cycle)") {
                client.documentManager.getDocument(documentId) == nil
            }
            XCTAssertTrue(
                client.isFormatRefused(documentId),
                "the mark stands after the refusal of cycle \(cycle)"
            )
            // While it stands, a reopen is answered with the disagreement rather
            // than waiting out its availability budget for a handshake this
            // client will not send — what the documentation promises a waiting
            // open, and the answer JS gives at the same point.
            do {
                _ = try await client.openDocument(documentId)
                XCTFail("the reopen of a refused document should have thrown")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .documentFormatMismatch)
                XCTAssertEqual(error.details?["declared"], .number(2))
                XCTAssertEqual(error.details?["actual"], .number(1))
            }
            // What the app does next: close the document it was told was
            // refused. That ends the cycle the mark belongs to.
            _ = await client.closeDocument(documentId)
            XCTAssertFalse(
                client.isFormatRefused(documentId),
                "a closed document no longer holds the belief that was refused"
            )
        }
        XCTAssertEqual(heard.value.count, 2, "each refusal was answered in full")
    }

    /// The mark is what refuses the handshake, not the closed `openDocs` entry.
    ///
    /// Without this the mark did nothing at all: `buildSyncStep1Message` already
    /// answers `nil` for a closed document, so every reason a refused document
    /// stayed quiet was the close rather than the refusal — and a document
    /// reopened from local data went straight back to handshaking.
    func testTheMarkRefusesTheHandshakeForADocumentThatIsOpenAgain() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = await sqliteClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        await client.handleWebSocketMessage(
            mismatchFrame(documentId, declared: 2, actual: 1)
        )
        try await waitFor("the document to be closed under the app") {
            client.documentManager.getDocument(documentId) == nil
        }

        // Put it back in `openDocs` through the MANAGER, deliberately going
        // around the client's own open — that answers a standing refusal by
        // throwing, and the claim here is about the second gate: with a document
        // open and a handshake buildable, the mark is what keeps the frame off
        // the wire. This is the state a watchdog retry or a connect sweep finds.
        _ = try await client.documentManager.openDocument(
            documentId: documentId,
            options: OpenDocumentOptions(
                waitForLoad: .local, enableNetworkSync: false, deferNetworkSync: true
            )
        )
        XCTAssertNotNil(
            client.documentManager.buildSyncStep1Message(documentId: documentId),
            "precondition: the reopened document can build a handshake"
        )

        let before = syncStep1Frames(server, documentId).count
        await client.startNetworkSync(documentId: documentId)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            syncStep1Frames(server, documentId).count, before,
            "a refused document sends no handshake even once it is open again"
        )

        // …and the close that ends the cycle lets the next handshake go out.
        _ = await client.closeDocument(documentId)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(
                waitForLoad: .local, enableNetworkSync: false, deferNetworkSync: true
            )
        )
        await client.startNetworkSync(documentId: documentId)
        try await waitFor("the handshake the cleared mark allows") { [self] in
            syncStep1Frames(server, documentId).count > before
        }
    }

    // MARK: - Behavior 20a — D9, the registration precedes the send

    func testTheAwaitingOpenIsRegisteredBeforeTheHandshakeCanLeave() throws {
        // The source pin for D9, on `openDocument`'s OWN body: the refusal
        // callback has to exist before anything can put a frame on the wire,
        // because `AwaitingOpenRegistry.fail` notifies only what is registered
        // and retains nothing.
        let body = try methodBody(
            of: "public func openDocument(",
            in: "Sources/JsBaoClient/JsBaoClient.swift"
        )
        guard let register = body.range(of: "awaitingOpens.register("),
              let send = body.range(of: "startNetworkSync(documentId: documentId)")
        else {
            return XCTFail("openDocument names both the registration and the send")
        }
        XCTAssertTrue(
            register.lowerBound < send.lowerBound,
            "the refusal callback is registered before the handshake can leave"
        )
    }

    func testARefusalDeliveredWhileTheSendIsSuspendedFailsThatOpen() async throws {
        // D9's behaviour. The loopback server holds the send, so the refusal is
        // answered while `openDocument` is still inside `wsManager.send` — the
        // window `AwaitingOpenRegistry` used to have no waiter for, and where a
        // client would report `NETWORK_TIMEOUT` about a room that answered at
        // once.
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = await sqliteClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)

        // Answer the handshake the moment it appears on the wire. Every value
        // the answering task needs is captured explicitly, so the closure holds
        // nothing of the test case itself (the v6 language mode refuses that).
        let frame = mismatchFrame(documentId, declared: 2, actual: 1)
        let answer: @Sendable () async -> Void = { [server, client, documentId, frame] in
            for _ in 0..<600 {
                let sawHandshake = server.receivedFrames.contains {
                    $0.contains("\"syncStep1\"") && $0.contains(documentId)
                }
                if sawHandshake {
                    await client.handleWebSocketMessage(frame)
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        Task { await answer() }

        do {
            _ = try await client.openDocument(
                documentId,
                options: OpenDocumentOptions(
                    waitForLoad: .network,
                    enableNetworkSync: true,
                    availabilityWait: 20
                )
            )
            XCTFail("the open was served a document the room refuses")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentFormatMismatch)
            XCTAssertEqual(error.details?["documentId"], .string(documentId))
            XCTAssertEqual(error.details?["declared"], .number(2))
            XCTAssertEqual(error.details?["actual"], .number(1))
        }
    }

    /// 3764-CR-03 — the refusal is claimed before the waiting open is released.
    ///
    /// Failing the wait resumes the open's task, whose abort path removes the
    /// document it registered. Released first, that abort could empty the entry
    /// before the handler asked "is it held?", and the handler would drop its
    /// own open's refusal as a frame for a closed document: no mark, no event.
    func testARefusalThatFailsAnOpenStillMarksAndAnnouncesIt() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }

        let client = await sqliteClient(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let documentId = newDocId()
        try await createLocal(client, documentId, format: 2)

        let heard = LockedBox<[DocumentFormatMismatchEvent]>([])
        let connectionErrors = LockedBox<[ConnectionErrorEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentFormatMismatchEvent.self) {
            event in heard.withValue { $0.append(event) }
        }
        let errorSubscription = client.eventEmitter.subscribe(ConnectionErrorEvent.self) {
            event in connectionErrors.withValue { $0.append(event) }
        }
        defer {
            subscription.cancel()
            errorSubscription.cancel()
        }

        let frame = mismatchFrame(documentId, declared: 2, actual: 1)
        let answer: @Sendable () async -> Void = { [server, client, documentId, frame] in
            for _ in 0..<600 {
                let sawHandshake = server.receivedFrames.contains {
                    $0.contains("\"syncStep1\"") && $0.contains(documentId)
                }
                if sawHandshake {
                    await client.handleWebSocketMessage(frame)
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let answering = Task { await answer() }

        do {
            _ = try await client.openDocument(
                documentId,
                options: OpenDocumentOptions(
                    waitForLoad: .network,
                    enableNetworkSync: true,
                    availabilityWait: 20
                )
            )
            XCTFail("the open was served a document the room refuses")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentFormatMismatch)
        }
        await answering.value

        XCTAssertTrue(
            client.isFormatRefused(documentId),
            "the open's own refusal left no mark, so the next open would retry it"
        )
        XCTAssertEqual(heard.value.count, 1, "the refusal of a waiting open is announced")
        XCTAssertEqual(connectionErrors.value.count, 1, "and notified once")
        XCTAssertNil(
            client.documentManager.getDocument(documentId),
            "the refused document is not left open"
        )
        XCTAssertEqual(
            client.documentManager.getLocalMetadata(documentId)?.documentFormat, 2,
            "the preserving close kept the local row"
        )
    }

    func testTheRefusalIsClaimedBeforeTheWaitingOpenIsReleased() throws {
        let body = try methodBody(
            of: "func refuseDocumentFormat(",
            in: "Sources/JsBaoClient/JsBaoClient.swift"
        )
        guard let claim = body.range(of: "formatRefusedDocuments[documentId] = error"),
              let close = body.range(of: "await documentManager.closeDocument("),
              let released = body.range(
                  of: "failAwaitingOpen(documentId, error: error)",
                  options: .backwards
              )
        else {
            return XCTFail("refuseDocumentFormat names the claim, the close and the release")
        }
        XCTAssertTrue(
            claim.lowerBound < released.lowerBound,
            "the mark is taken before the waiting open can resume and abort"
        )
        XCTAssertTrue(
            close.lowerBound < released.lowerBound,
            "the held document's waiter is released only after the preserving close"
        )
    }

    func testTheGenericErrorArmNeverSeesAFormatMismatch() throws {
        // The routing, on the router's own body: the mismatch arm comes before
        // the generic `case "error":` that emits a connection error for every
        // frame it receives.
        let body = try methodBody(
            of: "func handleWebSocketMessage(",
            in: "Sources/JsBaoClient/JsBaoClient.swift"
        )
        guard let mismatchArm = body.range(of: "case \"error\" where json[\"code\"]"),
              let generic = body.range(of: "case \"error\":\n")
        else {
            return XCTFail("the router names both error arms")
        }
        XCTAssertTrue(mismatchArm.lowerBound < generic.lowerBound)
        let armBody = body[mismatchArm.lowerBound..<generic.lowerBound]
        XCTAssertTrue(
            armBody.contains("documentFormatMismatch.rawValue")
                && armBody.contains("refuseDocumentFormat("),
            "the arm ahead of the generic one is the mismatch's, and it tears down"
        )
        let genericArm = body[generic.lowerBound...]
        let nextCase = genericArm.range(of: "\n        case ")?.lowerBound ?? genericArm.endIndex
        XCTAssertFalse(
            genericArm[..<nextCase].contains("refuseDocumentFormat("),
            "the generic arm no longer hands a mismatch to the teardown after notifying"
        )
    }

    func testTheTeardownStatesBothHalvesOnItsOwnBody() throws {
        let body = try methodBody(
            of: "func refuseDocumentFormat(",
            in: "Sources/JsBaoClient/JsBaoClient.swift"
        )
        // `CloseDocumentOptions()` alone does not stop a `retainLocal: false`
        // open from evicting at close, so the teardown says what it means.
        XCTAssertTrue(
            body.contains("documentManager.preserveLocalOnClose(")
            && body.range(of: "documentManager.preserveLocalOnClose(")!.lowerBound
                < body.range(of: "documentManager.closeDocument(")!.lowerBound,
            "the retention downgrade precedes the close it is about"
        )
        // The queued frames go before anything is awaited: a write that escaped
        // during the close would be a delta against a layout the room refuses.
        XCTAssertTrue(
            body.range(of: "discardQueuedOutboundUpdates(")!.lowerBound
                < body.range(of: "await documentManager.closeDocument(")!.lowerBound,
            "the outbound queue is dropped before the teardown awaits its close"
        )
    }

    func testTheMarkIsReadWhereAHandshakeLeavesAndClearedWhereACycleEnds() throws {
        let path = "Sources/JsBaoClient/JsBaoClient.swift"
        // The one place a `syncStep1` leaves, so the watchdog's retries, the
        // availability loop and the connect sweep are all covered by one rule.
        XCTAssertTrue(
            try methodBody(of: "func startNetworkSync(documentId: String, explicit: Bool)", in: path)
                .contains("isFormatRefused("),
            "the handshake consults the refusal"
        )
        // …and the open answers it rather than waiting for a handshake it will
        // not send.
        XCTAssertTrue(
            try methodBody(of: "public func openDocument(", in: path)
                .contains("formatRefusal("),
            "the open answers a standing refusal"
        )
        // The one place the bytes reach the socket.
        XCTAssertTrue(
            try methodBody(of: "func flushOutboundUpdates(", in: path)
                .contains("isFormatRefused("),
            "the send path consults the refusal"
        )
        for signature in [
            "public func closeDocument(",
            "public func evictLocalDocument(",
            "public func evictAllLocal(",
        ] {
            XCTAssertTrue(
                try methodBody(of: signature, in: path).contains("clearFormatRefusal("),
                "\(signature) ends the cycle the mark belongs to"
            )
        }
    }

    // MARK: - Source reading

    /// One method's OWN body, balanced from its signature — never a window of
    /// characters after a landmark, which eight children of this project have
    /// paid for. The parameter list is stepped over first, because a default
    /// value carries parentheses of its own.
    private func methodBody(of signature: String, in relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // JsBaoClientTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-client
        let source = try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8
        )
        guard let start = source.range(of: signature) else {
            XCTFail("\(signature) not found in \(relativePath)")
            return ""
        }
        var index = start.lowerBound
        var parens = 0
        var opened = false
        while index < source.endIndex {
            let c = source[index]
            if c == "(" { parens += 1; opened = true }
            else if c == ")" {
                parens -= 1
                if opened && parens == 0 { break }
            }
            index = source.index(after: index)
        }
        guard let open = source.range(of: "{", range: index..<source.endIndex) else {
            XCTFail("\(signature) has no body")
            return ""
        }
        var depth = 0
        var cursor = open.lowerBound
        while cursor < source.endIndex {
            let c = source[cursor]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            cursor = source.index(after: cursor)
        }
        return String(source[open.lowerBound...cursor])
    }
}
