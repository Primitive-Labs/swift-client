import Foundation

/// A typed local-only db3: one that lives only on this device and whose type
/// allows it (`[type] allowLocalOnly = true`). No room installs its type, so
/// its store holds the declarations the build carried when it was created
/// (install shape, as a room installs them) beside the derived forms the
/// device judge reads: per model each field's kind, the vector fields, the
/// enforced enums and the cleared names. Its writes are judged by them inside
/// the store transaction that commits them, and its constraints and index
/// list come from them. A port of js-bao's `local-type.ts` and the comparison
/// half of `typeInstall.ts`.
struct RecordLogLocalType: Equatable, Sendable {
    /// The type's name.
    var name: String
    /// The declarations' content hash.
    var hash: String
    /// The models in install shape: per model `fields` (each field's
    /// options), `constraints` (compound unique ones by name) and `cleared`
    /// (the sorted names it hides).
    var models: [String: JSONValue]

    init(name: String, hash: String, models: [String: JSONValue]) {
        self.name = name
        self.hash = hash
        self.models = models
    }

    /// A build's declarations for type `name`, or `nil` when their JSON is not an object.
    init?(name: String, declarations: PrimitiveDb3Types.LocalOnlyDeclarations) {
        guard let models = JSONValue(jsonText: declarations.modelsJSON)?.objectValue else { return nil }
        self.init(name: name, hash: declarations.hash, models: models)
    }

    /// Each model's field kinds (no `id`), vector encodings, enforced enums
    /// and hidden names, as the store's type state holds them for the judge.
    var derived: (
        kinds: [String: [String: String]], vectors: RecordLogVectorDeclarations, enums: RecordLogEnumDeclarations,
        cleared: RecordLogClearedDeclarations
    ) {
        var kinds: [String: [String: String]] = [:]
        var vectors: RecordLogVectorDeclarations = [:]
        var enums: RecordLogEnumDeclarations = [:]
        var cleared: RecordLogClearedDeclarations = [:]
        for (model, declaration) in models {
            var fieldKinds: [String: String] = [:]
            for (field, options) in recordLogLocalFields(declaration) {
                if field != "id", let kind = options["type"]?.stringValue { fieldKinds[field] = kind }
                if let encoding = recordLogLocalVectorEncoding(options) { vectors[model, default: [:]][field] = encoding }
                if let values = recordLogLocalEnforcedValues(field, options) { enums[model, default: [:]][field] = values }
            }
            kinds[model] = fieldKinds
            let hidden = recordLogLocalHidden(declaration)
            if !hidden.isEmpty { cleared[model] = hidden.sorted(by: recordLogCodeUnitOrder) }
        }
        return (kinds, vectors, enums, cleared)
    }
}

/// Code-unit order, as JavaScript sorts strings.
func recordLogCodeUnitOrder(_ a: String, _ b: String) -> Bool {
    Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16))
}

/// Whether `a` and `b` are the same declaration value code unit for code
/// unit, as JavaScript's `===` and js-bao's comparison read them: Swift's
/// `String` equality takes canonically equivalent strings (a precomposed
/// "é" and "e" with a combining accent) as equal, which would let a build
/// that swaps one enum value for its other form read as one that only adds.
/// Object keys compare as the dictionaries hold them.
func recordLogExactlyEqual(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (.string(let x)?, .string(let y)?): return x.utf16.elementsEqual(y.utf16)
    case (.array(let x)?, .array(let y)?): return x.count == y.count && zip(x, y).allSatisfy { recordLogExactlyEqual($0, $1) }
    case (.object(let x)?, .object(let y)?):
        return x.count == y.count && x.allSatisfy { key, value in y[key].map { recordLogExactlyEqual(value, $0) } ?? false }
    case (.some(let x), .some(let y)):
        if case .string = x { return false }
        if case .string = y { return false }
        return x == y
    default: return false
    }
}

/// An install-shape model's fields, each one's options.
func recordLogLocalFields(_ model: JSONValue?) -> [String: [String: JSONValue]] {
    (model?.objectValue?["fields"]?.objectValue ?? [:]).compactMapValues(\.objectValue)
}

/// An install-shape model's hidden (cleared and tombstoned) names.
func recordLogLocalHidden(_ model: JSONValue?) -> [String] {
    model?.objectValue?["cleared"]?.arrayValue?.compactMap(\.stringValue) ?? []
}

/// An install-shape model's compound unique constraints, by name.
func recordLogLocalConstraints(_ model: JSONValue?) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for (name, constraint) in model?.objectValue?["constraints"]?.objectValue ?? [:] {
        guard let object = constraint.objectValue, object["type"]?.stringValue == "unique",
              let fields = object["fields"]?.arrayValue?.compactMap(\.stringValue), !fields.isEmpty else { continue }
        out[name] = fields
    }
    return out
}

/// A field's vector encoding, when it is a well-formed vector field.
func recordLogLocalVectorEncoding(_ options: [String: JSONValue]) -> VectorEncoding? {
    guard options["type"]?.stringValue == "vector" else { return nil }
    return VectorEncoding(json: .object(["dims": options["dims"] ?? .null, "element": options["element"] ?? .null]))
}

/// The enforced values of a field, as the room reads them: a string field
/// with `enforceEnum` and a non-empty string `enum`.
func recordLogLocalEnforcedValues(_ field: String, _ options: [String: JSONValue]) -> [String]? {
    guard field != "id", options["enforceEnum"] == .bool(true), options["type"]?.stringValue == "string",
          let list = options["enum"]?.arrayValue, !list.isEmpty else { return nil }
    let values = list.compactMap(\.stringValue)
    return values.count == list.count ? values : nil
}

/// How a build's declarations relate to the installed ones: `same` hash (or
/// declarations that judge alike), `superset` when the build only adds,
/// `subset` when the installed ones only add to the build's (an older
/// build), `diverged` otherwise.
enum RecordLogDeclarationClass: String, Sendable, Equatable {
    case same
    case superset
    case subset
    case diverged
}

/// How a difference in one field option reads (js-bao's
/// `DB3_FIELD_OPTION_DIRECTIONS`): a key with no row compares as `changed`.
private let recordLogFieldOptionDirections: [String: String] = [
    "type": "type", "dims": "vector", "element": "vector", "required": "required", "indexed": "index", "unique": "index",
    "enum": "enum", "enforceEnum": "enforce", "default": "default", "autoAssign": "changed", "autoStamp": "changed",
    "maxLength": "changed", "maxCount": "changed", "deprecated": "ignored", "cleared": "ignored", "storedAs": "ignored",
    "description": "ignored", "class_name": "ignored",
]

/// The changes in one field's options from `a` to `b`, at most one per kind.
private func recordLogFieldChanges(_ path: String, _ a: [String: JSONValue], _ b: [String: JSONValue]) -> [(path: String, change: String)] {
    var kinds: [String] = []
    func add(_ kind: String) { if !kinds.contains(kind) { kinds.append(kind) } }
    for key in Set(a.keys).union(b.keys).sorted() {
        let before = a[key]
        let after = b[key]
        if recordLogExactlyEqual(before, after) { continue }
        switch recordLogFieldOptionDirections[key] ?? "changed" {
        case "ignored": break
        case "type": add("field-type-changed")
        case "vector": add("vector-changed")
        case "required": if after == .bool(true) { add("field-made-required") }
        case "index": if before == .bool(true) { add("index-dropped") }
        case "enforce": if before == .bool(true) { add("enum-enforcement-removed") }
        case "default": add("default-changed")
        case "enum":
            guard let now = after?.arrayValue else {
                add("enum-removed")
                break
            }
            guard let had = before?.arrayValue else { break }
            let removed = had.contains { value in !now.contains { recordLogExactlyEqual($0, value) } }
            let added = now.contains { value in !had.contains { recordLogExactlyEqual($0, value) } }
            if removed { add("enum-value-removed") } else if !added { add("field-option-changed") }
        default: add("field-option-changed")
        }
    }
    return kinds.map { (path, $0) }
}

/// Every change from `from` to `to` that is not an addition (js-bao's
/// `declarationChanges`). Additions are: a new model or field (unless
/// required in a model `from` declares), a name joining `cleared`, a new enum
/// value or an `enum` on a field that had none, `enforceEnum` turned on,
/// `indexed` or `unique` set, a new compound constraint, and dropping
/// `required`. The result is empty when `to` only adds to `from`.
func recordLogDeclarationChanges(_ from: [String: JSONValue], _ to: [String: JSONValue]) -> [(path: String, change: String)] {
    var out: [(path: String, change: String)] = []
    for (model, before) in from.sorted(by: { recordLogCodeUnitOrder($0.key, $1.key) }) {
        guard let after = to[model] else {
            out.append(("models.\(model)", "model-removed"))
            continue
        }
        let beforeFields = recordLogLocalFields(before)
        let afterFields = recordLogLocalFields(after)
        let hiddenAfter = Set(recordLogLocalHidden(after))
        let hiddenBefore = Set(recordLogLocalHidden(before))
        for name in hiddenBefore.sorted() where !hiddenAfter.contains(name) {
            out.append(("models.\(model).fields.\(name)", afterFields[name] != nil ? "field-uncleared" : "hidden-name-removed"))
        }
        for (field, options) in beforeFields.sorted(by: { $0.key < $1.key }) where !hiddenAfter.contains(field) {
            guard let next = afterFields[field] else {
                out.append(("models.\(model).fields.\(field)", "field-removed"))
                continue
            }
            out.append(contentsOf: recordLogFieldChanges("models.\(model).fields.\(field)", options, next))
        }
        for (field, options) in afterFields.sorted(by: { $0.key < $1.key })
        where beforeFields[field] == nil && !hiddenBefore.contains(field) && options["required"] == .bool(true) {
            out.append(("models.\(model).fields.\(field)", "required-field-added"))
        }
        let afterConstraints = recordLogLocalConstraints(after)
        for (name, fields) in recordLogLocalConstraints(before).sorted(by: { $0.key < $1.key }) {
            if let next = afterConstraints[name], recordLogExactlyEqual(.array(next.map { .string($0) }), .array(fields.map { .string($0) })) {
                continue
            }
            if afterConstraints[name] == nil && fields.contains(where: hiddenAfter.contains) { continue }
            out.append(("models.\(model).constraints.\(name)", "index-dropped"))
        }
    }
    return out
}

/// Classify `build` against the `installed` declarations (js-bao's
/// `classifyDeclarations`). Declarations that differ only in options no
/// rule reads are `same`; equal declarations under different hashes are `diverged`.
func recordLogClassifyDeclarations(
    installed: (hash: String, models: [String: JSONValue]), build: RecordLogLocalType
) -> RecordLogDeclarationClass {
    if installed.hash == build.hash { return .same }
    let forward = recordLogDeclarationChanges(installed.models, build.models).isEmpty
    let backward = recordLogDeclarationChanges(build.models, installed.models).isEmpty
    if forward && !backward { return .superset }
    if backward && !forward { return .subset }
    if forward && backward && !recordLogExactlyEqual(.object(installed.models), .object(build.models)) { return .same }
    return .diverged
}

/// The installed declarations as models the local-only constraint and index
/// rules read (``RecordLogLocalOnly``): each model's fields with their kind,
/// `indexed` and `unique`, a vector's encoding, and its compound unique
/// constraints, so a typed local-only db3's constraints and indexes carry
/// the room's names.
func recordLogLocalSchemas(_ models: [String: JSONValue]) -> [PrimitiveSchema] {
    models.keys.sorted().map { model in
        var fields: [String: FieldDescriptor] = [:]
        for (field, options) in recordLogLocalFields(models[model]) {
            let type = options["type"]?.stringValue.flatMap(PrimitiveFieldType.init(rawValue:)) ?? .string
            let encoding = recordLogLocalVectorEncoding(options)
            fields[field] = FieldDescriptor(
                type: type, indexed: options["indexed"] == .bool(true), unique: options["unique"] == .bool(true),
                dims: encoding?.dims, element: encoding?.element
            )
        }
        var constraints: [String: ConstraintDescriptor] = [:]
        for (name, names) in recordLogLocalConstraints(models[model]) { constraints[name] = ConstraintDescriptor(name: name, fields: names) }
        return PrimitiveSchema(name: model, fields: fields, constraints: constraints)
    }
}

/// `mutations` without the names their model's installed declarations hide
/// (cleared and tombstoned), as the room strips them before judging.
func recordLogWithoutHiddenNames(_ mutations: [RecordLogMutation], _ models: [String: JSONValue]) -> [RecordLogMutation] {
    mutations.map { mutation in
        let hidden = recordLogLocalHidden(models[mutation.model])
        guard !hidden.isEmpty else { return mutation }
        var out = mutation
        for name in hidden {
            out.fields?[name] = nil
            out.stringSetDeltas?[name] = nil
        }
        return out
    }
}

/// What a store did with a build's declarations for a typed local-only copy:
/// nothing to do (`same`, an older build's `subset`, a `diverged` build, or
/// not a typed local-only copy), `installed` (from the hash held before,
/// `nil` when it could not be read), or `refused` (the record check found
/// `reasons`; nothing written).
enum RecordLogLocalTypeInstall: Equatable, Sendable {
    case same
    case subset
    case diverged
    case untyped
    case installed(from: String?)
    case refused(reasons: [Db3TypeRefusalReason], unreadable: Bool)
}

/// A typed local-only copy's type as its store holds it: whether it is
/// typed, whether its declarations can be read, and when they can, the
/// name, hash, install-shape models and the judge's form of them.
struct RecordLogHeldLocalType: Equatable, Sendable {
    var typed: Bool
    var unreadable: Bool
    var name: String?
    var hash: String?
    var local: [String: JSONValue]?
    var declared: RecordLogDeclaredType?
}

/// The standing of a typed local-only copy with this build, as
/// `client.db3.state(id).error` reports it.
enum RecordLogLocalTypeStanding {
    static func unreadable(_ docId: String) -> Db3StateError {
        Db3StateError(
            code: JsBaoErrorCode.db3TypeRefused.rawValue,
            message: "the db3 '\(docId)' lives only on this device and its type's declarations cannot be read, so its writes are refused; "
                + "a build that declares its type recovers them when it opens the db3"
        )
    }

    static func diverged(_ docId: String, type: String) -> Db3StateError {
        Db3StateError(
            code: JsBaoErrorCode.db3TypeRefused.rawValue,
            message: "the db3 '\(docId)' holds declarations of type '\(type)' that this build's neither contain nor extend, so this build's "
                + "writes are refused; a build whose declarations contain both writes it"
        )
    }

    static func refused(_ docId: String, type: String, reasons: [Db3TypeRefusalReason], unreadable: Bool) -> Db3StateError {
        Db3StateError(
            code: JsBaoErrorCode.db3TypeRefused.rawValue,
            message: "the db3 '\(docId)' holds records this build's declarations of type '\(type)' do not take, so they were not installed"
                + (unreadable ? " and its writes stay refused" : "; its writes are judged by the declarations it holds")
                + ": " + reasons.map { "\($0.path) \($0.reason)" }.joined(separator: "; "),
            reasons: reasons
        )
    }
}
