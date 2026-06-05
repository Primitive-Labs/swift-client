import Foundation

enum Naming {

    /// Convert a TOML model name to a Swift type prefix using PascalCase.
    /// `tasks` → `Tasks`, `user_profile` → `UserProfile`, `liveUpdatesState` →
    /// `LiveUpdatesState`. No singularization — predictable, no English rules.
    /// Per-model `[models.X] class_name = "..."` overrides this.
    static func pascalCase(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        var capitalizeNext = true
        for ch in s {
            if ch == "_" || ch == "-" || ch == " " {
                capitalizeNext = true
                continue
            }
            if capitalizeNext {
                out.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Reserved Swift keywords we need to escape with backticks if they
    /// appear as field names. Codegen quotes the property name literally
    /// — `.default` is the most common collision (TOML field named
    /// `default`).
    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension",
        "fileprivate", "func", "import", "init", "inout", "internal",
        "let", "open", "operator", "private", "precedencegroup", "protocol",
        "public", "rethrows", "static", "struct", "subscript", "typealias",
        "var", "break", "case", "catch", "continue", "default", "defer",
        "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
        "return", "throw", "switch", "where", "while", "as", "Any", "false",
        "is", "nil", "self", "Self", "super", "throws", "true", "try",
    ]

    static func escapeIfReserved(_ s: String) -> String {
        if swiftKeywords.contains(s) { return "`\(s)`" }
        return s
    }

    /// Derive a Swift `enum` case identifier from an arbitrary `enum`
    /// value string. The value itself is always preserved verbatim as the
    /// case's explicit raw value (`case active = "Active"`), so only the
    /// *case name* needs to be a legal identifier:
    ///   - non-`[A-Za-z0-9_]` runs collapse to a single `_`
    ///     (`"In Progress"` → `in_Progress`, `"on-hold"` → `on_hold`)
    ///   - a leading digit is prefixed with `_` (`"2xl"` → `_2xl`)
    ///   - an empty/all-separator value becomes `_`
    ///   - reserved keywords are backtick-escaped
    /// Only ASCII digits (`0`–`9`) are treated as identifier digits.
    /// `Character.isNumber` also matches Unicode digits like Arabic-Indic
    /// `٠`–`٩`, superscripts, and Roman numerals that are *not* legal in a
    /// Swift identifier — emitting them would produce code that doesn't
    /// compile, so they're collapsed to a `_` separator instead.
    /// (`Character.isLetter` is fine: Swift identifiers permit Unicode
    /// letters.)
    /// Collision handling (two values mapping to the same case name) is the
    /// caller's job — `enumCaseNames(for:)` disambiguates.
    static func enumCaseIdentifier(_ value: String) -> String {
        var out = ""
        for ch in value {
            if ch.isLetter || ch.isASCIIDigit || ch == "_" {
                out.append(ch)
            } else if !out.hasSuffix("_") {
                out.append("_")
            }
        }
        // Trim a trailing separator artifact but keep a lone "_".
        if out.count > 1, out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty { out = "_" }
        if let first = out.first, first.isASCIIDigit { out = "_" + out }
        return escapeIfReserved(out)
    }

    /// Derive the nested-`enum` *type* name for a field that declares
    /// `enum = [...]`. A type name can't be backtick-escaped the way a
    /// property name can — `` `default` `` is fine as a property spelling
    /// but a nested type's name has to be a bare identifier — and
    /// `pascalCase` alone can still produce something illegal: a field name
    /// starting with a digit (`"2fa"` → `"2fa"` → leading-digit type name)
    /// or a Unicode-digit / punctuation character that isn't valid in a
    /// Swift identifier. So sanitize rather than escape:
    ///   - PascalCase the field name (`user_status` → `UserStatus`).
    ///   - Drop any character that isn't an ASCII letter/digit or `_`.
    ///   - Prefix `_` if the result is empty or starts with a digit.
    ///   - Append the `Value` suffix (`UserStatusValue`). The suffix alone
    ///     also lifts a bare keyword out of keyword-space (`Self` →
    ///     `SelfValue`, `default` → `DefaultValue`), so the result is
    ///     always a legal, non-keyword type identifier — no backticks.
    static func enumTypeName(forField field: String) -> String {
        var base = ""
        for ch in pascalCase(field) where ch.isLetter || ch.isASCIIDigit || ch == "_" {
            base.append(ch)
        }
        if base.isEmpty { base = "_" }
        if let first = base.first, first.isASCIIDigit { base = "_" + base }
        return base + "Value"
    }

    /// Map an ordered list of `enum` value strings to unique Swift case
    /// names, appending `_2`, `_3`, … to any name that would otherwise
    /// collide (e.g. `"on hold"` and `"on-hold"` both sanitize to
    /// `on_hold`). Returns `(caseName, rawValue)` pairs in input order.
    static func enumCaseNames(for values: [String]) -> [(name: String, raw: String)] {
        var used: [String: Int] = [:]
        var out: [(String, String)] = []
        for v in values {
            let base = enumCaseIdentifier(v)
            let count = used[base, default: 0]
            used[base] = count + 1
            let name = count == 0 ? base : "\(base)_\(count + 1)"
            out.append((name, v))
        }
        return out
    }
}

private extension Character {
    /// True only for the ASCII digits `0`–`9`. Unlike `isNumber` /
    /// `isWholeNumber`, this excludes Unicode digits (Arabic-Indic,
    /// superscripts, Roman numerals, …) that are not valid in a Swift
    /// identifier.
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
