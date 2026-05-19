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
/// type = "string" | "number" | "boolean" | "date" | "id" | "stringset"
/// indexed = true
/// unique  = true
/// required = true
/// auto_assign = true
/// max_length = 128
/// max_count = 10
/// default = "guest"   # any scalar
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
    public static func load(tomlString: String) throws -> [PrimitiveSchema] {
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
            schemasByName[key] = try buildSchemaSkeleton(name: key, table: model)
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
                    knownModels: Set(schemasByName.keys)
                )
                schemasByName[key] = schema
            }
        }

        return modelOrder.compactMap { schemasByName[$0] }
    }

    /// Read a TOML schema file from disk.
    public static func load(from url: URL) throws -> [PrimitiveSchema] {
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
        return try load(tomlString: text)
    }

    // MARK: - Skeleton (fields + compound constraints only)

    private static func buildSchemaSkeleton(
        name: String,
        table: TOMLTable
    ) throws -> PrimitiveSchema {
        let fields = try buildFields(modelName: name, table: table)
        let constraints = try buildUniqueConstraints(
            modelName: name, table: table, fieldNames: Set(fields.keys)
        )
        return PrimitiveSchema(
            name: name,
            fields: fields,
            constraints: constraints,
            relationships: [:]
        )
    }

    // MARK: - Fields

    private static func buildFields(
        modelName: String,
        table: TOMLTable
    ) throws -> [String: FieldDescriptor] {
        guard let fieldsTable = table["fields"]?.table else { return [:] }
        var out: [String: FieldDescriptor] = [:]
        for fieldName in fieldsTable.keys {
            guard let field = fieldsTable[fieldName]?.table else { continue }
            out[fieldName] = try buildField(
                modelName: modelName, fieldName: fieldName, table: field
            )
        }
        return out
    }

    private static func buildField(
        modelName: String,
        fieldName: String,
        table: TOMLTable
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

        return FieldDescriptor(
            type: type,
            indexed: table["indexed"]?.bool ?? false,
            unique:  table["unique"]?.bool  ?? false,
            required: table["required"]?.bool ?? false,
            autoAssign: table["auto_assign"]?.bool ?? false,
            maxLength: table["max_length"]?.int,
            maxCount: table["max_count"]?.int,
            default: decodeDefault(table["default"])
        )
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
        fieldNames: Set<String>
    ) throws -> [String: ConstraintDescriptor] {
        // `[[models.X.unique_constraints]]` lands under `unique_constraints`
        // as a TOMLArray of TOMLTables.
        guard let arr = table["unique_constraints"]?.array else { return [:] }
        var out: [String: ConstraintDescriptor] = [:]
        for idx in 0..<arr.count {
            guard let entry = arr[idx].table else { continue }
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
        knownModels: Set<String>
    ) throws -> [String: RelationshipDescriptor] {
        var out: [String: RelationshipDescriptor] = [:]
        for relName in relsTable.keys {
            guard let rel = relsTable[relName]?.table else { continue }
            out[relName] = try buildRelationship(
                modelName: modelName,
                relName: relName,
                table: rel,
                knownModels: knownModels
            )
        }
        return out
    }

    private static func buildRelationship(
        modelName: String,
        relName: String,
        table: TOMLTable,
        knownModels: Set<String>
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

        // Start with the base properties. Everything is stored as
        // plain `[String: String]` on `RelationshipDescriptor` so
        // unknown keys survive a round-trip (matches js-bao).
        var props: [String: String] = [
            "type": typeLiteral,
            "model": targetModel,
        ]

        switch typeLiteral {
        case "refersTo":
            if let s = table["related_id_field"]?.string {
                props["relatedIdField"] = s
            }

        case "hasMany":
            if let s = table["related_id_field"]?.string {
                props["relatedIdField"] = s
            }
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
            if let s = table["join_model_local_field"]?.string {
                props["joinModelLocalField"] = s
            }
            if let s = table["join_model_related_field"]?.string {
                props["joinModelRelatedField"] = s
            }
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

    // MARK: - Allowed values

    /// The six wire-level field types js-bao's TOML loader accepts.
    /// `.json` is supported in-memory in Swift but isn't part of the
    /// TOML surface — js-bao never declares json columns in TOML.
    private static let allowedFieldTypes: Set<PrimitiveFieldType> = [
        .string, .number, .boolean, .date, .id, .stringset,
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
        }
    }
}
