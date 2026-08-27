import Foundation
import XCTest

/// The codegen plugin must compile with no warnings (#2966).
///
/// `JsBaoCodegenPlugin` reached the consuming target's source directory
/// through `target.directory.string`, and PackagePlugin deprecated `Path` in
/// favour of `URL`. Every consumer build printed
/// `'string' is deprecated: Use `URL` type instead of `Path`` — the plugin is
/// compiled by SwiftPM in each package that uses it, so the warning was not
/// ours to see once and forget. The replacement accessor,
/// `Target.directoryURL`, is gated on `swift-tools-version: 6.1`, which is
/// why the manifest declares that version.
///
/// **How this is checked.** SwiftPM compiles a plugin target with the package
/// description version taken from the manifest, so the same diagnostics are
/// reproducible with one `swiftc -typecheck` over the plugin sources with
/// `-package-description-version` set to the version `Package.swift` declares.
/// The gate therefore cannot drift from the manifest: bump the tools version
/// and this compiles at the new version too.
///
/// Hermetic in the sense the rest of this suite uses: no server, no package
/// build, no network. It does run `swiftc` — the same toolchain already
/// running these tests — because a compiler diagnostic is the thing under
/// test and a source-text search would only guess at it.
final class PluginDeprecationHermeticTests: XCTestCase {

    // MARK: - Locations

    /// `#filePath` is this file under `swift-client/Tests/SwiftBaoCodegenTests/`.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SwiftBaoCodegenTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-client
    }

    private var manifestURL: URL { packageRoot.appending(path: "Package.swift") }

    private var pluginDirectory: URL {
        packageRoot.appending(path: "Plugins/JsBaoCodegenPlugin")
    }

    /// Every source file in the plugin target, so a file added beside
    /// `JsBaoCodegenPlugin.swift` is held to the same bar.
    private func pluginSources() throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: pluginDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(names.isEmpty, "no plugin sources at \(pluginDirectory.path)")
        return names.map { pluginDirectory.appending(path: $0) }
    }

    // MARK: - Manifest

    /// The version on the manifest's `// swift-tools-version:` line — the
    /// version SwiftPM compiles the plugin against, and the toolchain floor
    /// the package imposes on consumers.
    private func declaredToolsVersion() throws -> String {
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let firstLine = manifest.components(separatedBy: "\n").first ?? ""
        let pattern = /^\/\/ swift-tools-version:\s*([0-9]+(?:\.[0-9]+)*)/
        guard let match = try pattern.firstMatch(in: firstLine) else {
            XCTFail("no swift-tools-version line at the top of Package.swift: \(firstLine)")
            return ""
        }
        return String(match.1)
    }

    private func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// `a >= b`, comparing component by component (`6.10` is after `6.9`).
    private func version(_ a: String, isAtLeast b: String) -> Bool {
        let left = versionComponents(a)
        let right = versionComponents(b)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return true
    }

    // MARK: - Compiler harness

    private func run(_ executable: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The `swiftc` that goes with the toolchain running this test. Through
    /// `xcrun` on macOS so the compiler is handed an SDK; straight off `PATH`
    /// elsewhere.
    private func swiftcInvocation() throws -> (URL, [String]) {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        if FileManager.default.isExecutableFile(atPath: xcrun.path) {
            return (xcrun, ["swiftc"])
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["swiftc"])
    }

    /// `<toolchain>/usr/lib/swift/pm/PluginAPI`, the directory holding the
    /// `PackagePlugin` module SwiftPM compiles plugins against.
    private func pluginAPIDirectory() throws -> URL {
        let (executable, _) = try swiftcInvocation()
        let locator: (URL, [String]) =
            executable.lastPathComponent == "xcrun"
            ? (executable, ["-f", "swiftc"])
            : (URL(fileURLWithPath: "/usr/bin/env"), ["which", "swiftc"])
        let (status, output) = try run(locator.0, locator.1)
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, !path.isEmpty else {
            XCTFail("could not locate swiftc: \(output)")
            return packageRoot
        }
        let directory = URL(fileURLWithPath: path)
            .deletingLastPathComponent()  // bin
            .deletingLastPathComponent()  // usr
            .appending(path: "lib/swift/pm/PluginAPI")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path),
            "no PackagePlugin module at \(directory.path)")
        return directory
    }

    /// Type-check `sources` exactly the way SwiftPM compiles the plugin
    /// target: Swift 6 language mode (the package pins `swiftLanguageModes:
    /// [.v6]`) and the package description version off the manifest. No
    /// diagnostic-suppressing flags — the point is to see every warning.
    private func typecheck(_ sources: [URL], packageDescriptionVersion: String) throws -> (
        Int32, String
    ) {
        let (executable, prefix) = try swiftcInvocation()
        let arguments =
            prefix + [
                "-typecheck",
                "-swift-version", "6",
                "-package-description-version", packageDescriptionVersion,
                "-parse-as-library",
                "-I", try pluginAPIDirectory().path,
            ] + sources.map(\.path)
        return try run(executable, arguments)
    }

    /// Diagnostic lines (`…: warning: …` / `…: error: …`), without the source
    /// snippets the compiler prints under them.
    private func diagnostics(in output: String) -> [String] {
        output.components(separatedBy: "\n").filter {
            $0.contains(": warning: ") || $0.contains(": error: ")
        }
    }

    // MARK: - Behavior

    func testPluginCompilesWithNoDiagnosticsAtTheDeclaredToolsVersion() throws {
        let toolsVersion = try declaredToolsVersion()
        let (status, output) = try typecheck(
            try pluginSources(), packageDescriptionVersion: toolsVersion)
        let found = diagnostics(in: output)
        XCTAssertEqual(
            status, 0,
            "the plugin does not compile at swift-tools-version \(toolsVersion):\n\(output)")
        XCTAssertEqual(
            found, [],
            "the codegen plugin must compile warning-free at the tools version its own "
                + "manifest declares — every consumer build compiles it (#2966):\n"
                + found.joined(separator: "\n"))
    }

    /// The manifest is what makes the non-deprecated accessor reachable:
    /// `Target.directoryURL` is unavailable before PackageDescription 6.1
    /// ("'directoryURL' was introduced in PackageDescription 6.1"), and the
    /// only 6.0 route to the same URL goes through the deprecated `Path`.
    func testManifestDeclaresAToolsVersionThatOffersTheDirectoryURLAccessor() throws {
        let toolsVersion = try declaredToolsVersion()
        XCTAssertTrue(
            version(toolsVersion, isAtLeast: "6.1"),
            "swift-tools-version \(toolsVersion) has no Target.directoryURL, so the plugin "
                + "can only reach the target directory through the deprecated Path API")
    }

    // MARK: - Edge cases

    /// A harness that cannot see a deprecation would pass no matter what the
    /// plugin does. Compile a snippet that uses the accessor the plugin gave
    /// up, at the same version, and require the warning to come back.
    func testTheHarnessReportsADeprecationWhenTheSourceHasOne() throws {
        let toolsVersion = try declaredToolsVersion()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "js-bao-2966-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let probe = directory.appending(path: "DeprecationProbe.swift")
        try """
            import PackagePlugin
            import Foundation

            enum DeprecationProbe {
                static func directoryPath(of target: Target) -> String {
                    target.directory.string
                }
            }
            """.write(to: probe, atomically: true, encoding: .utf8)

        let (status, output) = try typecheck([probe], packageDescriptionVersion: toolsVersion)
        XCTAssertEqual(status, 0, "the probe must compile — a deprecation is a warning:\n\(output)")
        XCTAssertTrue(
            diagnostics(in: output).contains { $0.contains("is deprecated") },
            "the type-check harness saw no deprecation in a source that has one, so a green "
                + "result above would mean nothing:\n\(output)")
    }

    /// The warning had to go away by using a supported accessor, not by
    /// hiding the diagnostic — a `-suppress-warnings` flag, or a deprecated
    /// enclosing declaration (the compiler stays quiet about deprecated calls
    /// made from deprecated code).
    func testTheWarningIsNotSuppressed() throws {
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        for source in try pluginSources() {
            let text = try String(contentsOf: source, encoding: .utf8)
            for suppression in ["-suppress-warnings", "@available(*, deprecated"] {
                XCTAssertFalse(
                    text.contains(suppression),
                    "\(source.lastPathComponent) silences diagnostics with \(suppression)")
            }
        }
        XCTAssertFalse(
            manifest.contains("-suppress-warnings"),
            "the manifest silences plugin diagnostics with -suppress-warnings")
    }

    /// Raising the tools version raises the toolchain a consumer needs, so
    /// the package documents the floor — and the documented floor is the
    /// manifest's, not a number that was true once.
    func testDocumentedToolchainFloorMatchesTheManifest() throws {
        let toolsVersion = try declaredToolsVersion()
        let readme = try String(
            contentsOf: packageRoot.appending(path: "docs/README.md"), encoding: .utf8)
        let pattern = /Toolchain floor:\*{0,2} Swift ([0-9]+(?:\.[0-9]+)*)/
        guard let match = try pattern.firstMatch(in: readme) else {
            XCTFail("docs/README.md states no \"Toolchain floor: Swift <version>\"")
            return
        }
        XCTAssertEqual(
            String(match.1), toolsVersion,
            "docs/README.md documents a Swift \(String(match.1)) floor while Package.swift "
                + "declares swift-tools-version \(toolsVersion)")
    }
}
