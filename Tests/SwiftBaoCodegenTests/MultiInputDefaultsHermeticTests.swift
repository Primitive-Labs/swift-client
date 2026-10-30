import Foundation
import XCTest
@testable import swift_bao_codegen

/// Two declarations of one model across inputs compare their `default`
/// values as TOML values (#5025, 5025-SO-010), including the dates, times and
/// arrays the emitter does not write, so Swift refuses what js-bao refuses.
/// One input, and duplicates that agree, render as before.
final class MultiInputDefaultsHermeticTests: XCTestCase {

    private static func events(_ name: String, whenDefault: String, tagsDefault: String = "[\"a\"]") -> String {
        """
        [type]
        name = "\(name)"

        [models.events]
        class_name = "Event"

        [models.events.fields.code]
        type = "string"

        [models.events.fields.when]
        type = "date"
        default = \(whenDefault)

        [models.events.fields.tags]
        type = "stringset"
        default = \(tagsDefault)
        """
    }

    private func render(_ documents: [(String, String)]) throws -> [String: String] {
        let files = try CodegenRun.render(
            documents: documents.map { (sourceName: $0.0, source: $0.1) },
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
    }

    private func failure(_ documents: [(String, String)], file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            let files = try render(documents)
            XCTFail("expected a refusal, got \(files.keys.sorted())", file: file, line: line)
            return ""
        } catch let error as CodegenError {
            return error.description
        } catch {
            XCTFail("expected a CodegenError, got \(error)", file: file, line: line)
            return ""
        }
    }

    func testDifferingDateDefaultsAreRefusedNamingTheField() {
        let message = failure([
            ("a.toml", Self.events("a", whenDefault: "2020-01-01")),
            ("b.toml", Self.events("b", whenDefault: "2021-01-01")),
        ])
        XCTAssertTrue(message.contains("`events`"), message)
        XCTAssertTrue(message.contains("a.toml"), message)
        XCTAssertTrue(message.contains("b.toml"), message)
        XCTAssertTrue(message.contains("field `when` differs"), message)
        XCTAssertFalse(message.contains("field `tags`"), message)
    }

    func testDifferingTimeAndDateTimeDefaultsAreRefused() {
        XCTAssertTrue(failure([
            ("a.toml", Self.events("a", whenDefault: "10:00:00")),
            ("b.toml", Self.events("b", whenDefault: "11:00:00")),
        ]).contains("field `when` differs"))
        XCTAssertTrue(failure([
            ("a.toml", Self.events("a", whenDefault: "2020-01-01T10:00:00Z")),
            ("b.toml", Self.events("b", whenDefault: "2020-01-01T10:00:00")),
        ]).contains("field `when` differs"))
        XCTAssertTrue(failure([
            ("a.toml", Self.events("a", whenDefault: "2020-01-01")),
            ("b.toml", Self.events("b", whenDefault: "2020-01-01T00:00:00")),
        ]).contains("field `when` differs"))
    }

    func testDifferingStringSetDefaultsAreRefused() {
        let message = failure([
            ("a.toml", Self.events("a", whenDefault: "2020-01-01", tagsDefault: "[\"a\"]")),
            ("b.toml", Self.events("b", whenDefault: "2020-01-01", tagsDefault: "[\"a\", \"b\"]")),
        ])
        XCTAssertTrue(message.contains("field `tags` differs"), message)
        XCTAssertFalse(message.contains("field `when`"), message)
    }

    func testAgreeingDefaultsAreOneStructAsOneInputRendersIt() throws {
        let a = Self.events("a", whenDefault: "2020-01-01T10:00:00Z")
        let both = try render([("a.toml", a), ("b.toml", Self.events("b", whenDefault: "2020-01-01T10:00:00Z"))])
        XCTAssertEqual(both.keys.sorted(), ["Event.swift", "GeneratedModels.swift"])
        XCTAssertEqual(both["Event.swift"], try render([("a.toml", a)])["Event.swift"])
    }
}
