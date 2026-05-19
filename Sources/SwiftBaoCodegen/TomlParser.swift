import Foundation
import TOMLKit

enum CodegenError: Error, CustomStringConvertible {
    case parse(String)
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
    case invalidClassName(model: String, reason: String)

    var description: String {
        switch self {
        case let .parse(m):
            return "TOML parse error: \(m)"
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
        case let .invalidClassName(model, reason):
            return "Model `\(model)` class_name: \(reason)"
        }
    }
}

/// Parse a TOML schema into the codegen IR. Validation rules mirror
/// `JsBaoClient.TomlSchemaLoader` exactly — same input is accepted, same
/// errors are raised, so the build-time tool can't drift from runtime
/// semantics (a schema that codegens cleanly will also load cleanly at
/// runtime, and vice versa).
enum TomlParser {

    static func parse(tomlString: String, swiftNameSuffix: String) throws -> [ParsedSchema] {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: tomlString)
        } catch {
            throw CodegenError.parse(String(describing: error))
        }

        guard let modelsTable = table["models"]?.table else {
            throw CodegenError.missingModelsTable
        }

        // First pass: collect field/constraint/codegen info per model.
        var schemasByName: [String: ParsedSchema] = [:]
        var modelOrder: [String] = []
        for key in modelsTable.keys {
            guard let model = modelsTable[key]?.table else { continue }
            schemasByName[key] = try buildSchema(
                name: key, table: model, swiftNameSuffix: swiftNameSuffix
            )
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
                    knownModels: Set(schemasByName.keys)
                )
                schemasByName[key] = schema
            }
        }

        return modelOrder.compactMap { schemasByName[$0] }
    }

    // MARK: - Per-model

    private static func buildSchema(
        name: String,
        table: TOMLTable,
        swiftNameSuffix: String
    ) throws -> ParsedSchema {
        let (fieldOrder, fields) = try buildFields(modelName: name, table: table)
        let constraints = try buildUniqueConstraints(
            modelName: name, table: table, fieldNames: Set(fields.keys)
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

    // MARK: - Fields

    private static func buildFields(
        modelName: String,
        table: TOMLTable
    ) throws -> ([String], [String: ParsedField]) {
        guard let fieldsTable = table["fields"]?.table else { return ([], [:]) }
        var order: [String] = []
        var out: [String: ParsedField] = [:]
        for fieldName in fieldsTable.keys {
            guard let field = fieldsTable[fieldName]?.table else { continue }
            out[fieldName] = try buildField(
                modelName: modelName, fieldName: fieldName, table: field
            )
            order.append(fieldName)
        }
        return (order, out)
    }

    private static func buildField(
        modelName: String,
        fieldName: String,
        table: TOMLTable
    ) throws -> ParsedField {
        guard let typeLiteral = table["type"]?.string else {
            throw CodegenError.missingFieldType(model: modelName, field: fieldName)
        }
        guard let type = ParsedFieldType(rawValue: typeLiteral) else {
            throw CodegenError.unknownFieldType(
                model: modelName, field: fieldName, typeName: typeLiteral
            )
        }
        return ParsedField(
            type: type,
            indexed: table["indexed"]?.bool ?? false,
            unique: table["unique"]?.bool ?? false,
            required: table["required"]?.bool ?? false,
            autoAssign: table["auto_assign"]?.bool ?? false,
            maxLength: table["max_length"]?.int,
            maxCount: table["max_count"]?.int,
            defaultLiteral: decodeDefault(table["default"])
        )
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
        fieldNames: Set<String>
    ) throws -> [ParsedUniqueConstraint] {
        guard let arr = table["unique_constraints"]?.array else { return [] }
        var out: [ParsedUniqueConstraint] = []
        for idx in 0..<arr.count {
            guard let entry = arr[idx].table else { continue }
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
        knownModels: Set<String>
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
                    knownModels: knownModels
                )
            ))
        }
        return out
    }

    private static func buildRelationship(
        modelName: String,
        relName: String,
        table: TOMLTable,
        knownModels: Set<String>
    ) throws -> ParsedRelationship {
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
