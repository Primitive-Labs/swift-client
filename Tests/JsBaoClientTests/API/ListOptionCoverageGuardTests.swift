import XCTest
@testable import JsBaoClient

/// Guard against the defect class #2360 reported: an option field that
/// compiles, reads like JS parity, and silently does nothing.
///
/// Every field of `ListDocumentsOptions` and `MeOwnedDocumentsOptions` must be
/// in exactly one of two buckets:
///
///  - **implemented** — it has an observable effect (a query param, a
///    suppressed request, or a typed throw), asserted here or in
///    `MeOwnedDocumentsLocalFirstTests`;
///  - **deprecated** — it is annotated `@available(*, deprecated)` saying it
///    is not implemented, so the compiler tells callers.
///
/// The inventories below are the record of that classification. Adding a field
/// without classifying it fails `testInventoriesCoverEveryField` — Swift can't
/// read `@available` at runtime, so the inventory is what makes the
/// requirement mechanical.
///
/// Deprecated fields are stored under a `…Storage` name (the deprecation lives
/// on a computed property over that storage), which is why the expected
/// `Mirror` labels differ from the public field names.
final class ListOptionCoverageGuardTests: XCTestCase {

    // MARK: - Inventories

    /// `ListDocumentsOptions`: `documents.list` is a blocking server fetch, so
    /// only the query-string fields are implemented.
    private static let listDocumentsImplemented = ["includeRoot", "limit", "cursor", "tag", "forward"]
    private static let listDocumentsDeprecated = [
        "refreshFromServerStorage", "localOnlyStorage", "serverTimeoutMsStorage",
        "waitForLoadStorage", "returnPageStorage",
    ]

    /// `MeOwnedDocumentsOptions`: everything except `returnPage` is
    /// implemented (#2360).
    private static let ownedDocumentsImplemented = [
        "includeRoot", "refreshFromServer", "localOnly", "serverTimeoutMs",
        "waitForLoad", "forward",
    ]
    private static let ownedDocumentsDeprecated = ["returnPageStorage"]

    func testInventoriesCoverEveryField() {
        let listFields = Mirror(reflecting: ListDocumentsOptions()).children.compactMap { $0.label }
        XCTAssertEqual(
            Set(listFields),
            Set(Self.listDocumentsImplemented + Self.listDocumentsDeprecated),
            """
            A ListDocumentsOptions field is unclassified. Either implement it \
            (and assert its observable effect) or annotate it \
            @available(*, deprecated) and add it to the inventory here.
            """
        )

        let ownedFields = Mirror(reflecting: MeOwnedDocumentsOptions()).children.compactMap { $0.label }
        XCTAssertEqual(
            Set(ownedFields),
            Set(Self.ownedDocumentsImplemented + Self.ownedDocumentsDeprecated),
            """
            A MeOwnedDocumentsOptions field is unclassified. Either implement it \
            (and assert its observable effect) or annotate it \
            @available(*, deprecated) and add it to the inventory here.
            """
        )
    }

    // MARK: - Observable effects: ListDocumentsOptions

    /// Every implemented `ListDocumentsOptions` field reaches the wire.
    func testImplementedListDocumentsFieldsReachTheWire() async throws {
        let transport = RecordingTransport(json: #"{"items":[]}"#)
        let api = DocumentsAPI(
            transport: transport,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )

        _ = try await api._listImpl(options: ListDocumentsOptions(
            includeRoot: true, limit: 5, cursor: "c1", tag: "starred", forward: true
        ))

        let path = try XCTUnwrap(transport.lastCall?.path)
        for field in Self.listDocumentsImplemented {
            XCTAssertTrue(
                path.contains("\(field)="),
                "\(field) never reached the query string: \(path)"
            )
        }
    }

    /// The deprecated fields are inert: setting them changes nothing on the
    /// wire. (Their contract is the compiler warning, not behavior.)
    func testDeprecatedListDocumentsFieldsAreInert() async throws {
        let transport = RecordingTransport(json: #"{"items":[]}"#)
        let api = DocumentsAPI(
            transport: transport,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )

        _ = try await api._listImpl(options: ListDocumentsOptions())
        let baseline = transport.lastCall?.path

        _ = try await api._listImpl(options: ListDocumentsOptions(
            refreshFromServer: false,
            localOnly: true,
            serverTimeoutMs: 1,
            waitForLoad: "local",
            returnPage: true
        ))

        XCTAssertEqual(transport.lastCall?.path, baseline)
        XCTAssertEqual(transport.calls.count, 2, "the dead fields do not suppress the fetch either")
    }

    // MARK: - Observable effects: MeOwnedDocumentsOptions

    /// `includeRoot` / `forward` reach the query string; the local-first
    /// fields' effects are asserted in `MeOwnedDocumentsLocalFirstTests`
    /// (suppressed request for `localOnly` / `refreshFromServer`, typed throws
    /// for `waitForLoad` / `serverTimeoutMs`). This test pins the query half
    /// and re-checks the suppression half so the guard stands alone.
    func testImplementedOwnedDocumentsFieldsHaveObservableEffects() async throws {
        let transport = RecordingTransport(json: #"{"items":[]}"#)
        let api = MeAPI(transport: transport)

        _ = try await api.ownedDocuments(
            options: MeOwnedDocumentsOptions(includeRoot: true, forward: true)
        )
        let path = try XCTUnwrap(transport.lastCall?.path)
        XCTAssertTrue(path.contains("includeRoot=true"))
        XCTAssertTrue(path.contains("forward=true"))

        for options in [
            MeOwnedDocumentsOptions(refreshFromServer: false),
            MeOwnedDocumentsOptions(localOnly: true),
            MeOwnedDocumentsOptions(waitForLoad: .local),
        ] {
            let before = transport.calls.count
            _ = try await api.ownedDocuments(options: options)
            XCTAssertEqual(transport.calls.count, before, "\(options) must suppress the request")
        }

        // serverTimeoutMs: bounded fetch that throws on expiry.
        let stalled = RecordingTransport(responder: { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return TransportResponse(status: 200, headers: [:], body: Data())
        })
        let stalledAPI = MeAPI(transport: stalled)
        do {
            _ = try await stalledAPI.ownedDocuments(
                options: MeOwnedDocumentsOptions(serverTimeoutMs: 50, waitForLoad: .network)
            )
            XCTFail("serverTimeoutMs must bound the fetch")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .listTimeout)
        }
    }
}
