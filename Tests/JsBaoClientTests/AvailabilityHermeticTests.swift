import XCTest
@testable import JsBaoClient
import YSwift

/// #2667 (parity C8) — `openDocument` must throw the same typed errors JS
/// throws when the network path cannot be satisfied, instead of resolving
/// with a possibly-empty document the caller cannot tell apart from a
/// genuinely empty one.
///
/// Mirrors `tests/client/js-bao-client-open-availability-errors.test.ts` and
/// the two cases already pinned in `tests/client/js-bao-client-availability.test.ts`
/// (`DOCUMENT_UNAVAILABLE_OFFLINE`, `CONNECTION_DISABLED`).
///
/// Server-free (`*HermeticTests`): every case here is decided client-side —
/// before any frame could reach a server — so the client points at a closed
/// local port and the document ids are arbitrary.
final class AvailabilityHermeticTests: XCTestCase {

    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
    }

    /// A client wired to a closed local port: nothing it sends can be
    /// answered, which is exactly the "server unreachable" condition C8 is
    /// about.
    private func makeClient() -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "availability-hermetic-app",
            token: "test-token",
            offline: false,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        clients.append(client)
        return client
    }

    private func newDocId(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    /// Assert the open threw `JsBaoError` carrying `code`, reporting what came
    /// back instead when it did not.
    ///
    /// The expectation is the raw code string rather than a `JsBaoErrorCode`
    /// case on purpose: the string is the cross-platform contract these tests
    /// pin (the JS client throws `err.code = "NETWORK_TIMEOUT"` and friends),
    /// and stating it that way keeps each behavior's failing commit a
    /// test-only change.
    private func expectOpenError(
        _ code: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ open: () async throws -> YDocument
    ) async {
        do {
            _ = try await open()
            XCTFail(
                "openDocument resolved; expected \(code)",
                file: file, line: line
            )
        } catch let error as JsBaoError {
            XCTAssertEqual(
                error.code.rawValue, code,
                "expected \(code), got \(error.code.rawValue)",
                file: file, line: line
            )
        } catch {
            XCTFail(
                "expected JsBaoError(\(code)), got \(error)",
                file: file, line: line
            )
        }
    }

    /// Behavior 1 — a `.network` open while offline fast-fails with
    /// `DOCUMENT_UNAVAILABLE_OFFLINE` (JS `waitForAvailability`'s first
    /// fast-fail).
    func testNetworkOpenWhileOfflineThrowsDocumentUnavailableOffline() async throws {
        let client = makeClient()
        let docId = newDocId("offline-network")

        await client.goOffline()

        await expectOpenError("DOCUMENT_UNAVAILABLE_OFFLINE") {
            try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true,
                availabilityWait: 1
            ))
        }
    }

    /// Behavior 2 — a `.network` open that also turns network sync off asks
    /// for a server round-trip nothing will ever start, so it fast-fails with
    /// `NETWORK_REQUIRES_AUTOSTART` instead of waiting out the budget.
    func testNetworkOpenWithoutAutostartThrowsNetworkRequiresAutostart() async throws {
        let client = makeClient()
        let docId = newDocId("requires-autostart")

        await expectOpenError("NETWORK_REQUIRES_AUTOSTART") {
            try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: false,
                availabilityWait: 1
            ))
        }
    }

    /// Behavior 3 — the default `.localIfAvailableElseNetwork` mode with no
    /// local copy needs the network half, so turning network sync off leaves
    /// no way to satisfy the open: `NO_LOCAL_AND_NO_NETWORK`.
    func testElseNetworkOpenWithoutLocalOrNetworkThrowsNoLocalAndNoNetwork() async throws {
        let client = makeClient()
        let docId = newDocId("no-local-no-network")

        await expectOpenError("NO_LOCAL_AND_NO_NETWORK") {
            try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .localIfAvailableElseNetwork,
                enableNetworkSync: false,
                availabilityWait: 1
            ))
        }
    }

    /// Behavior 4 — with the connection deliberately disabled the socket will
    /// not come up on its own, so the open reports `CONNECTION_DISABLED`
    /// (the shape an auth failure or a logout leaves behind) rather than
    /// waiting for a handshake that cannot happen.
    func testNetworkOpenWithConnectionDisabledThrowsConnectionDisabled() async throws {
        let client = makeClient()
        let docId = newDocId("connection-disabled")

        await client.setShouldConnect(false)

        await expectOpenError("CONNECTION_DISABLED") {
            try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true,
                availabilityWait: 1
            ))
        }
    }

    /// Behavior 5 — the case that named the issue: the server never answers,
    /// so the availability budget runs out. The open must throw
    /// `NETWORK_TIMEOUT` instead of resolving with a possibly-empty document
    /// the caller cannot distinguish from a genuinely empty one.
    func testNetworkOpenThatNeverSyncsThrowsNetworkTimeout() async throws {
        let client = makeClient()
        let docId = newDocId("network-timeout")

        await expectOpenError("NETWORK_TIMEOUT") {
            try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true,
                availabilityWait: 1
            ))
        }
    }

    /// A failed open must not leave the document registered as open: the
    /// document manager put it there before the gate ran, and the next
    /// `openDocument` would take the already-open fast path and hand back
    /// that half-initialized document. JS drops the entry on exactly this
    /// path (`JsBaoClient.ts` → `docManager.removeOpenDoc`).
    func testFailedOpenDoesNotLeaveTheDocumentRegisteredAsOpen() async throws {
        let client = makeClient()
        let docId = newDocId("failed-open-cleanup")

        await client.setShouldConnect(false)

        await expectOpenError("CONNECTION_DISABLED") {
            try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true,
                availabilityWait: 1
            ))
        }

        XCTAssertFalse(
            client.documentManager.isOpen(docId),
            "a failed open left the document in openDocs; the next open would short-circuit to it"
        )
    }

    /// Behavior 7 — the sub-API twin callers reach through
    /// `client.documents.open(...)` forwards the same typed errors; no
    /// wrapper turns a failed open back into a document.
    func testDocumentsOpenTwinPropagatesTheTypedError() async throws {
        let client = makeClient()
        let docId = newDocId("twin-surface")

        await client.setShouldConnect(false)

        do {
            _ = try await client.documents.open(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true,
                availabilityWait: 1
            ))
            XCTFail("documents.open resolved; expected CONNECTION_DISABLED")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code.rawValue, "CONNECTION_DISABLED")
        }
    }

    /// A second open of a document that is ALREADY open does not fast-fail
    /// against it — JS early-returns on `hasOpenDoc` before
    /// `waitForAvailability`, so a live document is never reported as
    /// unreachable.
    func testReopeningALiveDocumentDoesNotFastFail() async throws {
        let client = makeClient()
        let docId = newDocId("reopen-live")

        let first = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local
        ))

        // Options that would fast-fail a fresh open of this document
        // (`NETWORK_REQUIRES_AUTOSTART`).
        let second = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .network,
            enableNetworkSync: false,
            availabilityWait: 1
        ))

        XCTAssertTrue(
            first === second,
            "the re-open handed back a different document than the live one"
        )
        XCTAssertTrue(
            client.documentManager.isOpen(docId),
            "the re-open dropped the document the first caller is still using"
        )
    }

    /// …and a re-open that DOES fail — the wait can still time out for a
    /// document that is open but not yet synced — must leave the live
    /// document alone. The failure cleanup belongs to the call that opened
    /// the document; running it here would cancel the observers and drop the
    /// sync, permission and persistence state of a document another caller is
    /// actively editing.
    func testFailedReopenLeavesTheLiveDocumentIntact() async throws {
        let client = makeClient()
        let docId = newDocId("reopen-live-failure")
        let schema = PrimitiveSchema(
            name: "availability_hermetic_reopen_rows",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string),
            ]
        )
        let store = client.sharedModel(for: schema)

        let live = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local
        ))

        // The server is unreachable, so this re-open cannot complete; whether
        // it throws is not what this pins — what happens to `live` is.
        _ = try? await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .network,
            enableNetworkSync: true,
            availabilityWait: 1
        ))

        XCTAssertTrue(
            client.documentManager.isOpen(docId),
            "a failed re-open unregistered the document the first caller is still using"
        )
        XCTAssertTrue(
            store.connectedDocIds.contains(docId),
            "a failed re-open disconnected the live document from the shared model store"
        )
        XCTAssertTrue(
            client.documentManager.getDocument(docId) === live,
            "a failed re-open replaced the live document handle"
        )
    }

    /// A failed open must not leave the document wired into the shared
    /// cross-document stores either: `Model.query()` would keep returning its
    /// rows and hand out a writer backed by a YDocument whose update observer
    /// the cleanup just cancelled, so writes through it would be neither
    /// synced nor persisted.
    func testFailedOpenDisconnectsTheDocumentFromSharedModels() async throws {
        let client = makeClient()
        let docId = newDocId("failed-open-shared-models")
        let schema = PrimitiveSchema(
            name: "availability_hermetic_rows",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string),
            ]
        )
        let store = client.sharedModel(for: schema)

        await client.setShouldConnect(false)

        await expectOpenError("CONNECTION_DISABLED") {
            try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true,
                availabilityWait: 1
            ))
        }

        XCTAssertFalse(
            store.connectedDocIds.contains(docId),
            "a failed open left the document connected to the shared model store"
        )
    }

    /// The wait has to bring the socket up itself when nothing else is:
    /// `startNetworkSync` only sends on a live transport, so without the
    /// connect the open would burn its whole budget without a frame going out
    /// and report `NETWORK_TIMEOUT` against a healthy server. JS connects on
    /// the same path (`connect()` ahead of `waitForAvailability`).
    func testNetworkOpenStartsTheConnectionWhileWaiting() async throws {
        let client = makeClient()
        let docId = newDocId("availability-connects")

        let sawConnecting = Flag()
        let subscription = client.eventEmitter.subscribe(StatusChangedEvent.self) { event in
            if event.status == .connecting { sawConnecting.set() }
        }
        defer { subscription.cancel() }

        // `autoNetwork: false` means nothing has connected this client, and
        // nothing else will: only the open itself can start the socket.
        XCTAssertFalse(client.isConnected)

        await expectOpenError("NETWORK_TIMEOUT") {
            try await client.openDocument(docId, options: OpenDocumentOptions(
                waitForLoad: .network,
                enableNetworkSync: true,
                availabilityWait: 1
            ))
        }

        XCTAssertTrue(
            sawConnecting.isSet,
            "the availability wait never tried to bring the connection up"
        )
    }

    /// Edge case — a `deferNetworkSync` open drives its own sync later, so it
    /// has no network wait to bound: it neither fast-fails nor times out,
    /// even under conditions (`setShouldConnect(false)`) that would fail an
    /// ordinary `.network` open.
    func testDeferNetworkSyncOpenNeitherFastFailsNorWaits() async throws {
        let client = makeClient()
        let docId = newDocId("defer-network-sync")

        await client.setShouldConnect(false)

        let start = Date()
        let doc = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .network,
            enableNetworkSync: true,
            availabilityWait: 5,
            deferNetworkSync: true
        ))
        XCTAssertNotNil(doc)
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 2,
            "a deferred-sync open waited on the network it was told not to touch"
        )
    }

    /// Edge case — a document that is already synced has the server state the
    /// wait exists to collect, so a `.network` open returns straight away
    /// instead of blocking again.
    func testAlreadySyncedDocumentOpensWithoutWaiting() async throws {
        let client = makeClient()
        let docId = newDocId("already-synced")

        _ = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .local
        ))
        client.documentManager.applySyncState(docId, isSynced: true)

        let start = Date()
        let doc = try await client.openDocument(docId, options: OpenDocumentOptions(
            waitForLoad: .network,
            enableNetworkSync: true,
            availabilityWait: 5
        ))
        XCTAssertNotNil(doc)
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 2,
            "an already-synced document waited for a second handshake"
        )
    }

    /// A one-way flag the status callback can set from the WebSocket's own
    /// queue while the test reads it from its.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
