import Foundation

struct EmitOptions {
    /// Access level applied to the generated struct, its members, and
    /// init signatures. Default is `public` so that app code can write
    /// `public extension TodoItem { ... }` (the shape the agent guide
    /// shows) without hitting the "public modifier cannot be used in
    /// extensions that declare members on an internal type" diagnostic.
    /// Override to `"internal"` for embedded-in-module use.
    var accessLevel: String = "public"

    /// The module that exports `PrimitiveModel`, `PrimitiveSchema`,
    /// `PrimitiveValue`, etc. Almost always `JsBaoClient`.
    var moduleImport: String = "JsBaoClient"

    /// Source file path written into the generated header comment so
    /// readers can find the TOML quickly. Pass an empty string to omit.
    var sourcePath: String = "schema.toml"

    /// Map from TOML model name → resolved Swift type name, across every
    /// model in the schema. Relationship accessors use it to name their
    /// typed return types (`task` → `TaskRecord?`). Empty for a single
    /// model with no relationships; the emitter falls back to the
    /// default-suffix rule for any name it can't find (so an emit driven
    /// straight off one `ParsedSchema` still produces something sane).
    var swiftNamesByModel: [String: String] = [:]
}

/// Emit one Swift source file per `ParsedSchema`. The generator never
/// loads or executes Swift — it's a string-template pass — so the build
/// tool plugin doesn't need a Swift toolchain beyond what's already
/// running the compile step.
struct SwiftEmitter {
    let options: EmitOptions

    init(options: EmitOptions) {
        self.options = options
    }

    func emit(schema: ParsedSchema) -> String {
        var src = ""
        src += header(schema: schema)
        src += "import Foundation\n"
        src += "import \(options.moduleImport)\n\n"
        src += structDecl(schema: schema)
        src += "\n"
        src += crossDocumentFacade(schema: schema)
        return src
    }

    // MARK: - Model facade (the one app-facing API per model)

    /// Emit the `Model.*` facade — the single app-facing surface for a
    /// model, mirroring the JS client's one-class design. Reads are statics
    /// that span every open document by default (scope with
    /// `options.documents`); writes are instance `save(in:)` / `delete(in:)`
    /// targeting one document (matching JS's instance writes). All delegate
    /// to the configured default
    /// `JsBaoClient`'s shared store (`JsBaoClient.configureDefault`). The
    /// per-doc / cross-doc plumbing (`TypedModel`, `MultiDocModel`) stays
    /// internal — app code only ever uses this facade.
    private func crossDocumentFacade(schema: ParsedSchema) -> String {
        let typeName = schema.swiftName
        let access = options.accessLevel
        var out = ""
        out += "/// The app-facing API for `\(typeName)` — one model, like the JS client.\n"
        out += "/// Reads span every open document by default (scope to specific docs with\n"
        out += "/// `options: QueryOptions(documents: [docId])`); `save(in:)` / `delete(in:)`\n"
        out += "/// target one document and throw if it isn't open. Backed by the configured\n"
        out += "/// default `JsBaoClient` (see `JsBaoClient.configureDefault`).\n"
        out += "\(access) extension \(typeName) {\n"
        out += "    // MARK: Reads (cross-document by default)\n\n"
        out += "    /// Query across all open documents. Rows that fail to decode (schema\n"
        out += "    /// drift) are skipped. Scope to one/some docs via `options.documents`.\n"
        out += "    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) -> [\(typeName)] {\n"
        out += "        JsBaoClient.requireDefault()\n"
        out += "            .queryShared(primitiveSchema, filter: filter, options: options)\n"
        out += "            .compactMap { \(typeName)(row: $0) }\n"
        out += "    }\n\n"
        out += "    /// Paginated query across all open documents. Returns the page's\n"
        out += "    /// rows plus `nextCursor`/`prevCursor`/`hasMore` — round-trip\n"
        out += "    /// `nextCursor` via `options.cursor` to page. Mirrors JS\n"
        out += "    /// `BaseModel.query()`'s `{ data, nextCursor, hasMore }` shape.\n"
        out += "    static func queryPaged(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PagedQueryResult<\(typeName)> {\n"
        out += "        let page = try JsBaoClient.requireDefault()\n"
        out += "            .queryPagedShared(primitiveSchema, filter: filter, options: options)\n"
        out += "        return PagedQueryResult(\n"
        out += "            data: page.data.compactMap { \(typeName)(row: $0) },\n"
        out += "            nextCursor: page.nextCursor,\n"
        out += "            prevCursor: page.prevCursor,\n"
        out += "            hasMore: page.hasMore\n"
        out += "        )\n"
        out += "    }\n\n"
        out += "    /// Count across all open documents.\n"
        out += "    static func count(_ filter: DocumentFilter? = nil) -> Int {\n"
        out += "        JsBaoClient.requireDefault().countShared(primitiveSchema, filter: filter)\n"
        out += "    }\n\n"
        out += "    /// Every record across all open documents.\n"
        out += "    static func findAll() -> [\(typeName)] {\n"
        out += "        query(nil, options: nil)\n"
        out += "    }\n\n"
        out += "    /// First record with `id` across all open documents, or `nil`.\n"
        out += "    static func find(_ id: String) -> \(typeName)? {\n"
        out += "        JsBaoClient.requireDefault().findShared(primitiveSchema, id: id).flatMap { \(typeName)(row: $0) }\n"
        out += "    }\n\n"
        out += "    /// First record matching a unique `constraint` and `value`,\n"
        out += "    /// across all open documents, or `nil`. First-match-wins in\n"
        out += "    /// document connect order (uniqueness is per-document, so the\n"
        out += "    /// same value may exist in more than one open doc). Mirrors the\n"
        out += "    /// JS client's `Model.findByUnique(constraintName, value)`.\n"
        out += "    static func findByUnique(_ constraint: String, _ value: PrimitiveValue) throws -> \(typeName)? {\n"
        out += "        try JsBaoClient.requireDefault()\n"
        out += "            .findByUniqueShared(primitiveSchema, constraint: constraint, value: value)\n"
        out += "            .flatMap { \(typeName)(row: $0) }\n"
        out += "    }\n\n"
        out += "    /// The first record matching `filter` across all open documents,\n"
        out += "    /// or `nil`. Equivalent to `query(filter, options).first` — mirrors\n"
        out += "    /// the JS client's `Model.queryOne(filter, options)`.\n"
        out += "    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) -> \(typeName)? {\n"
        out += "        JsBaoClient.requireDefault()\n"
        out += "            .queryOneShared(primitiveSchema, filter: filter, options: options)\n"
        out += "            .flatMap { \(typeName)(row: $0) }\n"
        out += "    }\n\n"
        out += "    /// Fire `callback` after any add/update/delete in any open document's\n"
        out += "    /// copy of this model (local or remote). Returns an unsubscribe closure.\n"
        out += "    @discardableResult\n"
        out += "    static func subscribe(_ callback: @escaping () -> Void) -> () -> Void {\n"
        out += "        JsBaoClient.requireDefault().subscribeShared(primitiveSchema, callback)\n"
        out += "    }\n\n"
        out += "    /// Aggregate (group / count / sum / avg / …) across all open documents.\n"
        out += "    static func aggregate(_ options: AggregateOptions) -> [[String: Any]] {\n"
        out += "        JsBaoClient.requireDefault().aggregateShared(primitiveSchema, options: options)\n"
        out += "    }\n\n"
        out += "    // MARK: Writes (target one document; throw if it isn't open)\n\n"
        out += "    /// Persist this record to document `documentId` — inserts it if it\n"
        out += "    /// doesn't exist yet, updates it in place if it does. One call for\n"
        out += "    /// both, matching the JS client's `save()`. Throws if the doc isn't\n"
        out += "    /// open. Returns `self` so you can `let saved = try note.save(in:)`.\n"
        out += "    @discardableResult\n"
        out += "    func save(in documentId: String) throws -> \(typeName) {\n"
        out += "        try JsBaoClient.requireDefault().saveShared(Self.primitiveSchema, id: id, values: primitiveValues(), in: documentId)\n"
        out += "        return self\n"
        out += "    }\n\n"
        out += "    /// Insert-or-update this record in `documentId`, matched by the\n"
        out += "    /// single-field unique constraint on `upsertOn` rather than `id` —\n"
        out += "    /// if a record already holds this row's `upsertOn` value, that\n"
        out += "    /// record is merged into (and keeps its id); otherwise a new\n"
        out += "    /// record is inserted. Mirrors the JS client's\n"
        out += "    /// `save({ upsertOn: field })`. Throws if the doc isn't open, if\n"
        out += "    /// `upsertOn` has no single-field unique constraint, or if the\n"
        out += "    /// `upsertOn` value is absent/empty. Returns `self`.\n"
        out += "    @discardableResult\n"
        out += "    func save(in documentId: String, upsertOn: String) throws -> \(typeName) {\n"
        out += "        try JsBaoClient.requireDefault().upsertShared(Self.primitiveSchema, id: id, values: primitiveValues(), on: upsertOn, in: documentId)\n"
        out += "        return self\n"
        out += "    }\n\n"
        out += "    /// Delete this record from document `documentId`. Throws if the doc isn't open.\n"
        out += "    func delete(in documentId: String) throws {\n"
        out += "        try JsBaoClient.requireDefault().deleteShared(Self.primitiveSchema, id: id, in: documentId)\n"
        out += "    }\n"
        out += "}\n"
        return out
    }

    // MARK: - Registration barrel

    /// Stable filename for the registration barrel. Distinct enough from a
    /// model name to avoid colliding with a `[models.generatedModels]` —
    /// and the driver guards against that collision explicitly.
    static let barrelFileName = "GeneratedModels.swift"

    /// Emit a single barrel file that aggregates every generated model so
    /// an app can register them all in one call. Mirrors the JS codegen's
    /// `index.ts` (#995): there the barrel re-exports + self-registers on
    /// import; Swift has no import-time side effects, so the barrel instead
    /// exposes `GeneratedModels.all` (the `[any PrimitiveModel.Type]`
    /// aggregate) plus a `register(on:)` convenience over
    /// `JsBaoClient.registerModels`.
    ///
    /// `schemas` is the full model set in TOML declaration order; the
    /// emitted array preserves it so the file is byte-stable across runs.
    func emitBarrel(schemas: [ParsedSchema]) -> String {
        let access = options.accessLevel
        var src = ""
        src += "// Generated by swift-bao-codegen — DO NOT EDIT.\n"
        if !options.sourcePath.isEmpty {
            src += "// Source: \(options.sourcePath) (registration barrel)\n"
        } else {
            src += "// Registration barrel\n"
        }
        src += "\n"
        src += "import Foundation\n"
        src += "import \(options.moduleImport)\n\n"
        src += "/// Aggregates every model generated from the schema so an app can\n"
        src += "/// register them in one call. Mirrors the JS codegen's `index.ts`\n"
        src += "/// barrel (\\`allModels\\` + auto-registration).\n"
        src += "\(access) enum GeneratedModels {\n"
        src += "    /// Every generated model type, in TOML declaration order.\n"
        src += "    \(access) static let all: [any PrimitiveModel.Type] = [\n"
        for schema in schemas {
            src += "        \(schema.swiftName).self,\n"
        }
        src += "    ]\n\n"
        src += "    /// The set of model names the TOML declared at codegen time,\n"
        src += "    /// in TOML declaration order. The source of truth for the\n"
        src += "    /// `register(on:)` self-check below — mirrors the JS barrel,\n"
        src += "    /// which re-loads the bundled TOML at import time and asserts\n"
        src += "    /// the generated set matches.\n"
        src += "    \(access) static let modelNames: [String] = [\n"
        for schema in schemas {
            src += "        \(quoted(schema.name)),\n"
        }
        src += "    ]\n\n"
        src += "    /// Register every generated model with a client in one call —\n"
        src += "    /// equivalent to `client.registerModels(GeneratedModels.all)`.\n"
        src += "    ///\n"
        src += "    /// Fails loud (a `precondition`) if the generated/registered\n"
        src += "    /// model set has drifted from the TOML model set baked in at\n"
        src += "    /// codegen time — i.e. someone hand-edited this barrel, or a\n"
        src += "    /// model's `class_name` / `modelName` no longer round-trips.\n"
        src += "    /// Mirrors the JS barrel's import-time assertion (#995): both a\n"
        src += "    /// generated model with no matching TOML entry, and a TOML entry\n"
        src += "    /// with no generated model, are surfaced — there, by throwing on\n"
        src += "    /// import; here, by a precondition in `register(on:)`.\n"
        src += "    \(access) static func register(on client: JsBaoClient) {\n"
        src += "        let registered = all.map { $0.primitiveSchema.name }\n"
        src += "        let expected = Set(modelNames)\n"
        src += "        let got = Set(registered)\n"
        src += "        precondition(\n"
        src += "            expected == got,\n"
        src += "            \"GeneratedModels is out of sync with the schema TOML. \"\n"
        src += "            + \"Expected models \\(modelNames.sorted()), but the \"\n"
        src += "            + \"generated set registers \\(registered.sorted()). \"\n"
        src += "            + \"Re-run swift-bao-codegen — do not hand-edit this file.\"\n"
        src += "        )\n"
        src += "        client.registerModels(all)\n"
        src += "    }\n"
        src += "}\n"
        return src
    }

    // MARK: - Header

    private func header(schema: ParsedSchema) -> String {
        var s = "// Generated by swift-bao-codegen — DO NOT EDIT.\n"
        if !options.sourcePath.isEmpty {
            s += "// Source: \(options.sourcePath) (model: \(schema.name))\n"
        } else {
            s += "// Model: \(schema.name)\n"
        }
        s += "\n"
        return s
    }

    // MARK: - Struct

    /// Emit-time field order. `TomlParser` already recovers TOML
    /// declaration order from the source, so the emitter just preserves
    /// it — a schema declared as `id, text, completed, createdAt` yields
    /// an init in that exact parameter order. (Previously this pinned
    /// `id` to the front because TOMLKit's iteration is alphabetical;
    /// the source-order recovery makes that hack unnecessary.)
    private func displayFieldOrder(_ schema: ParsedSchema) -> [String] {
        return schema.fieldOrder
    }

    private func structDecl(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        let typeName = schema.swiftName
        // `Equatable`, `Hashable`, and `Codable` synthesis only fires
        // when the conformance lives in the SAME file as the type
        // declaration. Adding the conformances here lets callers get
        // them for free — saves ~80 lines of hand-rolled boilerplate
        // per model. All generated stored-property types conform
        // (`String`, `Double`, `Bool`, `Set<String>`, plus their
        // optional forms), so synthesis succeeds for every schema.
        // CodingKeys synthesis also handles backtick-escaped property
        // names automatically (Swift 5.1+), so reserved-keyword
        // fields like `default` / `where` round-trip through
        // `JSONEncoder` / `JSONDecoder` without needing a manual
        // `CodingKeys` enum.
        var out = "\(access) struct \(typeName): PrimitiveModel, Equatable, Hashable, Codable {\n"
        out += staticMembers(schema: schema)
        out += "\n"
        out += nestedEnums(schema: schema)
        out += autoStampMetadata(schema: schema)
        out += storedProperties(schema: schema)
        out += "\n"
        out += designatedInit(schema: schema)
        out += "\n"
        out += recordInit(schema: schema)
        out += "\n"
        out += rowInit(schema: schema)
        out += "\n"
        out += primitiveValuesFn(schema: schema)
        out += relationshipAccessors(schema: schema)
        out += "}\n"
        return out
    }

    // MARK: - Relationship accessors

    /// Emit one static accessor per declared relationship. The generated
    /// struct is a doc-decoupled value type, so the accessors mirror the
    /// runtime resolvers on `PrimitiveRecord` (`refersTo` / `hasMany` /
    /// `hasManyThrough` in `JsBaoClient.RelationshipResolution`): the
    /// caller passes the source `PrimitiveRecord` they already have plus
    /// the target `DynamicModel`(s), and the accessor returns *typed*
    /// records — the same `init?(record:)` the rest of the file emits.
    ///
    /// Mirrors the JS codegen, which bakes typed `author()` / `posts(...)`
    /// accessors onto the generated class (#995). Swift can't store the
    /// doc binding on a value type, so the target model is an explicit
    /// parameter rather than implicit `this`.
    ///
    /// The return type names the target's resolved Swift type via
    /// `options.swiftNamesByModel`; when a target isn't in the map (an
    /// emit driven off a single bare `ParsedSchema`) we fall back to the
    /// default-suffix rule so the file still compiles in isolation.
    private func relationshipAccessors(schema: ParsedSchema) -> String {
        guard !schema.relationships.isEmpty else { return "" }
        let access = options.accessLevel
        var out = "\n"
        for (rname, rel) in schema.relationships {
            let props = Dictionary(uniqueKeysWithValues: rel.properties)
            guard let targetModel = props["model"] else { continue }
            let targetType = swiftTypeName(forModel: targetModel)
            let method = propName(rname)
            switch rel.rawType {
            case "refersTo":
                out += "    /// Follow the `\(rname)` relationship (refersTo → `\(targetModel)`).\n"
                out += "    /// `record` is this row's `PrimitiveRecord`; `target` is the\n"
                out += "    /// related model's `DynamicModel`. Returns `nil` when the foreign\n"
                out += "    /// key is unset or points at a missing record.\n"
                out += "    \(access) static func \(method)(\n"
                out += "        of record: PrimitiveRecord,\n"
                out += "        in target: DynamicModel\n"
                out += "    ) throws -> \(targetType)? {\n"
                out += "        try record.refersTo(relationship: \(quoted(rname)), target: target)\n"
                out += "            .flatMap(\(targetType).init(record:))\n"
                out += "    }\n\n"
            case "hasMany":
                out += "    /// Follow the `\(rname)` relationship (hasMany → `\(targetModel)`),\n"
                out += "    /// applying any emitted `order_by_field` / `order_direction`.\n"
                out += "    \(access) static func \(method)(\n"
                out += "        of record: PrimitiveRecord,\n"
                out += "        in target: DynamicModel\n"
                out += "    ) throws -> [\(targetType)] {\n"
                out += "        try record.hasMany(relationship: \(quoted(rname)), target: target)\n"
                out += "            .compactMap(\(targetType).init(record:))\n"
                out += "    }\n\n"
            case "hasManyThrough":
                out += "    /// Follow the `\(rname)` relationship (hasManyThrough → `\(targetModel)`)\n"
                out += "    /// via its join model. `joinModel` is the join `DynamicModel`;\n"
                out += "    /// `target` is the related model's `DynamicModel`.\n"
                out += "    \(access) static func \(method)(\n"
                out += "        of record: PrimitiveRecord,\n"
                out += "        through joinModel: DynamicModel,\n"
                out += "        in target: DynamicModel\n"
                out += "    ) throws -> [\(targetType)] {\n"
                out += "        try record.hasManyThrough(\n"
                out += "            relationship: \(quoted(rname)),\n"
                out += "            joinModel: joinModel,\n"
                out += "            target: target\n"
                out += "        ).compactMap(\(targetType).init(record:))\n"
                out += "    }\n\n"
            default:
                break
            }
        }
        // Trim the trailing blank line the last accessor leaves so the
        // closing brace sits flush, matching the rest of the emitter.
        if out.hasSuffix("\n\n") { out.removeLast() }
        return out
    }

    /// Resolve a target model name to its Swift type for relationship
    /// return types. Prefers the cross-model map populated by the driver;
    /// falls back to the default `pascalCase + suffix` rule (the suffix
    /// is recovered from the emit options when present, else `Record`).
    private func swiftTypeName(forModel model: String) -> String {
        if let mapped = options.swiftNamesByModel[model] { return mapped }
        return Naming.pascalCase(model) + "Record"
    }

    private func staticMembers(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = "    \(access) static let modelName = \(quoted(schema.name))\n"
        out += "    \(access) static let primitiveSchema = PrimitiveSchema(\n"
        out += "        name: \(quoted(schema.name)),\n"
        out += "        fields: [\n"
        // Preserve TOML insertion order for determinism, but collect the
        // longest key length for column-aligned readability.
        let keyWidth = displayFieldOrder(schema).map { $0.count + 2 }.max() ?? 0
        for fname in displayFieldOrder(schema) {
            guard let field = schema.fields[fname] else { continue }
            let key = quoted(fname)
            let pad = String(repeating: " ", count: max(0, keyWidth - key.count))
            out += "            \(key):\(pad) \(fieldDescriptorLiteral(field)),\n"
        }
        out += "        ]"
        if !schema.uniqueConstraints.isEmpty {
            out += ",\n        constraints: [\n"
            for c in schema.uniqueConstraints {
                let fieldsLit = c.fields.map { quoted($0) }.joined(separator: ", ")
                out += "            \(quoted(c.name)): ConstraintDescriptor(name: \(quoted(c.name)), fields: [\(fieldsLit)]),\n"
            }
            out += "        ]"
        }
        if !schema.relationships.isEmpty {
            out += ",\n        relationships: [\n"
            for (rname, rel) in schema.relationships {
                let propsLit = rel.properties.map { "\(quoted($0.0)): \(quoted($0.1))" }.joined(separator: ", ")
                out += "            \(quoted(rname)): RelationshipDescriptor(properties: [\(propsLit)]),\n"
            }
            out += "        ]"
        }
        out += "\n    )\n"
        return out
    }

    // MARK: - Nested enums (`enum = [...]` on a string field)

    /// Emit one nested `enum <Field>Value: String` per string field that
    /// declares `enum = [...]`, plus an `allowed<Field>Values` static set.
    ///
    /// The JS codegen renders an `enum` as a TS string-literal union and
    /// the value is purely advisory (the wire stays a plain string — #843,
    /// membership is NOT enforced on write). Swift's closest faithful
    /// analogue is a `String`-raw-valued nested enum: it gives callers a
    /// typed, exhaustive, autocompletable vocabulary while the stored
    /// property remains a plain `String` so every existing bridge
    /// (`init?(record:)`, `init?(row:)`, `primitiveValues()`, Codable
    /// synthesis, and the `FieldDescriptor` literal) keeps working
    /// unchanged. `<field>Enum` / `allowed<Field>Values` give callers an
    /// opt-in typed view and a validation set without forcing the property
    /// type to change.
    private func nestedEnums(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = ""
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname], let values = f.enumValues, !values.isEmpty
            else { continue }
            // Sanitize the field name into a legal, non-keyword *type*
            // identifier — a keyword-named field (`default`) or a name with
            // a leading digit / punctuation can't ride through `pascalCase`
            // alone (a type name can't be backtick-escaped). See
            // `Naming.enumTypeName`.
            let enumName = Naming.enumTypeName(forField: fname)
            let cases = Naming.enumCaseNames(for: values)
            out += "    /// Allowed values for the `\(fname)` field (TOML `enum`).\n"
            out += "    \(access) enum \(enumName): String, Codable, CaseIterable, Sendable {\n"
            for (name, raw) in cases {
                out += "        case \(name) = \(quoted(raw))\n"
            }
            out += "    }\n\n"
            // Validation set + a typed view over the stored String.
            let setLit = values.map { quoted($0) }.joined(separator: ", ")
            out += "    /// The raw `enum` value set for `\(fname)`, in declaration order.\n"
            out += "    \(access) static let allowed\(Naming.pascalCase(fname))Values: Set<String> = [\(setLit)]\n\n"
            out += "    /// Typed view over the `\(fname)` string. `nil` when the stored\n"
            out += "    /// value is absent or outside the declared `enum` set.\n"
            // Compose the accessor name first, *then* escape — otherwise a
            // keyword field like `default` would emit `` `default`Enum `` (the
            // backtick must wrap the whole identifier). `defaultEnum` isn't a
            // keyword, so escaping the composed name leaves it clean.
            let enumAccessor = Naming.escapeIfReserved(fname + "Enum")
            out += "    \(access) var \(enumAccessor): \(enumName)? {\n"
            out += "        \(propName(fname)).flatMap(\(enumName).init(rawValue:))\n"
            out += "    }\n\n"
        }
        return out
    }

    // MARK: - auto_stamp metadata

    /// Emit `auto_stamp` as an advisory `static let autoStampFields:
    /// [String: String]` (field name → `"create"` / `"update"` / `"both"`)
    /// so app code can read the declared policy by field name.
    ///
    /// This is purely advisory now: the FUNCTIONAL stamp policy rides
    /// inside the `primitiveSchema` literal's per-field `FieldDescriptor`
    /// (`autoStamp:` slot — #1056), which the shared runtime write path
    /// reads to actually stamp timestamps on save. The static map is kept
    /// for backward compatibility and for callers that want the policy keyed
    /// by name without walking the schema. Omitted entirely when no field
    /// declares `auto_stamp` (keeps output stable for the common case).
    private func autoStampMetadata(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        let stamped: [(String, ParsedAutoStamp)] = displayFieldOrder(schema).compactMap {
            guard let f = schema.fields[$0], let s = f.autoStamp else { return nil }
            return ($0, s)
        }
        if stamped.isEmpty { return "" }
        var out = "    /// Fields that auto-populate a timestamp, mapped to when\n"
        out += "    /// (`create` / `update` / `both`). Declared via TOML `auto_stamp`.\n"
        out += "    \(access) static let autoStampFields: [String: String] = [\n"
        for (fname, stamp) in stamped {
            out += "        \(quoted(fname)): \(quoted(stamp.rawValue)),\n"
        }
        out += "    ]\n\n"
        return out
    }

    private func fieldDescriptorLiteral(_ f: ParsedField) -> String {
        var args: [String] = ["type: \(swiftFieldType(f.type))"]
        if f.indexed    { args.append("indexed: true") }
        if f.unique     { args.append("unique: true") }
        if f.required   { args.append("required: true") }
        if f.autoAssign { args.append("autoAssign: true") }
        if let v = f.maxLength { args.append("maxLength: \(v)") }
        if let v = f.maxCount  { args.append("maxCount: \(v)") }
        if let d = f.defaultLiteral {
            args.append("default: \(defaultLiteral(d))")
        }
        // Auto-stamp policy rides INSIDE the FieldDescriptor literal so the
        // shared runtime write path (`DynamicModel.save`) reads it straight
        // off `primitiveSchema` and stamps `Date.now()`-style epoch millis
        // on insert/update. (The `autoStampFields` static below is kept as
        // advisory metadata for app code — backward-compatible — but the
        // functional source of truth is this slot.)
        if let s = f.autoStamp {
            args.append("autoStamp: .\(s.rawValue)")
        }
        return "FieldDescriptor(\(args.joined(separator: ", ")))"
    }

    private func swiftFieldType(_ t: ParsedFieldType) -> String {
        switch t {
        case .string:    return ".string"
        case .number:    return ".number"
        case .boolean:   return ".boolean"
        case .date:      return ".date"
        case .id:        return ".id"
        case .stringset: return ".stringset"
        }
    }

    private func defaultLiteral(_ d: ParsedDefault) -> String {
        switch d {
        case let .string(s):
            return ".scalar(.string(\(quoted(s))))"
        case let .number(n):
            return ".scalar(.number(\(formatDouble(n))))"
        case let .integer(i):
            return ".scalar(.number(\(i)))"
        case let .boolean(b):
            return ".scalar(.boolean(\(b)))"
        }
    }

    // MARK: - Stored properties

    private func storedProperties(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = ""
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname] else { continue }
            out += "    \(access) var \(propName(fname)): \(swiftStoredType(f, fieldName: fname))\n"
        }
        return out
    }

    /// Map a TOML field type to the user-facing Swift type. `id` and
    /// any `required: true` field is non-optional; everything else is
    /// optional. `id` always becomes `String` (PrimitiveRecord exposes
    /// it as `record.id`).
    private func swiftStoredType(_ f: ParsedField, fieldName: String) -> String {
        let base: String
        switch f.type {
        case .string, .id, .date: base = "String"
        case .number:              base = "Double"
        case .boolean:             base = "Bool"
        case .stringset:           base = "Set<String>"
        }
        let nonOptional = (f.type == .id) || f.required || (fieldName == "id")
        return nonOptional ? base : "\(base)?"
    }

    // MARK: - Designated init

    private func designatedInit(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var lines: [String] = []
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname] else { continue }
            let type = swiftStoredType(f, fieldName: fname)
            let isOptional = type.hasSuffix("?")
            // No defaults for non-optional `id` (caller must provide one).
            // Required non-id fields also have no default — matches the
            // demo's hand-written init shape.
            let suffix: String
            if isOptional {
                suffix = " = nil"
            } else {
                suffix = ""
            }
            lines.append("        \(propName(fname)): \(type)\(suffix)")
        }
        var out = "    \(access) init(\n"
        out += lines.joined(separator: ",\n")
        out += "\n    ) {\n"
        for fname in displayFieldOrder(schema) {
            out += "        self.\(propName(fname)) = \(propName(fname))\n"
        }
        out += "    }\n"
        return out
    }

    // MARK: - init?(record:)

    private func recordInit(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = "    \(access) init?(record: PrimitiveRecord) {\n"

        // Required guards for non-`id` required fields (id comes from
        // record.id and is always present).
        var guards: [String] = []
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname] else { continue }
            if fname == "id" { continue }
            if f.required {
                guards.append(
                    "let \(propName(fname)) = record[\(quoted(fname))]?.\(asAccessor(f.type))"
                )
            }
        }
        if !guards.isEmpty {
            out += "        guard "
            out += guards.joined(separator: ",\n              ")
            out += "\n        else { return nil }\n"
        }
        // Assignments
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname] else { continue }
            if fname == "id" {
                out += "        self.id = record.id\n"
                continue
            }
            if f.required {
                // Hoisted from the guard
                out += "        self.\(propName(fname)) = \(propName(fname))\n"
            } else {
                let acc = asAccessor(f.type)
                out += "        self.\(propName(fname)) = record[\(quoted(fname))]?.\(acc)\n"
            }
        }
        out += "    }\n"
        return out
    }

    /// The right `asXxx` PrimitiveValue accessor for a field type.
    /// `.date` reads as a `String` — the demo and the runtime use ISO-8601
    /// strings so dates don't need a separate Swift type. `.stringset`
    /// reads as `Set<String>?`.
    private func asAccessor(_ t: ParsedFieldType) -> String {
        switch t {
        case .string:    return "asString"
        case .number:    return "asNumber"
        case .boolean:   return "asBoolean"
        case .id:        return "asId"
        case .date:      return "asDateString"
        case .stringset: return "asStringSet"
        }
    }

    // MARK: - init?(row:)

    private func rowInit(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = "    /// Build from a SQLite-backed query row (`dynamic.query(...)`).\n"
        out += "    \(access) init?(row: [String: Any]) {\n"
        // Always require id from the row.
        var guardClauses: [String] = ["let id = row[\"id\"] as? String"]
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname] else { continue }
            if fname == "id" { continue }
            if f.required {
                guardClauses.append(
                    "let \(propName(fname)) = \(rowReadExpression(f, key: quoted(fname)))"
                )
            }
        }
        out += "        guard "
        out += guardClauses.joined(separator: ",\n              ")
        out += "\n        else { return nil }\n"
        out += "        self.id = id\n"
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname] else { continue }
            if fname == "id" { continue }
            if f.required {
                out += "        self.\(propName(fname)) = \(propName(fname))\n"
            } else {
                out += "        self.\(propName(fname)) = \(rowReadExpression(f, key: quoted(fname)))\n"
            }
        }
        out += "    }\n"
        return out
    }

    /// The expression that reads one field out of a SQLite-row dict.
    ///
    /// Scalars (`string` / `number` / `boolean` / `id` / `date`) are
    /// straight `as?` casts to their Swift type. Stringsets are special:
    /// `BaoModelQueryEngine.populateStringsetsFiltered` writes stringset
    /// columns back into the row dict as `[String]` (Swift array), not
    /// as `Set<String>`, so a direct `as? Set<String>` cast always
    /// fails and the row is silently dropped. Cast to `[String]` first
    /// and convert.
    ///
    /// The expression returns an `Optional` of the field's storage
    /// type — caller wraps in `let prop = ...` to unwrap it.
    private func rowReadExpression(_ f: ParsedField, key: String) -> String {
        if f.type == .stringset {
            return "(row[\(key)] as? [String]).map(Set.init)"
        }
        if f.type == .boolean {
            // BaoModelQueryEngine.executeQuery returns SQLite INTEGER
            // columns as `Int` — boolean fields are stored as INTEGER,
            // so a direct `as? Bool` cast always fails and the row's
            // bool either drops silently (optional) or aborts the
            // whole row (required). Fall back through Int → Bool.
            //
            // Use a non-trailing closure on `.map` because the read
            // expression sits inside a `guard let X = ..., let Y = ...
            // else { return nil }` chain — a trailing closure there
            // triggers the "trailing closure in this context is
            // confusable with the body of the statement" warning.
            return "(row[\(key)] as? Bool) ?? (row[\(key)] as? Int).map({ $0 != 0 })"
        }
        return "row[\(key)] as? \(swiftRowCastType(f))"
    }

    /// The non-optional Swift type for a SQLite row-cast (`as? T`).
    /// `.stringset` does not appear here — `rowReadExpression` handles
    /// it via the `[String] → Set<String>` conversion path.
    private func swiftRowCastType(_ f: ParsedField) -> String {
        switch f.type {
        case .string, .id, .date: return "String"
        case .number:              return "Double"
        case .boolean:             return "Bool"
        case .stringset:           return "Set<String>"   // unused; handled in rowReadExpression
        }
    }

    // MARK: - primitiveValues()

    private func primitiveValuesFn(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = "    \(access) func primitiveValues() -> [String: PrimitiveValue] {\n"

        // Required fields go in the literal; optional fields are
        // appended conditionally. `id` is excluded — DynamicModel writes
        // it separately.
        var requiredEntries: [(String, ParsedField)] = []
        var optionalEntries: [(String, ParsedField)] = []
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname] else { continue }
            if fname == "id" { continue }
            if f.required {
                requiredEntries.append((fname, f))
            } else {
                optionalEntries.append((fname, f))
            }
        }

        // `values` is mutated only when there are optional fields to
        // conditionally append — emit `let` otherwise to avoid the
        // "variable 'values' was never mutated" warning in app builds.
        let storageKeyword = optionalEntries.isEmpty ? "let" : "var"
        if requiredEntries.isEmpty {
            out += "        \(storageKeyword) values: [String: PrimitiveValue] = [:]\n"
        } else {
            out += "        \(storageKeyword) values: [String: PrimitiveValue] = [\n"
            for (fname, f) in requiredEntries {
                out += "            \(quoted(fname)): \(primitiveValueLiteral(f, propRef: propName(fname))),\n"
            }
            out += "        ]\n"
        }
        for (fname, f) in optionalEntries {
            // String?, Double?, Bool?, Set<String>? — `if let` shorthand
            out += "        if let \(propName(fname)) { values[\(quoted(fname))] = \(primitiveValueLiteral(f, propRef: propName(fname))) }\n"
        }
        out += "        return values\n"
        out += "    }\n"
        return out
    }

    private func primitiveValueLiteral(_ f: ParsedField, propRef: String) -> String {
        switch f.type {
        case .string:    return ".string(\(propRef))"
        case .number:    return ".number(\(propRef))"
        case .boolean:   return ".boolean(\(propRef))"
        case .id:        return ".id(\(propRef))"
        case .date:      return ".date(\(propRef))"
        case .stringset: return ".stringset(\(propRef))"
        }
    }

    // MARK: - Helpers

    private func propName(_ s: String) -> String {
        Naming.escapeIfReserved(s)
    }

    private func quoted(_ s: String) -> String {
        // Conservative: the field/model names that survive TOML parsing
        // can't contain `"` or `\`, so a verbatim wrap is safe.
        return "\"\(s)\""
    }

    private func formatDouble(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 1e16 {
            return "\(Int64(d))"
        }
        return "\(d)"
    }
}
