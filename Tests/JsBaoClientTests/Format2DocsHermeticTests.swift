import XCTest
@testable import JsBaoClient

/// The Swift client's large-document documentation (#3436, behavior 32).
///
/// A public surface nobody can find is a surface nobody uses, and this one is
/// large: nine error codes, a create option, a new event, and a set of rules
/// about when a document stops that an app CANNOT discover by reading its own
/// code. So the page is held to the code: every public name this child adds has
/// to appear in it, and the two deferrals have to be written down where the
/// person hitting them will look.
///
/// Held by NAME and not by prose, so the page can be rewritten freely — what it
/// may not do is quietly stop mentioning something it documents.
final class Format2DocsHermeticTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // JsBaoClientTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-client
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - The page exists and is reachable

    func testTheDocsIndexLinksThePage() throws {
        let index = try read("docs/README.md")
        XCTAssertTrue(
            index.contains("large-documents.md"),
            "docs/README.md does not link the large-documents page"
        )
    }

    // MARK: - Every public name this child adds

    func testThePageNamesEveryPublicSymbolThisChildAdds() throws {
        let page = try read("docs/large-documents.md")
        let names = [
            // The create option and what a document reports about itself.
            "documentFormat",
            "CreateDocumentOptions",
            "DocumentInfo",
            // The transport rules an app can observe.
            "syncStep1",
            "formats: [1, 2]",
            "manifestVersion",
            "4426",
            "ConnectionErrorEvent",
            "epoch.info",
            "epoch.seal",
            "epoch.resync",
            "update.ack",
            // The load and its event.
            "DocumentSnapshotLoadEvent",
            "document:snapshot-load",
            // Every one of the nine typed codes.
            "clientUpgradeRequired",
            "format2StorageUnavailable",
            "format2ReloadRequired",
            "format2QueryScope",
            "format2ModelNotHydrated",
            "format2FoldBroken",
            "snapshotManifestInvalid",
            "snapshotManifestUnsupported",
            "format2SnapshotLoadIncomplete",
            // The storage rule and the purge behavior.
            "not-persistent",
            ".sqlite",
            "evict",
            "wipeLocal",
        ]
        for name in names {
            XCTAssertTrue(
                page.contains(name),
                "docs/large-documents.md does not mention `\(name)`"
            )
        }
    }

    /// Every one of the nine codes this child added is on the page, and the
    /// check is against the ENUM rather than a list somebody has to remember
    /// to extend: a tenth code added later fails this until it is documented.
    func testEveryFormat2ErrorCodeIsDocumented() throws {
        let page = try read("docs/large-documents.md")
        let codes: [JsBaoErrorCode] = [
            .clientUpgradeRequired, .format2StorageUnavailable,
            .format2ReloadRequired, .format2QueryScope, .format2ModelNotHydrated,
            .format2FoldBroken, .snapshotManifestInvalid,
            .snapshotManifestUnsupported, .format2SnapshotLoadIncomplete,
        ]
        for code in codes {
            XCTAssertTrue(
                page.contains(".\(String(describing: code))"),
                "docs/large-documents.md does not document \(code.rawValue)"
            )
        }
    }

    // MARK: - The rules an app cannot infer from its own code

    func testThePageSaysWhatAHoldAndAStoppedDocumentMean() throws {
        let page = try read("docs/large-documents.md")
        for claim in [
            // The outbound hold: held means KEPT, not dropped.
            "kept",
            // A stopped document keeps answering reads and keeps its owed
            // writes — the thing an app most needs to be told.
            "stopped",
            "reads keep answering",
            // Fold-broken is sticky and clears only on a rebind.
            "sticky",
            // A close keeps everything; eviction and the account wipe do not.
            "closeDocument",
        ] {
            XCTAssertTrue(
                page.lowercased().contains(claim.lowercased()),
                "docs/large-documents.md does not say what `\(claim)` means here"
            )
        }
    }

    func testThePageSaysWhatIsDeferredAndToWhom() throws {
        let page = try read("docs/large-documents.md")
        XCTAssertTrue(
            page.contains("principle 11"),
            "the page does not record the deferral under principle 11"
        )
        // What is STILL deferred, and nothing else. This list has now moved
        // twice — "offline replay" came off it when phase B shipped, and the
        // storage cap and the `baseDiscontinuity` rule when phase C did. A
        // phrase the page uses to say the OPPOSITE is not a guard, so what is
        // graded is the principle-11 deferral that survives this child: the
        // verbs an operator reaches for on the CLI instead.
        let notInThisBuild = page.range(of: "## Not in this build").map {
            String(page[$0.lowerBound...])
        }
        let deferralSection = try XCTUnwrap(notInThisBuild)
        for deferred in ["ingest", "inspection", "web-admin"] {
            XCTAssertTrue(
                deferralSection.lowercased().contains(deferred.lowercased()),
                "the \"Not in this build\" section does not name `\(deferred)`"
            )
        }
        XCTAssertTrue(
            deferralSection.contains("primitive documents ingest"),
            "and it does not say where an operator does it instead"
        )
        // And what is no longer deferred is not still listed as though it were.
        for shipped in ["storage cap", "baseDiscontinuity"] {
            XCTAssertFalse(
                deferralSection.lowercased().contains(shipped.lowercased()),
                "`\(shipped)` ships in this build; the deferral list still names it"
            )
        }
    }

    // MARK: - #3437's phase C

    /// The page carries what phase C added: the reload from a base, the bulk
    /// load a client can be written through, and the room a device will give
    /// the document — each with the observable an app has to know about.
    func testThePageDocumentsTheReloadTheBulkLoadAndTheDeviceCap() throws {
        let page = try read("docs/large-documents.md")
        for claim in [
            // A reload is a whole load, never a range replacement — the
            // intent's Swift rule, and what the load event reports.
            "Reloading from a base",
            "Crossing a bulk load",
            "How much room a document may have",
            "baseDiscontinuity",
            "bulkIngest",
            "unverifiable",
            "over-quota",
            "largeDocumentStorage",
            "format2ModelNotHydrated",
        ] {
            XCTAssertTrue(
                page.contains(claim),
                "the page does not carry `\(claim)`"
            )
        }
        let reload = try XCTUnwrap(
            page.range(of: "## Reloading from a base").map { String(page[$0.lowerBound...]) }
        )
        XCTAssertTrue(
            reload.contains("mode` stays `\"load\"") || reload.contains("`\"load\"`"),
            "the page does not say the load event still reports a whole load"
        )
        XCTAssertTrue(
            reload.contains("query tables"),
            "nor that the reload takes the second view of the document with it"
        )
    }

    /// A copyable configuration for the device cap: an app cannot discover the
    /// option shape from a sentence about it.
    func testThePageCarriesACopyableStorageOption() throws {
        let page = try read("docs/large-documents.md")
        let fences = page.components(separatedBy: "```swift").dropFirst()
            .compactMap { $0.components(separatedBy: "```").first }
        XCTAssertTrue(
            fences.contains { $0.contains("LargeDocumentStorageOptions(") },
            "the page needs a `largeDocumentStorage` example a developer can copy"
        )
    }

    // MARK: - #3437's phase B

    /// The page carries what phase B added: the chain a client behind the room
    /// applies, the isolation of its overlay while it is behind, and the
    /// judgement its offline writes get — including the event an app has to
    /// subscribe to in order to hear about a DROPPED write, which is the one
    /// outcome no amount of reading its own code would reveal.
    func testThePageDocumentsTheChainAndTheOfflineJudgement() throws {
        let page = try read("docs/large-documents.md")
        let names = [
            "Catching up over the sealed chain",
            "Judging what was written offline",
            "DocumentOfflineWritesResolvedEvent",
            "documentOfflineWritesResolved",
            // The four verdicts, by the names the notices carry.
            "unverifiable",
            "dropped",
            // The two rules an app cannot infer.
            "oldest first",
            "no measured server offset",
        ]
        for name in names {
            XCTAssertTrue(
                page.contains(name),
                "docs/large-documents.md does not mention `\(name)`"
            )
        }
    }

    /// The subscription is COPYABLE, not described.
    ///
    /// An app that never subscribes hears nothing about a dropped offline
    /// write, so the snippet is the whole of what makes the event usable.
    func testThePageCarriesACopyableSubscriptionForTheReplayEvent() throws {
        let page = try read("docs/large-documents.md")
        XCTAssertTrue(
            page.contains("client.on(DocumentOfflineWritesResolvedEvent.self)"),
            "the page describes the replay event without showing how to "
                + "subscribe to it"
        )
        XCTAssertTrue(
            page.contains("event.notices"),
            "and the snippet does not read the notices, which are the payload"
        )
    }

    // MARK: - #3437's phase A

    /// The page carries the surface phase A of #3437 added, and the two
    /// behaviours an existing app can NOTICE — a replaced `YDocument` handle
    /// and a non-throwing mutation that now refuses. A compatible change
    /// nobody is told about is a breaking change in practice.
    func testThePageDocumentsFollowingARotationAndTheOfflineWindow() throws {
        let page = try read("docs/large-documents.md")
        let names = [
            // Following a seal, and the handle it replaces.
            "Following a rotation",
            "YDocument",
            // Adoption.
            "adopted",
            // The window, its numbers and its error.
            "offline write window",
            "1–14",
            "documentOfflineWindowExpired",
            "lastSyncAt",
            "windowDays",
            "overdueMs",
            // And the channel for the verbs that cannot throw.
            "DocumentWriteRefusedEvent",
        ]
        for name in names {
            XCTAssertTrue(
                page.contains(name),
                "docs/large-documents.md does not mention `\(name)`"
            )
        }
        // A copyable subscription, not a description of one (principle 7).
        XCTAssertTrue(
            page.contains("observeOnMainActor(DocumentWriteRefusedEvent.self)"),
            "the page does not show how to subscribe to the refusal event"
        )
        // And the error code is documented against the ENUM, as the nine
        // before it are, so a code added later fails this until it is.
        XCTAssertTrue(
            page.contains(".\(String(describing: JsBaoErrorCode.documentOfflineWindowExpired))"),
            "the page does not document the offline-window code"
        )
    }

    func testTheChangelogRecordsWhatPhaseAOfTheSiblingChanged() throws {
        let changelog = try read("CHANGELOG.md")
        let unreleased = try XCTUnwrap(
            changelog.range(of: "## Unreleased").map { String(changelog[$0.lowerBound...]) }
        )
        let entry = try XCTUnwrap(
            unreleased.range(of: "#3437").map { String(unreleased[$0.lowerBound...]) },
            "the changelog has no #3437 entry in the Unreleased section"
        )
        // The package ships by branch, so the changelog IS the migration note:
        // both noticeable behaviours have to be in it by name.
        for claim in ["DocumentWriteRefusedEvent", "YDocument", "read-only"] {
            XCTAssertTrue(
                entry.contains(claim),
                "the #3437 changelog entry does not mention `\(claim)`"
            )
        }
    }

    // MARK: - The changelog

    func testTheChangelogHasAnUnreleasedEntryForThisChange() throws {
        let changelog = try read("CHANGELOG.md")
        let unreleased = try XCTUnwrap(
            changelog.range(of: "## Unreleased").map { String(changelog[$0.lowerBound...]) }
        )
        // The entry is in the UNRELEASED section, not somewhere below it: this
        // package ships by branch, so "unreleased" is what an app takes on its
        // next `swift package update`.
        // Anchored on the entry's own heading rather than on the first mention
        // of #3436 anywhere above it (#3437). A later entry that merely CITES
        // #3436 in its prose — this child's close-initiator fix does, because
        // that is where the socket rebuild comes from — took the slice and made
        // #3436's entry read as saying nothing about itself.
        let heading = try XCTUnwrap(
            unreleased
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first(where: { $0.hasPrefix("### ") && $0.contains("#3436") }),
            "the changelog has no #3436 entry in the Unreleased section"
        )
        XCTAssertTrue(
            heading.contains("Large documents"),
            "the #3436 changelog entry does not say what it is about"
        )
        XCTAssertTrue(
            unreleased.contains("docs/large-documents.md"),
            "the changelog entry does not point at the page"
        )
    }
}
