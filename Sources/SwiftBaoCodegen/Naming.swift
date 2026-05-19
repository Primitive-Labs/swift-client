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
}
