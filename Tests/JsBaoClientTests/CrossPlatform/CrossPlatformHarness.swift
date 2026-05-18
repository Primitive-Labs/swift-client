import Foundation
import YSwift
import Yniffi
import XCTest

/// Helpers that drive the cjs harness scripts under
/// `CrossPlatform/harness/*.cjs`. These tests spawn Node subprocesses
/// to exercise the *real* js-bao read/write path against Swift-produced
/// (and JS-produced) YDoc update bytes, so we're not just assuming the
/// wire format matches — we're verifying it with both sides running.
///
/// Skips (with XCTSkip) if Node or the scripts aren't found; the
/// cross-platform tests are a superset gate, not a baseline.
enum CrossPlatformHarness {

    /// Absolute path to the `harness/` directory. The scripts resolve
    /// `require("js-bao")` / `require("yjs")` against the repo's
    /// `node_modules`, which lives two levels above `harness/`.
    static var harnessDir: URL {
        // __FILE__ equivalent — this file lives at
        // swift-client/Tests/JsBaoClientTests/CrossPlatform/CrossPlatformHarness.swift
        let thisFile = URL(fileURLWithPath: #file)
        return thisFile.deletingLastPathComponent().appendingPathComponent("harness")
    }

    static var readerScript: URL { harnessDir.appendingPathComponent("reader.cjs") }
    static var writerScript: URL { harnessDir.appendingPathComponent("writer.cjs") }
    static var schemaLoaderScript: URL {
        harnessDir.appendingPathComponent("schema-loader.cjs")
    }
    static var fixturesDir: URL {
        harnessDir.appendingPathComponent("fixtures")
    }

    /// Locate a `node` executable. Skips the test if none is found.
    static func nodePath() throws -> String {
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // Fall back to PATH lookup via /usr/bin/env.
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
        throw XCTSkip("node executable not found — cross-platform tests skipped")
    }

    /// Ensure the harness scripts are on disk. Skips otherwise.
    static func requireScripts() throws {
        guard FileManager.default.fileExists(atPath: readerScript.path),
              FileManager.default.fileExists(atPath: writerScript.path)
        else {
            throw XCTSkip("Harness scripts missing at \(harnessDir.path)")
        }
    }

    // MARK: - Reader: Swift-authored update → JS

    /// Run the JS reader on a Swift-produced update, capturing the JSON
    /// result. Throws if the subprocess fails.
    static func runReader(
        update: Data,
        arguments: [String]
    ) throws -> Any {
        try requireScripts()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try nodePath())
        proc.arguments = [readerScript.path] + arguments

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        stdin.fileHandleForWriting.write(update)
        try stdin.fileHandleForWriting.close()
        proc.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            throw HarnessError(
                exitCode: proc.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }
        return try JSONSerialization.jsonObject(with: outData, options: [])
    }

    // MARK: - Writer: JSON spec → JS-authored update → Swift

    /// Run the JS writer on a spec JSON; returns the produced update
    /// bytes suitable for `txn.transactionApplyUpdate`.
    static func runWriter(spec: Any) throws -> Data {
        try requireScripts()
        let specData = try JSONSerialization.data(withJSONObject: spec, options: [])
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try nodePath())
        proc.arguments = [writerScript.path]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        stdin.fileHandleForWriting.write(specData)
        try stdin.fileHandleForWriting.close()
        proc.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            throw HarnessError(
                exitCode: proc.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }
        return outData
    }

    // MARK: - Schema loader: TOML file → js-bao's loadSchemaFromTomlString output

    /// Run the JS schema-loader script against a TOML file on disk,
    /// returning the parsed JSON array js-bao emits
    /// (`DefinedModelSchema[]`).
    static func runSchemaLoader(tomlPath: URL) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: schemaLoaderScript.path) else {
            throw XCTSkip("schema-loader.cjs missing at \(schemaLoaderScript.path)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try nodePath())
        proc.arguments = [schemaLoaderScript.path, tomlPath.path]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        proc.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            throw HarnessError(
                exitCode: proc.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }
        let obj = try JSONSerialization.jsonObject(with: outData, options: [])
        guard let arr = obj as? [[String: Any]] else {
            throw HarnessError(
                exitCode: 0,
                stderr: "expected JSON array of schema objects, got \(type(of: obj))"
            )
        }
        return arr
    }

    // MARK: - Doc helpers

    /// Encode a YDoc's full state as update bytes.
    static func updateBytes(of doc: YDocument) -> Data {
        return doc.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
    }

    /// Apply update bytes to a YDoc (usually a fresh one).
    static func apply(update: Data, to doc: YDocument) throws {
        doc.transactSync { txn in
            _ = try? txn.transactionApplyUpdate(update: Array(update))
        }
    }

    struct HarnessError: Error, CustomStringConvertible {
        let exitCode: Int32
        let stderr: String
        var description: String {
            "Harness subprocess exit \(exitCode): \(stderr)"
        }
    }
}
