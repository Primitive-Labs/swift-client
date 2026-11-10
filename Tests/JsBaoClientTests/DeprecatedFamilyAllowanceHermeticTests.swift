import XCTest

/// `scripts/check-swift-deprecations.sh` fails on any deprecated call in the
/// published Swift trees. #5356 deprecated the documents family, and the
/// retired PrimitiveApp library's `#if DEBUG` inspector still calls it with no
/// successor for Yjs-document blobs; #4934 deletes the library. Until then one
/// file is let through, and only for diagnostics whose message ends with the
/// family marker every #5356 attribute carries.
///
/// The allowance lives in `scripts/lib/swift-allowed-deprecations.sh`, a shell
/// array nothing at build time can observe. This pins it: exactly one path,
/// a marker equal to the attributes' suffix, a path that exists, and both of
/// the gate's tiers filtering through it (the warning tier re-reads every
/// deprecation diagnostic, so a filter on one tier alone leaves the gate red).
/// #4934 deletes this test with the library.
final class DeprecatedFamilyAllowanceHermeticTests: XCTestCase {

    private static let helperPath = "scripts/lib/swift-allowed-deprecations.sh"
    private static let inspectorPath =
        "packages/swift-primitive-app/Sources/PrimitiveApp/Debug/DebugInspector.swift"

    private func helper() throws -> String {
        try XCTSkipUnless(
            ClientSourceText.isMonorepoCheckout,
            "no repository root next to this package — standalone SPM checkout"
        )
        return try ClientSourceText.repoFile(Self.helperPath)
    }

    private func marker(in helper: String) throws -> String {
        let line = try XCTUnwrap(
            helper.split(separator: "\n").first { $0.hasPrefix("DEPRECATED_FAMILY_MARKER=") },
            "the helper declares no DEPRECATED_FAMILY_MARKER"
        )
        return String(line.dropFirst("DEPRECATED_FAMILY_MARKER=".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    func testAllowedListIsExactlyTheRetiredInspector() throws {
        let body = try ClientSourceText.slice(
            try helper(), from: "\nDEPRECATED_FAMILY_SITES_ALLOWED=(", to: "\n)"
        )
        let entries = body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }

        XCTAssertEqual(
            entries, [Self.inspectorPath],
            """
            DEPRECATED_FAMILY_SITES_ALLOWED holds the retired library's debug \
            inspector and nothing else. Migrate any other caller of a deprecated \
            member instead of allowing it.
            """
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: ClientSourceText.repoRoot.appendingPathComponent(Self.inspectorPath).path
            ),
            "\(Self.inspectorPath) no longer exists: delete the allowance, the helper and this test with it."
        )
    }

    func testMarkerIsTheSuffixOfEveryFamilyDeprecation() throws {
        let marker = try marker(in: try helper())
        XCTAssertEqual(marker, "(api-surface-stability)")

        var familyAttributes = 0
        for source in try ClientSourceText.allClientSources() {
            for line in source.split(separator: "\n") where line.contains("@available(*, deprecated") {
                guard line.contains("api-surface-stability") else { continue }
                familyAttributes += 1
                XCTAssertTrue(
                    line.trimmingCharacters(in: .whitespaces).hasSuffix("\(marker)\")"),
                    "a family deprecation whose message does not end with \(marker): \(line)"
                )
            }
        }
        XCTAssertGreaterThan(familyAttributes, 0, "no deprecation carries \(marker)")
    }

    func testBothGateTiersFilterThroughTheAllowance() throws {
        _ = try helper()
        let script = try ClientSourceText.repoFile("scripts/check-swift-deprecations.sh")
        XCTAssertTrue(
            script.contains("lib/swift-allowed-deprecations.sh"),
            "the gate does not source \(Self.helperPath)"
        )
        let deprecationTier = try ClientSourceText.slice(script, from: "\nfindings=\"$(", to: "\n)\"")
        let warningTier = try ClientSourceText.slice(script, from: "\nwarning_findings=\"$(", to: "\n)\"")
        XCTAssertTrue(
            deprecationTier.contains("drop_allowed_family_sites"),
            "the deprecation tier does not filter through drop_allowed_family_sites"
        )
        XCTAssertTrue(
            warningTier.contains("drop_allowed_family_sites"),
            "the warning tier does not filter through drop_allowed_family_sites"
        )
    }
}
