import XCTest

/// Mechanical guard against the `Int(...pow(...))`-before-cap bug class.
///
/// Converting an exponential-backoff `Double` to `Int` **before** capping it
/// traps ("Double value cannot be converted to Int because the result would be
/// greater than Int.max") and aborts the whole process — which, in the test
/// suite, silently truncates the run. The client has shipped this bug three
/// times: `WebSocketManager.calculateReconnectDelay` (#2027),
/// `DocumentManager`'s create-commit retry, and `BlobManager.computeBackoff`
/// (#2056). There is no SwiftLint config in this repo, so the check lives here
/// as a test: it runs with the suite and fails on the fourth instance.
///
/// The rule: inside a `swift-client/Sources` file, an integer conversion whose
/// argument reaches an uncapped `pow(` must apply a `min(` before it — i.e. the
/// cap must be in the `Double` domain. `Int(min(pow(…), cap))` passes;
/// `Int(pow(…))` and `min(Int(pow(…)), cap)` do not.
///
/// "Reaches" covers two spellings, because #2056 shipped as the second one:
///
/// 1. **Inlined** — the `pow(` call sits inside the conversion's own argument
///    (`Int(pow(2.0, x))`, `min(Int(base * pow(2.0, x)), cap)`).
/// 2. **Variable-held** — the `pow(` result is bound to a local first and the
///    conversion takes the local (`let delay = base * pow(2.0, x)` then
///    `min(Int(delay), cap)`). This is exactly how `BlobManager.computeBackoff`
///    was written, and a detector that only reads the conversion's argument
///    text cannot see it. So the scan first collects the locals in each scope
///    that hold an *uncapped* `pow(` result, then treats a reference to one of
///    them the same way it treats a literal `pow(`.
///
/// Taint is scoped to the innermost enclosing `{ … }` block and only flows
/// forward from the binding, so a same-named local in another function (e.g.
/// `BlobManager.scheduleQueueProcessing`'s own `delay`) is not affected.
/// Assignments chain: a local derived from a tainted local is tainted too.
///
/// **Known blind spots.** This is a text scan, not a type checker, so it has
/// gaps. The list below is meant to be exhaustive — if you widen or narrow the
/// scan, change this list in the same edit. A mechanical check earns its keep
/// on what it is documented *not* to catch as much as on what it catches.
/// - A `min(` anywhere before the trigger inside the argument satisfies the
///   check, even when it caps something else (`Int(min(a, b) + pow(c, d))`).
/// - Taint does not cross function boundaries: a helper that *returns* an
///   uncapped `pow(` result is invisible at its call site.
/// - Only `min` is recognised as a cap; a bespoke clamp spelled another way
///   would be reported and needs an inline restructure (or the `min` form).
/// - Only `pow`/`powf`/`powl`/`exp2` calls start taint. Exponential growth
///   written another way — `1 << n`, repeated multiplication in a loop, a
///   precomputed table — is invisible. Recognising those shapes from text
///   without swamping the check in false positives is not practical.
/// - Taint follows simple local bindings only. Member writes (`self.delay =
///   …`), tuple and pattern bindings, `inout` parameters, and values captured
///   into a closure that runs elsewhere are all untracked.
/// - Statement boundaries are heuristic. A newline continues the statement
///   when the line just closed ends on a binary operator or the next line
///   opens with one — that covers the ~100-column wraps this codebase writes.
///   A wrap of another shape (a complete sub-expression continued by a leading
///   identifier, say) still ends the statement early and truncates the
///   right-hand side.
/// - Code inside string interpolation (`\(…)`) is blanked along with the rest
///   of the literal, and raw-string delimiters (`#"…"#`, `#"""…"""#`) are not
///   understood — a `"` inside a raw string can desynchronise the strip pass
///   for the rest of the file.
/// - Conversions labelled `exactly:`, `clamping:` or `truncatingIfNeeded:` are
///   skipped on purpose: none of them trap, so they are correct fixes for this
///   bug class rather than instances of it.
final class UncappedPowConversionGuardTests: XCTestCase {

    // MARK: - The check

    struct Violation: CustomStringConvertible {
        let file: String
        let line: Int
        let snippet: String

        var description: String {
            return "\(file):\(line) — \(snippet)"
        }
    }

    /// A local binding that holds an uncapped `pow()` result, with the source
    /// range over which references to it count as reaching that `pow()`.
    struct TaintedBinding {
        let name: String
        let declaredAt: Int
        let scope: Range<Int>
    }

    /// Integer conversions worth guarding. Their *unlabelled* initializer traps
    /// on an out-of-range or non-finite `Double` — that is the bug class. The
    /// labelled forms do not trap (`exactly:` returns `nil`, `clamping:`
    /// saturates, `truncatingIfNeeded:` wraps), so they are skipped; see
    /// `nonTrappingLabels`.
    private static let conversions = [
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    ]

    /// Argument labels that make an integer conversion non-trapping. A
    /// conversion using one of these is a *fix* for this bug class, not an
    /// instance of it — `Int(clamping: pow(2.0, x))` is safe, and
    /// `Int(exactly:)` is the hardening idiom used elsewhere in the client.
    private static let nonTrappingLabels = ["exactly:", "clamping:", "truncatingIfNeeded:"]

    /// Exponential-growth calls that start taint. `powf`/`powl` differ from
    /// `pow` only in precision, and `exp2` is the same doubling spelled
    /// differently.
    private static let powFunctions = ["pow", "powf", "powl", "exp2"]

    /// True when `source` might contain one of `powFunctions` — a cheap
    /// superset pre-filter (it matches the bare name, so `powf`/`powl` come
    /// along with `pow`) used to skip files the scan cannot flag.
    static func mayContainPowCall(_ source: String) -> Bool {
        return powFunctions.contains { source.contains($0) }
    }

    /// Find every integer conversion in `source` that reaches an uncapped
    /// `pow(` — either inlined in its argument or through a local that holds
    /// one.
    static func findViolations(in source: String, file: String = "<memory>") -> [Violation] {
        let stripped = stripCommentsAndStrings(source)
        let chars = Array(stripped)
        let blocks = braceBlocks(in: chars)
        let tainted = powTaintedBindings(in: chars, blocks: blocks)
        var violations: [Violation] = []

        var index = 0
        while index < chars.count {
            guard chars[index] == "(" else {
                index += 1
                continue
            }
            guard let conversion = conversionEndingAt(index, in: chars) else {
                index += 1
                continue
            }
            guard let close = matchingParen(openAt: index, in: chars) else {
                index += 1
                continue
            }
            let argument = String(chars[(index + 1)..<close])
            // `Int(exactly:)`, `Int(clamping:)` and `Int(truncatingIfNeeded:)`
            // do not trap, so an uncapped pow() reaching them is fine.
            let leading = argument.drop(while: { $0.isWhitespace })
            if nonTrappingLabels.contains(where: { leading.hasPrefix($0) }) {
                index += 1
                continue
            }
            let visible = visibleNames(of: tainted, at: index)
            if let trigger = firstUncappedTrigger(in: argument, tainted: visible) {
                let line = 1 + chars[0..<index].filter { $0 == "\n" }.count
                let via = trigger.hasSuffix("(") ? "" : " — `\(trigger)` holds an uncapped pow()"
                violations.append(Violation(
                    file: file,
                    line: line,
                    snippet: "\(conversion)(\(collapseWhitespace(argument)))\(via)"
                ))
            }
            index += 1
        }
        return violations
    }

    /// The first thing in `argument` that reaches an uncapped `pow()` — the
    /// literal `pow(` call, or a reference to a local that holds one — unless a
    /// `min(` caps it first. Returns `nil` when the argument is safe.
    private static func firstUncappedTrigger(
        in argument: String, tainted: Set<String>
    ) -> String? {
        let chars = Array(argument)
        var best: (offset: Int, name: String)?

        if let call = firstPowCall(in: chars) {
            best = (call.offset, call.name)
        }
        for name in tainted {
            guard let offset = firstWordOccurrence(of: name, in: chars) else { continue }
            if best == nil || offset < best!.offset {
                best = (offset, name)
            }
        }

        guard let trigger = best else { return nil }
        let prefix = String(chars[0..<trigger.offset])
        return prefix.contains("min(") ? nil : trigger.name
    }

    /// Locals holding an uncapped `pow()` result. Iterated to a fixed point so
    /// a local derived from a tainted local is tainted too.
    static func powTaintedBindings(in chars: [Character], blocks: [Range<Int>]) -> [TaintedBinding] {
        let candidates = Self.assignments(in: chars, blocks: blocks)
        var tainted: [TaintedBinding] = []
        var changed = true
        while changed {
            changed = false
            for assignment in candidates {
                let already = tainted.contains {
                    $0.name == assignment.name && $0.declaredAt == assignment.at
                }
                if already { continue }
                // `let ms = Int(clamping: pow(2.0, x))` yields an integer that
                // is already in range — it does not carry the pow() hazard on.
                if startsWithNonTrappingConversion(assignment.rhs) { continue }
                let visible = visibleNames(of: tainted, at: assignment.at)
                guard firstUncappedTrigger(in: assignment.rhs, tainted: visible) != nil else {
                    continue
                }
                tainted.append(TaintedBinding(
                    name: assignment.name, declaredAt: assignment.at, scope: assignment.scope))
                changed = true
            }
        }
        return tainted
    }

    /// The tainted names in effect at `index`: declared earlier, and in a scope
    /// that still encloses it.
    private static func visibleNames(of tainted: [TaintedBinding], at index: Int) -> Set<String> {
        var names: Set<String> = []
        for binding in tainted
        where binding.declaredAt < index && binding.scope.contains(index) {
            names.insert(binding.name)
        }
        return names
    }

    private struct Assignment {
        let name: String
        let rhs: String
        let at: Int
        let scope: Range<Int>
    }

    /// Every `name = <expression>` in the source (declarations and plain
    /// reassignments alike), with the expression text and the innermost block
    /// that encloses it.
    private static func assignments(in chars: [Character], blocks: [Range<Int>]) -> [Assignment] {
        var results: [Assignment] = []
        var index = 0
        while index < chars.count {
            guard chars[index] == "=" else {
                index += 1
                continue
            }
            // Reject `==`, `!=`, `<=`, `>=`, `+=`, `->`, … — only a plain
            // assignment binds a name to an expression.
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            let previous: Character? = index > 0 ? chars[index - 1] : nil
            if next == "=" || previous == "=" || previous.map({ "!<>+-*/%&|^~".contains($0) }) == true {
                index += 1
                continue
            }
            guard let name = assignedName(before: index, in: chars) else {
                index += 1
                continue
            }
            let end = statementEnd(after: index, in: chars)
            let rhs = String(chars[(index + 1)..<end])
            results.append(Assignment(
                name: name, rhs: rhs, at: index, scope: enclosingScope(of: index, in: blocks, count: chars.count)))
            index = end
        }
        return results
    }

    /// The identifier being assigned by the `=` at `equalsIndex`, stepping over
    /// a type annotation (`let delay: Double = …`) when one is present.
    private static func assignedName(before equalsIndex: Int, in chars: [Character]) -> String? {
        func identifier(endingBefore position: Int) -> (name: String, start: Int)? {
            var end = position
            while end > 0, chars[end - 1].isWhitespace { end -= 1 }
            var start = end
            while start > 0, chars[start - 1].isLetter || chars[start - 1].isNumber
                || chars[start - 1] == "_" {
                start -= 1
            }
            guard start < end else { return nil }
            let name = String(chars[start..<end])
            guard let first = name.first, first.isLetter || first == "_" else { return nil }
            return (name, start)
        }

        guard var candidate = identifier(endingBefore: equalsIndex) else { return nil }
        // `let x: Double = …` — the token before `=` is the type; step back
        // over the `:` to the real name.
        var before = candidate.start
        while before > 0, chars[before - 1].isWhitespace { before -= 1 }
        if before > 0, chars[before - 1] == ":" {
            guard let annotated = identifier(endingBefore: before - 1) else { return nil }
            candidate = annotated
        }
        // Reject `self.foo = …`-style member writes: taint tracking is local.
        var priorIndex = candidate.start
        while priorIndex > 0, chars[priorIndex - 1].isWhitespace { priorIndex -= 1 }
        if priorIndex > 0, chars[priorIndex - 1] == "." { return nil }
        let keywords: Set<String> = ["let", "var", "case", "return", "in", "where", "if", "guard"]
        return keywords.contains(candidate.name) ? nil : candidate.name
    }

    /// End of the statement starting after `start` — the first `;`, or the
    /// first newline at bracket depth 0 that does not continue the expression.
    ///
    /// The continuation check matters: without it a right-hand side wrapped at
    /// the column limit is truncated at the wrap, and the pre-fix
    /// `computeBackoff` written as
    ///
    /// ```swift
    /// let delay = Double(baseMs)
    ///     * pow(2.0, exponent)
    /// ```
    ///
    /// never taints `delay`, so the `min(Int(delay), maxMs)` below it passes —
    /// the exact bug shape this guard exists to catch, one line break away.
    private static func statementEnd(after start: Int, in chars: [Character]) -> Int {
        var depth = 0
        var index = start + 1
        while index < chars.count {
            let char = chars[index]
            if char == "(" || char == "[" || char == "{" { depth += 1 }
            if char == ")" || char == "]" || char == "}" {
                if depth == 0 { return index }
                depth -= 1
            }
            if depth == 0, char == ";" { return index }
            if depth == 0, char == "\n" {
                guard isLineWrap(at: index, in: chars, notBefore: start) else { return index }
            }
            index += 1
        }
        return chars.count
    }

    /// Whether the newline at `newlineIndex` wraps one expression across two
    /// lines rather than ending the statement: the line just closed ends on a
    /// binary operator, or the next line opens with one. `notBefore` is the
    /// `=` that started the statement, so `let x =` followed by its value on
    /// the next line counts as a wrap too.
    private static func isLineWrap(
        at newlineIndex: Int, in chars: [Character], notBefore lowerBound: Int
    ) -> Bool {
        let continuationOperators: Set<Character> = [
            "+", "-", "*", "/", "%", "&", "|", "^", "?", ":", ",", "=", "<", ">", ".",
        ]
        // Only the adjacent lines count — a blank line ends the statement.
        var before = newlineIndex - 1
        while before >= lowerBound, chars[before] == " " || chars[before] == "\t" { before -= 1 }
        if before >= lowerBound, continuationOperators.contains(chars[before]) { return true }

        var after = newlineIndex + 1
        while after < chars.count, chars[after] == " " || chars[after] == "\t" { after += 1 }
        guard after < chars.count else { return false }
        return continuationOperators.contains(chars[after])
    }

    /// Every balanced `{ … }` range in the source.
    private static func braceBlocks(in chars: [Character]) -> [Range<Int>] {
        var stack: [Int] = []
        var blocks: [Range<Int>] = []
        for (index, char) in chars.enumerated() {
            if char == "{" { stack.append(index) }
            if char == "}", let open = stack.popLast() { blocks.append(open..<(index + 1)) }
        }
        return blocks
    }

    /// The innermost block containing `index`, or the whole file.
    private static func enclosingScope(
        of index: Int, in blocks: [Range<Int>], count: Int
    ) -> Range<Int> {
        var best: Range<Int>?
        for block in blocks where block.contains(index) {
            if best == nil || block.lowerBound > best!.lowerBound { best = block }
        }
        return best ?? (0..<max(count, 1))
    }

    /// Whether `text` is an expression whose outermost call is a non-trapping
    /// integer conversion (`Int(clamping: …)` and friends).
    private static func startsWithNonTrappingConversion(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0.isWhitespace })
        guard let parenIndex = trimmed.firstIndex(of: "(") else { return false }
        guard conversions.contains(String(trimmed[trimmed.startIndex..<parenIndex])) else {
            return false
        }
        let argument = trimmed[trimmed.index(after: parenIndex)...].drop(while: { $0.isWhitespace })
        return nonTrappingLabels.contains { argument.hasPrefix($0) }
    }

    /// The first call to one of `powFunctions` in `chars`, as an offset and the
    /// spelling matched (`"pow("`, `"exp2("`, …). The name must stand as its
    /// own identifier — `mypow(` is not a match — and whitespace between the
    /// name and the `(` is tolerated.
    private static func firstPowCall(in chars: [Character]) -> (offset: Int, name: String)? {
        func isIdentifierChar(_ char: Character) -> Bool {
            return char.isLetter || char.isNumber || char == "_"
        }
        var index = 0
        while index < chars.count {
            guard chars[index].isLetter || chars[index] == "_" else {
                index += 1
                continue
            }
            var end = index
            while end < chars.count, isIdentifierChar(chars[end]) { end += 1 }
            let precededByIdentifier = index > 0 && isIdentifierChar(chars[index - 1])
            if !precededByIdentifier, powFunctions.contains(String(chars[index..<end])) {
                var after = end
                while after < chars.count, chars[after] == " " || chars[after] == "\t" {
                    after += 1
                }
                if after < chars.count, chars[after] == "(" {
                    return (index, String(chars[index..<end]) + "(")
                }
            }
            index = end
        }
        return nil
    }

    private static func firstOccurrence(of needle: String, in chars: [Character]) -> Int? {
        let pattern = Array(needle)
        guard !pattern.isEmpty, chars.count >= pattern.count else { return nil }
        for start in 0...(chars.count - pattern.count)
        where Array(chars[start..<(start + pattern.count)]) == pattern {
            return start
        }
        return nil
    }

    /// First reference to `name` as a whole identifier (not a substring of a
    /// longer name, and not a member access like `foo.name`).
    private static func firstWordOccurrence(of name: String, in chars: [Character]) -> Int? {
        let pattern = Array(name)
        guard !pattern.isEmpty, chars.count >= pattern.count else { return nil }
        func isIdentifierChar(_ char: Character) -> Bool {
            return char.isLetter || char.isNumber || char == "_"
        }
        for start in 0...(chars.count - pattern.count) {
            guard Array(chars[start..<(start + pattern.count)]) == pattern else { continue }
            if start > 0, isIdentifierChar(chars[start - 1]) || chars[start - 1] == "." { continue }
            let after = start + pattern.count
            if after < chars.count, isIdentifierChar(chars[after]) { continue }
            return start
        }
        return nil
    }

    /// The conversion identifier immediately preceding the `(` at `openIndex`,
    /// when it is one of the guarded integer types and stands as its own token.
    private static func conversionEndingAt(_ openIndex: Int, in chars: [Character]) -> String? {
        var start = openIndex
        while start > 0, chars[start - 1].isLetter || chars[start - 1].isNumber {
            start -= 1
        }
        guard start < openIndex else { return nil }
        let identifier = String(chars[start..<openIndex])
        guard conversions.contains(identifier) else { return nil }
        // Reject member accesses like `foo.Int(` / `x.UInt64(`.
        if start > 0, chars[start - 1] == "." { return nil }
        return identifier
    }

    private static func matchingParen(openAt: Int, in chars: [Character]) -> Int? {
        var depth = 0
        var index = openAt
        while index < chars.count {
            if chars[index] == "(" { depth += 1 }
            if chars[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// Blank out comments and string literals — single-line and `"""` — so
    /// `pow(` mentioned in prose (or in a string) can't trip the check, and so
    /// brackets inside a literal can't mis-scope taint. Newlines are preserved
    /// so reported line numbers stay accurate. Raw-string delimiters (`#"…"#`)
    /// are not understood; see the blind-spot list.
    private static func stripCommentsAndStrings(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        let chars = Array(source)
        var index = 0
        var blockDepth = 0

        while index < chars.count {
            let char = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil

            if blockDepth > 0 {
                if char == "*", next == "/" {
                    blockDepth -= 1
                    output.append(" ")
                    output.append(" ")
                    index += 2
                    continue
                }
                if char == "/", next == "*" {
                    blockDepth += 1
                    output.append(" ")
                    output.append(" ")
                    index += 2
                    continue
                }
                output.append(char == "\n" ? "\n" : " ")
                index += 1
                continue
            }

            if char == "/", next == "*" {
                blockDepth = 1
                output.append(" ")
                output.append(" ")
                index += 2
                continue
            }
            if char == "/", next == "/" {
                while index < chars.count, chars[index] != "\n" {
                    output.append(" ")
                    index += 1
                }
                continue
            }
            // Multiline literal. Blanked wholesale (newlines preserved) so its
            // prose can neither trigger the check nor unbalance `braceBlocks`
            // with stray `{`/`(` — several `Sources` files carry multiline SQL.
            if char == "\"", next == "\"", index + 2 < chars.count, chars[index + 2] == "\"" {
                output.append("   ")
                index += 3
                while index < chars.count {
                    if chars[index] == "\\" {
                        output.append(" ")
                        if index + 1 < chars.count { output.append(" ") }
                        index += 2
                        continue
                    }
                    if chars[index] == "\"", index + 2 < chars.count,
                       chars[index + 1] == "\"", chars[index + 2] == "\"" {
                        output.append("   ")
                        index += 3
                        break
                    }
                    output.append(chars[index] == "\n" ? "\n" : " ")
                    index += 1
                }
                continue
            }
            if char == "\"" {
                output.append(" ")
                index += 1
                while index < chars.count {
                    if chars[index] == "\\" {
                        output.append(" ")
                        if index + 1 < chars.count { output.append(" ") }
                        index += 2
                        continue
                    }
                    if chars[index] == "\n" {
                        // Unterminated literal — bail out of string mode.
                        break
                    }
                    let closing = chars[index] == "\""
                    output.append(" ")
                    index += 1
                    if closing { break }
                }
                continue
            }

            output.append(char)
            index += 1
        }
        return output
    }

    private static func collapseWhitespace(_ text: String) -> String {
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Tests

    /// The detector itself: it must flag the two shapes that trap and accept
    /// the shape that doesn't.
    func testDetectorFlagsUncappedConversionsOnly() {
        // Capping after an inlined conversion.
        let uncapped = "return min(Int(delay2 * pow(2.0, e)), backoffMax)\n"
        XCTAssertEqual(
            Self.findViolations(in: uncapped).count, 1,
            "capping after the conversion must be flagged")

        // The bug shape as it shipped in WebSocketManager (#2027).
        let uncappedDirect = "let seconds = Int(pow(2.0, Double(attempts)))\n"
        XCTAssertEqual(
            Self.findViolations(in: uncappedDirect).count, 1,
            "a bare Int(pow(...)) must be flagged")

        // The correct shape: cap in the Double domain, then convert.
        let capped = "let seconds = Int(min(pow(2.0, Double(attempts)), Double(maxSeconds)))\n"
        XCTAssertTrue(
            Self.findViolations(in: capped).isEmpty,
            "capping before the conversion must pass")

        // Multi-line correct shape (DocumentManager's spelling).
        let cappedMultiline = """
        var delayMs = Int(
            min(
                Double(backoff.maxMs),
                Double(backoff.baseMs) * pow(backoff.factor, Double(attempt))
            )
        )
        """
        XCTAssertTrue(
            Self.findViolations(in: cappedMultiline).isEmpty,
            "the multi-line capped spelling must pass")

        // `pow(` inside a comment or a string must not trip the check.
        let inProse = """
        // Never write Int(pow(2.0, x)) here.
        let message = "Int(pow(2.0, x))"
        """
        XCTAssertTrue(
            Self.findViolations(in: inProse).isEmpty,
            "pow( in comments or strings must be ignored")
    }

    /// The spelling #2056 actually shipped: the `pow()` result is bound to a
    /// local and the conversion takes the local, so the conversion's own
    /// argument text contains no `pow(` at all. A detector that reads only the
    /// argument passes this — which is why the guard was rewritten to track the
    /// binding. Verbatim from `BlobManager.computeBackoff` at `87297c7e0`.
    func testDetectorFlagsTheVariableHeldSpellingThatShipped() {
        let asShipped = """
        func computeBackoff(attempts: Int) -> Int {
            let exponent = Double(max(0, attempts - 1))
            let delay = Double(baseMs) * pow(2.0, exponent)
            return min(Int(delay), maxMs)
        }
        """
        let violations = Self.findViolations(in: asShipped, file: "BlobManager.swift")
        XCTAssertEqual(
            violations.count, 1,
            "the variable-held spelling that shipped as #2056 must be flagged: \(violations)")

        // The fix for that exact code: cap in the Double domain before
        // converting, with the pow result still held in a local.
        let asFixed = """
        static func uploadBackoffMs(attempts: Int, baseMs: Int, maxMs: Int) -> Int {
            let exponent = max(0.0, Double(attempts) - 1.0)
            let delay = Double(baseMs) * pow(2.0, exponent)
            guard delay.isFinite else { return maxMs }
            return Int(min(delay, Double(maxMs)))
        }
        """
        XCTAssertTrue(
            Self.findViolations(in: asFixed).isEmpty,
            "the shipped fix must pass: \(Self.findViolations(in: asFixed))")

        // Taint chains through derived locals.
        let derived = """
        func f() {
            let raw = pow(2.0, e)
            let scaled = raw * 1000.0
            return Int(scaled)
        }
        """
        XCTAssertEqual(
            Self.findViolations(in: derived).count, 1,
            "a local derived from an uncapped pow() local must be flagged")
    }

    /// The same pre-fix body wrapped at the column limit. `statementEnd` used
    /// to stop at the first newline, so the `* pow(2.0, exponent)` continuation
    /// was never part of the right-hand side and `delay` was never tainted —
    /// the guarded bug shape escaped the guard one line break away.
    func testDetectorFlagsTheLineWrappedPreFixSpelling() {
        // Wrap after the trailing `*` operator.
        let wrappedAfterOperator = """
        func computeBackoff(attempts: Int) -> Int {
            let exponent = Double(max(0, attempts - 1))
            let delay = Double(baseMs) *
                pow(2.0, exponent)
            return min(Int(delay), maxMs)
        }
        """
        XCTAssertEqual(
            Self.findViolations(in: wrappedAfterOperator, file: "BlobManager.swift").count, 1,
            "a wrap after the operator must still taint the local: "
                + "\(Self.findViolations(in: wrappedAfterOperator))")

        // Wrap before the leading `*` operator — the spelling the reviewer
        // pointed at, and the one this codebase's ~100-column style produces.
        let wrappedBeforeOperator = """
        func computeBackoff(attempts: Int) -> Int {
            let exponent = Double(max(0, attempts - 1))
            let delay = Double(baseMs)
                * pow(2.0, exponent)
            return min(Int(delay), maxMs)
        }
        """
        XCTAssertEqual(
            Self.findViolations(in: wrappedBeforeOperator, file: "BlobManager.swift").count, 1,
            "a wrap before the operator must still taint the local: "
                + "\(Self.findViolations(in: wrappedBeforeOperator))")

        // The value on its own line after `=`.
        let wrappedAfterEquals = """
        func computeBackoff(attempts: Int) -> Int {
            let delay =
                Double(baseMs) * pow(2.0, Double(attempts))
            return min(Int(delay), maxMs)
        }
        """
        XCTAssertEqual(
            Self.findViolations(in: wrappedAfterEquals).count, 1,
            "a value wrapped onto the line after `=` must still taint the local: "
                + "\(Self.findViolations(in: wrappedAfterEquals))")
    }

    /// The non-trapping labelled initializers are fixes for this bug class, not
    /// instances of it. Flagging them would break CI for a developer applying
    /// the client's own `Int(exactly:)` hardening idiom to a pow-derived value.
    func testDetectorSkipsNonTrappingLabelledConversions() {
        let clamping = "let seconds = Int(clamping: pow(2.0, Double(attempts)))\n"
        XCTAssertTrue(
            Self.findViolations(in: clamping).isEmpty,
            "Int(clamping:) saturates, it does not trap: \(Self.findViolations(in: clamping))")

        let exactly = """
        func f() {
            let delay = Double(baseMs) * pow(2.0, exponent)
            return Int(exactly: delay.rounded(.towardZero)) ?? maxMs
        }
        """
        XCTAssertTrue(
            Self.findViolations(in: exactly).isEmpty,
            "Int(exactly:) returns nil, it does not trap: \(Self.findViolations(in: exactly))")

        let truncating = "let wrapped = Int64(truncatingIfNeeded: raw)\n"
        XCTAssertTrue(
            Self.findViolations(in: truncating).isEmpty,
            "Int64(truncatingIfNeeded:) wraps, it does not trap")

        // A local bound from a non-trapping conversion holds an in-range
        // integer, so it must not carry the pow() hazard forward.
        let viaLocal = """
        func f() {
            let ms = Int(clamping: pow(2.0, e))
            return Int(ms)
        }
        """
        XCTAssertTrue(
            Self.findViolations(in: viaLocal).isEmpty,
            "a clamped local is no longer tainted: \(Self.findViolations(in: viaLocal))")

        // The unlabelled initializer is still the bug.
        let unlabelled = "let seconds = Int(pow(2.0, Double(attempts)))\n"
        XCTAssertEqual(
            Self.findViolations(in: unlabelled).count, 1,
            "the trapping unlabelled initializer must still be flagged")
    }

    /// `pow` is not the only spelling of exponential growth in C-family maths.
    func testDetectorFlagsOtherExponentialSpellings() {
        for call in ["powf(2.0, e)", "powl(2.0, e)", "exp2(e)", "pow (2.0, e)"] {
            let source = "let seconds = Int(\(call))\n"
            XCTAssertEqual(
                Self.findViolations(in: source).count, 1,
                "`\(call)` must be flagged: \(Self.findViolations(in: source))")
        }

        // A longer identifier that merely ends in one of the names is not a
        // match.
        let unrelated = "let seconds = Int(mypow(2.0, e))\n"
        XCTAssertTrue(
            Self.findViolations(in: unrelated).isEmpty,
            "`mypow(` is a different function: \(Self.findViolations(in: unrelated))")
    }

    /// Multiline string literals are blanked like any other literal: their
    /// prose can't trigger the check, and their brackets can't unbalance the
    /// block scan and mis-scope taint across the rest of the file.
    func testDetectorIgnoresMultilineStringLiterals() {
        let withMultilineLiteral = """
        func query() -> String {
            return \"\"\"
            SELECT { Int(pow(2.0, x)) } FROM t WHERE (a > b
            \"\"\"
        }

        func backoff(attempts: Int) -> Int {
            let delay = Double(baseMs) * pow(2.0, Double(attempts))
            return Int(min(delay, Double(maxMs)))
        }
        """
        XCTAssertTrue(
            Self.findViolations(in: withMultilineLiteral).isEmpty,
            "a multiline literal must neither trigger the check nor unbalance the scan: "
                + "\(Self.findViolations(in: withMultilineLiteral))")

        // And a real violation after an unbalanced literal is still found.
        let violationAfterLiteral = """
        func query() -> String {
            return \"\"\"
            SELECT { FROM t WHERE (a > b
            \"\"\"
        }

        func backoff(attempts: Int) -> Int {
            let delay = Double(baseMs) * pow(2.0, Double(attempts))
            return min(Int(delay), maxMs)
        }
        """
        XCTAssertEqual(
            Self.findViolations(in: violationAfterLiteral).count, 1,
            "the scan must resynchronise after a multiline literal: "
                + "\(Self.findViolations(in: violationAfterLiteral))")
    }

    /// Taint must not leak across scopes: an unrelated local that happens to
    /// share a name with a tainted one in another function is fine. This is a
    /// real case — `BlobManager` has a tainted `delay` in `uploadBackoffMs` and
    /// an ordinary `delay` in `scheduleQueueProcessing`.
    func testTaintIsScopedToItsOwnBlock() {
        let twoFunctions = """
        func backoff(attempts: Int) -> Int {
            let delay = Double(baseMs) * pow(2.0, Double(attempts))
            return Int(min(delay, Double(maxMs)))
        }

        func schedule(delayMs: Int) {
            let delay = max(0, delayMs)
            sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
        """
        XCTAssertTrue(
            Self.findViolations(in: twoFunctions).isEmpty,
            "a same-named local in another scope must not inherit taint: \(Self.findViolations(in: twoFunctions))")
    }

    /// The guard itself: no Swift source in the client may convert an uncapped
    /// `pow(` result to an integer.
    func testNoUncappedPowConversionsInSources() throws {
        let sources = try Self.swiftSourceFiles()
        // The client has ~100 source files; 50 is a deliberately loose floor
        // that only trips if `#filePath` resolution broke and the enumerator
        // walked the wrong directory. Without it, a broken path would scan zero
        // files and pass silently.
        XCTAssertGreaterThan(
            sources.count, 50,
            "the scan found suspiciously few sources — the path resolution is probably wrong")

        var violations: [Violation] = []
        for url in sources {
            let contents = try String(contentsOf: url, encoding: .utf8)
            guard Self.mayContainPowCall(contents) else { continue }
            violations += Self.findViolations(in: contents, file: url.lastPathComponent)
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Uncapped pow() → integer conversion(s) found. Cap in the Double \
            domain BEFORE converting — `Int(min(pow(...), Double(cap)))`, not \
            `min(Int(pow(...)), cap)` — or the conversion traps and aborts the \
            process (#2027, #2056):
            \(violations.map(\.description).joined(separator: "\n"))
            """
        )
    }

    /// `swift-client/Sources/**.swift`, resolved relative to this test file so
    /// the scan works from any working directory.
    private static func swiftSourceFiles() throws -> [URL] {
        // .../swift-client/Tests/JsBaoClientTests/<thisFile>.swift
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JsBaoClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift-client
        let sources = packageRoot.appendingPathComponent("Sources")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sources.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(domain: "UncappedPowConversionGuardTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Sources directory not found at \(sources.path)"
            ])
        }

        var files: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil) else {
            return files
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }
}
