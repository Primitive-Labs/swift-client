import XCTest
@testable import JsBaoClient

/// Phase F of the concurrency-modernization epic (#1946) put the `JsBaoClient`
/// target in the Swift 6 language mode; #2310 finished the package — every
/// target now builds in `.v6` through the package-level `swiftLanguageModes`
/// pin, so strict concurrency checking is `complete` and its diagnostics are
/// hard errors throughout.
///
/// What proves the flip is the compiler — `swift build` fails outright if a
/// `Sendable` violation reappears in `Sources/JsBaoClient`. These tests cover
/// the part the compiler cannot: that the flip is still *committed*, that no
/// target has quietly opted back out, and that the regression gate reads the
/// committed mode instead of the temporary manifest rewrite it used while the
/// target was still in `.v5`. A silent revert of any of those would leave a
/// green build and a green gate meaning nothing.
///
/// Source-structural, in the style of the rest of the epic's invariant tests.
/// All server-free.
final class SwiftSixLanguageModeTests: XCTestCase {

    private static func manifest() throws -> String {
        try ClientSourceText.packageFile("Package.swift")
    }

    /// The `JsBaoClient` target's declaration, from its name to the start of
    /// the next target. Anchored so a per-target check can't pass on text that
    /// belongs to some other target.
    ///
    /// Two steps, because `name: "JsBaoClient",` is not unique: it first
    /// matches the *package* name at the top of the manifest, and
    /// `ClientSourceText.slice` takes the first match. Narrowing to the
    /// `targets:` array first is what makes the second anchor the target's.
    private static func jsBaoClientTargetDeclaration() throws -> String {
        let manifest = ClientSourceText.stripComments(try manifest())
        let targetsArray = try ClientSourceText.slice(
            manifest,
            from: "targets: [",
            to: ".executableTarget("
        )
        // `slice` requires its end anchor to be present, and the one that
        // bounded the array above was consumed with it — put it back.
        return try ClientSourceText.slice(
            targetsArray + ".executableTarget(",
            from: "name: \"JsBaoClient\",",
            to: ".executableTarget("
        )
    }

    // MARK: - Behavior 1 — the whole package is in the Swift 6 language mode

    func testPackageDeclaresTheSwiftSixLanguageMode() throws {
        let manifest = ClientSourceText.stripComments(try Self.manifest())
        XCTAssertTrue(
            manifest.contains("swiftLanguageModes: [.v6]"),
            "the package must build in the Swift 6 language mode (#1946, #2310)"
        )
    }

    /// A per-target `swiftSettings` override wins over the package pin, so the
    /// library target must not carry one — with the package at `.v6` the only
    /// reason to add one back would be to opt out.
    func testJsBaoClientTargetDoesNotOverrideThePackageMode() throws {
        let target = try Self.jsBaoClientTargetDeclaration()
        XCTAssertFalse(
            target.contains("swiftSettings:"),
            "the JsBaoClient target inherits .v6 from the package pin — a swiftSettings override can only weaken it"
        )
    }

    /// The anchor above has to actually be the target's, or the test before it
    /// is really asserting "somewhere in most of the manifest".
    func testTargetDeclarationIsAnchoredToTheTargetNotThePackage() throws {
        let target = try Self.jsBaoClientTargetDeclaration()
        XCTAssertTrue(target.contains("path: \"Sources/JsBaoClient\","),
                      "the slice must cover the JsBaoClient target's body")
        for stray in ["platforms:", "products:", ".library(", ".package(url:"] {
            XCTAssertFalse(
                target.contains(stray),
                "the slice leaked package-level manifest content (\(stray)) — it is not target-anchored"
            )
        }
    }

    /// `.swiftLanguageMode` is a tools-version 6.0 manifest API — without the
    /// bump the manifest does not even parse.
    func testManifestDeclaresToolsVersionSixPointZero() throws {
        let manifest = try Self.manifest()
        XCTAssertTrue(
            manifest.hasPrefix("// swift-tools-version: 6.0"),
            "the .swiftLanguageMode setting requires swift-tools-version 6.0"
        )
    }

    // MARK: - Behavior 2 — the mode is the package pin, not per-target opt-ins

    /// The `[.v5]` pin is gone (#2310). While it was there it was what kept
    /// `SwiftBaoCodegen`, the two test targets and `E2EMiniApp` in Swift 5 mode;
    /// re-introducing it would silently drop all of them back out.
    func testPackageDefaultLanguageModeIsNoLongerSwiftFive() throws {
        let manifest = ClientSourceText.stripComments(try Self.manifest())
        XCTAssertFalse(
            manifest.contains("swiftLanguageModes: [.v5]"),
            "a [.v5] package pin would drop every target back out of the Swift 6 mode"
        )
    }

    /// With the package pin doing the work there is nothing left to opt in:
    /// `.swiftLanguageMode(...)` must not appear on any target. A per-target
    /// setting can now only be an opt-OUT, which is what this catches.
    func testNoTargetCarriesAPerTargetLanguageModeSetting() throws {
        let manifest = ClientSourceText.stripComments(try Self.manifest())
        let occurrences = manifest.components(separatedBy: ".swiftLanguageMode(").count - 1
        XCTAssertEqual(occurrences, 0,
                       "expected no per-target language-mode settings, found \(occurrences)")
    }

    /// Every target the package declares is covered by the pin — this is the
    /// list #2310 flipped, restated so adding a target without thinking about
    /// its mode is at least a conscious edit here.
    func testEveryDeclaredTargetIsCoveredByThePackagePin() throws {
        let manifest = ClientSourceText.stripComments(try Self.manifest())
        for target in [
            "JsBaoClient", "SwiftBaoCodegen", "JsBaoCodegenPlugin",
            "JsBaoClientTests", "SwiftBaoCodegenTests", "E2EMiniApp",
        ] {
            XCTAssertTrue(
                manifest.contains("name: \"\(target)\""),
                "\(target) is no longer declared in the manifest — the pin's coverage list is stale"
            )
        }
    }

    // MARK: - Behavior 2b — `#file` changed meaning with the mode

    /// The Swift 6 language mode turns `#file` into the *concise* form
    /// (`<module>/<file>`) rather than the full source path. Anything that
    /// built a filesystem path out of `#file` therefore started resolving
    /// against the process's working directory instead of the source tree.
    ///
    /// In this target that silently downgraded every cross-platform test to an
    /// `XCTSkip` — the harness locator could no longer find `harness/`, and a
    /// skip is not a failure, so a full green run said nothing (#2310). This
    /// asserts the locator lands back in the source tree and that the scripts
    /// it points at are really there.
    func testHarnessLocatorResolvesAgainstTheSourceTree() throws {
        let dir = CrossPlatformHarness.harnessDir
        XCTAssertTrue(
            dir.path.hasSuffix("Tests/JsBaoClientTests/CrossPlatform/harness"),
            "the harness locator must resolve inside the source tree, got \(dir.path) — "
            + "the usual cause is `#file` where `#filePath` is meant"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: CrossPlatformHarness.readerScript.path),
            "reader.cjs not found at \(CrossPlatformHarness.readerScript.path)"
        )
    }

    /// The same trap anywhere else in the package: `#file` is fine for a
    /// diagnostic string, but never for building a path. Catching the
    /// `URL(fileURLWithPath: #file)` spelling is enough — that is the one that
    /// turns into a wrong directory rather than a cosmetically shorter label.
    func testNoSourceBuildsAPathFromTheConciseFileLiteral() throws {
        // Assembled from two pieces so this file does not match its own needle.
        let banned = "URL(fileURLWithPath: #" + "file)"
        for relativePath in try ClientSourceText.packageSwiftFiles() {
            let text = try ClientSourceText.packageFile(relativePath)
            XCTAssertFalse(
                ClientSourceText.stripComments(text).contains(banned),
                "\(relativePath) builds a path from `#file`, which is the concise "
                + "`<module>/<file>` form under the Swift 6 language mode — use `#filePath`"
            )
        }
    }

    // MARK: - Behavior 3 — the gate now reads the committed mode

    /// While the target was in `.v5` the gate installed `.v6` itself by
    /// rewriting `Package.swift` and restoring it afterwards. Under the real
    /// mode that rewrite is not just redundant, it is wrong: its anchors are
    /// the `5.9` tools-version line and a target without `swiftSettings`,
    /// neither of which exists any more.
    func testGateNoLongerRewritesTheManifest() throws {
        let gate = try ClientSourceText.packageFile("scripts/v6-sendable-gate.sh")
        XCTAssertFalse(gate.contains("swift-tools-version: 5.9"),
                       "the gate must not rewrite the manifest's tools version")
        XCTAssertFalse(gate.contains("p.write_text(src)"),
                       "the gate must not write Package.swift at all")
        XCTAssertFalse(gate.contains("--scratch-path .build-v6"),
                       "with the mode committed there is no second scratch path to build in")
    }

    /// The replacement for that rewrite's self-check. A gate that measured a
    /// `.v5` build would find zero `Sendable` errors and report PASS, so it has
    /// to confirm the committed mode before it believes a clean build — and it
    /// reads that from the resolved manifest, not from a grep that a stray line
    /// elsewhere in the file could satisfy.
    func testGateVerifiesTheCommittedModeBeforeBuilding() throws {
        let gate = try ClientSourceText.packageFile("scripts/v6-sendable-gate.sh")
        XCTAssertTrue(gate.contains("swift package dump-package"),
                      "the gate must read the mode from the resolved manifest")
        XCTAssertTrue(gate.contains("swiftLanguageMode"),
                      "the gate must reject a per-target override of the package mode")
        XCTAssertTrue(gate.contains("swiftLanguageVersions"),
                      "the gate must check the package-level pin is still [.v6]")
    }

    /// Under the real mode a green build is the invariant, so ANY non-zero
    /// build status fails the gate. While the target was in `.v5` the gate
    /// deliberately tolerated a failing build — that was the build it was
    /// counting errors in.
    func testGateFailsOnAnyBuildFailure() throws {
        let gate = try ClientSourceText.packageFile("scripts/v6-sendable-gate.sh")
        XCTAssertTrue(
            gate.contains("if [ \"$BUILD_RC\" != \"0\" ]; then"),
            "the gate must fail on a non-zero build status, not only on counted sites"
        )
        XCTAssertTrue(gate.contains("exit \"$FAILED\""),
                      "the gate must exit non-zero on a regression")
    }

    /// The gate keeps its assertion interface and `run-tests.sh` keeps calling
    /// it that way — the flip changes what the gate reads, not its role.
    func testRunTestsStillRunsTheGateInAssertionMode() throws {
        let runner = try ClientSourceText.packageFile("run-tests.sh")
        XCTAssertTrue(runner.contains("v6-sendable-gate.sh --max"),
                      "run-tests.sh must invoke the gate in assertion mode")
        XCTAssertTrue(runner.contains("V6_MAX_SITES=0"),
                      "the target-wide budget stays at zero")
    }

    // MARK: - Behavior 4 — the docs describe the gate's real role

    /// `docs/testing.md` described the gate as a preview of a mode the package
    /// did not compile in. Leaving that in place would tell the next reader the
    /// budget is advisory.
    func testTestingDocDescribesTheGateUnderTheCommittedMode() throws {
        let doc = try ClientSourceText.packageFile("docs/testing.md")
        XCTAssertFalse(
            doc.contains("The package still compiles in Swift 5 language mode"),
            "testing.md must not still describe the library target as Swift 5"
        )
        XCTAssertTrue(
            doc.contains("Swift 6 language mode"),
            "testing.md must say the JsBaoClient target builds in the Swift 6 language mode"
        )
    }

    // MARK: - Behavior 5 (#2318) — the warning-level counter and its safety argument

    /// The `#SendableClosureCaptures` site Phase F left behind is cleared by a
    /// closure-specific `@unchecked Sendable` box inside the provider, so the
    /// public `StorageProvider` protocol keeps its shape. The box is the only
    /// `@unchecked` claim in the file beyond the class's own conformance —
    /// scoped that way deliberately, because the class conformance predates it.
    func testProviderCarriesOnlyTheQueueWorkUncheckedClaim() throws {
        let source = try ClientSourceText.clientSource("Storage/SQLiteStorageProvider.swift")
        let declarations = ClientSourceText.uncheckedDeclarations(in: source)

        XCTAssertEqual(
            declarations.count, 2,
            """
            expected exactly two @unchecked declarations — the class conformance \
            and the QueueWork box — found: \(declarations)
            """
        )
        XCTAssertTrue(
            declarations.contains { $0.contains("class SQLiteStorageProvider") },
            "the class's own @unchecked conformance should still be one of them"
        )
        XCTAssertTrue(
            declarations.contains { $0.contains("struct QueueWork<Output>") },
            "the queue hop must be contained in the closure-specific QueueWork box (#2318)"
        )
    }

    /// The box's `@unchecked` claim rests on the queue being serial. A
    /// `.concurrent` attribute would silently invalidate it — the compiler
    /// would not notice, which is why this is checked in source text.
    func testProviderQueueIsStillSerial() throws {
        let code = try ClientSourceText.code("Storage/SQLiteStorageProvider.swift")
        let declaration = try ClientSourceText.slice(code, from: "private let queue =", to: "\n")

        XCTAssertTrue(declaration.contains("DispatchQueue("),
                      "the hop must still run on a DispatchQueue")
        XCTAssertFalse(declaration.contains("attributes: .concurrent"),
                       "a concurrent queue invalidates the QueueWork safety argument (#2318)")
    }

    /// And on the box never outliving the hop: it is created and consumed
    /// inside `onQueue`, never stored.
    func testQueueWorkIsNotStored() throws {
        let code = try ClientSourceText.code("Storage/SQLiteStorageProvider.swift")
        let uses = code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("QueueWork") }

        XCTAssertEqual(
            uses.sorted(),
            ["let work = QueueWork(run: work)", "private struct QueueWork<Output>: @unchecked Sendable {"],
            "QueueWork must only be declared and used as a local inside onQueue — found: \(uses)"
        )
    }

    /// The claim is documented where it is made, framed as containment of the
    /// existing API contract rather than a general transfer-safety proof.
    func testQueueWorkCarriesItsSafetyArgument() throws {
        let source = try ClientSourceText.clientSource("Storage/SQLiteStorageProvider.swift")
        let doc = try XCTUnwrap(
            ClientSourceText.docComment(
                precedingDeclaration: "    private struct QueueWork<Output>",
                in: source
            ),
            "the QueueWork box must carry a doc comment"
        )

        XCTAssertTrue(doc.contains("serial"), "the safety argument must name the serial queue")
        XCTAssertTrue(doc.contains("continuation"),
                      "the safety argument must name the suspended caller")
        XCTAssertTrue(doc.contains("never"),
                      "the safety argument must state the box does not outlive the hop")
    }

    /// A green build says nothing about warning-level diagnostics — that blind
    /// spot is what let 11 of them survive Phase F. The gate counts them now,
    /// and `run-tests.sh` asserts the budget alongside the error one.
    func testGateCountsWarningLevelConcurrencySites() throws {
        let gate = try ClientSourceText.packageFile("scripts/v6-sendable-gate.sh")
        XCTAssertTrue(gate.contains("--max-warnings"),
                      "the gate must expose a warning-site budget (#2318)")
        XCTAssertTrue(gate.contains("warning_sites()"),
                      "the gate must count warning-level strict-concurrency sites")
        XCTAssertTrue(gate.contains("Sources/JsBaoClient"),
                      "the warning counter must be scoped to the target's own sources")
    }

    /// An incremental build over an up-to-date module re-emits no warnings, so
    /// a warm `.build` would hand the counter an empty log and read as PASS.
    func testGateForcesTheTargetToRecompile() throws {
        let gate = try ClientSourceText.packageFile("scripts/v6-sendable-gate.sh")
        XCTAssertTrue(
            gate.contains("find Sources/JsBaoClient -name '*.swift' -exec touch {} +"),
            "the gate must force a recompile, or a warm .build makes the warning count meaningless"
        )
    }

    func testRunTestsAssertsTheWarningBudgetAtZero() throws {
        let runner = try ClientSourceText.packageFile("run-tests.sh")
        XCTAssertTrue(runner.contains("V6_MAX_WARNING_SITES=0"),
                      "the warning budget stays at zero")
        XCTAssertTrue(runner.contains("--max-warnings \"$V6_MAX_WARNING_SITES\""),
                      "run-tests.sh must pass the warning budget to the gate")
    }
}
