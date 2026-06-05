import Foundation

/// Parsed-TOML intermediate representation. The codegen tool keeps its
/// own copy (rather than depending on `JsBaoClient.PrimitiveSchema`) so
/// the build-time tool doesn't pull in YSwift / sqlite at link time —
/// `swift-bao-codegen` is a pure TOML→Swift text transform.
///
/// Field/relationship semantics mirror `JsBaoClient.TomlSchemaLoader`
/// 1:1; if you change validation rules in one place, change them here.
struct ParsedSchema {
    var name: String
    var swiftName: String
    var fieldOrder: [String]
    var fields: [String: ParsedField]
    var uniqueConstraints: [ParsedUniqueConstraint]
    var relationships: [(name: String, descriptor: ParsedRelationship)]
}

struct ParsedField {
    var type: ParsedFieldType
    var indexed: Bool
    var unique: Bool
    var required: Bool
    var autoAssign: Bool
    var maxLength: Int?
    var maxCount: Int?
    var defaultLiteral: ParsedDefault?
    /// Allowed-value set for a `string` field (`enum = ["a","b","c"]`).
    /// Mirrors js-bao's `FieldOptions.enum` (#843): advisory / codegen-only,
    /// only valid on a `string` field, non-empty, all strings. `nil` when
    /// the TOML omits `enum`. Preserves source order.
    var enumValues: [String]?
    /// Auto-timestamp policy (`auto_stamp = "create" | "update" | "both"`).
    /// Mirrors js-bao's `FieldOptions.autoStamp`. `nil` when omitted.
    var autoStamp: ParsedAutoStamp?
}

enum ParsedFieldType: String {
    case string
    case number
    case boolean
    case date
    case id
    case stringset
}

/// When an `auto_stamp` field is auto-populated with a timestamp. Raw
/// values match the TOML literals js-bao accepts (`create`/`update`/`both`).
enum ParsedAutoStamp: String {
    case create
    case update
    case both
}

enum ParsedDefault {
    case string(String)
    case number(Double)
    case integer(Int64)
    case boolean(Bool)
}

struct ParsedUniqueConstraint {
    var name: String
    var fields: [String]
}

struct ParsedRelationship {
    var rawType: String                 // refersTo | hasMany | hasManyThrough
    var properties: [(String, String)]  // ordered (key, value) pairs
}
