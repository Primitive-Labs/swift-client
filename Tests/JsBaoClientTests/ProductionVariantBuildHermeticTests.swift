import Foundation
import XCTest

/// The production variant of the Swift client (#5360): `Package.swift`
/// defines the `PRIMITIVE_EXPERIMENTAL_APIS` compile condition on the client
/// and its tests unless the build environment sets
/// `PRIMITIVE_EXPERIMENTAL_APIS=0`, and the client compiles without it, every
/// experimental declaration compiled out by its `#if` region.
///
/// Both checks run SwiftPM itself on a scratch path of their own,
/// `.build/production-variant-probe`, never the one the enclosing `swift test`
/// holds (the default `.build`, or `.build/production-variant` for the
/// production-variant run), so the nested command never waits on its parent's
/// lock. They skip on a standalone checkout: the published mirrors carry the
/// line patched to a constant.
final class ProductionVariantBuildHermeticTests: XCTestCase {

    private static let condition = "PRIMITIVE_EXPERIMENTAL_APIS"
    private static let probeScratch = ".build/production-variant-probe"
    /// The bound on the nested build: a cold one takes well under a minute.
    private static let buildTimeout: TimeInterval = 15 * 60

    private struct Run {
        let status: Int32
        let output: String
        let elapsed: TimeInterval
    }

    private func skipUnlessMonorepo() throws {
        try XCTSkipUnless(
            ClientSourceText.isMonorepoCheckout,
            "no repository root next to this package — standalone SPM checkout"
        )
    }

    private var probeScratchURL: URL {
        ClientSourceText.packageRoot.appendingPathComponent(Self.probeScratch)
    }

    /// `swift <arguments>` in the package root, with the flag set to `flag`
    /// (`nil` removes it), failing the test when it outlives `timeout`.
    private func swift(_ arguments: [String], flag: String?, timeout: TimeInterval) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift"] + arguments
        process.currentDirectoryURL = ClientSourceText.packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment[Self.condition] = flag
        process.environment = environment
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("production-variant-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        addTeardownBlock { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle

        let started = Date()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 10)
            XCTFail("`swift \(arguments.joined(separator: " "))` ran \(Int(Date().timeIntervalSince(started)))s, past its \(Int(timeout))s bound")
        }
        return Run(
            status: process.terminationStatus,
            output: (try? String(contentsOf: output, encoding: .utf8)) ?? "",
            elapsed: Date().timeIntervalSince(started)
        )
    }

    /// The targets of `swift package dump-package` under `flag` that define
    /// the condition.
    private func targetsDefiningCondition(flag: String?) throws -> Set<String> {
        let run = try swift(
            ["package", "dump-package", "--scratch-path", probeScratchURL.path],
            flag: flag,
            timeout: Self.buildTimeout
        )
        XCTAssertEqual(run.status, 0, "dump-package failed:\n\(run.output)")
        guard let start = run.output.firstIndex(of: "{") else {
            XCTFail("dump-package printed no manifest:\n\(run.output)")
            return []
        }
        let json = try JSONSerialization.jsonObject(with: Data(run.output[start...].utf8))
        let targets = (json as? [String: Any])?["targets"] as? [[String: Any]] ?? []
        XCTAssertFalse(targets.isEmpty, "dump-package listed no targets")
        var defining = Set<String>()
        for target in targets {
            let settings = target["settings"] as? [[String: Any]] ?? []
            let defines = settings.compactMap { setting -> String? in
                guard setting["tool"] as? String == "swift",
                      let kind = setting["kind"] as? [String: Any],
                      let define = kind["define"] as? [String: Any] else { return nil }
                return define["_0"] as? String
            }
            if defines.contains(Self.condition), let name = target["name"] as? String {
                defining.insert(name)
            }
        }
        return defining
    }

    /// Behaviour 10 and edge E5: the condition follows the environment on
    /// every evaluation, so a manifest evaluated under `0` is not served
    /// again from the cache once the variable is gone.
    func testManifestDefinesTheConditionUnlessTheFlagIsZero() throws {
        try skipUnlessMonorepo()
        let full: Set<String> = ["JsBaoClient", "JsBaoClientTests"]
        XCTAssertEqual(try targetsDefiningCondition(flag: nil), full, "variable unset")
        XCTAssertEqual(try targetsDefiningCondition(flag: "false"), full, "only the literal 0 builds production")
        XCTAssertEqual(try targetsDefiningCondition(flag: "1"), full, "only the literal 0 builds production")
        XCTAssertEqual(try targetsDefiningCondition(flag: "0"), [], "PRIMITIVE_EXPERIMENTAL_APIS=0")
        XCTAssertEqual(try targetsDefiningCondition(flag: nil), full, "variable unset after =0")
    }

    /// Behaviour 11: the client compiles with the experimental declarations
    /// compiled out, on a scratch path that is not the enclosing run's.
    func testClientBuildsWithoutTheCondition() throws {
        try skipUnlessMonorepo()
        let bundle = Bundle(for: Self.self).bundleURL.resolvingSymlinksInPath().path
        let probe = probeScratchURL.resolvingSymlinksInPath().path
        XCTAssertFalse(
            bundle.hasPrefix(probe + "/"),
            "the nested build must not share the enclosing run's scratch path (\(bundle))"
        )

        let run = try swift(
            ["build", "--target", "JsBaoClient", "--scratch-path", probeScratchURL.path],
            flag: "0",
            timeout: Self.buildTimeout
        )
        print("ProductionVariantBuildHermeticTests: production build took \(Int(run.elapsed))s")
        XCTAssertEqual(run.status, 0, "PRIMITIVE_EXPERIMENTAL_APIS=0 swift build --target JsBaoClient failed:\n\(run.output)")
    }
}
