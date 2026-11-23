import XCTest
@testable import JsBaoClient

/// Regression tests for the `Double → Int` conversions fed by data the
/// client does not control (#2056). None of them caused the `BlobManager`
/// crash, but each took an unbounded JSON / document number straight into
/// `Int(_:)`, which traps — aborting the whole process — on a non-finite or
/// out-of-range value. They now use `Int(exactly:)` and surface the bad value
/// as an error or an absent field instead. (The integration-proxy status case
/// left with `IntegrationsAPI`, retired by #3188; the `DoDb.intValue` cases
/// left with `DoDb` and `client.databases`, retired by #3189.)
final class ExternalNumberConversionTests: XCTestCase {

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
