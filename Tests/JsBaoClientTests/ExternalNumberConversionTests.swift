import XCTest
@testable import JsBaoClient

/// Regression tests for the three `Double → Int` conversions fed by data the
/// client does not control (#2056). None of them caused the `BlobManager`
/// crash, but all three took an unbounded JSON / document number straight into
/// `Int(_:)`, which traps — aborting the whole process — on a non-finite or
/// out-of-range value. They now use `Int(exactly:)` and surface the bad value
/// as an error or an absent field instead.
final class ExternalNumberConversionTests: XCTestCase {

    // MARK: - DoDb.intValue (API/DoDb.swift)

    func testDoDbIntValueAcceptsInRangeNumbers() throws {
        XCTAssertEqual(try DoDb.intValue(7, field: "count"), 7)
        XCTAssertEqual(try DoDb.intValue(7.0, field: "count"), 7)
        // Truncation toward zero, as the old `Int(_:)` did.
        XCTAssertEqual(try DoDb.intValue(7.9, field: "count"), 7)
        XCTAssertEqual(try DoDb.intValue(-7.9, field: "count"), -7)
    }

    func testDoDbIntValueRejectsOutOfRangeNumbersInsteadOfTrapping() {
        for bad: Double in [.infinity, -.infinity, .nan, 1e30, -1e30] {
            XCTAssertThrowsError(
                try DoDb.intValue(bad, field: "count"),
                "value \(bad) must surface as an error, not trap"
            ) { error in
                XCTAssertEqual(error as? DoDbError, .unexpectedResponse(field: "count"))
            }
        }
    }

    func testDoDbIntValueRejectsMissingField() {
        XCTAssertThrowsError(try DoDb.intValue(nil, field: "count")) { error in
            XCTAssertEqual(error as? DoDbError, .unexpectedResponse(field: "count"))
        }
    }

    // MARK: - Integration proxy status (API/IntegrationsAPI.swift)

    /// Returns a canned proxy envelope so `IntegrationsAPI.call` runs its real
    /// envelope parsing over a hostile `status` value.
    private struct StubTransport: Transport {
        let json: String

        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(json.utf8)
            )
        }
    }

    private func callProxy(envelope json: String) async throws -> IntegrationCallResponse {
        let api = IntegrationsAPI(transport: StubTransport(json: json))
        return try await api.call(IntegrationCallRequest(integrationKey: "k"))
    }

    func testIntegrationStatusDecodesInRangeNumbers() async throws {
        let ok = try await callProxy(envelope: #"{"status":200}"#).status
        XCTAssertEqual(ok, 200)
        let whole = try await callProxy(envelope: #"{"status":404.0}"#).status
        XCTAssertEqual(whole, 404)
        // Truncation toward zero, as the old `Int(_:)` did.
        let fractional = try await callProxy(envelope: #"{"status":404.7}"#).status
        XCTAssertEqual(fractional, 404)
    }

    func testIntegrationStatusRejectsOutOfRangeNumbersInsteadOfTrapping() async {
        // Finite but far past `Int.max`, plus the JSON spellings that carry no
        // usable number at all. Every one of these used to reach a trapping
        // `Int(_:)`.
        //
        // A JSON literal that overflows `Double` itself (`1e400`) is not
        // covered here: it never reaches this parser. `TransportResponse`'s
        // `JSONValue` conversion re-serializes the parsed graph through
        // `JSONSerialization`, which rejects the resulting infinity one layer
        // earlier — a separate hardening question from this conversion.
        for bad in ["1e30", "-1e30", "\"200\"", "null"] {
            do {
                let response = try await callProxy(envelope: "{\"status\":\(bad)}")
                XCTFail("status \(bad) must be rejected, not decoded as \(response.status)")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .integrationProxyFailed, "status \(bad)")
            } catch {
                XCTFail("status \(bad) threw an unexpected error: \(error)")
            }
        }
    }

    func testIntegrationMissingStatusIsRejected() async {
        do {
            let response = try await callProxy(envelope: #"{"headers":{}}"#)
            XCTFail("a missing status must be rejected, not decoded as \(response.status)")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .integrationProxyFailed)
            XCTAssertEqual(error.message, "Integration response missing status")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - SchemaDiscovery.boundedInt (Schema/SchemaDiscovery.swift)

    func testSchemaBoundedIntAcceptsInRangeNumbers() {
        XCTAssertEqual(SchemaDiscovery.boundedInt(64), 64)
        XCTAssertEqual(SchemaDiscovery.boundedInt(64.8), 64)
        XCTAssertEqual(SchemaDiscovery.boundedInt(0), 0)
    }

    func testSchemaBoundedIntRejectsOutOfRangeNumbersInsteadOfTrapping() {
        for bad: Double in [.infinity, -.infinity, .nan, 1e30, -1e30] {
            XCTAssertNil(
                SchemaDiscovery.boundedInt(bad),
                "value \(bad) must decode as absent, not trap")
        }
        XCTAssertNil(SchemaDiscovery.boundedInt(nil))
    }
}
