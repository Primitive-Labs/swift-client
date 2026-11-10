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
//   (`idx_named_<model>_<name>`, or the field's shared index), or a string-set
//   field's member index (`idx_members_<model>_<field>`, #5156), a model's
//   text index (`idx_text_<model>`, #5223), or a vector field's vector index
//   (`idx_vec_<model>_<field>`, #5230).
// - Every index is on the device (#5220): each lists its kind and `on:
//   .device`, and a registration placed `.server` or `.both` is refused
//   `DB3_LOCAL_ONLY`.
enum RecordLogLocalOnly {

    /// The room's name of a declared field's shared index.
    static func fieldIndexName(model: String, field: String) -> String {
        "idx_records_\(model.lowercased())_\(field.lowercased())"
    }

    /// The room's name of an index registered under `name`.
    static func namedIndexName(model: String, name: String) -> String {
        "idx_named_\(model.lowercased())_\(name.lowercased())"
    }

    /// The room's name of a member index (#5156): `idx_members_<model>_<field>`
    /// lowercased, then `_2`, `_3`, … while an index of `taken` holds the name.
    private static func memberIndexName(model: String, field: String, taken: [String]) -> String {
        let held = Set(taken.map { $0.lowercased() })
        let base = "idx_members_\(model)_\(field)".lowercased()
        if !held.contains(base) { return base }
        var n = 2
        while held.contains("\(base)_\(n)") { n += 1 }
        return "\(base)_\(n)"
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
        var members = false
        var origins: [Db3IndexOrigin]
        /// A text index's options (#5223); `nil` for any other kind.
        var text: RecordLogTextIndexOptions?
        /// A vector index's options with its field's encoding (#5230); `nil` for any other kind.
        var vector: RecordLogVectorOptions?

        var kind: Db3IndexKind { vector != nil ? .vector : text != nil ? .text : members ? .members : .scalar }

        var index: Db3Index {
            Db3Index(
                name: name, model: model, fields: fields, unique: unique, members: members, origins: origins,
                kind: kind, on: .device,
                text: text.map { Db3TextIndex(tokenizer: $0.tokenizer, prefix: $0.prefix, weights: $0.weights) },
                vector: vector.map(RecordLogLocalOnly.listed)
            )
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
    /// same fields, or as an index of its own. A member registration is listed
    /// with `members` and its named origin alone, in place of any index a
    /// declaration would keep over its field, as the room keeps no declaration
    /// origin on a member index. A text registration is listed beside any
    /// index over the same fields (#5223). Sorted by name, as the room lists
    /// its registry.
    static func indexList(_ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex]) -> [Db3Index] {
        listings(schemas, registrations).map(\.index)
    }

    private static func listings(_ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex]) -> [Listing] {
        var byDefinition = RecordLogOrderedMap<[String], Listing>()
        for listing in declarationIndexes(schemas) { byDefinition[[listing.model] + listing.fields] = listing }
        for registration in registrations {
            let key = [registration.model] + registration.fields
            let origin = Db3IndexOrigin(kind: .named, unique: registration.unique)
            if registration.kind == .vector, let vector = registration.vector {
                // A vector index stands beside any index over its field, keyed apart as a text index is.
                byDefinition[["\u{0}vector"] + key] = Listing(
                    name: registration.name, model: registration.model, fields: registration.fields, unique: false,
                    origins: [Db3IndexOrigin(kind: .named, unique: false)], vector: vector
                )
                continue
            }
            if registration.kind == .text {
                byDefinition[["\u{0}text"] + key] = Listing(
                    name: registration.name, model: registration.model, fields: registration.fields, unique: false,
                    origins: [Db3IndexOrigin(kind: .named, unique: false)],
                    text: registration.text ?? RecordLogTextIndexOptions(
                        tokenizer: .unicode61, prefix: [], weights: Dictionary(uniqueKeysWithValues: registration.fields.map { ($0, 1) })
                    )
                )
                continue
            }
            if registration.members {
                byDefinition[key] = Listing(
                    name: registration.name, model: registration.model, fields: registration.fields, unique: false, members: true,
                    origins: [Db3IndexOrigin(kind: .named, unique: false)]
                )
                continue
            }
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

    /// A registration as the room checks it: `{ model, field | fields, kind?, on?,
    /// unique?, name? }`, or a member index's `{ model, field, members: true }` /
    /// `{ model, field, kind: .members }`.
    struct Registration: Equatable {
        var model: String
        var fields: [String]
        var unique: Bool
        var name: String?
        /// A member index on the one field (#5156).
        var members = false
        /// What the index is (#5220).
        var kind: Db3IndexKind = .scalar
        /// A text index's options, filled in (#5223).
        var text: RecordLogTextIndexOptions?
        /// A vector index's options as sent (#5230), checked against the field's declaration when it is registered.
        var vector: Db3VectorIndexOptions?
    }

    private static func invalid(_ message: String) -> JsBaoError {
        JsBaoError(code: .db3IndexInvalid, message: message)
    }

    /// A registration checked by the room's rules, in the room's order (#5220):
    /// its shape, `DB3_INDEX_INVALID` naming what is wrong (a member or text
    /// index takes no `unique` or `name`, a member index no `fields`;
    /// `members: true` is `kind: .members`; `text` options go with `kind:
    /// .text` only, and are checked and filled in, #5223); then `on: .server`
    /// or `.both` `DB3_LOCAL_ONLY` (`details.on`), as every index of a
    /// local-only db3 lives on the device. A vector index covers one field
    /// and its options' `nbucket` and `codesize` are positive and at most
    /// ``RecordLogVectorOptions/maxCount`` (#5230). A
    /// unique index is allowed: the device enforces it.
    static func parse(_ body: Db3IndexRegistration) throws -> Registration {
        guard RecordLogSchema.isValidIdentifier(body.model) else {
            throw invalid("model must be an identifier (letters, digits and _, not starting with a digit)")
        }
        if body.members == true, let kind = body.kind, kind != .members {
            throw invalid("members: true is kind: \"members\": give kind: \"\(kind.rawValue)\" without members, or kind: \"members\"")
        }
        let kind = body.kind ?? (body.members == true ? .members : .scalar)
        if kind != .scalar && (body.unique != nil || body.name != nil) {
            throw invalid("unique and name apply to a scalar index only: a \(kind.rawValue) index takes neither")
        }
        if body.text != nil && kind != .text { throw invalid("text options apply to kind: \"text\" only") }
        if kind != .vector && body.vector != nil {
            throw invalid("vector options apply to a vector index only: give kind: \"vector\", or leave vector out")
        }
        if kind == .members && body.fields != nil {
            throw invalid("A member index is { model, field, kind: \"members\" }: it covers one field and takes no fields")
        }
        if kind == .vector {
            if case .ann(let nbucket, let codesize, _)? = body.vector?.index {
                // Past JavaScript's safe integers the device could neither list the count exactly nor multiply it.
                let counts = 1...RecordLogVectorOptions.maxCount
                if let nbucket, !counts.contains(nbucket) {
                    throw invalid(nbucket < 1 ? "vector.index.nbucket must be a positive integer" : "vector.index.nbucket must be at most \(counts.upperBound)")
                }
                if let codesize, !counts.contains(codesize) {
                    throw invalid(codesize < 1 ? "vector.index.codesize must be a positive integer" : "vector.index.codesize must be at most \(counts.upperBound)")
                }
            }
            if let fields = body.fields, fields.count != 1 {
                throw invalid("A vector index is { model, field, kind: \"vector\" }: it covers one vector field")
            }
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
        if kind == .scalar && fields.count > 1 && (body.name == nil || !unique) {
            throw invalid("An index over several fields is a unique constraint: give it a name and unique: true")
        }
        let text = kind == .text ? try RecordLogTextIndexOptions.parse(fields: fields, raw: body.text?.json) : nil
        if let on = body.on, on != .device {
            throw JsBaoError(
                code: .db3LocalOnly,
                message: "The db3 lives only on this device, so its indexes are on the device: register it with on: .device, or leave on out",
                details: ["on": .string(on.rawValue)]
            )
        }
        return Registration(
            model: body.model, fields: fields, unique: unique, name: body.name, members: kind == .members, kind: kind, text: text,
            vector: kind == .vector ? (body.vector ?? Db3VectorIndexOptions()) : nil
        )
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
    /// (`registerIndex`): a definition a member index holds is
    /// `DB3_INDEX_EXISTS`; a field declared a string set takes no index of its
    /// own value (`DB3_INDEX_SET_FIELD`, pointing at `members: true`); a
    /// `name` another registration of the model holds over other fields is
    /// `DB3_INDEX_NAME_TAKEN`; a `name` on a definition already indexed under
    /// another is `DB3_INDEX_EXISTS`. A definition already listed gets the
    /// named origin; otherwise the registration is an index of its own.
    /// Records sharing a unique key are the store's to refuse, as it writes
    /// the registration. `members: true` registers a member index instead
    /// (``registerMembers(_:_:_:)``).
    ///
    /// - Returns: The registrations as they now are, and the index as the list now shows it.
    static func register(
        _ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex], _ body: Db3IndexRegistration
    ) throws -> (registrations: [RecordLogLocalIndex], index: Db3Index) {
        let parsed = try parse(body)
        if parsed.members { return try registerMembers(schemas, registrations, parsed) }
        if parsed.kind == .text { return try registerText(schemas, registrations, parsed) }
        if parsed.kind == .vector { return try registerVector(schemas, registrations, parsed) }
        let list = listings(schemas, registrations).filter { $0.kind != .text && $0.kind != .vector }
        let existing = list.first { $0.model == parsed.model && $0.fields == parsed.fields }
        // The field's member index is named before its kind is judged, so the
        // refusal says which registration holds it.
        if let existing, existing.members {
            throw JsBaoError(
                code: .db3IndexExists,
                message: "\(existing.name) is a member index on \(parsed.model).\(parsed.fields[0]): drop it first",
                details: ["index": .string(existing.name)]
            )
        }
        let schema = schemas.first { $0.name == parsed.model }
        for field in parsed.fields where isSetField(schema, field) {
            throw JsBaoError(
                code: .db3IndexSetField,
                message: "\(parsed.model).\(field) is a string set, and a set field takes no index of its own value: "
                    + "register it with members: true to index its members",
                details: ["field": .string(field)]
            )
        }
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
        let next = registrations.filter { !($0.model == parsed.model && $0.fields == parsed.fields && $0.kind != .text) } + [registration]
        guard let index = indexList(schemas, next).first(where: { $0.name == indexName }) else {
            throw invalid("The registration names no index")
        }
        return (next, index)
    }

    /// Register a member index on a local-only db3 (#5156), by the room's
    /// rules (`registerMemberIndex`), in the room's order: the registration
    /// the field holds answers first, its member index again (registrations
    /// unchanged) whatever the field's declaration has become since, a scalar
    /// index (declared or registered) `DB3_INDEX_EXISTS`; only then is a field
    /// declared with another type than `stringset` `DB3_INDEX_NOT_SET_FIELD`.
    /// A field no model declares may be opted in. The registration is never
    /// unique, has no developer name, and adds no constraint.
    private static func registerMembers(
        _ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex], _ parsed: Registration
    ) throws -> (registrations: [RecordLogLocalIndex], index: Db3Index) {
        let field = parsed.fields[0]
        let list = listings(schemas, registrations)
        if let existing = list.first(where: { $0.model == parsed.model && $0.fields == [field] && $0.kind != .text }) {
            if existing.members { return (registrations, existing.index) }
            throw JsBaoError(
                code: .db3IndexExists,
                message: "\(existing.name) already indexes \(parsed.model) on \(field): drop it before registering a member index",
                details: ["index": .string(existing.name)]
            )
        }
        if let declared = schemas.first(where: { $0.name == parsed.model })?.fields[field], declared.type != .stringset {
            throw JsBaoError(
                code: .db3IndexNotSetField,
                message: "\(parsed.model).\(field) is not a string set: a member index is for a string-set field; "
                    + "register a field index without members",
                details: ["field": .string(field)]
            )
        }
        let name = memberIndexName(model: parsed.model, field: field, taken: list.map(\.name) + registrations.map(\.name))
        let next = registrations + [RecordLogLocalIndex(name: name, model: parsed.model, fields: [field], unique: false, members: true)]
        guard let index = indexList(schemas, next).first(where: { $0.name == name }) else {
            throw invalid("The registration names no index")
        }
        return (next, index)
    }

    /// Register a text index on a local-only db3 (#5223), by the room's rules
    /// (js-bao's `registerTextIndex`): one per model, so a text index of the
    /// model over other fields is `DB3_INDEX_EXISTS` (`details.index`), and the
    /// same fields again answer the index as it is. Its name is
    /// `idx_text_<model>` lowercased, `_2`, `_3`, … while another index holds
    /// it without case; it is never unique, has no developer name, and adds
    /// no constraint.
    private static func registerText(
        _ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex], _ parsed: Registration
    ) throws -> (registrations: [RecordLogLocalIndex], index: Db3Index) {
        let list = listings(schemas, registrations)
        if let held = list.first(where: { $0.kind == .text && $0.model == parsed.model }) {
            guard held.fields == parsed.fields else {
                throw JsBaoError(
                    code: .db3IndexExists,
                    message: "\(parsed.model) already has a text index, \(held.name), on \(held.fields.joined(separator: ", ")): "
                        + "a model has one text index, so drop it before registering another",
                    details: ["index": .string(held.name)]
                )
            }
            return (registrations, held.index)
        }
        let taken = Set((list.map(\.name) + registrations.map(\.name)).map { $0.lowercased() })
        let base = RecordLogTextIndexOptions.indexName(parsed.model)
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base)_\(n)"
            n += 1
        }
        let next = registrations + [RecordLogLocalIndex(
            name: name, model: parsed.model, fields: parsed.fields, unique: false, kind: .text, text: parsed.text
        )]
        guard let index = indexList(schemas, next).first(where: { $0.name == name }) else {
            throw invalid("The registration names no index")
        }
        return (next, index)
    }

    /// Register a vector index on a local-only db3 (#5230), by js-bao's rules
    /// (`registerVectorIndex`): one per vector field, so the field's again
    /// answers the index as it is; a field the model's registered schema does
    /// not declare `type: vector` with its encoding is `DB3_INDEX_INVALID`.
    /// Its name is `idx_vec_<model>_<field>` lowercased, `_2`, `_3`, … while
    /// another index holds it without case; its options are listed filled in
    /// (`cos`, `exact`) with the field's encoding.
    private static func registerVector(
        _ schemas: [PrimitiveSchema], _ registrations: [RecordLogLocalIndex], _ parsed: Registration
    ) throws -> (registrations: [RecordLogLocalIndex], index: Db3Index) {
        let field = parsed.fields[0]
        let list = listings(schemas, registrations)
        if let held = list.first(where: { $0.kind == .vector && $0.model == parsed.model && $0.fields == [field] }) {
            return (registrations, held.index)
        }
        let declared = schemas.first { $0.name == parsed.model }?.fields[field]
        guard let declared, declared.type == .vector, let encoding = declared.vectorEncoding else {
            throw invalid(
                "\(parsed.model).\(field) is not a vector field: a vector index covers a field the model's declaration gives type \"vector\", dims and element"
            )
        }
        let options = parsed.vector ?? Db3VectorIndexOptions()
        let index: RecordLogVectorOptions.Index
        switch options.index ?? .exact {
        case .exact: index = .exact
        case .ann(let nbucket, let codesize, let quantizer): index = .ann(nbucket: nbucket, codesize: codesize, quantizer: quantizer?.rawValue)
        }
        let vector = RecordLogVectorOptions(distance: options.distance?.rawValue ?? "cos", index: index, dims: encoding.dims, element: encoding.element)
        let taken = Set((list.map(\.name) + registrations.map(\.name)).map { $0.lowercased() })
        let base = "idx_vec_\(parsed.model)_\(field)".lowercased()
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base)_\(n)"
            n += 1
        }
        let next = registrations + [RecordLogLocalIndex(name: name, model: parsed.model, fields: [field], unique: false, kind: .vector, vector: vector)]
        guard let index = indexList(schemas, next).first(where: { $0.name == name }) else {
            throw invalid("The registration names no index")
        }
        return (next, index)
    }

    /// A vector index's options as a listing answers them.
    static func listed(_ vector: RecordLogVectorOptions) -> Db3VectorIndex {
        let index: Db3VectorIndexOptions.Mode
        switch vector.index {
        case .exact: index = .exact
        case .ann(let nbucket, let codesize, let quantizer):
            index = .ann(nbucket: nbucket, codesize: codesize, quantizer: quantizer.flatMap(Db3VectorIndexOptions.Quantizer.init(rawValue:)))
        }
        return Db3VectorIndex(distance: Db3VectorIndexOptions.Distance(rawValue: vector.distance) ?? .cos, index: index, dims: vector.dims, element: vector.element)
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

    /// The view, member, text and vector indexes a local-only db3's list asks the store for.
    static func entries(_ list: [Db3Index]) -> [RecordLogIndexEntry] {
        list.map {
            RecordLogIndexEntry(
                name: $0.name, model: $0.model, fields: $0.fields, unique: $0.unique, members: $0.members, kind: $0.kind, on: .device,
                text: $0.text.map { text in
                    .object([
                        "tokenizer": .string(text.tokenizer.rawValue), "prefix": .array(text.prefix.map { .number(Double($0)) }),
                        "weights": .object(text.weights.mapValues { .number($0) }),
                    ])
                },
                vector: $0.vector.map(entryOptions)
            )
        }
    }

    /// A listed vector index's options as the store's entry reads them.
    private static func entryOptions(_ vector: Db3VectorIndex) -> JSONValue {
        let index: JSONValue
        switch vector.index {
        case .exact: index = "exact"
        case .ann(let nbucket, let codesize, let quantizer):
            var object: [String: JSONValue] = ["mode": "ann"]
            if let nbucket { object["nbucket"] = .number(Double(nbucket)) }
            if let codesize { object["codesize"] = .number(Double(codesize)) }
            if let quantizer { object["quantizer"] = .string(quantizer.rawValue) }
            index = .object(object)
        }
        var object: [String: JSONValue] = ["distance": .string(vector.distance.rawValue), "index": index]
        if let dims = vector.dims { object["dims"] = .number(Double(dims)) }
        if let element = vector.element { object["element"] = .string(element.rawValue) }
        return .object(object)
    }
}

extension Db3IndexRegistration {
    /// A registration with every key as given, as a decoded body can carry
    /// it: what the room's `DB3_INDEX_INVALID` checks judge, since the public
    /// initializers build valid shapes only.
    init(
        model: String, field: String?, fields: [String]?, unique: Bool?, name: String?, members: Bool?, kind: Db3IndexKind? = nil,
        on: Db3IndexPlacement? = nil, text: Db3TextIndexOptions? = nil, vector: Db3VectorIndexOptions? = nil
    ) {
        self.model = model
        self.field = field
        self.fields = fields
        self.unique = unique
        self.name = name
        self.members = members
        self.kind = kind
        self.on = on
        self.text = text
        self.vector = vector
    }
}

extension Db3Index {
    /// An index as a local-only db3's list answers it (#5155), on the device (#5220).
    init(
        name: String, model: String, fields: [String], unique: Bool, members: Bool, origins: [Db3IndexOrigin], kind: Db3IndexKind,
        on: Db3IndexPlacement, text: Db3TextIndex? = nil, vector: Db3VectorIndex? = nil
    ) {
        self.name = name
        self.model = model
        self.fields = fields
        self.unique = unique
        self.members = members
        self.origins = origins
        self.kind = kind
        self.on = on
        self.text = text
        self.vector = vector
        // A db3 that lives only on this device has one generation of each index, and no shared model.
        self.generation = nil
        self.revision = nil
        self.annModel = nil
    }
}
