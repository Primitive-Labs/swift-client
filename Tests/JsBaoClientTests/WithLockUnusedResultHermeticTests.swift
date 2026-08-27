import Foundation
import XCTest

/// Mechanical guard against the `withLock { collection.remove(x) }` warning
/// class.
///
/// `NSLock.withLock` (and the `Mutex`-shaped helpers around it) is generic over
/// its closure's return type, so a one-expression closure body implicitly
/// returns whatever that expression evaluates to. When the expression is a
/// result-returning collection mutation — `Set.remove` hands back an
/// `Element?`, `Dictionary.removeValue(forKey:)` an optional value — the
/// `withLock` call itself becomes non-`Void`, and in statement position the
/// compiler reports "result of call to 'withLock' is unused [#no-usage]"
/// (#2747, `JsBaoClient.swift:3281`).
///
/// The fix is always the same one character: discard inside the closure
/// (`withLock { _ = set.remove(x) }`), which is what every neighbouring call
/// site already does. `pnpm swift:check:warnings` cannot catch a regression
/// here — its accept-list is the app-layer trees and it filters
/// `swift-client/` diagnostics out as dependency warnings — so, like the rest
/// of the client's compiler-adjacent invariants, the check lives with the test
/// suite. Source-structural and server-free.
///
/// The rule: a `withLock { … }` written as a whole statement, on one line, may
/// not leave a result-returning mutation undiscarded.
///
/// **Known blind spots.** This is a text scan, not a type checker. The list is
/// meant to be exhaustive — widen or narrow the scan and this list changes in
/// the same edit. A mechanical check earns its keep on what it is documented
/// *not* to catch as much as on what it catches.
/// - Only single-line closures are read. A multi-line `withLock { … }` whose
///   last statement returns a value warns just the same, but recognising the
///   "last statement" of a block from text is a different, much larger job.
/// - Only the listed mutations trigger (`removeTriggers`). A statement-position
///   `withLock { set.contains(x) }`, or a call into a `@discardableResult`-less
///   helper of the client's own, is invisible.
/// - The call must open the line: `defer { lock.withLock { … } }` and a
///   `withLock` nested inside another expression are skipped, because whether
///   the enclosing context consumes the result is not decidable from text.
/// - A closure body containing braces of its own (`withLock { if a { b } }`) is
///   skipped: its shape is a statement block, not the one-expression implicit
///   return this warning class is about.
/// - A mutation whose result is chained onward through optional chaining
///   (`withLock { tasks.removeValue(forKey: id)?.cancel() }`) is skipped: the
///   call's type is `Void?`, which the compiler does not report.
/// - "Sole statement of its block" is only exempt when the enclosing header
///   demonstrably consumes a value — a declared return type, or a computed
///   property/getter/subscript. Whether a *declared* return type is really
///   non-`Void` is read from text: `-> Void` and `-> ()` are spelled out, but a
///   typealias for `Void` would be missed.
final class WithLockUnusedResultHermeticTests: XCTestCase {

    // MARK: - The check

    struct Violation: CustomStringConvertible {
        let file: String
        let line: Int
        let snippet: String

        var description: String {
            return "\(file):\(line) — \(snippet)"
        }
    }

    /// Standard-library mutations that hand a value back. `removeAll()` and
    /// `append(_:)` return `Void` and are deliberately absent; `remove(` does
    /// not match `removeAll(` because the paren is part of the needle.
    private static let removeTriggers = [
        ".remove(",
        ".insert(",
        ".removeValue(",
        ".removeFirst(",
        ".removeLast(",
        ".popLast(",
        ".popFirst(",
        ".updateValue(",
    ]

    /// Whether `text` is a bare receiver chain (`lock.`, `self.lock.`) — i.e.
    /// the `withLock` call starts the statement rather than feeding a `return`,
    /// an assignment, or a surrounding expression.
    static func isReceiverChain(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }

    /// The single-expression body of a one-line trailing closure that starts at
    /// `open` (just past `withLock {`) and closes at the end of `line`. `nil`
    /// when the closure runs past the line or carries braces of its own.
    static func singleExpressionBody(of line: String, from open: String.Index) -> String? {
        guard line.hasSuffix("}") else { return nil }
        let body = line[open..<line.index(before: line.endIndex)]
        guard !body.contains("{"), !body.contains("}") else { return nil }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the line at `index` sits in an implicit-return position: the only
    /// statement of its block, *and* that block hands a value back to its caller.
    ///
    /// Being alone in a block is not enough. `func reset() { … }` returns `Void`,
    /// so a value left in its one-statement body is unused and warns exactly like
    /// the shipped bug did — only a block that consumes a result is exempt.
    static func isImplicitReturnPosition(_ lines: [String], _ index: Int) -> Bool {
        func neighbour(from start: Int, step: Int) -> String? {
            var i = start
            while i >= 0 && i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
                i += step
            }
            return nil
        }
        guard let above = neighbour(from: index - 1, step: -1),
              let below = neighbour(from: index + 1, step: 1) else { return false }
        guard above.hasSuffix("{"), below == "}" else { return false }
        return declaresResult(above)
    }

    /// Whether a block header returns a value to its caller: a declared return
    /// type (`-> Bool {`, `() -> [StreamEntry] in`), or a computed property,
    /// getter, or subscript, whose body position *is* the value. A `func` with no
    /// arrow returns `Void`; so does `defer {`, an `if` branch, or a
    /// `Void`-taking trailing closure — none of them consume anything.
    static func declaresResult(_ header: String) -> Bool {
        if header.contains("-> Void") || header.contains("-> ()") { return false }
        if header.contains("->") { return true }
        let words = header.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
        if words.contains("func") { return false }
        if words.contains("var") || words.contains("subscript") { return true }
        return words.first == "get"
    }

    /// Whether the mutation's result is chained onward through optional chaining
    /// (`tasks.removeValue(forKey: id)?.cancel()`). The chain's type is `Void?`
    /// when the tail call returns `Void`, and the compiler does not report that.
    static func isOptionalChained(_ body: String) -> Bool {
        let tails = removeTriggers.compactMap { body.range(of: $0, options: .backwards)?.upperBound }
        guard let lastTrigger = tails.max() else { return false }
        return body[lastTrigger...].contains("?.")
    }

    /// Every statement-position `withLock` in `source` that discards nothing.
    static func findViolations(in source: String, file: String) -> [Violation] {
        let lines = ClientSourceText.stripComments(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var violations: [Violation] = []
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let call = line.range(of: ".withLock {") else { continue }
            guard isReceiverChain(String(line[line.startIndex..<call.lowerBound])) else { continue }
            guard var body = singleExpressionBody(of: line, from: call.upperBound) else { continue }
            // A `return` here belongs to the closure, not to the caller: it makes
            // `withLock` non-`Void` rather than consuming its result.
            if body.hasPrefix("return ") { body = String(body.dropFirst("return ".count)) }
            guard !body.hasPrefix("_ =") else { continue }
            guard removeTriggers.contains(where: { body.contains($0) }) else { continue }
            guard !isOptionalChained(body) else { continue }
            guard !isImplicitReturnPosition(lines, index) else { continue }
            violations.append(Violation(file: file, line: index + 1, snippet: line))
        }
        return violations
    }

    // MARK: - Detector tests

    func testDetectorFlagsTheUndiscardedStatementThatShipped() {
        let source = """
        func startNetworkSync(_ documentId: String) {
            lock.withLock { _ = subscribedDocuments.insert(documentId) }
            lock.withLock { syncStep2ReceivedFor.remove(documentId) }
            scheduleSyncWatchdog(documentId)
        }
        """
        let violations = Self.findViolations(in: source, file: "Sample.swift")
        XCTAssertEqual(violations.map(\.line), [3], "\(violations)")
    }

    /// A one-statement `Void` function is the bug, not an implicit return:
    /// Swift 6.3 reports `result of call to 'withLock' is unused` here too.
    func testDetectorFlagsTheOneStatementBodyOfAVoidFunction() {
        let source = """
        func reset(_ documentId: String) {
            lock.withLock { syncStep2ReceivedFor.remove(documentId) }
        }
        """
        let violations = Self.findViolations(in: source, file: "Sample.swift")
        XCTAssertEqual(violations.map(\.line), [2], "\(violations)")
    }

    /// The `return` is the *closure's*. It hands the mutation's result to
    /// `withLock`, whose own result is still dropped on the floor.
    func testDetectorFlagsAnExplicitReturnInsideTheClosure() {
        let source = """
        func reset(_ documentId: String) {
            scheduleSyncWatchdog(documentId)
            lock.withLock { return syncStep2ReceivedFor.remove(documentId) }
        }
        """
        let violations = Self.findViolations(in: source, file: "Sample.swift")
        XCTAssertEqual(violations.map(\.line), [3], "\(violations)")
    }

    /// `removeValue(forKey:)?.cancel()` types as `Void?`, which the compiler
    /// does not report — so neither does this (`DocumentManager.swift`,
    /// `cancelPendingPersist`).
    func testDetectorSkipsAnOptionalChainedVoidTail() {
        let source = """
        private func cancelPendingPersist(documentId: String) {
            lock.withLock { persistDebounceTasks.removeValue(forKey: documentId)?.cancel() }
        }
        """
        XCTAssertEqual(Self.findViolations(in: source, file: "Sample.swift").map(\.description), [])
    }

    func testDetectorSkipsCallsWhoseResultIsUsed() {
        let source = """
        var defaultDocumentId: String? {
            get { lock.withLock { defaultDocumentIdStorage } }
        }
        var claimed: String? {
            lock.withLock { pending.removeValue(forKey: id) }
        }
        func take(_ id: String) -> String? {
            let removed = lock.withLock { pending.removeValue(forKey: id) }
            return removed
        }
        func report(_ id: String) -> Bool {
            return lock.withLock { reported.insert(id).inserted }
        }
        """
        XCTAssertEqual(Self.findViolations(in: source, file: "Sample.swift").map(\.description), [])
    }

    /// The implicit-return body of a one-line function looks exactly like the
    /// bug from the outside — only its position in the block tells them apart.
    func testDetectorSkipsTheImplicitReturnBodyOfAOneLineFunction() {
        let source = """
        internal func noteDisconnectedSyncSkip(_ documentId: String) -> Bool {
            lock.withLock { disconnectedSyncSkipReported.insert(documentId).inserted }
        }
        """
        XCTAssertEqual(Self.findViolations(in: source, file: "Sample.swift").map(\.description), [])
    }

    func testDetectorSkipsVoidReturningMutations() {
        let source = """
        func reset() {
            lock.withLock { disconnectedSyncSkipReported.removeAll() }
            lock.withLock { pendingUpdates[documentId] = nil }
            lock.withLock { queue.append(update) }
        }
        """
        XCTAssertEqual(Self.findViolations(in: source, file: "Sample.swift").map(\.description), [])
    }

    /// A comment quoting the bug shape is not the bug shape.
    func testDetectorIgnoresComments() {
        let source = """
        func reset() {
            // lock.withLock { syncStep2ReceivedFor.remove(documentId) }
            lock.withLock { _ = syncStep2ReceivedFor.remove(documentId) }
        }
        """
        XCTAssertEqual(Self.findViolations(in: source, file: "Sample.swift").map(\.description), [])
    }

    // MARK: - The guard

    /// No client source may leave a `withLock` result undiscarded.
    func testNoUndiscardedWithLockResultsInSources() throws {
        let files = try ClientSourceText.packageSwiftFiles()
            .filter { $0.hasPrefix("Sources/") }
        // The client has ~100 source files; 50 is a deliberately loose floor
        // that only trips if path resolution broke and the walker read the
        // wrong directory, which would scan nothing and pass silently.
        XCTAssertGreaterThan(
            files.count, 50,
            "the scan found suspiciously few sources — the path resolution is probably wrong")

        var violations: [Violation] = []
        for path in files {
            let contents = try ClientSourceText.packageFile(path)
            guard contents.contains("withLock") else { continue }
            violations += Self.findViolations(in: contents, file: path)
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Statement-position `withLock` call(s) returning a discarded value. \
            The closure implicitly returns the mutation's result, so `withLock` \
            is non-Void and the compiler warns "result of call to 'withLock' is \
            unused [#no-usage]". Discard inside the closure — \
            `withLock { _ = set.remove(x) }` (#2747):
            \(violations.map(\.description).joined(separator: "\n"))
            """
        )
    }

    /// The site from #2747, specifically: the sync cycle still clears
    /// `syncStep2ReceivedFor` for the document under the lock, and does it with
    /// the explicit discard.
    func testStartNetworkSyncClearsSyncStepTwoUnderTheLockWithAnExplicitDiscard() throws {
        let region = try ClientSourceText.slice(
            ClientSourceText.code("JsBaoClient.swift"),
            from: "guard let message = documentManager.buildSyncStep1Message(documentId: documentId)",
            to: "scheduleSyncWatchdog(documentId)"
        )
        XCTAssertTrue(
            region.contains("lock.withLock { _ = syncStep2ReceivedFor.remove(documentId) }"),
            """
            the new-cycle reset must still clear `syncStep2ReceivedFor` for the \
            document under the lock (#2664, C14), with the result discarded \
            inside the closure so `withLock` stays Void (#2747)
            """
        )
    }
}
