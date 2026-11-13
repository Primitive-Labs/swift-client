import Foundation
import XCTest

/// The bundled SQLite compiles without warnings in an app's build. Every app on
/// the client compiles the `JsBaoSQLite` target, and its sources are the SQLite
/// release files, unmodified (`BundledSQLiteHermeticTests` holds them byte for
/// byte), so they cannot carry pragmas: what keeps their diagnostics out of an
/// app's build log is the target's `cSettings` in `Package.swift`.
///
/// Each check compiles the target's C sources with the toolchain's
/// `clang -fsyntax-only`, the way the build systems do: their flags first
/// (clang modules on; `-Wshorten-64-to-32` and `-Wlogical-op-parentheses`,
/// which `swiftbuild` and Xcode enable; `-Wambiguous-macro`, on by default),
/// then the target's defines and unsafe flags read from the manifest. A bare
/// clang reports none of the three families on its own, so the harness check
/// compiles the same sources without the manifest's flags and requires each
/// family back: a clean result then means the manifest's flags did the work.
final class BundledSQLiteWarningsHermeticTests: XCTestCase {

    /// The SQLite sources the target compiles, in the order the manifest lists them.
    private static let expectedSources = ["sqlite3.c", "vec1.c", "jsbao_init.c"]

    /// The only warning families the target may suppress by name: the ones the
    /// release sources trip. `-Wno-ambiguous-macro` is admitted for the case
    /// where `-fno-modules` cannot be used and the family is suppressed instead.
    private static let allowedSuppressions: Set<String> = [
        "-Wno-shorten-64-to-32",
        "-Wno-logical-op-parentheses",
        "-Wno-ambiguous-macro",
    ]

    /// A private module cache for this class's compiles, so the SDK module is
    /// built once and nothing outside the temporary directory is written.
    private static let moduleCache: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-sqlite-warnings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: moduleCache)
        super.tearDown()
    }

    /// The flags every build route passes before a target's own: modules on
    /// and the three families enabled.
    private static var buildSystemFlags: [String] {
        [
            "-fmodules",
            "-fmodules-cache-path=\(moduleCache.path)",
            "-Wambiguous-macro",
            "-Wshorten-64-to-32",
            "-Wlogical-op-parentheses",
        ]
    }

    private static var vendorDirectory: URL {
        ClientSourceText.packageRoot.appendingPathComponent("Vendor/JsBaoSQLite")
    }

    // MARK: - The target as the manifest declares it

    private struct SQLiteTarget {
        var sources: [String]
        var defines: [String]
        var unsafeFlags: [String]
    }

    /// The `JsBaoSQLite` target block of the comment-stripped manifest. The
    /// library product of the same name comes first, so the slice starts at the
    /// target's `path:`, which only the target has.
    private func manifestTarget() throws -> SQLiteTarget {
        let manifest = ClientSourceText.stripComments(try ClientSourceText.packageFile("Package.swift"))
        let block = try ClientSourceText.slice(manifest, from: "path: \"Vendor/JsBaoSQLite\"", to: ".target(")

        let sourcesList = try XCTUnwrap(
            Self.captures(#"sources:\s*\[([^\]]*)\]"#, in: block).first?.first ?? nil,
            "could not read `sources:` from the JsBaoSQLite target"
        )
        let sources = Self.stringLiterals(in: sourcesList)

        let defines = Self.captures(#"\.define\(\s*"([^"]+)"\s*(?:,\s*to:\s*"([^"]*)"\s*)?\)"#, in: block)
            .compactMap { groups -> String? in
                guard let name = groups[0] else { return nil }
                if let value = groups[1] { return "-D\(name)=\(value)" }
                return "-D\(name)"
            }

        let unsafeFlags = Self.captures(#"\.unsafeFlags\(\s*\[([^\]]*)\]"#, in: block)
            .compactMap { $0[0] }
            .flatMap(Self.stringLiterals(in:))

        XCTAssertFalse(sources.isEmpty, "read no sources from the JsBaoSQLite target")
        XCTAssertFalse(defines.isEmpty, "read no `.define`s from the JsBaoSQLite target")
        XCTAssertFalse(unsafeFlags.isEmpty, "read no `.unsafeFlags` from the JsBaoSQLite target")
        return SQLiteTarget(sources: sources, defines: defines, unsafeFlags: unsafeFlags)
    }

    /// Every match of `pattern` in `text`, as its capture groups (nil for a
    /// group that did not take part).
    private static func captures(_ pattern: String, in text: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    private static func stringLiterals(in text: String) -> [String] {
        captures(#""([^"]*)""#, in: text).compactMap { $0[0] }
    }

    // MARK: - The compiler

    private struct Compile {
        var status: Int32
        var output: String

        /// The warnings clang reports at a line of a vendored file. A
        /// driver-level line (no `<file>:<line>:<col>:` prefix) is not counted.
        var sourceWarnings: [String] {
            output.split(separator: "\n").map(String.init).filter {
                $0.range(of: #"^/.*Vendor/JsBaoSQLite/[^:]+:[0-9]+:[0-9]+: warning:"#, options: .regularExpression) != nil
            }
        }

        func warnings(tagged family: String) -> [String] {
            sourceWarnings.filter { $0.hasSuffix("[\(family)]") }
        }

        /// The source warnings counted by family, for a failure message.
        var summary: String {
            var counts: [String: Int] = [:]
            for line in sourceWarnings {
                let family = line.range(of: #"\[-W[^\]]+\]$"#, options: .regularExpression).map { String(line[$0]) }
                counts[family ?? "(untagged)", default: 0] += 1
            }
            return counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        }
    }

    /// `clang -fsyntax-only` over one vendored file, build-system flags first.
    private func compile(_ file: String, defines: [String], targetFlags: [String]) throws -> Compile {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let (executable, prefix): (URL, [String]) =
            FileManager.default.isExecutableFile(atPath: xcrun.path)
            ? (xcrun, ["clang"])
            : (URL(fileURLWithPath: "/usr/bin/env"), ["clang"])
        let arguments = prefix
            + ["-fsyntax-only", "-x", "c", "-I", Self.vendorDirectory.appendingPathComponent("include").path]
            + Self.buildSystemFlags
            + defines
            + targetFlags
            + [Self.vendorDirectory.appendingPathComponent(file).path]

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
        return Compile(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Behaviour 1: no warnings under the manifest's flags

    func testEachBundledSourceCompilesWithoutWarningsUnderTheManifestFlags() throws {
        let target = try manifestTarget()
        XCTAssertEqual(target.sources, Self.expectedSources, "the JsBaoSQLite target's sources")
        for file in target.sources {
            let result = try compile(file, defines: target.defines, targetFlags: target.unsafeFlags)
            XCTAssertEqual(result.status, 0, "clang failed on \(file):\n\(result.output)")
            XCTAssertEqual(
                result.sourceWarnings.count, 0,
                "\(file) reports \(result.sourceWarnings.count) warnings (\(result.summary)); first: "
                    + "\(result.sourceWarnings.prefix(3).joined(separator: "\n"))"
            )
        }
    }

    // MARK: - Behaviour 6: the harness reproduces each family

    func testWithoutTheManifestFlagsEachFamilyIsReported() throws {
        let target = try manifestTarget()

        let sqlite = try compile("sqlite3.c", defines: target.defines, targetFlags: [])
        XCTAssertFalse(
            sqlite.warnings(tagged: "-Wambiguous-macro").isEmpty,
            "sqlite3.c without the manifest's flags reports no -Wambiguous-macro (\(sqlite.summary))"
        )
        XCTAssertFalse(
            sqlite.warnings(tagged: "-Wshorten-64-to-32").isEmpty,
            "sqlite3.c without the manifest's flags reports no -Wshorten-64-to-32 (\(sqlite.summary))"
        )

        let vec1 = try compile("vec1.c", defines: target.defines, targetFlags: [])
        XCTAssertFalse(
            vec1.warnings(tagged: "-Wlogical-op-parentheses").isEmpty,
            "vec1.c without the manifest's flags reports no -Wlogical-op-parentheses (\(vec1.summary))"
        )
    }

    // MARK: - Behaviour 7: the suppression is narrow

    func testTheTargetSuppressesOnlyTheFamiliesTheReleaseSourcesTrip() throws {
        let flags = try manifestTarget().unsafeFlags
        XCTAssertFalse(flags.contains("-w"), "the JsBaoSQLite target silences every warning: \(flags)")
        for flag in flags where flag.hasPrefix("-Wno-") {
            XCTAssertTrue(
                Self.allowedSuppressions.contains(flag),
                "\(flag) suppresses a family the release sources do not trip; allowed: \(Self.allowedSuppressions.sorted())"
            )
        }
    }
}
