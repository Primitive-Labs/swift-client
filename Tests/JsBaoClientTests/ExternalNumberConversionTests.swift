import XCTest
@testable import JsBaoClient

/// Regression tests for the `Double → Int` conversions fed by data the
/// client does not control (#2056). None of them caused the `BlobManager`
/// crash, but each took an unbounded JSON / document number straight into
/// `Int(_:)`, which traps — aborting the whole process — on a non-finite or
/// out-of-range value. They now use `Int(exactly:)` and surface the bad value
/// as an error or an absent field instead. (The integration-proxy status case
/// left with `IntegrationsAPI`, retired by #3188.)
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
