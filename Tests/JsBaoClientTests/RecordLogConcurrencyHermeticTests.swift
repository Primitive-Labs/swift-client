import XCTest

/// The record-log client's concurrency claims, read from its source: the
/// session is an actor whose decision regions never suspend, and every
/// `@unchecked Sendable` in the module carries a written safety argument
/// naming the lock it rests on.
final class RecordLogConcurrencyHermeticTests: XCTestCase {

    func testTheSessionIsAnActorAndItsFrameHandlersNeverSuspend() throws {
        let source = try ClientSourceText.code("RecordLog/RecordLogSession.swift")
        XCTAssertTrue(source.contains("actor RecordLogSession {"), "the session is an actor")
        // From the open to the last frame handler: every decision the session
        // makes about a frame, a refusal or an open. A suspension anywhere in
        // here would let a later frame, or a disconnect, interleave with it.
        let regions = [
            try ClientSourceText.slice(source, from: "func start() {", to: "func disconnected() {"),
            try ClientSourceText.slice(source, from: "func receive(_ frame: [String: JSONValue]) {", to: "private func committed("),
        ]
        for region in regions {
            XCTAssertFalse(region.contains("await"), "a decision region must not suspend:\n\(region.prefix(400))")
        }
        // The handlers the region must cover, by name.
        for handler in [
            "func opened(", "func catchUpPage(", "func results(", "func refused(", "func gap(",
            "func released(", "func error(", "func caughtUp(", "func drain(",
        ] {
            XCTAssertTrue(regions[1].contains(handler), "\(handler) is inside the region under test")
        }
    }

    func testEveryUncheckedSendableInTheModuleNamesTheLockItRestsOn() throws {
        let files = try ClientSourceText.packageSwiftFiles().filter {
            $0.hasPrefix("Sources/JsBaoClient/RecordLog/") || $0 == "Sources/JsBaoClient/Schema/LocalRecordDelegate.swift"
        }
        XCTAssertGreaterThan(files.count, 5)
        var claims = 0
        for file in files {
            let lines = try ClientSourceText.packageFile(file).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(": @unchecked Sendable")
                && (line.contains("class ") || line.contains("struct ")) {
                claims += 1
                var comment: [String] = []
                var at = index - 1
                while at >= 0, lines[at].trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    comment.insert(lines[at], at: 0)
                    at -= 1
                }
                let argument = comment.joined(separator: "\n")
                XCTAssertTrue(argument.contains("`@unchecked Sendable`"), "\(file): \(line) carries no safety argument")
                XCTAssertTrue(argument.contains("lock"), "\(file): \(line)'s argument names no lock:\n\(argument)")
            }
        }
        XCTAssertGreaterThanOrEqual(claims, 4, "the store, the group commit, the binding and its delivery box")
    }
}
