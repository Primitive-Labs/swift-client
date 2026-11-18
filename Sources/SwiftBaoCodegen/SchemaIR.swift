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
    /// The basename of the input file that declared the model, which its
    /// generated file's header names. Empty for a schema parsed on its own.
    var sourceName: String = ""
    /// The db3 types (type files) that declare this model, sorted: what a
    /// renamed model's `primitiveSchema.fieldNameTypes` lists.
    var typeNames: [String] = []
}

struct ParsedField: Equatable {
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
    /// A string set field's `default` members (`default = ["a"]`), which a
    /// generated model reads where a db3 record does not hold the field, as
    /// js-bao's getter does; `nil` on any other field or a default that is
    /// not an array of strings. The field descriptor carries no default for
    /// it, so a create writes none.
    var stringSetDefault: [String]? = nil
    /// A vector field's number of numbers (#5225); `nil` on any other field.
    var dims: Int? = nil
    /// A vector field's element type, `f32`, `f16` or `i8` (#5225); `nil` on any other field.
    var element: String? = nil
    /// Declared `deprecated = true`: still read and written, and generated
    /// `@available(*, deprecated)`.
    var deprecated: Bool = false
    /// Declared `cleared = true` (beside `deprecated`): the field reads as
    /// unset everywhere, so the parser drops it from the model it returns.
    var cleared: Bool = false
    /// The field's stored name (`storedAs`) when it was renamed: records,
    /// the socket and the generated code's runtime keys use it; the Swift
    /// property keeps the field's key. `nil` when never renamed.
    var storedAs: String? = nil
    /// The shared enum the field's `ref` named (#5896), beside the
    /// expansion that filled `type` and `enumValues`; `nil` for a field
    /// without `ref`, a hand-written `enum = [...]` included.
    var sharedEnum: SharedEnumRef? = nil
    /// The object def a JSON field's `ref` named (#5899), beside the
    /// expansion to a plain `string` field; `nil` for any other field.
    var json: Db3JSONRef? = nil

    /// The field as its expanded declaration reads, without the shared enum
    /// a `ref` named: two declarations of one model compare by this, as
    /// js-bao compares the expanded tables. A JSON field's def is kept: two
    /// declarations binding a field to different defs differ (#5899).
    var declared: ParsedField {
        var copy = self
        copy.sharedEnum = nil
        return copy
    }
}

/// A `schemas/` def a db3 field's `ref` named (#5896): the file's stem
/// and the def's name, as js-bao's `SharedEnumRef` has them.
struct SharedEnumRef: Equatable {
    let file: String
    let name: String
}

/// The `schemas/` object def a db3 JSON field's `ref` named (#5899): the
/// file's stem and the def's name, as js-bao's `SharedObjectRef` has them.
struct Db3JSONRef: Equatable {
    let file: String
    let name: String

    /// `schemas.<file>.<Name>`.
    var id: String { "schemas.\(file).\(name)" }

    /// The file stem as a Swift identifier's part: every character that is
    /// not a letter, digit or `_` written `_`.
    var stemPart: String {
        String(file.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "_" })
    }

    /// `Db3JSON_<file>_<Name>`: the alias `Primitive.generated.swift` declares for the def's type.
    var aliasName: String { "Db3JSON_\(stemPart)_\(name)" }

    /// `Db3JSONDef_<file>_<Name>`: the binding enum that carries the def's id and schema.
    var bindingName: String { "Db3JSONDef_\(stemPart)_\(name)" }
}

enum ParsedFieldType: String {
    case string
    case number
    case boolean
    case date
    case id
    case stringset
    /// A db3 vector field (#5225), in a type file only: `[Float]` in Swift.
    case vector
}

/// When an `auto_stamp` field is auto-populated with a timestamp. Raw
/// values match the TOML literals js-bao accepts (`create`/`update`/`both`).
enum ParsedAutoStamp: String {
    case create
    case update
    case both
}

enum ParsedDefault: Equatable {
    case string(String)
    case number(Double)
    case integer(Int64)
    case boolean(Bool)
}

struct ParsedUniqueConstraint: Equatable {
    var name: String
    var fields: [String]
}

struct ParsedRelationship {
    var rawType: String                 // refersTo | hasMany | hasManyThrough
    var properties: [(String, String)]  // ordered (key, value) pairs
}
