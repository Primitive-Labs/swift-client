import XCTest

/// #5227 behaviour 9 — vec1 reaches a process's very first connections, and
/// SQLite's own initialization is left as it ships. SQLite sets vec1 up on each
/// connection it opens; this test process initialized SQLite long ago, so the
/// check runs in `JsBaoSQLiteProbe`, a fresh process (see its `main.swift`).
/// `sqlite3_config` must succeed before its first SQLite call, as it does for
/// any SQLite; two connections opened at once from two threads, its first
/// SQLite connections, must both answer vec1; and after it shuts SQLite down,
/// two more opened at once while SQLite initializes again must too. The probe
/// must finish: a registration that hung under the thread-safe build shows
/// here as the timeout.
final class BundledSQLiteFreshProcessHermeticTests: XCTestCase {

    private static let timeout: TimeInterval = 10

    /// The built `JsBaoSQLiteProbe`, in the products directory beside this
    /// test bundle. `swift test` builds it with the test target.
    private func probeBinary() throws -> URL {
        let bundle = Bundle(for: Self.self).bundleURL
        let candidates = [
            bundle.deletingLastPathComponent().appendingPathComponent("JsBaoSQLiteProbe"),
            bundle.appendingPathComponent("JsBaoSQLiteProbe"),
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            XCTFail("JsBaoSQLiteProbe is not built beside the test bundle: \(candidates.map(\.path))")
            throw CocoaError(.fileNoSuchFile)
        }
        return binary
    }

    /// The vec1 version js-bao's sqlite-wasm build carries: the `vec1:` line of
    /// `packages/js-bao/vendor/sqlite-wasm/VERSION`.
    private static func wasmVec1() throws -> String {
        let lines = try ClientSourceText.repoFile("packages/js-bao/vendor/sqlite-wasm/VERSION").split(separator: "\n")
        let line = try XCTUnwrap(lines.first { $0.hasPrefix("vec1: ") }, "the wasm VERSION names its vec1")
        return String(line.dropFirst("vec1: ".count)).trimmingCharacters(in: .whitespaces)
    }

    func testFirstConnectionsAnswerVec1BeforeAndAfterAShutdown() throws {
        let expected = try Self.wasmVec1()
        let process = Process()
        process.executableURL = try probeBinary()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let timedOut = exited.wait(timeout: .now() + Self.timeout) == .timedOut
        if timedOut {
            process.terminate()
            exited.wait()
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertFalse(timedOut, "the probe did not finish within \(Int(Self.timeout)) s; it printed: \(text)")
        XCTAssertEqual(process.terminationStatus, 0, "the probe printed: \(text)")

        let lines = text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        let steps = lines.filter { $0["step"] != nil }
        XCTAssertEqual(steps.compactMap { $0["step"] as? String }, ["config", "shutdown", "config after shutdown"], text)
        for step in steps {
            XCTAssertEqual(step["rc"] as? Int, 0, "\(step["step"] ?? "?") is SQLITE_OK: \(text)")
        }
        let connections = lines.filter { $0["round"] != nil }
        XCTAssertEqual(
            connections.map { "\($0["round"] ?? "?").\($0["thread"] ?? "?")" }.sorted(), ["1.1", "1.2", "2.1", "2.2"],
            "one line per thread and round: \(text)"
        )
        for line in connections {
            let which = "round \(line["round"] ?? "?") thread \(line["thread"] ?? "?")"
            XCTAssertNil(line["error"], "\(which): \(text)")
            XCTAssertEqual(line["vec1"] as? String, expected, "\(which): \(text)")
            XCTAssertEqual(line["rowid"] as? Int, 2, "\(which): \(text)")
            XCTAssertEqual(line["d"] as? Double ?? -1, 0.02, accuracy: 1e-6, "\(which): \(text)")
        }
    }
}
