import Foundation
import XCTest
@testable import swift_bao_codegen

/// #6304 — swift-bao-codegen reads a `date` default as the shared field
/// grammar reads it, so a Swift model fills the same instant the web client
/// and the room do.
///
/// `tests/fixtures/read-default-dates-6304/dates.json` lists date defaults
/// and the ISO string each reads as (`read-default-dates-6304.test.ts` holds
/// the grammar to it). The whole default is read: a space-separated time with
/// an offset keeps its time, and text after a date is no date literal.
final class ReadDefaultDatesHermeticTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Default: Decodable {
            let `default`: String
            let reads: String?
        }
        let defaults: [Default]
    }

    private func fixture() throws -> Fixture {
        var url = URL(fileURLWithPath: #filePath)
        // The file, SwiftBaoCodegenTests, Tests, swift-client.
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("tests/fixtures/read-default-dates-6304/dates.json"))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testADateDefaultReadsAsTheSharedGrammarReadsIt() throws {
        let defaults = try fixture().defaults
        XCTAssertFalse(defaults.isEmpty)
        for zone in ["UTC", "America/New_York", "Asia/Kolkata"] {
            let timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            for entry in defaults {
                XCTAssertEqual(SwiftEmitter.isoDate(entry.default, timeZone: timeZone), entry.reads, "\(entry.default) in \(zone)")
            }
        }
    }

    /// A date-time without an offset is local time, as `Date.parse` reads it.
    func testADateTimeWithoutAnOffsetIsLocalTime() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(SwiftEmitter.isoDate("2026-04-05T10:00", timeZone: newYork), "2026-04-05T14:00:00.000Z")
        XCTAssertEqual(SwiftEmitter.isoDate("2026-04-05 10:00", timeZone: newYork), "2026-04-05T14:00:00.000Z")
        XCTAssertEqual(SwiftEmitter.isoDate("2026-04-05T10:00:00.5", timeZone: newYork), "2026-04-05T14:00:00.500Z")
        // A date alone is UTC midnight wherever it is read.
        XCTAssertEqual(SwiftEmitter.isoDate("2026-04-05", timeZone: newYork), "2026-04-05T00:00:00.000Z")
    }

    /// Text after the date is no date literal; the old reader took the date
    /// prefix and dropped the rest.
    func testTextAfterADateIsNoDateLiteral() {
        XCTAssertNil(SwiftEmitter.isoDate("2026-04-05junk"))
        XCTAssertNil(SwiftEmitter.isoDate("2026-04-05 1:00 PM"))
    }
}
