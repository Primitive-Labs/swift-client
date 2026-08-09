import Foundation
import XCTest
@testable import JsBaoClient

/// `JsBaoClient.lock` is a plain `NSLock`, so it is **not** recursive: a
/// property whose getter takes it must never be read from inside another
/// critical section that already holds it.
///
/// This is a real regression, not a hypothetical. #2367 turned the `get*()`
/// accessors into properties, which meant `networkMode` — until then the name
/// of the private *storage* — became a lock-taking public property while the
/// storage was renamed to `networkModeStorage`. Every internal
/// `lock.withLock { networkMode }` read silently became a self-deadlock.
/// `networkStatus` had one, and reading `client.networkStatus` hung the whole
/// suite rather than failing a test.
///
/// So each of these is exercised under the shared watchdog, which **fails**
/// instead of hanging. A hang here would otherwise look identical to a slow
/// live test and could sit undiagnosed for a full suite run.
final class ClientPropertyLockReentrancyTests: XCTestCase {

    /// A bare client: bootstrapped token, no auto-connect, memory storage —
    /// constructs without any dev server.
    private func makeClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "test-app",
            token: "test-token",
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    /// Every client property whose getter acquires `lock`. Reading each one
    /// must return; the composite `networkStatus` is the one that regressed,
    /// because it reads a second lock-confined value inside its own hold.
    ///
    /// One read per name in ``lockTakingPropertyNames(in:)``. If that
    /// derivation finds a name with no read here,
    /// ``testTheBehavioralSweepCoversEveryDerivedProperty`` fails.
    func testEveryLockTakingClientPropertyReturns() {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        assertCompletes(within: 3, "client.networkMode") {
            _ = client.networkMode
        }
        assertCompletes(within: 3, "client.networkStatus") {
            _ = client.networkStatus
        }
        assertCompletes(within: 3, "client.defaultDocumentId") {
            _ = client.defaultDocumentId
        }
        assertCompletes(within: 3, "client.retentionPolicy") {
            _ = client.retentionPolicy
        }
        assertCompletes(within: 3, "client.initialReachabilityLatched") {
            _ = client.initialReachabilityLatched
        }
    }

    /// The names the sweep above reads, by hand. Kept beside it so the check
    /// below can compare them against what the source actually declares.
    private static let behaviorallyCovered: Set<String> = [
        "networkMode", "networkStatus", "defaultDocumentId", "retentionPolicy",
        "initialReachabilityLatched",
    ]

    /// The hand-written sweep drifts by construction — a new lock-taking
    /// property is easy to add and easy to forget here, and
    /// `initialReachabilityLatched` had already been missed. So the list is
    /// derived from the source and compared, rather than trusted.
    func testTheBehavioralSweepCoversEveryDerivedProperty() throws {
        let derived = try Self.lockTakingPropertyNames(
            in: ClientSourceText.clientSource("JsBaoClient.swift")
        )
        XCTAssertFalse(
            derived.isEmpty,
            "the source scan found no lock-taking properties at all — it has stopped working, "
                + "which would also silently disarm the critical-section scan below"
        )
        let missing = derived.subtracting(Self.behaviorallyCovered).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            """
            JsBaoClient.swift declares lock-taking properties that \
            testEveryLockTakingClientPropertyReturns does not read: \(missing). \
            Add a read there (and the name to `behaviorallyCovered`) — an \
            unread one self-deadlocks with this whole suite green.
            """
        )
    }

    /// `isOnline()` is the path the regression actually surfaced through — it
    /// reads `networkStatus`, which read `networkMode`, which took the lock a
    /// second time. Pinned separately so the composite stays covered even if
    /// the property list above is edited.
    func testIsOnlineDoesNotReenterTheLock() {
        let client = makeClient()
        defer { Task { await client.destroy() } }

        assertCompletes(within: 3, "client.isOnline()") {
            _ = client.isOnline()
        }
    }

    /// The structural half: no critical section in `JsBaoClient.swift` may name
    /// a lock-taking property. The behavioral tests above only cover the
    /// entry points they call; this covers the ones nobody has called yet.
    ///
    /// The scan is deliberately narrow — it looks for a reference to one of
    /// the lock-taking names inside a `lock.withLock` block — so it reports
    /// the re-entry shape rather than trying to model Swift scoping. Both
    /// `networkMode` and `self.networkMode` are matched: inside an escaping
    /// closure `self.` is often the required spelling, so it is the shape a
    /// regression is *most* likely to take, not an exotic one. A reference
    /// through any other receiver (`options.networkMode`) is not a re-entry
    /// and is not matched.
    ///
    /// The name list is derived from the source rather than hand-maintained —
    /// see ``lockTakingPropertyNames(in:)``.
    func testNoCriticalSectionReadsALockTakingProperty() throws {
        let source = try ClientSourceText.clientSource("JsBaoClient.swift")
        let lines = ClientSourceText.stripComments(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Storage spellings are the correct thing to read inside the lock, so
        // they must not be flagged — hence the word-boundary check below.
        let lockTaking = try Self.lockTakingPropertyNames(in: source).sorted()
        XCTAssertFalse(lockTaking.isEmpty, "the source scan found no lock-taking properties")

        var index = 0
        while index < lines.count {
            guard lines[index].contains("lock.withLock") else {
                index += 1
                continue
            }
            var depth = lines[index].filter { $0 == "{" }.count
                - lines[index].filter { $0 == "}" }.count
            var body = [lines[index]]
            var cursor = index
            while depth > 0 && cursor + 1 < lines.count {
                cursor += 1
                body.append(lines[cursor])
                depth += lines[cursor].filter { $0 == "{" }.count
                    - lines[cursor].filter { $0 == "}" }.count
            }

            for (offset, line) in body.enumerated() {
                for name in lockTaking where containsIdentifier(name, in: line) {
                    XCTFail(
                        """
                        JsBaoClient.swift:\(index + 1 + offset) reads the lock-taking \
                        property `\(name)` inside a `lock.withLock` block. `lock` is a \
                        non-recursive NSLock, so this deadlocks — read the \
                        `\(name)Storage` backing value instead.
                        """
                    )
                }
            }
            index = cursor + 1
        }
    }

    /// A guard is only as good as its matcher, and this one silently reported
    /// clean over `self.networkMode` — the spelling an escaping closure
    /// usually requires — until the review of #2367 caught it. So the matcher
    /// itself is pinned, positively and negatively.
    func testTheMatcherFlagsSelfQualifiedReadsAndNothingElse() {
        // Re-entries: both must be flagged.
        XCTAssertTrue(containsIdentifier("networkMode", in: "lock.withLock { networkMode }"))
        XCTAssertTrue(
            containsIdentifier("networkMode", in: "lock.withLock { self.networkMode }"),
            "`self.` is the usual spelling inside an escaping closure and deadlocks identically"
        )
        XCTAssertTrue(containsIdentifier("networkMode", in: "return (self.networkMode, x)"))

        // Not re-entries: none may be flagged.
        XCTAssertFalse(
            containsIdentifier("networkMode", in: "lock.withLock { networkModeStorage }"),
            "the storage spelling is the CORRECT thing to read inside the lock"
        )
        XCTAssertFalse(
            containsIdentifier("networkMode", in: "lock.withLock { options.networkMode }"),
            "a different receiver is a different object"
        )
        XCTAssertFalse(
            containsIdentifier("networkMode", in: "lock.withLock { other.self.networkMode }"),
            "`self` reached through another receiver is not this instance"
        )
        XCTAssertFalse(containsIdentifier("networkMode", in: "let preNetworkMode = 1"))
    }

    /// `name` appears as a whole identifier, not as a prefix (`networkMode`
    /// must not match `networkModeStorage`) and not as a member of some other
    /// receiver (`options.networkMode`). A `self.` receiver **does** match:
    /// `lock.withLock { self.networkMode }` deadlocks exactly as
    /// `lock.withLock { networkMode }` does.
    private func containsIdentifier(_ name: String, in line: String) -> Bool {
        let characters = Array(line)
        var searchStart = characters.startIndex
        while let range = line.range(
            of: name,
            range: line.index(line.startIndex, offsetBy: searchStart)..<line.endIndex
        ) {
            let lower = line.distance(from: line.startIndex, to: range.lowerBound)
            let upper = line.distance(from: line.startIndex, to: range.upperBound)
            let beforeOK: Bool
            if lower == 0 {
                beforeOK = true
            } else if characters[lower - 1] == "." {
                // A member reference. It is a re-entry only when the receiver
                // is `self` — any other receiver is a different object.
                beforeOK = Self.receiverIsSelf(characters, dotIndex: lower - 1)
            } else {
                beforeOK = !isIdentifierCharacter(characters[lower - 1])
            }
            let afterOK = upper == characters.count || !isIdentifierCharacter(characters[upper])
            if beforeOK && afterOK { return true }
            searchStart = upper
            if searchStart >= characters.count { break }
        }
        return false
    }

    /// Whether the identifier run ending at `dotIndex - 1` is exactly `self`
    /// (and is itself not the tail of a longer member chain like
    /// `wrapper.self`, which cannot occur, or `mySelf`, which can).
    private static func receiverIsSelf(_ characters: [Character], dotIndex: Int) -> Bool {
        var start = dotIndex
        while start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber
            || characters[start - 1] == "_" {
            start -= 1
        }
        guard String(characters[start..<dotIndex]) == "self" else { return false }
        // `self` must not itself be a member of something (`x.self.y`).
        return start == 0 || characters[start - 1] != "."
    }

    private func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Every `JsBaoClient` property whose accessor body takes `lock`, read out
    /// of the source instead of maintained by hand.
    ///
    /// The hand-written list this replaces had already drifted — it named four
    /// properties while `initialReachabilityLatched` was a fifth — and a
    /// missing name silently disarms both halves of this suite. The scan is
    /// the same shape as the critical-section scan below: find a computed
    /// property declaration (`… var name: Type {`), take its braced body by
    /// depth counting, and keep the name when the body mentions
    /// `lock.withLock`.
    static func lockTakingPropertyNames(in source: String) throws -> Set<String> {
        let lines = ClientSourceText.stripComments(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var names: Set<String> = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasSuffix("{"), let name = declaredPropertyName(in: line) else {
                index += 1
                continue
            }
            var depth = line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            var body = ""
            var cursor = index
            while depth > 0 && cursor + 1 < lines.count {
                cursor += 1
                body += lines[cursor] + "\n"
                depth += lines[cursor].filter { $0 == "{" }.count
                    - lines[cursor].filter { $0 == "}" }.count
            }
            if body.contains("lock.withLock") { names.insert(name) }
            index = cursor + 1
        }
        return names
    }

    /// The property name in a computed-property declaration line, or `nil`
    /// when the line isn't one. Matches `… var name: Type {` and rejects
    /// stored declarations (no trailing `{`, handled by the caller) and
    /// anything with a `(` before the `:` (a function).
    private static func declaredPropertyName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let varRange = trimmed.range(of: "var ") else { return nil }
        // `var` must start the declaration modulo access/`static` modifiers.
        let prefix = trimmed[trimmed.startIndex..<varRange.lowerBound]
        let allowedModifiers: Set<String> = [
            "public", "internal", "private", "fileprivate", "open", "static", "final",
            "nonisolated", "class", "package",
        ]
        for word in prefix.split(separator: " ") {
            // `private(set)` / `public private(set)` — the access-level scope
            // is irrelevant here, so normalize it away.
            let bare = String(word).replacingOccurrences(of: "(set)", with: "")
            guard allowedModifiers.contains(bare) else { return nil }
        }
        let rest = trimmed[varRange.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = rest[rest.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(" "), !name.contains("("), !name.contains(")") else {
            return nil
        }
        return name
    }
}
