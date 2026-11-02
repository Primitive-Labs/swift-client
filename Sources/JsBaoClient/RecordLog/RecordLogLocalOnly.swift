import Foundation

// A db3 that lives only on this device (#5155): no room declares its
// constraints or keeps its index registry, so the device does, by the room's
// rules and names. A port of js-bao's `record-log-client/local-only.ts`.
//
// - Its constraints are the registered models' unique constraints, then one
//   per unique registration no declared constraint of its model covers with
//   the same fields, named after the index (the room's
//   `withRegistryConstraints`).
// - Its index list is the room's registry over the same origins: one index
//   per declared `indexed` or `unique` field (`idx_records_<model>_<field>`)
//   and per compound unique constraint (`idx_uc_<model>_<name>`), each
//   origin `declaration`, and one per registration made here, origin `named`
//   (`idx_named_<model>_<name>`, or the field's shared index).
enum RecordLogLocalOnly {

    /// The room's name of a declared field's shared index.
    static func fieldIndexName(model: String, field: String) -> String {
        "idx_records_\(model.lowercased())_\(field.lowercased())"
    }

    /// The room's name of an index registered under `name`.
    static func namedIndexName(model: String, name: String) -> String {
        "idx_named_\(model.lowercased())_\(name.lowercased())"
    }

    /// The room's name of a compound unique constraint's index.
    private static func constraintIndexName(model: String, constraint: String) -> String {
        let name = String(constraint.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (scalar == "_" || CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "_"
        })
        let safe = RecordLogSchema.isValidIdentifier(name) ? name : "c_\(name)"
        return "idx_uc_\(model.lowercased())_\(safe.lowercased())"
    }

    private static func isSetField(_ schema: PrimitiveSchema?, _ field: String) -> Bool {
        schema?.fields[field]?.type == .stringset
    }

    private static func sameFieldSet(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && a.sorted() == b.sorted()
    }

    /// The declared constraints in force: every model's unique constraints, over no string-set field.
    static func declaredConstraints(_ schemas: [PrimitiveSchema]) -> [RecordLogConstraint] {
        schemas.flatMap { schema in
            schema.resolvedUniqueConstraints.compactMap { constraint -> RecordLogConstraint? in
                guard !constraint.fields.isEmpty, !constraint.fields.contains(where: { isSetField(schema, $0) }) else { return nil }
                return RecordLogConstraint(model: schema.name, name: constraint.name, fields: constraint.fields)
            }
        }
    }

    /// One index of a local-only db3's list while it is assembled.
    private struct Listing {
        var name: String
        var model: String
        var fields: [String]
        var unique: Bool
        var origins: [Db3IndexOrigin]

        var index: Db3Index {
            Db3Index(name: name, model: model, fields: fields, unique: unique, members: false, origins: origins)
        }
    }

    /// The indexes the declarations keep, each with its declaration origin:
    /// one per field declared `indexed` or `unique` (not `id`, not a string
    /// set), unique exactly when a declared constraint covers it, and one per
    /// compound unique constraint.
    private static func declarationIndexes(_ schemas: [PrimitiveSchema]) -> [Listing] {
        var out: [Listing] = []
        for schema in schemas where RecordLogSchema.isValidIdentifier(schema.name) {
            let model = schema.name
            var wants = RecordLogOrderedMap<[String], Listing>()
            for (field, descriptor) in schema.fields.sorted(by: { $0.key < $1.key }) {
                guard field != "id", descriptor.type != .stringset, RecordLogSchema.isValidIdentifier(field) else { continue }
                guard descriptor.indexed || descriptor.unique else { continue }
                wants[[field]] = Listing(
                    name: fieldIndexName(model: model, field: field), model: model, fields: [field], unique: false,
                    origins: [Db3IndexOrigin(kind: .declaration, unique: false)]
                )
            }
            for constraint in declaredConstraints([schema]) {
                let fields = constraint.fields
                if fields == ["id"] || !fields.allSatisfy(RecordLogSchema.isValidIdentifier) { continue }
                if var wanted = wants[fields] {
                    wanted.unique = true
                    wanted.origins = [Db3IndexOrigin(kind: .declaration, unique: true)]
                    wants[fields] = wanted
                    continue
                }
                wants[fields] = Listing(
                    name: constraintIndexName(model: model, constraint: constraint.name), model: model, fields: fields,
                    unique: true, origins: [Db3IndexOrigin(kind: .declaration, unique: true)]
                )
            }
            out.append(contentsOf: wants.entries.map(\.value))
        }
        return out
    }

    /// A local-only db3's index list: the declarations' indexes, with each
    /// registration made here added as a `named` origin of the index over the
    /// same fields, or as an index of its own. Sorted by name, as the room
    /// lists its registry.
    static func indexList(_ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex]) -> [Db3Index] {
        listings(schemas, registrations).map(\.index)
    }

    private static func listings(_ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex]) -> [Listing] {
        var byDefinition = RecordLogOrderedMap<[String], Listing>()
        for listing in declarationIndexes(schemas) { byDefinition[[listing.model] + listing.fields] = listing }
        for registration in registrations {
            let key = [registration.model] + registration.fields
            let origin = Db3IndexOrigin(kind: .named, unique: registration.unique)
            if var held = byDefinition[key] {
                held.origins = held.origins.filter { $0.kind != .named } + [origin]
                held.unique = held.origins.contains { $0.unique }
                byDefinition[key] = held
                continue
            }
            byDefinition[key] = Listing(
                name: registration.name, model: registration.model, fields: registration.fields, unique: registration.unique,
                origins: [origin]
            )
        }
        return byDefinition.entries.map(\.value).sorted { $0.name < $1.name }
    }

    /// A local-only db3's constraints in force: the declared ones, then one
    /// per unique index of its list no declared constraint of its model covers
    /// with the same fields, named after the index, over no field the model
    /// declares a string set.
    static func constraints(_ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex]) -> [RecordLogConstraint] {
        let declared = declaredConstraints(schemas)
        var out = declared
        for index in listings(schemas, registrations) {
            guard index.unique, index.origins.contains(where: { $0.kind == .named && $0.unique }) else { continue }
            if declared.contains(where: { $0.model == index.model && sameFieldSet($0.fields, index.fields) }) { continue }
            let schema = schemas.first { $0.name == index.model }
            if index.fields.contains(where: { isSetField(schema, $0) }) { continue }
            out.append(RecordLogConstraint(model: index.model, name: index.name, fields: index.fields))
        }
        return out
    }

    /// The most duplicate keys a refused unique registration names, as the room names them.
    static let maxDuplicates = 10

    /// A registration as the room checks it: `{ model, field | fields, unique?, name? }`.
    struct Registration: Equatable {
        var model: String
        var fields: [String]
        var unique: Bool
        var name: String?
    }

    private static func invalid(_ message: String) -> JsBaoError {
        JsBaoError(code: .db3IndexInvalid, message: message)
    }

    /// A registration checked by the room's rules, or `DB3_INDEX_INVALID`
    /// naming what is wrong. A member index is not one: the caller refuses it.
    static func parse(_ body: Db3IndexRegistration) throws -> Registration {
        guard RecordLogSchema.isValidIdentifier(body.model) else {
            throw invalid("model must be an identifier (letters, digits and _, not starting with a digit)")
        }
        guard (body.field == nil) != (body.fields == nil) else { throw invalid("Give exactly one of field and fields") }
        let fields = body.field.map { [$0] } ?? body.fields ?? []
        guard !fields.isEmpty else { throw invalid("fields must be a non-empty array of field names") }
        for field in fields {
            guard RecordLogSchema.isValidIdentifier(field) else { throw invalid("Field \"\(field)\" must be an identifier") }
            if field == "id" { throw invalid("id needs no index: the primary key serves it") }
            if let reserved = recordLogReservedFieldProblem(field) { throw invalid(reserved) }
        }
        guard Set(fields).count == fields.count else { throw invalid("fields must not repeat a field") }
        if let name = body.name, !RecordLogSchema.isValidIdentifier(name) { throw invalid("name must be an identifier") }
        let unique = body.unique == true
        if fields.count > 1 && (body.name == nil || !unique) {
            throw invalid("An index over several fields is a unique constraint: give it a name and unique: true")
        }
        return Registration(model: body.model, fields: fields, unique: unique, name: body.name)
    }

    /// `DB3_INDEX_NOT_UNIQUE`: live records of `model` share the key over
    /// `fields`, the keys named in `duplicates` (`{ values, count }`).
    static func notUnique(model: String, fields: [String], duplicates: [(values: [JSONValue], count: Int)]) -> JsBaoError {
        JsBaoError(
            code: .db3IndexNotUnique,
            message: "Live \(model) records share \(fields.joined(separator: ", ")): resolve the duplicates before registering a unique index",
            details: ["duplicates": .array(duplicates.map {
                .object(["values": .array($0.values), "count": .number(Double($0.count))])
            })]
        )
    }

    /// Register a named origin on a local-only db3, by the room's rules
    /// (`registerIndex`): a field declared a string set takes no index
    /// (`DB3_INDEX_SET_FIELD`); a `name` another registration of the model
    /// holds over other fields is `DB3_INDEX_NAME_TAKEN`; a `name` on a
    /// definition already indexed under another is `DB3_INDEX_EXISTS`. A
    /// definition already listed gets the named origin; otherwise the
    /// registration is an index of its own. Records sharing a unique key are
    /// the store's to refuse, as it writes the registration.
    ///
    /// - Returns: The registrations as they now are, and the index as the list now shows it.
    static func register(
        _ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex], _ body: Db3IndexRegistration
    ) throws -> (registrations: [RecordLogLocalIndex], index: Db3Index) {
        let parsed = try parse(body)
        let schema = schemas.first { $0.name == parsed.model }
        for field in parsed.fields where isSetField(schema, field) {
            throw JsBaoError(
                code: .db3IndexSetField,
                message: "\(parsed.model).\(field) is a string set, and a set field takes no index: "
                    + "$contains and facets read its members from the record itself",
                details: ["field": .string(field)]
            )
        }
        let list = listings(schemas, registrations)
        let existing = list.first { $0.model == parsed.model && $0.fields == parsed.fields }
        let existingNamed = existing.flatMap { held in registrations.first { $0.name == held.name }?.named }
        if let name = parsed.name {
            if let holder = registrations.first(where: { $0.model == parsed.model && $0.named == name && $0.fields != parsed.fields }) {
                throw JsBaoError(
                    code: .db3IndexNameTaken,
                    message: "\(parsed.model) already has an index named \(name) (\(holder.name)) over other fields",
                    details: ["index": .string(holder.name)]
                )
            }
            if let existing, existingNamed != name {
                throw JsBaoError(
                    code: .db3IndexExists,
                    message: "\(existing.name) already indexes \(parsed.model) on \(parsed.fields.joined(separator: ", ")): "
                        + "register it without a name, or drop it first",
                    details: ["index": .string(existing.name)]
                )
            }
        }
        let indexName = existing?.name
            ?? parsed.name.map { namedIndexName(model: parsed.model, name: $0) }
            ?? fieldIndexName(model: parsed.model, field: parsed.fields[0])
        let registration = RecordLogLocalIndex(
            name: indexName, model: parsed.model, fields: parsed.fields, unique: parsed.unique, named: parsed.name ?? existingNamed
        )
        let next = registrations.filter { !($0.model == parsed.model && $0.fields == parsed.fields) } + [registration]
        guard let index = indexList(schemas, next).first(where: { $0.name == indexName }) else {
            throw invalid("The registration names no index")
        }
        return (next, index)
    }

    /// Remove a registration's named origin on a local-only db3, by the
    /// room's rules (`dropIndex`): a name no index of the list has is
    /// `DB3_INDEX_NOT_FOUND`; an index a declaration keeps is
    /// `DB3_INDEX_IN_USE`, naming the origins that remain.
    ///
    /// - Returns: The registrations as they now are.
    static func drop(_ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex], name: String) throws -> [RecordLogLocalIndex] {
        guard let index = listings(schemas, registrations).first(where: { $0.name == name }) else {
            throw JsBaoError(code: .db3IndexNotFound, message: "No registered index is named \(name)", details: ["index": .string(name)])
        }
        let remaining = index.origins.filter { $0.kind != .named }
        guard remaining.isEmpty else {
            throw JsBaoError(
                code: .db3IndexInUse,
                message: "\(name) is kept by \(remaining.map(\.kind.rawValue).joined(separator: " and ")): change the declaration to drop it",
                details: [
                    "index": .string(name),
                    "origins": .array(remaining.map { .object(["kind": .string($0.kind.rawValue), "unique": .bool($0.unique)]) }),
                ]
            )
        }
        return registrations.filter { $0.name != name }
    }

    /// The view indexes a local-only db3's list asks the store for.
    static func entries(_ list: [Db3Index]) -> [RecordLogIndexEntry] {
        list.map { RecordLogIndexEntry(name: $0.name, model: $0.model, fields: $0.fields, unique: $0.unique) }
    }
}

extension Db3Index {
    /// An index as a local-only db3's list answers it (#5155).
    init(name: String, model: String, fields: [String], unique: Bool, members: Bool, origins: [Db3IndexOrigin]) {
        self.name = name
        self.model = model
        self.fields = fields
        self.unique = unique
        self.members = members
        self.origins = origins
    }
}
