import XCTest
@testable import JsBaoClient

/// #1993 Phase D4 — boundary bookkeeping for the types that stay
/// class-plus-lock while the async managers become actors.
///
/// Phases D1-D3 converted `OfflineStore`, `KvCache` and `AnalyticsQueue`. Two
/// types the design originally listed were deliberately kept out of that set by
/// the sponsor: `DatabaseSubscriptionRegistry` (it did no I/O; it left with
/// `client.databases` in #3189) and `AuthController` (deferred to #2173). Keeping a lock is fine; keeping a
/// bare `@unchecked Sendable` is not, because that attribute is a claim the
/// compiler never checks. This suite checks that the invariants each type's
/// safety argument relies on hold in the code.
///
/// Structural checks read comment-stripped source, so a phrase quoted in a doc
/// comment cannot decide whether an invariant holds.
///
/// Every test here is server-free.
final class SyncAdjacentBoundaryTypesTests: XCTestCase {

    // MARK: - The invariants behind the safety arguments

    /// `AuthController`'s argument claims every mutable field is lock-confined.
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

    // MARK: - The gate scripts

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
