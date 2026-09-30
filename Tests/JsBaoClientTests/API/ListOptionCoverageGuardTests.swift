import XCTest
@testable import JsBaoClient

/// Guard against the defect class #2360 reported: an option field that
/// compiles, reads like JS parity, and silently does nothing.
///
/// Every field of `MeOwnedDocumentsOptions` must be in exactly one of two
/// buckets:
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
/// **The deprecated inventory is empty since #2367**, which removed the dead
/// fields #2360 deprecated rather than leaving them inert. It stays in the
/// structure because the classification requirement outlives this particular
/// clearing: a field added tomorrow still has to land in one bucket or the
/// other. (#2951 removed `ListDocumentsOptions` along with `documents.list`,
/// so only the owned-documents inventory is left.)
final class ListOptionCoverageGuardTests: XCTestCase {

    // MARK: - Inventories

    /// `MeOwnedDocumentsOptions`: every field is implemented since #2367
    /// removed `returnPage`. `serverTimeoutMs` is now `serverTimeout`, in
    /// seconds.
    private static let ownedDocumentsImplemented = [
        "includeRoot", "refreshFromServer", "localOnly", "serverTimeout",
        "waitForLoad", "forward",
    ]
    private static let ownedDocumentsDeprecated: [String] = []

    func testInventoriesCoverEveryField() {
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

    // MARK: - Observable effects: MeOwnedDocumentsOptions

    /// `includeRoot` / `forward` reach the query string; the local-first
    /// fields' effects are asserted in `MeOwnedDocumentsLocalFirstTests`
    /// (suppressed request for `localOnly` / `refreshFromServer`, typed throws
    /// for `waitForLoad` / `serverTimeout`). This test pins the query half
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

        // serverTimeout: bounded fetch that throws on expiry.
        let stalled = RecordingTransport(responder: { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return TransportResponse(status: 200, headers: [:], body: Data())
        })
        let stalledAPI = MeAPI(transport: stalled)
        do {
            _ = try await stalledAPI.ownedDocuments(
                options: MeOwnedDocumentsOptions(serverTimeout: 0.05, waitForLoad: .network)
            )
            XCTFail("serverTimeout must bound the fetch")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .listTimeout)
        }
    }
}
