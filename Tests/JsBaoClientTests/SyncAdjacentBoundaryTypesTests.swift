import XCTest
@testable import JsBaoClient

/// #1993 Phase D4 — boundary bookkeeping for the types that stay
/// class-plus-lock while the async managers become actors.
///
/// Phases D1-D3 converted `OfflineStore`, `KvCache` and `AnalyticsQueue`. Two
/// types the design originally listed were deliberately kept out of that set by
/// the sponsor: `DatabaseSubscriptionRegistry` (permanently — it does no I/O)
/// and `AuthController` (deferred to #2173). Keeping a lock is fine; keeping a
/// bare `@unchecked Sendable` is not, because that attribute is a claim the
/// compiler never checks. This suite is the enforcement: it asserts each of the
/// two carries a written safety argument that names the state its lock confines,
/// and that the accompanying invariants hold in the code rather than only in the
/// prose.
///
/// Structural checks read comment-stripped source, so a phrase quoted in a doc
/// comment cannot decide whether an invariant holds. The safety-argument checks
/// deliberately read the raw source — the argument *is* the comment.
///
/// Every test here is server-free.
final class SyncAdjacentBoundaryTypesTests: XCTestCase {

    // MARK: - The written safety arguments

    /// The same acceptance bar Phase C set for the sync-domain model layer
    /// (`SendableModelLayerTests.testUncheckedConformancesCarryWrittenSafetyArguments`),
    /// applied to Phase D's two sync-adjacent boundary types: the declaration
    /// must be preceded by a doc comment that says "safety argument" and names
    /// the specific lock and the specific fields it confines. A later
    /// conformance cannot be added bare, and an existing one cannot quietly
    /// stop naming its locks.
    func testSyncAdjacentBoundaryTypesCarryWrittenSafetyArguments() throws {
        let cases: [(file: String, declaration: String, mustMention: [String])] = [
            (
                "Internal/DatabaseSubscriptionRegistry.swift",
                "final class DatabaseSubscriptionRegistry: @unchecked Sendable",
                // The lock, both fields it confines, the closures that make the
                // conformance unchecked in the first place, and the rule that
                // keeps a re-entrant callback from deadlocking a non-recursive
                // NSLock.
                ["NSLock", "lock", "registrations", "originContext",
                 "onChange", "releases `lock`"]
            ),
            (
                "Internal/AuthController.swift",
                "public final class AuthController: @unchecked Sendable",
                // One lock, the state it confines, the two invariants that make
                // one lock sufficient, and the documented `deinit` exception.
                // The `await` clause is quoted in full on purpose: a bare
                // "held across an `await`" substring would survive a rewrite
                // that reversed the claim (review of PR #2266).
                ["NSLock", "lock", "currentToken", "networkMode", "_transport",
                 "pendingRefresh", "No lock is held across an `await`",
                 "deinit", "#2173"]
            ),
        ]

        for entry in cases {
            let source = try ClientSourceText.clientSource(entry.file)
            guard let argument = ClientSourceText.docComment(
                precedingDeclaration: entry.declaration, in: source
            ) else {
                XCTFail("\(entry.file): expected declaration `\(entry.declaration)`")
                continue
            }
            XCTAssertTrue(
                argument.contains("safety argument"),
                "\(entry.file): `\(entry.declaration)` must be preceded by a written safety argument"
            )
            for token in entry.mustMention {
                XCTAssertTrue(
                    argument.contains(token),
                    "\(entry.file): the safety argument must name `\(token)`"
                )
            }
        }
    }

    /// The registry stays a class **by decision**, not by omission, so pin the
    /// decision: it must not have drifted into an actor, and it must not have
    /// grown a second lock (the safety argument's "there is no acquisition
    /// order to get wrong" clause depends on there being exactly one).
    func testTheRegistryStaysClassPlusLockWithASingleLock() throws {
        let code = try ClientSourceText.code("Internal/DatabaseSubscriptionRegistry.swift")
        XCTAssertTrue(
            code.contains("final class DatabaseSubscriptionRegistry"),
            "the registry is deliberately not an actor — see the Decisions of record on #1993"
        )
        XCTAssertFalse(code.contains("actor DatabaseSubscriptionRegistry"))
        XCTAssertEqual(
            code.components(separatedBy: "NSLock()").count - 1, 1,
            "exactly one lock — a second one would make the safety argument's single-lock claim false"
        )
    }

    /// `AuthController`'s argument claims every mutable field is lock-confined.
    /// The token check above only proves the field *names* appear in the prose.
    /// This checks the code: no read of `networkMode` may sit outside a
    /// `lock.withLock` region. (It is the field that had genuinely
    /// unsynchronized reads before this phase — the offline-grant guards and
    /// the `AuthStateEvent` payloads — so it is the one worth pinning.)
    func testAuthControllerReadsNetworkModeOnlyUnderTheLock() throws {
        let code = try ClientSourceText.code("Internal/AuthController.swift")
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var depth = 0
        var inLock = false
        var checked = 0

        for line in lines {
            if !inLock, line.contains("lock.withLock") {
                inLock = true
                depth = 0
            }
            if inLock {
                depth += line.filter { $0 == "{" }.count
                depth -= line.filter { $0 == "}" }.count
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("networkMode"),
               !trimmed.hasPrefix("private var networkMode") {
                checked += 1
                XCTAssertTrue(inLock, "`networkMode` is read outside `lock` at: \(trimmed)")
            }

            if inLock, depth <= 0 { inLock = false }
        }

        XCTAssertGreaterThan(checked, 0, "expected at least one networkMode access to check")
    }

    // MARK: - The two dead methods

    /// `has(databaseId:subscriptionKey:)` and `clear()` had zero callers in
    /// `Sources/` and `Tests/` — dead code the design flagged for deletion
    /// rather than for porting. Assert they are gone, and that nothing has
    /// reintroduced a caller.
    func testDeadRegistryMethodsAreDeleted() throws {
        let code = try ClientSourceText.code("Internal/DatabaseSubscriptionRegistry.swift")
        XCTAssertFalse(
            code.contains("func has(databaseId:"),
            "DatabaseSubscriptionRegistry.has had no callers and was deleted in #1993 Phase D4"
        )
        XCTAssertFalse(
            code.contains("func clear()"),
            "DatabaseSubscriptionRegistry.clear had no callers and was deleted in #1993 Phase D4"
        )

        let callers = try ClientSourceText.allClientSources()
            .filter { $0.contains("subscriptionRegistry.has(") || $0.contains("subscriptionRegistry.clear(") }
        XCTAssertTrue(callers.isEmpty, "a caller of a deleted registry method reappeared")

        // The surviving surface is what `DatabasesAPI` and `JsBaoClient` use.
        for survivor in ["func register(", "func unregister(", "func list()",
                         "func dispatch(", "func setOriginContext("] {
            XCTAssertTrue(code.contains(survivor), "the deletion must not have taken `\(survivor)` with it")
        }
    }

    /// Behavioral cover for the deletion: the registry still registers,
    /// replaces, dispatches, unregisters and lists. Written against the real
    /// type with no server, so it is the regression that would actually catch a
    /// too-eager deletion.
    func testRegistryStillRoutesFramesAfterTheDeletion() {
        let registry = DatabaseSubscriptionRegistry(logger: Logger(level: .none, scope: "db-sub"))
        registry.setOriginContext(DatabaseSubscriptionRegistry.OriginContext(
            getConnectionId: { "conn-1" },
            getCurrentUserId: { "user-1" }
        ))

        let received = ThreadSafeBox<[DatabaseChangePayload]>([])
        registry.register(databaseId: "db1", subscriptionKey: "k1", params: ["limit": 10]) { payload in
            received.mutate { $0.append(payload) }
        }

        XCTAssertEqual(registry.list().count, 1)
        XCTAssertEqual(registry.list().first?.databaseId, "db1")

        // A frame from this very connection is attributed to us.
        registry.dispatch([
            "databaseId": "db1",
            "subscriptionKey": "k1",
            "changes": [],
            "timestamp": "2026-01-01T00:00:00Z",
            "originConnectionId": "conn-1",
            "originUserId": "user-1",
        ])
        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(received.value.first?.isOrigin, true)
        XCTAssertEqual(received.value.first?.isOriginUser, true)

        // A frame from someone else is not.
        registry.dispatch([
            "databaseId": "db1",
            "subscriptionKey": "k1",
            "changes": [],
            "timestamp": "2026-01-01T00:00:01Z",
            "originConnectionId": "conn-2",
            "originUserId": "user-2",
        ])
        XCTAssertEqual(received.value.count, 2)
        XCTAssertEqual(received.value.last?.isOrigin, false)
        XCTAssertEqual(received.value.last?.isOriginUser, false)

        // Unregister is what `clear()` never got used for — it still works, and
        // it is the only removal path the client has.
        registry.unregister(databaseId: "db1", subscriptionKey: "k1")
        XCTAssertTrue(registry.list().isEmpty)
        registry.dispatch([
            "databaseId": "db1", "subscriptionKey": "k1", "changes": [],
            "timestamp": "2026-01-01T00:00:02Z",
        ])
        XCTAssertEqual(received.value.count, 2, "a frame after unregister must be dropped")
    }

    /// The safety argument's load-bearing clause: `dispatch` must not hold the
    /// lock while it calls out to app code. If it did, an `onChange` that calls
    /// back into the registry would deadlock against the non-recursive
    /// `NSLock`. Prove it behaviorally rather than by reading the source — a
    /// handler that unregisters itself completes instead of hanging.
    func testDispatchDoesNotHoldTheLockWhileCallingBack() {
        let registry = DatabaseSubscriptionRegistry(logger: Logger(level: .none, scope: "db-sub"))
        let reentered = ThreadSafeBox<Bool>(false)

        registry.register(databaseId: "db1", subscriptionKey: "k1", params: [:]) { [weak registry] _ in
            // Re-entering under a held non-recursive lock would deadlock here.
            registry?.unregister(databaseId: "db1", subscriptionKey: "k1")
            reentered.mutate { $0 = true }
        }

        registry.dispatch([
            "databaseId": "db1", "subscriptionKey": "k1", "changes": [],
            "timestamp": "2026-01-01T00:00:00Z",
        ])

        XCTAssertTrue(reentered.value, "the callback must have run to completion")
        XCTAssertTrue(registry.list().isEmpty, "the re-entrant unregister must have taken effect")
    }

    // MARK: - The docs the phase owes

    /// `docs/architecture.md` used to state flatly that the client "does **not**
    /// use actors". Three phases of this epic made that false. The doc now has
    /// to describe both domains and carry the two review invariants, because
    /// those invariants are the only thing standing between a future change and
    /// the races the conversion removed.
    func testArchitectureDocDescribesBothDomainsAndTheReviewInvariants() throws {
        let doc = try ClientSourceText.packageFile("docs/architecture.md")

        XCTAssertFalse(
            doc.contains("does **not** use actors"),
            "architecture.md still claims the client uses no actors — three of them exist"
        )
        for actor in ["OfflineStore", "KvCache", "AnalyticsQueue"] {
            XCTAssertTrue(doc.contains(actor), "architecture.md must name the \(actor) actor")
        }
        XCTAssertTrue(doc.contains("two domains") || doc.contains("Two domains"),
                      "architecture.md must describe the two-domain split")
        XCTAssertTrue(doc.contains("No `await` inside a decision block"),
                      "architecture.md must carry the decision-block review invariant")
        // Quoted in full for the same reason as the safety-argument clause
        // above: `contains("reentrant")` passes a rewrite saying actor
        // isolation is *not* reentrant, which would invert the invariant.
        XCTAssertTrue(doc.contains("actor isolation is *reentrant*"),
                      "the invariant only makes sense once the doc says actor isolation is reentrant")
        XCTAssertTrue(doc.contains("written safety argument"),
                      "architecture.md must carry the @unchecked Sendable review invariant")
    }

    /// `docs/testing.md` has to explain the two gates, and specifically the rule
    /// the TSan baseline shrink follows — remove a signature only after a clean
    /// run, and add the suite that exercises it to the default filter. Without
    /// that second half a removed entry means nothing.
    func testTestingDocRecordsTheGatesAndTheBaselineShrinkRule() throws {
        let doc = try ClientSourceText.packageFile("docs/testing.md")

        XCTAssertTrue(doc.contains("v6-sendable-gate.sh"), "testing.md must document the Sendable gate")
        XCTAssertTrue(doc.contains("tsan-gate.sh"), "testing.md must document the TSan gate")
        XCTAssertTrue(doc.contains("baseline"), "testing.md must explain the baseline-diff policy")
        XCTAssertTrue(
            doc.contains("only after a clean run") || doc.contains("Remove only after a clean run"),
            "testing.md must state that a baseline entry is removed only after a clean run"
        )
        XCTAssertTrue(
            doc.contains("default filter"),
            "testing.md must state that the suite covering a removed entry joins the default filter"
        )
    }

    /// The gate scripts the doc points at have to actually be there and be
    /// executable — a documented gate nobody can run is worse than none.
    func testBothGateScriptsExistAndAreExecutable() throws {
        for script in ["scripts/v6-sendable-gate.sh", "scripts/tsan-gate.sh"] {
            let url = ClientSourceText.packageRoot.appendingPathComponent(script)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(script)")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "\(script) is not executable")
        }
    }
}
