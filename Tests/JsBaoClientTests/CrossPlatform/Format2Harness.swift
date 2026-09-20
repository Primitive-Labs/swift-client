import Foundation
import XCTest

/// Drives `harness/format2.cjs` — the TypeScript half of the format-2 parity
/// check (#3436, criterion 12).
///
/// The fold is the one thing in this design that must not drift: the Durable
/// Object's authoritative table and every client's merged view are folded by
/// one implementation (`overlaySql.ts`), and Swift is the third. So the Swift
/// tests never assert against a transcription of the expected rows — they
/// assert against what the REAL js-bao code, running in this subprocess,
/// produces for the same input.
///
/// **This harness FAILS rather than skips when `node` is missing.** The other
/// cross-platform suites are a superset gate and skip; a parity check that
/// silently skips is a criterion nobody is measuring.
enum Format2Harness {

    static var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("harness/format2.cjs")
    }

    /// Locate `node`, FAILING if there is none. Deliberately not the skipping
    /// lookup `CrossPlatformHarness` uses.
    static func nodePath() throws -> String {
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let env = Process()
        env.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        env.arguments = ["which", "node"]
        let out = Pipe()
        env.standardOutput = out
        env.standardError = Pipe()
        try env.run()
        env.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw Format2HarnessError(
            message: "node executable not found — the format-2 parity check "
                + "cannot run, and a parity check that skips is a criterion "
                + "nobody is measuring"
        )
    }

    /// Send one JSON request, read one JSON response.
    static func run(_ request: [String: Any]) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw Format2HarnessError(message: "harness missing at \(script.path)")
        }
        let requestData = try JSONSerialization.data(withJSONObject: request)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try nodePath())
        proc.arguments = [script.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        stdin.fileHandleForWriting.write(requestData)
        try stdin.fileHandleForWriting.close()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw Format2HarnessError(
                message: "format2.cjs exited \(proc.terminationStatus): "
                    + (String(data: errData, encoding: .utf8) ?? "")
                    + (String(data: outData, encoding: .utf8) ?? "")
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: outData) as? [String: Any]
        else {
            throw Format2HarnessError(
                message: "format2.cjs printed no JSON object: "
                    + (String(data: outData, encoding: .utf8) ?? "")
            )
        }
        if let error = object["error"] as? String {
            throw Format2HarnessError(message: "format2.cjs reported: \(error)")
        }
        return object
    }
}

struct Format2HarnessError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
