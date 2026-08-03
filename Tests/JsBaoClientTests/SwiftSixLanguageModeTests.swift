import XCTest
@testable import JsBaoClient

/// Phase F of the concurrency-modernization epic (#1946): the `JsBaoClient`
/// target adopts the Swift 6 language mode, so strict concurrency checking is
/// `complete` and its diagnostics are hard errors.
///
/// What proves the flip is the compiler — `swift build` fails outright if a
/// `Sendable` violation reappears in `Sources/JsBaoClient`. These tests cover
/// the part the compiler cannot: that the flip is still *committed*, that it
/// stayed scoped to the one target, and that the regression gate now reads the
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
    /// the next target. Anchored so the check can't pass on a
    /// `.swiftLanguageMode(.v6)` that drifted onto some other target.
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

    // MARK: - Behavior 1 — the target is in the Swift 6 language mode

    func testJsBaoClientTargetDeclaresTheSwiftSixLanguageMode() throws {
        let target = try Self.jsBaoClientTargetDeclaration()
        XCTAssertTrue(
            target.contains(".swiftLanguageMode(.v6)"),
            "the JsBaoClient target must build in the Swift 6 language mode (#1946)"
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

    // MARK: - Behavior 2 — the flip stays scoped to that one target

    /// The package default stays at `.v5`, which is what keeps `SwiftBaoCodegen`,
    /// the two test targets and `E2EMiniApp` in Swift 5 mode. Raising the
    /// package default would pull all of them in at once — the test targets
    /// still carry strict-concurrency warnings that would become errors.
    func testPackageDefaultLanguageModeStaysAtSwiftFive() throws {
        let manifest = ClientSourceText.stripComments(try Self.manifest())
        XCTAssertTrue(
            manifest.contains("swiftLanguageModes: [.v5]"),
            "the package-level pin must stay [.v5] so the flip is target-scoped"
        )
        XCTAssertFalse(
            manifest.contains("swiftLanguageModes: [.v6]"),
            "a package-wide .v6 default would flip the test targets with it"
        )
    }

    /// Only `JsBaoClient` carries the setting: exactly one occurrence in the
    /// whole manifest, and it is inside that target.
    func testNoOtherTargetOptsIntoTheSwiftSixMode() throws {
        let manifest = ClientSourceText.stripComments(try Self.manifest())
        let occurrences = manifest.components(separatedBy: ".swiftLanguageMode(.v6)").count - 1
        XCTAssertEqual(occurrences, 1,
                       "expected exactly one target-scoped .v6 opt-in, found \(occurrences)")
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
                      "the gate must check the JsBaoClient target's language mode")
        XCTAssertTrue(gate.contains("swiftLanguageVersions"),
                      "the gate must check the package-level pin is still [.v5]")
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
}
