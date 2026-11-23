import XCTest
import Foundation
@testable import JsBaoClient

/// Reading a stored entry or row back into a `JSONValue` throws no Swift
/// error for well-formed JSON, and gives the value `JSONDecoder` gives.
///
/// The decoder's `JSONValue.init(from:)` probes each kind with `try?`, so a
/// string throws twice and an object four times; on the record-log store's
/// hot path that was most of the time an acknowledgement took. Throws are
/// counted through the Swift runtime's own `_swift_willThrow` hook — the one
/// XCTest installs to observe errors — so nothing stands in for the runtime.
final class RecordLogJSONParseHermeticTests: XCTestCase {

    // MARK: - Round trips

    func testEveryJSONKindRoundTripsThroughTheStoredText() {
        let values: [JSONValue] = [
            .null,
            .bool(true),
            .bool(false),
            .number(0),
            .number(1),
            .number(-42),
            .number(0.1),
            .number(-2.5e-8),
            .number(9_007_199_254_740_992),
            .number(1.7976931348623157e308),
            .string(""),
            .string("plain"),
            .string("quote \" backslash \\ slash / tab \t newline \n control \u{01}"),
            .string("é ü 漢字 🎉"),
            .array([]),
            .array([.number(1), .bool(true), .number(0), .bool(false), .null, .string("1")]),
            .object([:]),
            .object(["a": .number(1), "b": .bool(true), "c": .null, "d": .string("x")]),
            .object([
                "nested": .object(["list": .array([.object(["deep": .array([.array([.bool(false)])])])])]),
                "emoji 🎉": .string("v"),
            ]),
        ]
        for value in values {
            let text = RecordLogJSON.text(value)
            XCTAssertEqual(RecordLogJSON.parse(text), value, text)
        }
    }

    func testABoolStaysDistinctFromZeroAndOne() {
        XCTAssertEqual(RecordLogJSON.parse("true"), .bool(true))
        XCTAssertEqual(RecordLogJSON.parse("false"), .bool(false))
        XCTAssertEqual(RecordLogJSON.parse("1"), .number(1))
        XCTAssertEqual(RecordLogJSON.parse("0"), .number(0))
        XCTAssertEqual(
            RecordLogJSON.parse("[true,1,false,0]"),
            .array([.bool(true), .number(1), .bool(false), .number(0)])
        )
        XCTAssertEqual(RecordLogJSON.row("{\"done\":true,\"n\":1}"), ["done": .bool(true), "n": .number(1)])
    }

    /// The parse gives what `JSONDecoder` gives — the same value for JSON, and
    /// nothing for text that is not JSON.
    func testTheParseAgreesWithJSONDecoder() {
        let texts = [
            // Well-formed.
            "null", "true", "false", "0", "-0", "7", "-12", "3.25", "1e3", "1E-3", "-1.5e+10", "123456789012345678",
            "0.30000000000000004", "\"\"", "\"a\"", "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"", "\"\\u00e9\\u6f22\"",
            "\"\\ud83c\\udf89\"", "\"é漢🎉\"", "[]", "{}", " \t\r\n[ 1 , 2 ]\n ", "{\"a\":{\"b\":[{\"c\":null}]}}",
            "{\"k\" : \"v\" , \"n\" : -0.5}", "[[[[[]]]]]",
            // Not JSON.
            "", " ", "nul", "tru", "fals", "nulll", "01", "-", "1.", ".5", "1e", "+1", "--1", "0x10", "NaN", "Infinity",
            "\"unterminated", "\"bad \\x escape\"", "\"\\u12\"", "\"raw \u{01} control\"", "[1,]", "[1 2]", "[",
            "]", "{", "{\"a\"}", "{\"a\":}", "{\"a\":1,}", "{a:1}", "{\"a\":1 \"b\":2}", "1 2", "[] x", "'a'",
            "1e400", "-1e400", "1e-400", "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800x\"", "{\"a\":1,\"a\":2}", "[,]", "[1,,]",
            String(repeating: "[", count: 600) + String(repeating: "]", count: 600),
            String(repeating: "[", count: 400) + String(repeating: "]", count: 400),
        ]
        for text in texts {
            let expected = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            XCTAssertEqual(RecordLogJSON.parse(text), expected, "parse(\(text.debugDescription))")
        }
    }

    /// A byte-order mark before the document is skipped, as the decoder skips
    /// it, and only there. A repeated key's later value is never converted by
    /// the decoder, so one the type could not carry — or one only its scanner
    /// would pass — does not refuse the object that keeps the first.
    func testABOMAndADiscardedRepeatedValueReadAsJSONDecoderReadsThem() {
        let discarded = [
            "1e400", "-1e400", "1e-400", "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"", "\"\\x\"", "\"\\uZZZZ\"",
            "\"raw \u{01} control\"", "01", "1.", "-", "1e", "1e+", "--1", "1-2", "1.2.3", "1ee2", "[1e400]", "[01]",
            "{\"b\":01}", "{\"x\":1,\"x\":1e400}", "{\"\\x\":1}", "[1,]", "{\"b\":1,}",
            // Still refused: what the decoder's scanner checks in a value it discards.
            "\"\\u12\"", "-a", "1x", "+1", ".5", "Infinity", "NaN", "0x10", "nul", "truex", "true1", "\"a\"x",
            "\"\\\"", "{\"b\" 1}", "{1:2}", "[1 2]", "[,]", "{,}", "[1,,2]", "\"open",
            String(repeating: "[", count: 600) + String(repeating: "]", count: 600),
        ]
        var texts = [
            "\u{FEFF}{\"a\":1}", "\u{FEFF}1", "\u{FEFF}\"x\"", "\u{FEFF} {\"a\":1}", " \u{FEFF}{\"a\":1}",
            "\u{FEFF}", "[\u{FEFF}1]", "\u{FEFF}\u{FEFF}1", "{\"a\":1e400,\"a\":1}", "{\"a\":1,\"a\":1e400,\"a\":2}",
            "[{\"a\":1,\"a\":1e400}]", "{\"a\":{\"x\":1,\"x\":1e400}}",
        ]
        for value in discarded {
            texts.append("{\"a\":1,\"a\":\(value)}")
            texts.append("{\"a\":1,\"a\":\(value),\"b\":true}")
            texts.append("{\"a\":\(value)}")
        }
        for text in texts {
            let expected = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            XCTAssertEqual(RecordLogJSON.parse(text), expected, "parse(\(text.debugDescription))")
        }
        XCTAssertEqual(RecordLogJSON.row("{\"a\":1,\"a\":1e400}"), ["a": .number(1)])
        XCTAssertEqual(RecordLogJSON.parse("\u{FEFF}{\"a\":1}"), .object(["a": .number(1)]))
    }

    // MARK: - No thrown errors

    func testParsingAStoredEntryAndARowThrowsNoSwiftError() throws {
        let row: JSONValue = .object([
            "id": .string("n00001"), "title": .string("t1"), "n": .number(1), "done": .bool(false),
            "tags": .array([.string("a"), .string("b")]), "meta": .object(["x": .null, "y": .number(2.5)]),
        ])
        let entry: JSONValue = .object([
            "seq": .number(1), "w": .string("writer"),
            "mutations": .array([.object(["model": .string("Note"), "kind": .string("create"), "fields": row])]),
        ])
        let entryText = RecordLogJSON.text(entry)
        let rowText = RecordLogJSON.text(row)

        var parsedEntry: JSONValue?
        var parsedRow: RecordLogRow = [:]
        let thrown = try SwiftThrowCounter.counting {
            parsedEntry = RecordLogJSON.parse(entryText)
            parsedRow = RecordLogJSON.row(rowText)
        }
        XCTAssertEqual(parsedEntry, entry)
        XCTAssertEqual(parsedRow, row.objectValue)
        XCTAssertEqual(thrown, 0, "Swift errors thrown while parsing well-formed JSON")
    }

    /// The counter itself counts: one throw caught on this thread reads as one.
    func testTheThrowCounterSeesAThrow() throws {
        struct Probe: Error {}
        let thrown = try SwiftThrowCounter.counting {
            _ = try? { () throws -> Int in throw Probe() }()
        }
        XCTAssertEqual(thrown, 1)
    }
}

/// Counts the Swift errors thrown on the calling thread while `body` runs,
/// through the runtime's `_swift_willThrow` hook. The hook in place before —
/// XCTest's own — is chained to and put back afterwards.
enum SwiftThrowCounter {
    private typealias Hook = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private nonisolated(unsafe) static var previous: Hook?
    private nonisolated(unsafe) static var thread: pthread_t?
    private nonisolated(unsafe) static var count = 0
    private static let lock = NSLock()

    static func counting(_ body: () -> Void) throws -> Int {
        // `RTLD_DEFAULT`, which Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_swift_willThrow") else {
            throw XCTSkip("the Swift runtime exports no _swift_willThrow hook")
        }
        let slot = symbol.assumingMemoryBound(to: Optional<Hook>.self)
        lock.lock()
        defer { lock.unlock() }
        previous = slot.pointee
        thread = pthread_self()
        count = 0
        slot.pointee = { error in
            if let thread = SwiftThrowCounter.thread, pthread_equal(thread, pthread_self()) != 0 {
                SwiftThrowCounter.count += 1
            }
            SwiftThrowCounter.previous?(error)
        }
        defer {
            slot.pointee = previous
            thread = nil
        }
        body()
        return count
    }
}
