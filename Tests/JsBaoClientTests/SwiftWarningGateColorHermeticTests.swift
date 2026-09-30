import Foundation
import XCTest

/// `scripts/check-swift-deprecations.sh` is the only thing standing between a
/// published Swift tree and a shipped compiler warning. #3588 found that it had
/// never been able to fail for a source reason: swiftc colorizes its
/// diagnostics *even when its output is redirected into a file*, putting an SGR
/// escape between the `: ` and the `warning:` that both of the gate's scan
/// patterns spelled literally. Five warnings shipped behind a gate reporting
/// every tree clean.
///
/// The gate's own unit suite (`tests/unit/scripts/swift-deprecation-gate.test.ts`)
/// missed it because every fixture it fed the script was uncolored. These cases
/// replay a log with the real escape bytes in it, through the committed script,
/// the same way that suite does: a stubbed `swift` on PATH cats a canned build
/// log, and a stubbed `xcrun` reports no iPhoneSimulator SDK so the gate runs
/// its host slice alone.
///
/// Why here as well as there: the Swift trees this gate guards are this
/// package's, and `swift test --filter HermeticTests` is the evidence command
/// the Swift side of the fleet replays.
final class SwiftWarningGateColorHermeticTests: XCTestCase {

    /// The severity marker as Swift 6.4 writes it into a redirected build log:
    /// `^[[1;33m` before the word, `^[[1;39m` after it, `^[[0m` closing the
    /// message. Real escape bytes — a fixture that wrote `^[` as two characters
    /// would pass against the very pattern this test exists to pin.
    private static let coloredWarning = "\u{1B}[1;33mwarning: \u{1B}[1;39m"
    private static let reset = "\u{1B}[0m"

    private struct GateRun {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run the committed gate against `log` in a throwaway repo root.
    ///
    /// `__ROOT__` in `log` is replaced with that root, so a fixture line can
    /// name a path inside one of the watched trees without knowing where the
    /// temp directory landed.
    private func runGate(log: String) throws -> GateRun {
        let script = try ClientSourceText.repoFile("scripts/check-swift-deprecations.sh")

        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-warning-gate-color-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // The gate resolves its root with `cd … && pwd`, which reports the
        // physical path (`/private/var/…`), and then matches that string
        // against the diagnostic lines. Resolve here so the fixture's paths
        // and the gate's `$ROOT` are spelled the same way.
        let root = created.resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: created) }

        let scripts = root.appendingPathComponent("scripts")
        let bin = root.appendingPathComponent("bin")
        for dir in [scripts, bin] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let scriptPath = scripts.appendingPathComponent("check-swift-deprecations.sh")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        let canned = log.replacingOccurrences(of: "__ROOT__", with: root.path)
        try write(
            executable: bin.appendingPathComponent("swift"),
            "#!/bin/bash\ncat <<'GATE_FIXTURE_LOG'\n\(canned)\nGATE_FIXTURE_LOG\nexit 0\n"
        )
        // No iPhoneSimulator SDK: the gate skips its cross-compile slice, so
        // the fixture needs no `Package.swift` for a deployment target to be
        // read out of.
        try write(
            executable: bin.appendingPathComponent("xcrun"),
            "#!/bin/bash\necho 'xcrun: unable to find SDK' >&2\nexit 1\n"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "")"
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return GateRun(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private func write(executable url: URL, _ body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    private func skipUnlessMonorepo() throws {
        try XCTSkipUnless(
            ClientSourceText.isMonorepoCheckout,
            "no repository root next to this package — standalone SPM checkout"
        )
    }

    func testDeprecationTierMatchesAColoredDiagnostic() throws {
        try skipUnlessMonorepo()

        let run = try runGate(
            log: """
            __ROOT__/packages/swift-primitive-app/Sources/PrimitiveApp/State/PrimitiveAppState.swift:407:26: \
            \(Self.coloredWarning)'signIn(email:password:)' is deprecated: Use signInAsync(email:password:).\(Self.reset)
            Build complete! (1.10s)
            """
        )

        XCTAssertEqual(run.status, 1, "gate stdout:\n\(run.stdout)\nstderr:\n\(run.stderr)")
        XCTAssertTrue(
            run.stderr.contains("in-repo Swift app-layer code calls deprecated declarations"),
            "deprecation tier did not report:\n\(run.stderr)"
        )
        XCTAssertTrue(
            run.stderr.contains(
                "packages/swift-primitive-app/Sources/PrimitiveApp/State/PrimitiveAppState.swift:407:26"
            ),
            "site not named:\n\(run.stderr)"
        )
    }

    func testWarningTierMatchesAColoredDiagnostic() throws {
        try skipUnlessMonorepo()

        let run = try runGate(
            log: """
            __ROOT__/swift-client/Sources/JsBaoClient/JsBaoClient.swift:3570:5: \
            \(Self.coloredWarning)'@discardableResult' declared on a function returning 'Void' is unnecessary\(Self.reset)
            Build complete! (0.80s)
            """
        )

        XCTAssertEqual(run.status, 1, "gate stdout:\n\(run.stdout)\nstderr:\n\(run.stderr)")
        XCTAssertTrue(
            run.stderr.contains("published Swift code builds with warnings"),
            "warning tier did not report:\n\(run.stderr)"
        )
        XCTAssertTrue(
            run.stderr.contains("swift-client/Sources/JsBaoClient/JsBaoClient.swift:3570:5"),
            "site not named:\n\(run.stderr)"
        )
        // The escapes are stripped before the scan, so the sites a human reads
        // carry no control bytes either.
        XCTAssertFalse(run.stderr.contains("\u{1B}["), "escape bytes in output:\n\(run.stderr)")
    }

    /// The control: the same fixture, with a log the compiler would write for a
    /// clean tree, passes. Without it a gate that failed unconditionally would
    /// satisfy both cases above.
    func testCleanBuildLogStillPasses() throws {
        try skipUnlessMonorepo()

        let run = try runGate(log: "Build complete! (0.42s)")

        XCTAssertEqual(run.status, 0, "gate stdout:\n\(run.stdout)\nstderr:\n\(run.stderr)")
        XCTAssertTrue(
            run.stdout.contains("no deprecated Primitive Swift client members"),
            "gate did not report a clean tree:\n\(run.stdout)"
        )
    }
}
