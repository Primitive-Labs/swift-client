import Foundation
import TOMLKit

/// Loads a set of `PrimitiveSchema`s from a TOML file, matching
/// js-bao's `loadSchemaFromTomlString` (js-bao package, dist/index.js
/// lines 7150–7472).
///
/// The TOML shape:
/// ```toml
/// [models.<ModelName>]
///
/// [models.<ModelName>.fields.<fieldName>]
/// type = "string" | "number" | "boolean" | "date" | "id" | "stringset" | "vector"
/// indexed = true
/// unique  = true
/// required = true
/// auto_assign = true
/// max_length = 128
/// max_count = 10
/// default = "guest"   # any scalar
/// dims = 768           # a vector field: how many numbers
/// element = "f32"      # a vector field: "f32" | "f16" | "i8"
///
/// [models.<ModelName>.relationships.<relName>]
/// type = "refersTo" | "hasMany" | "hasManyThrough"
/// model = "OtherModel"
/// related_id_field = "authorId"
/// # hasMany ordering (optional):
/// order_by_field = "createdAt"
/// order_direction = "ASC"  # or "DESC"
/// # hasManyThrough (required):
/// join_model = "UserTag"
/// join_model_local_field = "userId"
/// join_model_related_field = "tagId"
/// # hasManyThrough ordering (optional):
/// join_model_order_by_field = "position"
/// join_model_order_direction = "ASC"
///
/// [[models.<ModelName>.unique_constraints]]
/// name = "email_per_tenant"
/// fields = ["email", "tenantId"]
/// ```
///
/// Property names in TOML are snake_case; the loader converts them to
/// the camelCase keys `RelationshipDescriptor` stores internally, so
/// downstream code sees the same shape whether the schema was built
/// in Swift or loaded from TOML.
///
/// Validation (matches js-bao):
///  - Unknown field `type` literal → `.unknownFieldType`.
///  - Unknown relationship `type` → `.unknownRelationshipType`.
///  - Relationship `model` must be defined in the same file →
///    `.unknownRelatedModel`.
///  - `hasManyThrough.join_model` must be defined →
///    `.unknownJoinModel`.
///  - Every field in a unique constraint must exist on its model →
///    `.uniqueConstraintUnknownField`.
///  - A `vector` field (#5225) belongs to a db3 type file (one with a
///    `[type]` table) → `.vectorFieldOutsideDb3Type`; it needs `dims` (an
///    integer of at least 1) and `element`, and takes no index, uniqueness,
///    default, stamp or length option, and any other field takes neither
///    `dims` nor `element` → `.invalidVectorField`; no unique constraint
///    names one → `.vectorInUniqueConstraint`.
/// > **Codegen is the recommended path.** Prefer `swift-bao-codegen` at
/// > build time — see [`docs/codegen.md`](../../../docs/codegen.md). The
/// > runtime TOML loader is fully supported and kept as public API for
/// > the cases where build-time codegen doesn't fit (loading schemas
/// > you don't own, programmatic / dynamic schema construction, tests,
/// > tooling). For inspecting docs whose schema you don't own at build
/// > time, `SchemaDiscovery` (reads `_meta_<modelName>` Y.Maps written
/// > by other clients) is usually a better fit than runtime TOML.
public enum TomlSchemaLoader {

    /// Parse a TOML string and return one `PrimitiveSchema` per
    /// `[models.<name>]` table.
    ///
    /// - Parameter strict: when `true` (default, matches js-bao's
    ///   `loadSchemaFromTomlString({strict: true})`), reject any
    ///   unknown key under a model/field/relationship/unique-constraint
    ///   table. When `false`, accept everything silently — kept for
    ///   loading legacy/third-party TOML that hasn't been audited yet.
    /// - Parameter vectors: whether a field may be `type = "vector"`; `nil`
    ///   (the default) allows one when the text is a db3 type file (it has a
    ///   `[type]` table), as js-bao's loader does.
    public static func load(
        tomlString: String,
        strict: Bool = true,
        vectors: Bool? = nil
    ) throws -> [PrimitiveSchema] {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: tomlString)
        } catch {
            throw TomlSchemaLoaderError.parse(message: String(describing: error))
        }

        guard let modelsTable = table["models"]?.table else {
            throw TomlSchemaLoaderError.missingModelsTable
        }

        // First pass: collect field/constraint info for every model so
        // relationship validation (which needs the full name set) can
        // run afterward.
        var schemasByName: [String: PrimitiveSchema] = [:]
        var modelOrder: [String] = []
        for key in modelsTable.keys {
            guard let model = modelsTable[key]?.table else { continue }
            schemasByName[key] = try buildSchemaSkeleton(
                name: key, table: model, strict: strict, vectors: vectors ?? (table["type"]?.table != nil)
            )
            modelOrder.append(key)
        }

        // Second pass: resolve relationships now that every model name
        // is known.
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

    /// Read a TOML schema file from disk.
    public static func load(
        from url: URL,
        strict: Bool = true,
        vectors: Bool? = nil
    ) throws -> [PrimitiveSchema] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TomlSchemaLoaderError.fileRead(url: url, underlying: error)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TomlSchemaLoaderError.fileRead(
                url: url,
                underlying: NSError(
                    domain: "TomlSchemaLoader", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Not valid UTF-8"]
                )
            )
        }
        return try load(tomlString: text, strict: strict, vectors: vectors)
    }

    // MARK: - Skeleton (fields + compound constraints only)

    private static func buildSchemaSkeleton(
        name: String,
        table: TOMLTable,
        strict: Bool,
        vectors: Bool
    ) throws -> PrimitiveSchema {
        if strict {
            try checkUnknownKeys(
                in: table,
                allowed: knownModelKeys,
                context: "Model `\(name)`"
            )
        }
        let fields = try buildFields(modelName: name, table: table, strict: strict, vectors: vectors)
        let constraints = try buildUniqueConstraints(
            modelName: name, table: table,
            fieldNames: Set(fields.keys),
            strict: strict
        )
        // A vector cannot be part of a unique key (#5225).
        for constraint in constraints.values.sorted(by: { $0.name < $1.name }) {
            if let field = constraint.fields.first(where: { fields[$0]?.type == .vector }) {
                throw TomlSchemaLoaderError.vectorInUniqueConstraint(model: name, constraint: constraint.name, field: field)
            }
        }
        let schema = PrimitiveSchema(
            name: name,
            fields: fields,
            constraints: constraints,
            relationships: [:]
        )
        // #3719 — a unique constraint on a stringset field is refused here,
        // with js-bao's sentence: no writer can key it consistently.
        if let violation = schema.uniqueStringsetViolation {
            throw TomlSchemaLoaderError.uniqueOnStringset(message: violation.message)
        }
        return schema
    }

    // MARK: - Fields

    private static func buildFields(
        modelName: String,
        table: TOMLTable,
        strict: Bool,
        vectors: Bool
    ) throws -> [String: FieldDescriptor] {
        guard let fieldsTable = table["fields"]?.table else { return [:] }
        var out: [String: FieldDescriptor] = [:]
        for fieldName in fieldsTable.keys {
            guard let field = fieldsTable[fieldName]?.table else { continue }
            out[fieldName] = try buildField(
                modelName: modelName, fieldName: fieldName,
                table: field, strict: strict, vectors: vectors
            )
        }
        return out
    }

    private static func buildField(
        modelName: String,
        fieldName: String,
        table: TOMLTable,
        strict: Bool,
        vectors: Bool
    ) throws -> FieldDescriptor {
        guard let typeLiteral = table["type"]?.string else {
            throw TomlSchemaLoaderError.missingFieldType(
                model: modelName, field: fieldName
            )
        }
        guard let type = PrimitiveFieldType(rawValue: typeLiteral),
              allowedFieldTypes.contains(type)
        else {
            throw TomlSchemaLoaderError.unknownFieldType(
                model: modelName, field: fieldName, typeName: typeLiteral
            )
        }
        if strict {
            try checkUnknownKeys(
                in: table,
                allowed: knownFieldKeys,
                context: "Model `\(modelName)` field `\(fieldName)`"
            )
        }
        if type == .vector && !vectors {
            throw TomlSchemaLoaderError.vectorFieldOutsideDb3Type(model: modelName, field: fieldName)
        }
        // Judged before the other options, so one that does not apply to a
        // vector is named even when its value would parse.
        if let reason = vectorFieldProblem(table, type: typeLiteral) {
            throw TomlSchemaLoaderError.invalidVectorField(model: modelName, field: fieldName, reason: reason)
        }

        // Parse `auto_stamp = "create" | "update" | "both"`. Fail-fast on
        // an unrecognized literal — mirrors js-bao `tomlLoader.ts`'s
        // `VALID_AUTO_STAMP_VALUES` guard.
        var autoStamp: AutoStamp? = nil
        if let rawStamp = table["auto_stamp"]?.string {
            guard let parsed = AutoStamp(rawValue: rawStamp) else {
                throw TomlSchemaLoaderError.invalidAutoStamp(
                    model: modelName, field: fieldName, value: rawStamp
                )
            }
            autoStamp = parsed
        }

        return FieldDescriptor(
            type: type,
            indexed: table["indexed"]?.bool ?? false,
            unique:  table["unique"]?.bool  ?? false,
            required: table["required"]?.bool ?? false,
            autoAssign: table["auto_assign"]?.bool ?? false,
            maxLength: table["max_length"]?.int,
            maxCount: table["max_count"]?.int,
            default: decodeDefault(table["default"]),
            autoStamp: autoStamp,
            dims: type == .vector ? table["dims"]?.int : nil,
            element: type == .vector ? table["element"]?.string.flatMap(VectorElement.init(rawValue:)) : nil
        )
    }

    /// The options a vector field may not carry, as TOML spells them.
    private static let notOnAVector = [
        "indexed", "unique", "default", "enum", "auto_assign", "auto_stamp", "max_length", "max_count",
    ]

    /// The flags of ``notOnAVector``, which `false` leaves off. Any other
    /// option is refused whatever its value: `default = false` would write
    /// `false` into the vector.
    private static let vectorFlagOptions: Set<String> = ["indexed", "unique", "auto_assign"]

    /// What is wrong with a field table's vector options, or `nil`: js-bao's
    /// `vectorFieldProblem` with TOML spelling. A vector field needs `dims`
    /// (an integer of at least 1) and `element` (`f32`, `f16` or `i8`) and
    /// carries none of ``notOnAVector`` (a flag set `false` is no option); any other
    /// field carries neither `dims` nor `element`.
    private static func vectorFieldProblem(_ table: TOMLTable, type: String) -> String? {
        guard type == "vector" else {
            for key in ["dims", "element"] where table[key] != nil {
                return "`\(key)` applies to a vector field only, not a \"\(type)\" field"
            }
            return nil
        }
        guard let dims = table["dims"]?.int, dims >= 1 else {
            return "a vector field needs `dims`, an integer of at least 1"
                + (table["dims"].map { ", not \(tomlText($0))" } ?? "")
        }
        guard let element = table["element"]?.string, VectorElement(rawValue: element) != nil else {
            return "a vector field needs `element`, one of "
                + VectorElement.allCases.map(\.rawValue).joined(separator: ", ")
                + (table["element"].map { ", not \(tomlText($0))" } ?? "")
        }
        for key in notOnAVector {
            guard let value = table[key] else { continue }
            if vectorFlagOptions.contains(key), value.bool == false { continue }
            return "`\(key)` does not apply to a vector field"
        }
        return nil
    }

    /// A TOML value as a refusal quotes it: a string quoted, a number as written.
    private static func tomlText(_ value: any TOMLValueConvertible) -> String {
        if let text = value.string { return "\"\(text)\"" }
        if let number = value.int { return String(number) }
        if let number = value.double { return PrimitiveValue.jsNumberString(number) }
        if let flag = value.bool { return flag ? "true" : "false" }
        return "a \(value.type)"
    }

    /// `default` is heterogeneous — string, int, double, or bool. We
    /// keep only scalar defaults (matches js-bao; function defaults
    /// like `$generate_ulid` aren't expressible in TOML).
    private static func decodeDefault(_ value: TOMLValue?) -> DefaultValue? {
        guard let value else { return nil }
        if let s = value.string { return .scalar(.string(s)) }
        if let b = value.bool   { return .scalar(.boolean(b)) }
        if let i = value.int    { return .scalar(.number(Double(i))) }
        if let d = value.double { return .scalar(.number(d)) }
        return nil
    }

    // MARK: - Compound unique constraints

    private static func buildUniqueConstraints(
        modelName: String,
        table: TOMLTable,
        fieldNames: Set<String>,
        strict: Bool
    ) throws -> [String: ConstraintDescriptor] {
        // `[[models.X.unique_constraints]]` lands under `unique_constraints`
        // as a TOMLArray of TOMLTables.
        guard let arr = table["unique_constraints"]?.array else { return [:] }
        var out: [String: ConstraintDescriptor] = [:]
        for idx in 0..<arr.count {
            guard let entry = arr[idx].table else { continue }
            if strict {
                try checkUnknownKeys(
                    in: entry,
                    allowed: knownUniqueConstraintKeys,
                    context: "Model `\(modelName)` unique_constraints[\(idx)]"
                )
            }
            guard let name = entry["name"]?.string else {
                throw TomlSchemaLoaderError.malformedUniqueConstraint(
                    model: modelName, index: idx, reason: "missing `name`"
                )
            }
            guard let fieldsArr = entry["fields"]?.array else {
                throw TomlSchemaLoaderError.malformedUniqueConstraint(
                    model: modelName, index: idx, reason: "missing `fields`"
                )
            }
            var fields: [String] = []
            for i in 0..<fieldsArr.count {
                guard let s = fieldsArr[i].string else {
                    throw TomlSchemaLoaderError.malformedUniqueConstraint(
                        model: modelName, index: idx,
                        reason: "`fields[\(i)]` is not a string"
                    )
                }
                fields.append(s)
            }
            for f in fields where !fieldNames.contains(f) {
                throw TomlSchemaLoaderError.uniqueConstraintUnknownField(
                    model: modelName, constraint: name, field: f
                )
            }
            out[name] = ConstraintDescriptor(name: name, fields: fields)
        }
        return out
    }

    // MARK: - Relationships

    private static func buildRelationships(
        modelName: String,
        relsTable: TOMLTable,
        knownModels: Set<String>,
        strict: Bool
    ) throws -> [String: RelationshipDescriptor] {
        var out: [String: RelationshipDescriptor] = [:]
        for relName in relsTable.keys {
            guard let rel = relsTable[relName]?.table else { continue }
            out[relName] = try buildRelationship(
                modelName: modelName,
                relName: relName,
                table: rel,
                knownModels: knownModels,
                strict: strict
            )
        }
        return out
    }

    private static func buildRelationship(
        modelName: String,
        relName: String,
        table: TOMLTable,
        knownModels: Set<String>,
        strict: Bool
    ) throws -> RelationshipDescriptor {
        guard let typeLiteral = table["type"]?.string else {
            throw TomlSchemaLoaderError.missingRelationshipType(
                model: modelName, relationship: relName
            )
        }
        guard allowedRelationshipTypes.contains(typeLiteral) else {
            throw TomlSchemaLoaderError.unknownRelationshipType(
                model: modelName, relationship: relName, typeName: typeLiteral
            )
        }
        guard let targetModel = table["model"]?.string else {
            throw TomlSchemaLoaderError.missingRelationshipModel(
                model: modelName, relationship: relName
            )
        }
        guard knownModels.contains(targetModel) else {
            throw TomlSchemaLoaderError.unknownRelatedModel(
                model: modelName, relationship: relName, target: targetModel
            )
        }
        if strict {
            try checkUnknownKeys(
                in: table,
                allowed: knownRelationshipKeys,
                context: "Model `\(modelName)` relationship `\(relName)`"
            )
        }

        // Start with the base properties. Everything is stored as
        // plain `[String: String]` on `RelationshipDescriptor` so
        // unknown keys survive a round-trip (matches js-bao).
        var props: [String: String] = [
            "type": typeLiteral,
            "model": targetModel,
        ]

        switch typeLiteral {
        case "refersTo":
            // js-bao tomlLoader.ts:153 — `related_id_field` is required.
            guard let s = table["related_id_field"]?.string else {
                throw TomlSchemaLoaderError.missingRelationshipField(
                    model: modelName, relationship: relName,
                    relType: typeLiteral, field: "related_id_field"
                )
            }
            props["relatedIdField"] = s

        case "hasMany":
            // js-bao tomlLoader.ts:163 — required for hasMany too.
            guard let s = table["related_id_field"]?.string else {
                throw TomlSchemaLoaderError.missingRelationshipField(
                    model: modelName, relationship: relName,
                    relType: typeLiteral, field: "related_id_field"
                )
            }
            props["relatedIdField"] = s
            if let s = table["order_by_field"]?.string {
                props["orderByField"] = s
            }
            if let s = table["order_direction"]?.string {
                props["orderDirection"] = s
            }

        case "hasManyThrough":
            guard let joinModel = table["join_model"]?.string else {
                throw TomlSchemaLoaderError.missingJoinModel(
                    model: modelName, relationship: relName
                )
            }
            guard knownModels.contains(joinModel) else {
                throw TomlSchemaLoaderError.unknownJoinModel(
                    model: modelName, relationship: relName, joinModel: joinModel
                )
            }
            props["joinModel"] = joinModel
            // js-bao tomlLoader.ts — both join-model link fields required.
            guard let local = table["join_model_local_field"]?.string else {
                throw TomlSchemaLoaderError.missingRelationshipField(
                    model: modelName, relationship: relName,
                    relType: typeLiteral, field: "join_model_local_field"
                )
            }
            props["joinModelLocalField"] = local
            guard let related = table["join_model_related_field"]?.string else {
                throw TomlSchemaLoaderError.missingRelationshipField(
                    model: modelName, relationship: relName,
                    relType: typeLiteral, field: "join_model_related_field"
                )
            }
            props["joinModelRelatedField"] = related
            if let s = table["join_model_order_by_field"]?.string {
                props["joinModelOrderByField"] = s
            }
            if let s = table["join_model_order_direction"]?.string {
                props["joinModelOrderDirection"] = s
            }

        default:
            // Unreachable — `allowedRelationshipTypes` already gated.
            break
        }

        return RelationshipDescriptor(properties: props)
    }

    // MARK: - Strict-mode helpers

    /// Throw if any key in `table` is not in `allowed`. Mirrors js-bao
    /// `tomlLoader.ts` `checkUnknownKeys`.
    private static func checkUnknownKeys(
        in table: TOMLTable,
        allowed: Set<String>,
        context: String
    ) throws {
        for key in table.keys where !allowed.contains(key) {
            throw TomlSchemaLoaderError.unknownKey(
                context: context, key: key,
                allowed: allowed.sorted()
            )
        }
    }

    private static let knownModelKeys: Set<String> = [
        "fields", "relationships", "unique_constraints", "class_name",
    ]

    private static let knownFieldKeys: Set<String> = [
        "type", "indexed", "unique", "required",
        "auto_assign", "auto_stamp",
        "max_length", "max_count", "default",
        "dims", "element",
    ]

    private static let knownRelationshipKeys: Set<String> = [
        "type", "model",
        "related_id_field",
        "join_model", "join_model_local_field", "join_model_related_field",
        "order_by_field", "order_direction",
        "join_model_order_by_field", "join_model_order_direction",
    ]

    private static let knownUniqueConstraintKeys: Set<String> = [
        "name", "fields",
    ]

    // MARK: - Allowed values

    /// The wire-level field types js-bao's TOML loader accepts (`vector` in a
    /// db3 type file only, #5225).
    /// `.json` is supported in-memory in Swift but isn't part of the
    /// TOML surface — js-bao never declares json columns in TOML.
    private static let allowedFieldTypes: Set<PrimitiveFieldType> = [
        .string, .number, .boolean, .date, .id, .stringset, .vector,
    ]

    private static let allowedRelationshipTypes: Set<String> = [
        "refersTo", "hasMany", "hasManyThrough",
    ]
}

// MARK: - Errors

public enum TomlSchemaLoaderError: Error, CustomStringConvertible {
    case parse(message: String)
    case fileRead(url: URL, underlying: Error)
    case missingModelsTable
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
    case missingRelationshipField(
        model: String, relationship: String,
        relType: String, field: String
    )
    case unknownKey(context: String, key: String, allowed: [String])
    case invalidAutoStamp(model: String, field: String, value: String)
    /// A unique constraint on a stringset field (#3719); `message` is the
    /// sentence js-bao's loader answers.
    case uniqueOnStringset(message: String)
    /// A `vector` field outside a db3 type file (#5225): a schema with no
    /// `[type]` table describes documents, which carry no vectors.
    case vectorFieldOutsideDb3Type(model: String, field: String)
    /// A vector field the loader cannot encode, or `dims`/`element` on
    /// another field (#5225); `reason` is js-bao's sentence.
    case invalidVectorField(model: String, field: String, reason: String)
    /// A unique constraint naming a vector field (#5225).
    case vectorInUniqueConstraint(model: String, constraint: String, field: String)

    public var description: String {
        switch self {
        case let .parse(message):
            return "TOML parse error: \(message)"
        case let .fileRead(url, underlying):
            return "Failed to read \(url.path): \(underlying)"
        case .missingModelsTable:
            return "TOML is missing required top-level [models] table"
        case let .missingFieldType(model, field):
            return "Model `\(model)` field `\(field)` is missing required `type`"
        case let .unknownFieldType(model, field, typeName):
            return "Model `\(model)` field `\(field)` has unknown type `\(typeName)` — allowed: string, number, boolean, date, id, stringset, vector"
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
        case let .missingRelationshipField(model, relationship, relType, field):
            return "Model `\(model)` \(relType) relationship `\(relationship)` is missing required `\(field)`"
        case let .unknownKey(context, key, allowed):
            return "\(context): unknown key `\(key)`. Allowed: \(allowed.joined(separator: ", "))"
        case let .invalidAutoStamp(model, field, value):
            return "Model `\(model)` field `\(field)` has invalid auto_stamp value `\(value)` — must be one of: create, update, both"
        case let .uniqueOnStringset(message):
            return message
        case let .vectorFieldOutsideDb3Type(model, field):
            return "Model `\(model)` field `\(field)`: a vector field belongs to a db3 type (a schema with a [type] table); a document schema or a database type cannot declare one"
        case let .invalidVectorField(model, field, reason):
            return "Model `\(model)` field `\(field)`: \(reason)"
        case let .vectorInUniqueConstraint(model, constraint, field):
            return "[[models.\(model).unique_constraints]]: unique constraint \"\(constraint)\" names the vector field \"\(field)\", which cannot be unique"
        }
    }
}
