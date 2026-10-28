import Foundation
import XCTest
@testable import JsBaoClient

/// A model-free JS client in a Node child process
/// (`tests/client/helpers/record-log-model-free-child-4624.ts`, run as
/// `node --import tsx` from the repository root) on one document of a live
/// format-3 app. Each `send` writes one JSON command line and waits for the
/// child's one answer line. A child that cannot start, or that stops
/// answering, fails with its stderr rather than hanging; `stop` kills it.
final class ModelFreeJSChild: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lines = LockedBox<[String]>([])
    private let partial = LockedBox<Data>(Data())
    private let stderrText = LockedBox<String>("")
    private let directory: String
    private static let marker = "[model-free-child] "

    /// `requestText` replaces the request the child is handed (a test of a
    /// child that cannot start passes one it cannot parse).
    init(app: TestApp, documentId: String, requestText: String? = nil) throws {
        directory = NSTemporaryDirectory() + "rl-model-free-child-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let request: JSONValue = [
            "apiUrl": .string(TestConfig.httpUrl), "wsUrl": .string(TestConfig.wsUrl), "appId": .string(app.appId),
            "token": .string(app.ownerJWT), "globalAdminAppId": .string(TestConfig.globalAdminAppId),
            "dataDir": .string(directory), "documentId": .string(documentId),
        ]
        let repoRoot = ClientSourceText.repoRoot
        process.executableURL = URL(fileURLWithPath: try CrossPlatformHarness.nodePath())
        process.arguments = [
            "--import", "tsx", repoRoot.appendingPathComponent("tests/client/helpers/record-log-model-free-child-4624.ts").path,
            requestText ?? RecordLogJSON.text(request),
        ]
        process.currentDirectoryURL = repoRoot
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let lines = lines, partial = partial, stderrText = stderrText
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            partial.withValue { buffer in
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    // The child's answers; anything else is its client's log.
                    guard line.hasPrefix(Self.marker) else { continue }
                    lines.withValue { $0.append(String(line.dropFirst(Self.marker.count))) }
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrText.withValue { $0 += String(decoding: chunk, as: UTF8.self) }
        }
        try process.run()
    }

    /// Wait for the child's `{"ready":true}`: its client is connected and the document open.
    func ready(timeout: TimeInterval = 60) async throws {
        let line = try await nextLine(timeout: timeout, what: "the JS child to open the document")
        guard RecordLogJSON.parse(line)?["ready"] == .bool(true) else {
            throw TestSetupError("the JS child answered \(line) before it was ready; stderr: \(stderrText.value)")
        }
    }

    /// Send one command; the child's `value`, or a thrown error naming its refusal.
    @discardableResult
    func send(_ command: JSONValue, timeout: TimeInterval = 60) async throws -> JSONValue {
        let text = RecordLogJSON.text(command) + "\n"
        input.fileHandleForWriting.write(Data(text.utf8))
        let line = try await nextLine(timeout: timeout, what: "the JS child to answer \(text)")
        guard let reply = RecordLogJSON.parse(line) else { throw TestSetupError("the JS child answered \(line)") }
        guard reply["ok"] == .bool(true) else {
            throw JsBaoError(
                code: JsBaoErrorCode(rawValue: reply["code"]?.stringValue ?? "") ?? .unavailable,
                message: reply["error"]?.stringValue ?? line
            )
        }
        return reply["value"] ?? .null
    }

    /// Whether the child process is still running.
    var isRunning: Bool { process.isRunning }

    /// Kill the child, waiting until it has exited (SIGKILL after 5 s of
    /// SIGTERM), and remove its directory.
    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func nextLine(timeout: TimeInterval, what: String) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = lines.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) { return line }
            if !process.isRunning {
                // Let the last of stderr arrive.
                try await Task.sleep(nanoseconds: 200_000_000)
                if let line = lines.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) { return line }
                throw TestSetupError(
                    "the JS child exited \(process.terminationStatus) waiting for \(what); stderr: \(stderrText.value)"
                )
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestSetupError("timed out waiting for \(what); stderr: \(stderrText.value)")
    }
}
