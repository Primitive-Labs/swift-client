import Foundation

/// A field's default value. Either a literal scalar or a named function
/// that js-bao encodes on the wire as `"$<name>"`.
public enum DefaultValue: Equatable, Hashable, Sendable {
    case scalar(PrimitiveValue)
    case function(name: String)

    /// Encode for a `_meta_*` YMap write. Returns the primitive the Rust
    /// side will parse as JSON — a `String`, `Double`, or `Bool`.
    public func encodedForMeta() -> Any {
        switch self {
        case let .function(name):
            return "$\(name)"
        case let .scalar(.string(s)):
            return s
        case let .scalar(.number(n)):
            return n
        case let .scalar(.boolean(b)):
            return b
        case let .scalar(.id(s)):
            return s
        case let .scalar(.date(s)):
            return s
        case .scalar(.stringset), .scalar(.json):
            // These field types don't serialize as primitive scalars on the
            // meta layer; js-bao has no precedent for them as defaults.
            return NSNull()
        }
    }

    /// Decode a value read back from a `_meta_*` YMap into a DefaultValue.
    /// `"$name"` → function; everything else → scalar. Mirrors js-bao's
    /// read semantics — see `yDocSchema.ts readFieldMeta`.
    public static func decode(fromMeta value: Any) -> DefaultValue? {
        if let s = value as? String {
            if s.hasPrefix("$") {
                return .function(name: String(s.dropFirst()))
            }
            return .scalar(.string(s))
        }
        if let b = value as? Bool {
            return .scalar(.boolean(b))
        }
        if let n = value as? Double {
            return .scalar(.number(n))
        }
        if let n = value as? Int {
            return .scalar(.number(Double(n)))
        }
        return nil
    }
}

/// When an `auto_stamp` field is auto-populated with a timestamp on write.
/// Mirrors js-bao's `FieldOptions.autoStamp` (`"create" | "update" | "both"`).
///
///   - `.create`: stamped only on insert, and only when the field has no
///     caller-supplied value (matches js-bao's `applyAutoStamps` create
///     branch + `BaseModel.save`'s explicit-wins rule).
///   - `.update`: stamped on every write (insert and update) unless the
///     caller supplied an explicit non-nil value on this save.
///   - `.both`: same firing as `.update` — stamps on every write. (js-bao
///     treats `both` like `update` for firing; the distinction is only
///     advisory metadata.)
public enum AutoStamp: String, Equatable, Hashable, Sendable {
    case create
    case update
    case both
}

/// Field metadata — one per field in a `_meta_{modelName}` YMap.
///
/// Mirrors js-bao's `DiscoveredField` / `FieldOptions` shape. Bool flags
/// default to `false`; nil optionals are omitted from the wire.
public struct FieldDescriptor: Equatable, Hashable, Sendable {
    public var type: PrimitiveFieldType
    public var indexed: Bool
    public var unique: Bool
    public var required: Bool
    public var autoAssign: Bool
    public var maxLength: Int?
    public var maxCount: Int?
    public var `default`: DefaultValue?
    /// Auto-timestamp policy (`auto_stamp = "create" | "update" | "both"`).
    /// `nil` when the field declares no `auto_stamp`. Read by the shared
    /// write path (`DynamicModel.save`) to stamp `Date.now()`-style epoch
    /// milliseconds on insert / update, mirroring js-bao's `BaseModel.save`.
    public var autoStamp: AutoStamp?

    public init(
        type: PrimitiveFieldType,
        indexed: Bool = false,
        unique: Bool = false,
        required: Bool = false,
        autoAssign: Bool = false,
        maxLength: Int? = nil,
        maxCount: Int? = nil,
        default: DefaultValue? = nil,
        autoStamp: AutoStamp? = nil
    ) {
        self.type = type
        self.indexed = indexed
        self.unique = unique
        self.required = required
        self.autoAssign = autoAssign
        self.maxLength = maxLength
        self.maxCount = maxCount
        self.default = `default`
        self.autoStamp = autoStamp
    }
}

/// Compound unique constraint (two or more fields). Single-field uniques
/// live on the field, not here — matches js-bao's `metaSync.ts` behavior.
public struct ConstraintDescriptor: Equatable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var fields: [String]

    public init(name: String, type: String = "unique", fields: [String]) {
        self.name = name
        self.type = type
        self.fields = fields
    }

    /// JSON-encoded field list, matching js-bao's wire format — the
    /// `fields` value in a `_constraints.<name>` map is a JSON STRING, not
    /// a Y.Array.
    public var fieldsJson: String {
        let items = fields.map { PrimitiveValue.jsonEncodeString($0) }.joined(separator: ",")
        return "[\(items)]"
    }

    /// Parse the JSON-encoded fields string. Malformed input yields an
    /// empty list — matches js-bao's `yDocSchema.ts readConstraints`
    /// fallback.
    public static func decodeFields(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }
}

/// Relationship metadata. Stored as a plain `[String: String]` so unknown
/// keys survive a round-trip — mirrors js-bao's read path, which does a
/// generic `for … of relMeta.entries()` and preserves every key.
public struct RelationshipDescriptor: Equatable, Hashable, Sendable {
    public var properties: [String: String]

    public init(properties: [String: String]) {
        self.properties = properties
    }

    public var type: String { properties["type"] ?? "" }
    public var model: String { properties["model"] ?? "" }

    public static func refersTo(
        model: String,
        relatedIdField: String
    ) -> RelationshipDescriptor {
        RelationshipDescriptor(properties: [
            "type": "refersTo",
            "model": model,
            "relatedIdField": relatedIdField,
        ])
    }

    public static func hasMany(
        model: String,
        relatedIdField: String,
        orderByField: String? = nil,
        orderDirection: String? = nil
    ) -> RelationshipDescriptor {
        var props: [String: String] = [
            "type": "hasMany",
            "model": model,
            "relatedIdField": relatedIdField,
        ]
        if let orderByField { props["orderByField"] = orderByField }
        if let orderDirection { props["orderDirection"] = orderDirection }
        return RelationshipDescriptor(properties: props)
    }

    public static func hasManyThrough(
        model: String,
        joinModel: String,
        joinModelLocalField: String,
        joinModelRelatedField: String,
        joinModelOrderByField: String? = nil,
        joinModelOrderDirection: String? = nil
    ) -> RelationshipDescriptor {
        var props: [String: String] = [
            "type": "hasManyThrough",
            "model": model,
            "joinModel": joinModel,
            "joinModelLocalField": joinModelLocalField,
            "joinModelRelatedField": joinModelRelatedField,
        ]
        if let joinModelOrderByField {
            props["joinModelOrderByField"] = joinModelOrderByField
        }
        if let joinModelOrderDirection {
            props["joinModelOrderDirection"] = joinModelOrderDirection
        }
        return RelationshipDescriptor(properties: props)
    }
}

/// Runtime schema for one model. Constructable programmatically (write
/// path) and loadable from a YDoc's `_meta_*` (read path, via
/// `SchemaDiscovery`).
public struct PrimitiveSchema: Equatable, Sendable {
    public var name: String
    public var fields: [String: FieldDescriptor]
    public var constraints: [String: ConstraintDescriptor]
    public var relationships: [String: RelationshipDescriptor]

    public init(
        name: String,
        fields: [String: FieldDescriptor],
        constraints: [String: ConstraintDescriptor] = [:],
        relationships: [String: RelationshipDescriptor] = [:]
    ) {
        self.name = name
        self.fields = fields
        self.constraints = constraints
        self.relationships = relationships
    }

    /// The constraint list that actually gets ENFORCED at runtime —
    /// includes both synthetic single-field constraints (one per
    /// `unique: true` field) and the explicit compound constraints.
    /// Mirrors js-bao's `resolveUniqueConstraints` in `schema.ts`.
    ///
    /// Note: only the compound constraints are written into
    /// `_meta_*._constraints` (single-field uniques live on the field
    /// itself as `unique = true`). But both are enforced at write time
    /// via `_uniqueIdx_{modelName}_{constraintName}` indexes.
    public var resolvedUniqueConstraints: [ConstraintDescriptor] {
        var out: [ConstraintDescriptor] = []
        // Synthetic single-field constraints for each `unique: true` field.
        // Sorted to keep constraint-name generation deterministic.
        for (fieldName, desc) in fields.sorted(by: { $0.key < $1.key }) where desc.unique {
            out.append(ConstraintDescriptor(
                name: "\(name)_\(fieldName)_unique",
                fields: [fieldName]
            ))
        }
        // Explicit compound constraints.
        for c in constraints.values.sorted(by: { $0.name < $1.name }) {
            out.append(c)
        }
        return out
    }
}
