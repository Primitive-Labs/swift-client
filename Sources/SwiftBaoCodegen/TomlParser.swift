import Foundation
import TOMLKit

enum CodegenError: Error, CustomStringConvertible {
    case parse(String)
    case missingFieldType(model: String, field: String)
    case unknownFieldType(model: String, field: String, typeName: String)
    case malformedUniqueConstraint(model: String, index: Int, reason: String)
    case uniqueConstraintUnknownField(model: String, constraint: String, field: String)
    case missingRelationshipType(model: String, relationship: String)
    case unknownRelationshipType(model: String, relationship: String, typeName: String)
    case missingRelationshipModel(model: String, relationship: String)
    case unknownRelatedModel(model: String, relationship: String, target: String)
    case missingJoinModel(model: String, relationship: String)
    case unknownJoinModel(model: String, relationship: String, joinModel: String)
    case invalidClassName(model: String, reason: String)
    case invalidAutoStamp(model: String, field: String, value: String)
    case enumOnNonStringField(model: String, field: String, typeName: String)
    case malformedEnum(model: String, field: String, reason: String)
    case unknownKey(context: String, key: String, allowed: [String])

    var description: String {
        switch self {
        case let .parse(m):
            return "TOML parse error: \(m)"
        case let .missingFieldType(model, field):
            return "Model `\(model)` field `\(field)` is missing required `type`"
        case let .unknownFieldType(model, field, typeName):
            return "Model `\(model)` field `\(field)` has unknown type `\(typeName)` — allowed: string, number, boolean, date, id, stringset"
        case let .malformedUniqueConstraint(model, index, reason):
            return "Model `\(model)` unique_constraints[\(index)]: \(reason)"
        case let .uniqueConstraintUnknownField(model, constraint, field):
            return "Model `\(model)` unique constraint `\(constraint)` references unknown field `\(field)`"
        case let .missingRelationshipType(model, relationship):
            return "Model `\(model)` relationship `\(relationship)` is missing required `type`"
        case let .unknownRelationshipType(model, relationship, typeName):
            return "Model `\(model)` relationship `\(relationship)` has unknown type `\(typeName)` — allowed: refersTo, hasMany, hasManyThrough"
        case let .missingRelationshipModel(model, relationship):
            return "Model `\(model)` relationship `\(relationship)` is missing required `model`"
        case let .unknownRelatedModel(model, relationship, target):
            return "Model `\(model)` relationship `\(relationship)` targets undefined model `\(target)`"
        case let .missingJoinModel(model, relationship):
            return "Model `\(model)` hasManyThrough relationship `\(relationship)` is missing required `join_model`"
        case let .unknownJoinModel(model, relationship, joinModel):
            return "Model `\(model)` hasManyThrough relationship `\(relationship)` references undefined join_model `\(joinModel)`"
        case let .invalidClassName(model, reason):
            return "Model `\(model)` class_name: \(reason)"
        case let .invalidAutoStamp(model, field, value):
            return "Model `\(model)` field `\(field)` has invalid auto_stamp value `\(value)` — must be one of: create, update, both"
        case let .enumOnNonStringField(model, field, typeName):
            return "Model `\(model)` field `\(field)`: `enum` is only valid on a \"string\" field, not \"\(typeName)\""
        case let .malformedEnum(model, field, reason):
            return "Model `\(model)` field `\(field)`: `enum` \(reason)"
        case let .unknownKey(context, key, allowed):
            return "\(context): unknown key `\(key)`. Allowed: \(allowed.joined(separator: ", "))"
        }
    }
}

/// Allowed-key sets for strict validation. Mirror js-bao's
/// `tomlLoader.ts` (`KNOWN_*` sets) verbatim so a TOML the JS loader
/// rejects in strict mode is rejected here too, and vice versa.
private enum KnownKeys {
    static let model: Set<String> = [
        "fields", "relationships", "unique_constraints", "class_name",
    ]
    static let field: Set<String> = [
        "type", "indexed", "unique", "required", "auto_assign",
        "auto_stamp", "max_length", "max_count", "default", "enum",
    ]
    static let relationship: Set<String> = [
        "type", "model", "related_id_field", "join_model",
        "join_model_local_field", "join_model_related_field",
        "order_by_field", "order_direction",
        "join_model_order_by_field", "join_model_order_direction",
    ]
    static let uniqueConstraint: Set<String> = ["name", "fields"]
}

/// Parse a TOML schema into the codegen IR. Validation rules mirror
/// `JsBaoClient.TomlSchemaLoader` exactly — same input is accepted, same
/// errors are raised, so the build-time tool can't drift from runtime
/// semantics (a schema that codegens cleanly will also load cleanly at
/// runtime, and vice versa).
enum TomlParser {

    /// When `strict` is true (the default, mirroring js-bao's
    /// `loadSchemaFromTomlString` strict mode), unknown keys at the
    /// model / field / relationship / unique-constraint level raise a
    /// `CodegenError.unknownKey` instead of being silently dropped — so
    /// a typo'd key (`requierd = true`) fails loud at codegen time
    /// rather than producing a subtly-wrong model. Pass `strict: false`
    /// (the `--no-strict` CLI flag) for the legacy lenient behavior.
    static func parse(
        tomlString: String,
        swiftNameSuffix: String,
        strict: Bool = true
    ) throws -> [ParsedSchema] {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: tomlString)
        } catch {
            throw CodegenError.parse(String(describing: error))
        }

        // A fresh-template schema.toml ships with no models yet (the
        // user adds the first `[models.<name>]` block as their next
        // step). The SPM build plugin already tolerates this — it
        // scans for `[models.X]` headers and emits zero commands if
        // none exist. The standalone tool needs to match: returning
        // an empty schema list lets a wrapper script (run.sh,
        // run-ios.sh) call codegen unconditionally without failing
        // before the schema has any models.
        guard let modelsTable = table["models"]?.table else {
            return []
        }

        // First pass: collect field/constraint/codegen info per model.
        var schemasByName: [String: ParsedSchema] = [:]
        var modelOrder: [String] = []
        for key in modelsTable.keys {
            guard let model = modelsTable[key]?.table else { continue }
            // Reject unknown top-level model keys before building (so a
            // misspelled `feilds`/`relationship` surfaces with the model
            // named, not as a silently-missing section).
            try checkUnknownKeys(
                model, allowed: KnownKeys.model,
                context: "Model `\(key)`", strict: strict
            )
            var schema = try buildSchema(
                name: key, table: model,
                swiftNameSuffix: swiftNameSuffix, strict: strict
            )
            // TOMLKit hands keys back alphabetically, which is fine for
            // every internal use (lookups go through a dictionary) but
            // misleading for the emitted Swift init — a user-declared
            // schema order of `id, text, completed, createdAt` should
            // map to that *same* init parameter order, not the alphabetical
            // `id, completed, createdAt, text`. A positional init written
            // against the declared order would otherwise silently swap
            // arguments of compatible types. Recover declaration order by
            // scanning the raw TOML source for the field-table headers.
            schema.fieldOrder = reorderBySource(
                fields: schema.fieldOrder,
                model: key,
                source: tomlString
            )
            schemasByName[key] = schema
            modelOrder.append(key)
        }

        // Second pass: relationships (need full known-model set).
        for key in modelOrder {
            guard let model = modelsTable[key]?.table,
                  var schema = schemasByName[key] else { continue }
            if let relsTable = model["relationships"]?.table {
                schema.relationships = try buildRelationships(
                    modelName: key,
                    relsTable: relsTable,
                    knownModels: Set(schemasByName.keys),
                    strict: strict
                )
                schemasByName[key] = schema
            }
        }

        return modelOrder.compactMap { schemasByName[$0] }
    }

    // MARK: - Strict unknown-key validation

    /// Raise `CodegenError.unknownKey` for any key in `table` that isn't
    /// in `allowed`, when `strict`. No-op when `strict` is false. Mirrors
    /// js-bao `tomlLoader.checkUnknownKeys`. The `allowed` list is sorted
    /// in the error message for a deterministic, scan-friendly hint.
    private static func checkUnknownKeys(
        _ table: TOMLTable,
        allowed: Set<String>,
        context: String,
        strict: Bool
    ) throws {
        guard strict else { return }
        for key in table.keys where !allowed.contains(key) {
            throw CodegenError.unknownKey(
                context: context, key: key, allowed: allowed.sorted()
            )
        }
    }

    // MARK: - Per-model

    private static func buildSchema(
        name: String,
        table: TOMLTable,
        swiftNameSuffix: String,
        strict: Bool
    ) throws -> ParsedSchema {
        let (fieldOrder, fields) = try buildFields(
            modelName: name, table: table, strict: strict
        )
        let constraints = try buildUniqueConstraints(
            modelName: name, table: table, fieldNames: Set(fields.keys),
            strict: strict
        )
        let swiftName = try resolveSwiftName(
            modelName: name, table: table, suffix: swiftNameSuffix
        )
        return ParsedSchema(
            name: name,
            swiftName: swiftName,
            fieldOrder: fieldOrder,
            fields: fields,
            uniqueConstraints: constraints,
            relationships: []
        )
    }

    private static func resolveSwiftName(
        modelName: String,
        table: TOMLTable,
        suffix: String
    ) throws -> String {
        // Language-agnostic per-model override:
        //   [models.<name>]
        //   class_name = "TaskRecord"
        // Mirrors js-bao's `class_name` (parsed by tomlLoader.ts), so
        // the same TOML serves both runtimes — no swift-specific keys.
        if let value = table["class_name"] {
            guard let s = value.string, !s.isEmpty else {
                throw CodegenError.invalidClassName(
                    model: modelName,
                    reason: "must be a non-empty string"
                )
            }
            // Reject anything that isn't a valid Swift identifier
            // up front — otherwise a value like "My Record" would
            // emit `struct My Record: PrimitiveModel`, and the
            // Swift compile error would point at the generated
            // file rather than the TOML.
            let validIdentifier = s.range(
                of: "^[A-Za-z_][A-Za-z0-9_]*$",
                options: .regularExpression
            ) != nil
            guard validIdentifier else {
                throw CodegenError.invalidClassName(
                    model: modelName,
                    reason: "'\(s)' is not a valid Swift identifier (must match [A-Za-z_][A-Za-z0-9_]*)"
                )
            }
            // Reserved Swift keywords would parse correctly as a
            // type name only if backtick-escaped, but the emitter
            // doesn't escape struct names — so `class_name = "let"`
            // would emit `struct let: PrimitiveModel { ... }` and
            // Swift would reject it at compile time, pointing at
            // the generated file. Catch it here so the error
            // surfaces from the codegen tool naming the offending
            // TOML model instead.
            guard !Naming.swiftKeywords.contains(s) else {
                throw CodegenError.invalidClassName(
                    model: modelName,
                    reason: "'\(s)' is a reserved Swift keyword and cannot be used as a type name"
                )
            }
            return s
        }
        return Naming.pascalCase(modelName) + suffix
    }

    // MARK: - Source-order recovery

    /// Reorder `fields` to match the order they appear in `source` for
    /// the given `model`. Field names not found in the source scan
    /// (inline-table form, dotted-key form, anything the regex misses)
    /// keep the parser's original ordering and are appended at the
    /// end — so the worst case degrades to today's alphabetical
    /// behavior, never to a missing field.
    private static func reorderBySource(
        fields: [String],
        model: String,
        source: String
    ) -> [String] {
        let known = Set(fields)
        let sourceOrder = scanFieldHeaders(model: model, source: source)
            .filter { known.contains($0) }
        if sourceOrder.isEmpty { return fields }
        var seen = Set(sourceOrder)
        var out = sourceOrder
        for f in fields where !seen.contains(f) {
            out.append(f)
            seen.insert(f)
        }
        return out
    }

    /// Match `[models.<model>.fields.<field>]` headers in the raw TOML
    /// in source order. Accepts bare or quoted keys for both segments
    /// (TOML requires quoting non-ASCII keys; bare keys are
    /// `[A-Za-z0-9_-]+`).
    private static func scanFieldHeaders(model: String, source: String) -> [String] {
        let bareModel = NSRegularExpression.escapedPattern(for: model)
        let modelAlt = "(?:\(bareModel)|\"\(bareModel)\")"
        // Field name in the captured group: bare token OR quoted (any
        // chars except `"`). Strip the quotes after the match.
        let pattern =
            #"\[\s*models\s*\.\s*"# + modelAlt +
            #"\s*\.\s*fields\s*\.\s*([A-Za-z0-9_\-]+|"[^"]*")\s*\]"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = source as NSString
        let matches = re.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var out: [String] = []
        for m in matches where m.numberOfRanges > 1 {
            let r = m.range(at: 1)
            if r.location == NSNotFound { continue }
            var name = ns.substring(with: r)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            if !seen.contains(name) {
                seen.insert(name)
                out.append(name)
            }
        }
        return out
    }

    // MARK: - Fields

    private static func buildFields(
        modelName: String,
        table: TOMLTable,
        strict: Bool
    ) throws -> ([String], [String: ParsedField]) {
        guard let fieldsTable = table["fields"]?.table else { return ([], [:]) }
        var order: [String] = []
        var out: [String: ParsedField] = [:]
        for fieldName in fieldsTable.keys {
            guard let field = fieldsTable[fieldName]?.table else { continue }
            out[fieldName] = try buildField(
                modelName: modelName, fieldName: fieldName,
                table: field, strict: strict
            )
            order.append(fieldName)
        }
        return (order, out)
    }

    private static func buildField(
        modelName: String,
        fieldName: String,
        table: TOMLTable,
        strict: Bool
    ) throws -> ParsedField {
        // js-bao validates the field type FIRST (before the unknown-key
        // sweep) — match that order so the error a malformed field
        // surfaces is identical across runtimes.
        guard let typeLiteral = table["type"]?.string else {
            throw CodegenError.missingFieldType(model: modelName, field: fieldName)
        }
        guard let type = ParsedFieldType(rawValue: typeLiteral) else {
            throw CodegenError.unknownFieldType(
                model: modelName, field: fieldName, typeName: typeLiteral
            )
        }
        try checkUnknownKeys(
            table, allowed: KnownKeys.field,
            context: "Model `\(modelName)` field `\(fieldName)`",
            strict: strict
        )
        let autoStamp = try decodeAutoStamp(
            table["auto_stamp"], modelName: modelName, fieldName: fieldName
        )
        let enumValues = try decodeEnum(
            table["enum"], fieldType: type,
            modelName: modelName, fieldName: fieldName
        )
        return ParsedField(
            type: type,
            indexed: table["indexed"]?.bool ?? false,
            unique: table["unique"]?.bool ?? false,
            required: table["required"]?.bool ?? false,
            autoAssign: table["auto_assign"]?.bool ?? false,
            maxLength: table["max_length"]?.int,
            maxCount: table["max_count"]?.int,
            defaultLiteral: decodeDefault(table["default"]),
            enumValues: enumValues,
            autoStamp: autoStamp
        )
    }

    /// Parse `auto_stamp = "create" | "update" | "both"`. Fail-fast on any
    /// other value — mirrors js-bao `tomlLoader.ts` (`VALID_AUTO_STAMP_VALUES`),
    /// so a value the JS codegen rejects is rejected here too rather than
    /// silently dropped.
    private static func decodeAutoStamp(
        _ value: TOMLValue?,
        modelName: String,
        fieldName: String
    ) throws -> ParsedAutoStamp? {
        guard let value else { return nil }
        guard let s = value.string, let stamp = ParsedAutoStamp(rawValue: s) else {
            throw CodegenError.invalidAutoStamp(
                model: modelName,
                field: fieldName,
                value: value.string ?? String(describing: value)
            )
        }
        return stamp
    }

    /// Parse `enum = ["a","b","c"]`. Validated unconditionally and
    /// fail-fast — a malformed `enum` must NOT silently fall back to a bare
    /// `String`, because the author's intent was an exhaustive value set.
    /// Mirrors js-bao `tomlLoader.ts` `parseFieldOptions` (#843): only valid
    /// on a `string` field, non-empty, all values strings. Source order is
    /// preserved.
    private static func decodeEnum(
        _ value: TOMLValue?,
        fieldType: ParsedFieldType,
        modelName: String,
        fieldName: String
    ) throws -> [String]? {
        guard let value else { return nil }
        guard fieldType == .string else {
            throw CodegenError.enumOnNonStringField(
                model: modelName, field: fieldName, typeName: fieldType.rawValue
            )
        }
        guard let arr = value.array else {
            throw CodegenError.malformedEnum(
                model: modelName, field: fieldName,
                reason: "must be a non-empty array of strings"
            )
        }
        guard arr.count > 0 else {
            throw CodegenError.malformedEnum(
                model: modelName, field: fieldName,
                reason: "must be a non-empty array of strings"
            )
        }
        var out: [String] = []
        for i in 0..<arr.count {
            guard let s = arr[i].string else {
                throw CodegenError.malformedEnum(
                    model: modelName, field: fieldName,
                    reason: "values must all be strings"
                )
            }
            out.append(s)
        }
        return out
    }

    private static func decodeDefault(_ value: TOMLValue?) -> ParsedDefault? {
        guard let value else { return nil }
        if let s = value.string { return .string(s) }
        if let b = value.bool   { return .boolean(b) }
        if let i = value.int    { return .integer(Int64(i)) }
        if let d = value.double { return .number(d) }
        return nil
    }

    // MARK: - Compound unique constraints

    private static func buildUniqueConstraints(
        modelName: String,
        table: TOMLTable,
        fieldNames: Set<String>,
        strict: Bool
    ) throws -> [ParsedUniqueConstraint] {
        guard let arr = table["unique_constraints"]?.array else { return [] }
        var out: [ParsedUniqueConstraint] = []
        for idx in 0..<arr.count {
            guard let entry = arr[idx].table else { continue }
            try checkUnknownKeys(
                entry, allowed: KnownKeys.uniqueConstraint,
                context: "Model `\(modelName)` unique_constraints[\(idx)]",
                strict: strict
            )
            guard let name = entry["name"]?.string else {
                throw CodegenError.malformedUniqueConstraint(
                    model: modelName, index: idx, reason: "missing `name`"
                )
            }
            guard let fieldsArr = entry["fields"]?.array else {
                throw CodegenError.malformedUniqueConstraint(
                    model: modelName, index: idx, reason: "missing `fields`"
                )
            }
            var fields: [String] = []
            for i in 0..<fieldsArr.count {
                guard let s = fieldsArr[i].string else {
                    throw CodegenError.malformedUniqueConstraint(
                        model: modelName, index: idx,
                        reason: "`fields[\(i)]` is not a string"
                    )
                }
                fields.append(s)
            }
            for f in fields where !fieldNames.contains(f) {
                throw CodegenError.uniqueConstraintUnknownField(
                    model: modelName, constraint: name, field: f
                )
            }
            out.append(ParsedUniqueConstraint(name: name, fields: fields))
        }
        return out
    }

    // MARK: - Relationships

    private static func buildRelationships(
        modelName: String,
        relsTable: TOMLTable,
        knownModels: Set<String>,
        strict: Bool
    ) throws -> [(name: String, descriptor: ParsedRelationship)] {
        var out: [(String, ParsedRelationship)] = []
        for relName in relsTable.keys {
            guard let rel = relsTable[relName]?.table else { continue }
            out.append((
                relName,
                try buildRelationship(
                    modelName: modelName,
                    relName: relName,
                    table: rel,
                    knownModels: knownModels,
                    strict: strict
                )
            ))
        }
        return out
    }

    private static func buildRelationship(
        modelName: String,
        relName: String,
        table: TOMLTable,
        knownModels: Set<String>,
        strict: Bool
    ) throws -> ParsedRelationship {
        try checkUnknownKeys(
            table, allowed: KnownKeys.relationship,
            context: "Model `\(modelName)` relationship `\(relName)`",
            strict: strict
        )
        guard let typeLiteral = table["type"]?.string else {
            throw CodegenError.missingRelationshipType(model: modelName, relationship: relName)
        }
        let allowed: Set<String> = ["refersTo", "hasMany", "hasManyThrough"]
        guard allowed.contains(typeLiteral) else {
            throw CodegenError.unknownRelationshipType(
                model: modelName, relationship: relName, typeName: typeLiteral
            )
        }
        guard let target = table["model"]?.string else {
            throw CodegenError.missingRelationshipModel(model: modelName, relationship: relName)
        }
        guard knownModels.contains(target) else {
            throw CodegenError.unknownRelatedModel(
                model: modelName, relationship: relName, target: target
            )
        }

        var props: [(String, String)] = [
            ("type", typeLiteral),
            ("model", target),
        ]

        switch typeLiteral {
        case "refersTo":
            if let s = table["related_id_field"]?.string {
                props.append(("relatedIdField", s))
            }
        case "hasMany":
            if let s = table["related_id_field"]?.string {
                props.append(("relatedIdField", s))
            }
            if let s = table["order_by_field"]?.string {
                props.append(("orderByField", s))
            }
            if let s = table["order_direction"]?.string {
                props.append(("orderDirection", s))
            }
        case "hasManyThrough":
            guard let joinModel = table["join_model"]?.string else {
                throw CodegenError.missingJoinModel(model: modelName, relationship: relName)
            }
            guard knownModels.contains(joinModel) else {
                throw CodegenError.unknownJoinModel(
                    model: modelName, relationship: relName, joinModel: joinModel
                )
            }
            props.append(("joinModel", joinModel))
            if let s = table["join_model_local_field"]?.string {
                props.append(("joinModelLocalField", s))
            }
            if let s = table["join_model_related_field"]?.string {
                props.append(("joinModelRelatedField", s))
            }
            if let s = table["join_model_order_by_field"]?.string {
                props.append(("joinModelOrderByField", s))
            }
            if let s = table["join_model_order_direction"]?.string {
                props.append(("joinModelOrderDirection", s))
            }
        default:
            break
        }

        return ParsedRelationship(rawType: typeLiteral, properties: props)
    }
}
