import XCTest

/// `scripts/check-swift-deprecations.sh` holds every published Swift tree to a
/// warning-free build. When #3313 turned that tier on for `swift-client` it
/// found 13 warnings in `Sources/` (fixed there) and 20 in `Tests/`, and parked
/// the second set behind a tracked exemption list — one that its own comment
/// says "shrinks to empty when the test warnings are fixed. Do not add to it."
///
/// #3314 fixed those 20 and emptied the list. The list is a shell array, so
/// nothing at build time can observe that it stayed empty: a later change could
/// re-add a tree and the gate would go quiet about it, which is the exact
/// condition the gate exists to end. This reads the committed script — the
/// style the other gate-shape invariants in this target use
/// (`ActorizedBlobManagerTests`' TSan baseline check) — and asserts the array
/// declares no entries.
final class WarningTierExemptionHermeticTests: XCTestCase {

    func testWarningTierExemptListIsEmpty() throws {
        // The gate script lives above the package root, and the published
        // SwiftPM mirror carries `swift-client/` alone — so in a standalone
        // checkout there is no script to read. Skipped there rather than
        // failed; inside the monorepo a missing script still fails, which is
        // the case that would mean the gate itself had gone away.
        try XCTSkipUnless(
            ClientSourceText.isMonorepoCheckout,
            "no repository root next to this package — standalone SPM checkout"
        )

        let script = try ClientSourceText.repoFile("scripts/check-swift-deprecations.sh")
        let body = try ClientSourceText.slice(
            script, from: "\nWARNING_TIER_EXEMPT=(", to: "\n)"
        )
        let entries = body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        XCTAssertEqual(
            entries, [],
            """
            WARNING_TIER_EXEMPT must stay empty. An entry means a published \
            Swift tree is shipping unread compiler diagnostics: fix the \
            warnings the gate reports for that path instead of exempting it.
            """
        )
    }
}
