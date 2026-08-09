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
        out += "    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> [\(typeName)] {\n"
        out += "        try JsBaoClient.requireDefault()\n"
        out += "            .codegen.query(primitiveSchema, filter: filter, options: options)\n"
        out += "            .compactMap { \(typeName)(row: $0) }\n"
        out += "    }\n\n"
        out += "    /// Query across all open documents and batch-prefetch related\n"
        out += "    /// records into each row's `related` bag. Mirrors JS\n"
        out += "    /// `BaseModel.query(filter, { include })`.\n"
        out += "    static func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil, include: [Include]) throws -> [\(typeName)] {\n"
        out += "        try JsBaoClient.requireDefault()\n"
        out += "            .codegen.query(primitiveSchema, filter: filter, options: options, include: include)\n"
        out += "            .compactMap { \(typeName)(row: $0) }\n"
        out += "    }\n\n"
        out += "    /// Paginated query across all open documents. Returns the page's\n"
        out += "    /// rows plus `nextCursor`/`prevCursor`/`hasMore` — round-trip\n"
        out += "    /// `nextCursor` via `options.cursor` to page. Mirrors JS\n"
        out += "    /// `BaseModel.query()`'s `{ data, nextCursor, hasMore }` shape.\n"
        out += "    static func queryPaged(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> PagedQueryResult<\(typeName)> {\n"
        out += "        let page = try JsBaoClient.requireDefault()\n"
        out += "            .codegen.queryPaged(primitiveSchema, filter: filter, options: options)\n"
        out += "        return PagedQueryResult(\n"
        out += "            data: page.data.compactMap { \(typeName)(row: $0) },\n"
        out += "            nextCursor: page.nextCursor,\n"
        out += "            prevCursor: page.prevCursor,\n"
        out += "            hasMore: page.hasMore\n"
        out += "        )\n"
        out += "    }\n\n"
        out += "    /// Paginated query with query-time relationship includes.\n"
        out += "    static func queryPaged(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil, include: [Include]) throws -> PagedQueryResult<\(typeName)> {\n"
        out += "        let page = try JsBaoClient.requireDefault()\n"
        out += "            .codegen.queryPaged(primitiveSchema, filter: filter, options: options, include: include)\n"
        out += "        return PagedQueryResult(\n"
        out += "            data: page.data.compactMap { \(typeName)(row: $0) },\n"
        out += "            nextCursor: page.nextCursor,\n"
        out += "            prevCursor: page.prevCursor,\n"
        out += "            hasMore: page.hasMore\n"
        out += "        )\n"
        out += "    }\n\n"
        out += "    /// Count across all open documents.\n"
        out += "    static func count(_ filter: DocumentFilter? = nil) throws -> Int {\n"
        out += "        try JsBaoClient.requireDefault().codegen.count(primitiveSchema, filter: filter)\n"
        out += "    }\n\n"
        out += "    /// Every record across all open documents. Synchronous like the\n"
        out += "    /// rest of the facade reads (#1156) — the shared store never\n"
        out += "    /// suspends. Throws `PrimitiveDecodeError` if any stored row no\n"
        out += "    /// longer decodes as `\(typeName)` — JS `findAll` never drops rows,\n"
        out += "    /// so schema drift surfaces loudly instead of silently shrinking\n"
        out += "    /// the result.\n"
        out += "    static func findAll() throws -> [\(typeName)] {\n"
        out += "        try JsBaoClient.requireDefault()\n"
        out += "            .codegen.query(primitiveSchema, filter: nil, options: nil)\n"
        out += "            .map { row in\n"
        out += "                guard let decoded = \(typeName)(row: row) else {\n"
        out += "                    throw PrimitiveDecodeError(modelName: modelName, row: row)\n"
        out += "                }\n"
        out += "                return decoded\n"
        out += "            }\n"
        out += "    }\n\n"
        out += "    /// First record with `id` across all open documents; `nil` only when\n"
        out += "    /// no open document has it. Synchronous like the rest of the facade\n"
        out += "    /// reads (#1156) — the shared store never suspends. Throws\n"
        out += "    /// `PrimitiveDecodeError` when the row exists but no longer decodes\n"
        out += "    /// as `\(typeName)` — distinct from the `nil` not-found case.\n"
        out += "    static func find(_ id: String) throws -> \(typeName)? {\n"
        out += "        guard let row = JsBaoClient.requireDefault().codegen.find(primitiveSchema, id: id) else {\n"
        out += "            return nil\n"
        out += "        }\n"
        out += "        guard let decoded = \(typeName)(row: row) else {\n"
        out += "            throw PrimitiveDecodeError(modelName: modelName, row: row)\n"
        out += "        }\n"
        out += "        return decoded\n"
        out += "    }\n\n"
        out += "    /// First record matching a unique `constraint` and `value`,\n"
        out += "    /// across all open documents, or `nil`. First-match-wins in\n"
        out += "    /// document connect order (uniqueness is per-document, so the\n"
        out += "    /// same value may exist in more than one open doc). Mirrors the\n"
        out += "    /// JS client's `Model.findByUnique(constraintName, value)`.\n"
        out += "    static func findByUnique(_ constraint: String, _ value: PrimitiveValue) throws -> \(typeName)? {\n"
        out += "        try JsBaoClient.requireDefault()\n"
        out += "            .codegen.findByUnique(primitiveSchema, constraint: constraint, value: value)\n"
        out += "            .flatMap { \(typeName)(row: $0) }\n"
        out += "    }\n\n"
        out += "    /// The first record matching `filter` across all open documents,\n"
        out += "    /// or `nil`. Equivalent to `query(filter, options).first` — mirrors\n"
        out += "    /// the JS client's `Model.queryOne(filter, options)`.\n"
        out += "    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> \(typeName)? {\n"
        out += "        try JsBaoClient.requireDefault()\n"
        out += "            .codegen.queryOne(primitiveSchema, filter: filter, options: options)\n"
        out += "            .flatMap { \(typeName)(row: $0) }\n"
        out += "    }\n\n"
        out += "    /// The first record matching `filter` with query-time relationship\n"
        out += "    /// includes attached under `related`, or `nil`. Equivalent to\n"
        out += "    /// `query(filter, options, include:).first` — mirrors the JS client's\n"
        out += "    /// `Model.queryOne(filter, { include })`.\n"
        out += "    static func queryOne(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil, include: [Include]) throws -> \(typeName)? {\n"
        out += "        try JsBaoClient.requireDefault()\n"
        out += "            .codegen.queryOne(primitiveSchema, filter: filter, options: options, include: include)\n"
        out += "            .flatMap { \(typeName)(row: $0) }\n"
        out += "    }\n\n"
        out += "    /// Fire `callback` after any add/update/delete in any open document's\n"
        out += "    /// copy of this model (local or remote). Returns an unsubscribe closure.\n"
        out += "    ///\n"
        out += "    /// The callback is `@Sendable` (#1992): it runs on whichever thread\n"
        out += "    /// committed the change — a local writer's thread, or the\n"
        out += "    /// observer-drain queue — so state it captures must be safe to touch\n"
        out += "    /// from either.\n"
        out += "    @discardableResult\n"
        out += "    static func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {\n"
        out += "        JsBaoClient.requireDefault().codegen.subscribe(primitiveSchema, callback)\n"
        out += "    }\n\n"
        out += "    /// Aggregate (group / count / sum / avg / …) across all open documents.\n"
        out += "    static func aggregate(_ options: AggregateOptions) throws -> [[String: Any]] {\n"
        out += "        try JsBaoClient.requireDefault().codegen.aggregate(primitiveSchema, options: options)\n"
        out += "    }\n\n"
        out += "    // MARK: Writes (target one document; throw if it isn't open)\n\n"
        out += "    /// Persist this record to document `documentId` — inserts it if it\n"
        out += "    /// doesn't exist yet, updates it in place if it does. One call for\n"
        out += "    /// both, matching the JS client's `save()`. Throws if the doc isn't\n"
        out += "    /// open.\n"
        out += "    ///\n"
        out += "    /// Updating writes only the fields assigned since this value was\n"
        out += "    /// read (`_changedFields`), so two devices editing different fields\n"
        out += "    /// of the same record merge instead of clobbering. Inserting writes\n"
        out += "    /// every field.\n"
        out += "    ///\n"
        out += "    /// Returns the record AS SAVED, re-read from the document with no\n"
        out += "    /// pending changes left — so a field this save didn't write carries\n"
        out += "    /// whatever another device put there, and an insert's schema\n"
        out += "    /// defaults and `auto_stamp` values are filled in. Assign it back\n"
        out += "    /// (`task = try task.save(in: doc)`) when you keep using the value\n"
        out += "    /// after the save; `self` itself still holds the values you had.\n"
        out += "    @discardableResult\n"
        out += "    func save(in documentId: String) throws -> \(typeName) {\n"
        out += "        let record = try JsBaoClient.requireDefault().codegen.save(Self.primitiveSchema, id: id, values: primitiveValues(), in: documentId, changedFields: _changedFields)\n"
        out += "        guard var saved = \(typeName)(record: record) else {\n"
        out += "            var fallback = self\n"
        out += "            fallback.discardChanges()\n"
        out += "            return fallback\n"
        out += "        }\n"
        out += "        // Carried over, not persisted: query-time includes and the\n"
        out += "        // caller-pinned-id flag have no representation in the stored\n"
        out += "        // record, and this path never changes the record's id.\n"
        out += "        saved.related = related\n"
        out += "        saved._explicitId = _explicitId\n"
        out += "        return saved\n"
        out += "    }\n\n"
        out += "    /// Insert-or-update this record in `documentId`, matched by the\n"
        out += "    /// single-field unique constraint on `upsertOn` rather than `id` —\n"
        out += "    /// if a record already holds this row's `upsertOn` value, that\n"
        out += "    /// record is merged into (and keeps its id); otherwise a new\n"
        out += "    /// record is inserted. Mirrors the JS client's\n"
        out += "    /// `save({ upsertOn: field })`. Throws if the doc isn't open, if\n"
        out += "    /// `upsertOn` has no single-field unique constraint, or if the\n"
        out += "    /// `upsertOn` value is absent/empty.\n"
        out += "    ///\n"
        out += "    /// Returns the RESOLVED record: on the merge path its `id` is the\n"
        out += "    /// EXISTING record's id (JS reassigns `this.id = existingId`) and\n"
        out += "    /// its fields reflect the merged state, NOT necessarily `self`.\n"
        out += "    @discardableResult\n"
        out += "    func save(in documentId: String, upsertOn: String) throws -> \(typeName) {\n"
        out += "        let result = try JsBaoClient.requireDefault().codegen.upsert(Self.primitiveSchema, id: id, values: primitiveValues(), on: upsertOn, in: documentId, explicitId: _explicitId, changedFields: _changedFields)\n"
        out += "        if let resolved = \(typeName)(record: result.record) { return resolved }\n"
        out += "        var copy = self\n"
        out += "        copy.id = result.record.id\n"
        out += "        copy.discardChanges()\n"
        out += "        return copy\n"
        out += "    }\n\n"
        out += "    /// Insert-or-update this record, matched by the NAMED unique\n"
        out += "    /// constraint (single-field or compound). Mirrors the JS client's\n"
        out += "    /// `Model.upsertByUnique(constraintName, lookupValue, data,\n"
        out += "    /// options)` — the lookup values come straight from this record's\n"
        out += "    /// fields (every constraint field must be set), and `mode` maps\n"
        out += "    /// JS's flags: `.mustExist` ⇔ `objectMustExist`, `.mustNotExist`\n"
        out += "    /// ⇔ `objectMustNotExist`, `.either` ⇔ default.\n"
        out += "    ///\n"
        out += "    /// Search scope matches js-bao: the existing-record lookup spans\n"
        out += "    /// EVERY open document. A match in any open doc is then saved\n"
        out += "    /// through the explicit `documentId` target, matching JS\n"
        out += "    /// `existingRecord.save({ targetDocument })`; a fresh insert also\n"
        out += "    /// lands in `documentId`. Throws if the\n"
        out += "    /// constraint isn't declared, a constraint field is unset, an\n"
        out += "    /// explicit (pinned) id collides with a matched record\n"
        out += "    /// (`UpsertError.explicitIdConflict`), or (on insert) `documentId`\n"
        out += "    /// isn't open.\n"
        out += "    ///\n"
        out += "    /// Returns the RESOLVED record: on the merge path its `id` is the\n"
        out += "    /// EXISTING record's id and its fields reflect the merged state.\n"
        out += "    @discardableResult\n"
        out += "    func upsertByUnique(_ constraint: String, mode: UpsertMode = .either, in documentId: String) throws -> \(typeName) {\n"
        out += "        let result = try JsBaoClient.requireDefault().codegen.upsertByUnique(Self.primitiveSchema, id: id, values: primitiveValues(), constraint: constraint, mode: mode, in: documentId, explicitId: _explicitId, changedFields: _changedFields)\n"
        out += "        if let resolved = \(typeName)(record: result.record) { return resolved }\n"
        out += "        var copy = self\n"
        out += "        copy.id = result.record.id\n"
        out += "        copy.discardChanges()\n"
        out += "        return copy\n"
        out += "    }\n\n"
        out += "    /// `upsertByUnique` overload taking an EXPLICIT lookup value (one\n"
        out += "    /// per constraint field) — mirrors js-bao's separate\n"
        out += "    /// `uniqueLookupValue` argument. The values must agree with this\n"
        out += "    /// record's own constraint fields (js-bao throws on mismatch). Use\n"
        out += "    /// when you want to make the lookup key explicit at the call site.\n"
        out += "    @discardableResult\n"
        out += "    func upsertByUnique(_ constraint: String, lookupValue: [PrimitiveValue], mode: UpsertMode = .either, in documentId: String) throws -> \(typeName) {\n"
        out += "        let result = try JsBaoClient.requireDefault().codegen.upsertByUnique(Self.primitiveSchema, id: id, values: primitiveValues(), constraint: constraint, mode: mode, in: documentId, explicitId: _explicitId, uniqueLookupValue: lookupValue, changedFields: _changedFields)\n"
        out += "        if let resolved = \(typeName)(record: result.record) { return resolved }\n"
        out += "        var copy = self\n"
        out += "        copy.id = result.record.id\n"
        out += "        copy.discardChanges()\n"
        out += "        return copy\n"
        out += "    }\n\n"
        out += "    /// Delete this record from document `documentId`. Throws if the doc isn't open.\n"
        out += "    func delete(in documentId: String) throws {\n"
        out += "        try JsBaoClient.requireDefault().codegen.delete(Self.primitiveSchema, id: id, in: documentId)\n"
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
        // declaration. Declaring the conformances here lets callers get
        // them for free — saves ~80 lines of hand-rolled boilerplate
        // per model. All generated stored-property types conform
        // (`String`, `Double`, `Bool`, `Set<String>`, plus their
        // optional forms), so the members below compile for every
        // schema.
        //
        // Three of the four members are emitted rather than synthesized,
        // because the struct carries non-schema bookkeeping the
        // synthesized versions would pick up: `CodingKeys`, `==`, and
        // `hash(into:)` list the real fields only (see
        // `equatableHashableCodableConformance`), and `init(from:)` is
        // emitted so a decoded record marks its fields changed (see
        // `codableDecodeInit`). Only `encode(to:)` is synthesized — it
        // follows the emitted `CodingKeys`, so `_explicitId` /
        // `_changedFields` / `related` can't leak into the JSON.
        // Backtick-escaped property names (`default`, `where`) round-trip
        // fine: the emitted `CodingKeys` cases carry the same escapes.
        var out = "\(access) struct \(typeName): PrimitiveModel, PrimitiveRowDecodable, Equatable, Hashable, Codable {\n"
        out += staticMembers(schema: schema)
        out += "\n"
        out += nestedEnums(schema: schema)
        out += autoStampMetadata(schema: schema)
        out += storedProperties(schema: schema)
        out += "\n"
        out += relatedRecordsProperty(schema: schema)
        out += "\n"
        out += idProvenanceProperty(schema: schema)
        out += "\n"
        out += changeTrackingMembers(schema: schema)
        out += "\n"
        out += designatedInit(schema: schema)
        out += "\n"
        out += autoIdInit(schema: schema)
        out += "\n"
        out += recordInit(schema: schema)
        out += "\n"
        out += rowInit(schema: schema)
        out += "\n"
        out += primitiveValuesFn(schema: schema)
        out += "\n"
        out += codableDecodeInit(schema: schema)
        out += "\n"
        out += equatableHashableCodableConformance(schema: schema)
        out += relationshipAccessors(schema: schema)
        out += "}\n"
        return out
    }

    // MARK: - Explicit-id provenance (#1122)

    /// Query-time include payloads attached under `_related`. This is not
    /// persisted model data and is excluded from Codable/Equatable/Hashable.
    private func relatedRecordsProperty(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        return "    \(access) var related: RelatedRecords = .empty\n"
    }

    /// Emit the non-persisted `_explicitId` provenance flag plus the
    /// public `id`-was-pinned accessor the facade reads. Tracks whether
    /// the caller pinned the id (designated `init(id:…)`) or let it be
    /// auto-generated (the auto-id convenience init). Mirrors js-bao's
    /// `_constructorProvidedId` — used by `save(in:upsertOn:)` /
    /// `upsertByUnique` to decide whether an id colliding with a matched
    /// record is a hard conflict (explicit) or a silent discard (auto).
    ///
    /// Excluded from `Codable` (via the emitted `CodingKeys`) and from
    /// `Equatable`/`Hashable` (via the emitted `==` / `hash(into:)`), so
    /// it never serializes and never affects value equality — it is pure
    /// call-site provenance, not record data.
    private func idProvenanceProperty(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = ""
        out += "    /// `true` when the caller pinned `id` via the designated\n"
        out += "    /// initializer; `false` when it was auto-generated. Drives the\n"
        out += "    /// explicit-id-conflict check on `save(in:upsertOn:)` /\n"
        out += "    /// `upsertByUnique` (js-bao `_constructorProvidedId` parity).\n"
        out += "    /// Not part of the record's persisted/equatable identity.\n"
        out += "    \(access) private(set) var _explicitId: Bool = true\n"
        return out
    }

    /// Emit the convenience initializer that AUTO-generates the id. A
    /// caller using this path is treated as not pinning an id, so a
    /// later upsert that collides on the unique value silently merges
    /// into the existing record (js-bao auto-id parity) rather than
    /// throwing `UpsertError.explicitIdConflict`. Mirrors js-bao's
    /// `new Model({ …no id… })` constructor path.
    private func autoIdInit(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        // Params: every field EXCEPT id, in display order.
        var lines: [String] = []
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname], fname != "id" else { continue }
            let type = swiftStoredType(f, fieldName: fname)
            let suffix = type.hasSuffix("?") ? " = nil" : ""
            lines.append("        \(propName(fname)): \(type)\(suffix)")
        }
        var out = ""
        out += "    /// Create a record with an auto-generated id. The id is NOT\n"
        out += "    /// treated as caller-pinned, so an `upsert` that collides on a\n"
        out += "    /// unique value merges into the existing record rather than\n"
        out += "    /// throwing `UpsertError.explicitIdConflict`. Mirrors js-bao's\n"
        out += "    /// id-less `new Model({...})` constructor.\n"
        if lines.isEmpty {
            // Id-only model: no parameters.
            out += "    \(access) init() {\n"
        } else {
            out += "    \(access) init(\n"
            out += lines.joined(separator: ",\n")
            out += "\n    ) {\n"
        }
        out += "        self.id = PrimitiveSchemaRegistry.newId()\n"
        for fname in displayFieldOrder(schema) where fname != "id" {
            out += "        self.\(propName(fname)) = \(propName(fname))\n"
        }
        out += "        self.related = .empty\n"
        out += "        self._explicitId = false\n"
        out += "        self._changedFields = Set(primitiveValues().keys)\n"
        out += "    }\n"
        return out
    }

    /// Emit explicit `CodingKeys` + `==` + `hash(into:)` that cover only
    /// the real schema fields — excluding the `_explicitId` provenance
    /// flag. This replaces the compiler's same-file synthesis (which
    /// would otherwise pull `_explicitId` into Codable/Equatable/Hashable)
    /// while preserving the exact same observable conformance behavior.
    private func equatableHashableCodableConformance(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        let fields = displayFieldOrder(schema).filter { schema.fields[$0] != nil }
        var out = ""
        // CodingKeys: only the real fields. `_explicitId` is omitted, so
        // it never encodes and decode leaves it at its `true` default.
        out += "    \(access) enum CodingKeys: String, CodingKey {\n"
        out += "        case " + fields.map { propName($0) }.joined(separator: ", ") + "\n"
        out += "    }\n\n"
        // Equatable: compare only real fields.
        out += "    \(access) static func == (lhs: \(schema.swiftName), rhs: \(schema.swiftName)) -> Bool {\n"
        let eqLines = fields.map { "        lhs.\(propName($0)) == rhs.\(propName($0))" }
        out += eqLines.joined(separator: " &&\n") + "\n"
        out += "    }\n\n"
        // Hashable: hash only real fields.
        out += "    \(access) func hash(into hasher: inout Hasher) {\n"
        for f in fields {
            out += "        hasher.combine(\(propName(f)))\n"
        }
        out += "    }\n"
        return out
    }

    // MARK: - Relationship accessors

    /// Emit one idiomatic INSTANCE accessor per declared relationship,
    /// mirroring the JS client's generated instance methods (#1151):
    /// `author.posts()` (→ `[Post]`) and `post.author()` (→ `Author?`).
    /// Each accessor auto-resolves the related model itself — the call
    /// site is just `try author.posts()`, no manually-constructed
    /// `DynamicModel` target to pass in.
    ///
    /// How the value-type struct reaches the related data: the emitter
    /// already knows the target's resolved Swift type (via
    /// `options.swiftNamesByModel`), and every generated type exposes
    /// `static let primitiveSchema`. So the accessor resolves the target
    /// model from `TargetRecord.primitiveSchema` and delegates to the
    /// configured default `JsBaoClient`'s cross-document relationship
    /// helpers (`codegen.refersTo` / `codegen.hasMany` / `codegen.hasManyThrough`)
    /// — the same shared store the rest of the facade reads. This matches
    /// JS, where the target model class is baked in at codegen and the
    /// accessor queries it (`relationshipManager.ts`). No global model
    /// registry is needed because the target type is known statically.
    ///
    /// Synchronous `throws`, matching the generated `find()` / `findAll()`
    /// facade and the rest of this facade (#1156) — the helper path never
    /// suspends. Like the rest of this facade, a missing default client is a
    /// `JsBaoClient.requireDefault()` precondition.
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
            let relatedAccessor = propName("related" + Naming.pascalCase(rname))
            switch rel.rawType {
            case "refersTo":
                // The foreign key is a field on THIS model — read it off the
                // struct's own property, exactly like JS reads `this[relatedIdField]`.
                guard let fk = props["relatedIdField"] else { continue }
                let fkProp = propName(fk)
                out += "    /// Follow the `\(rname)` relationship (refersTo → `\(targetModel)`):\n"
                out += "    /// resolve the `\(targetType)` this record's `\(fk)` points at, across\n"
                out += "    /// all open documents. Returns `nil` when the foreign key is unset\n"
                out += "    /// or points at a missing record. Mirrors the JS `\(method)()`\n"
                out += "    /// instance accessor.\n"
                out += "    \(access) func \(method)() throws -> \(targetType)? {\n"
                out += "        JsBaoClient.requireDefault()\n"
                out += "            .codegen.refersTo(target: \(targetType).primitiveSchema, foreignKey: \(fkProp))\n"
                out += "            .flatMap { \(targetType)(row: $0) }\n"
                out += "    }\n\n"
                out += "    /// Typed query-time include payload for `\(rname)`, when present in `related`.\n"
                out += "    \(access) var \(relatedAccessor): \(targetType)? {\n"
                out += "        related.one(\(quoted(rname)), as: \(targetType).self)\n"
                out += "            ?? related.one(\(targetType).modelName, as: \(targetType).self)\n"
                out += "    }\n\n"
                out += "    /// Build a query-time include for `\(rname)`.\n"
                out += "    \(access) static func include\(Naming.pascalCase(rname))(\n"
                out += "        filter: DocumentFilter? = nil,\n"
                out += "        projection: [String: Int]? = nil,\n"
                out += "        resultKey: String? = \(quoted(rname)),\n"
                out += "        include: [Include]? = nil\n"
                out += "    ) -> Include {\n"
                out += "        Include(\n"
                out += "            type: .refersTo,\n"
                out += "            target: JsBaoClient.requireDefault().codegen.includeTarget(for: \(targetType).primitiveSchema),\n"
                out += "            sourceField: \(quoted(fk)),\n"
                out += "            filter: filter,\n"
                out += "            projection: projection,\n"
                out += "            resultKey: resultKey,\n"
                out += "            include: include\n"
                out += "        )\n"
                out += "    }\n\n"
            case "hasMany":
                guard let fk = props["relatedIdField"] else { continue }
                let orderArgs = relationshipOrderArgs(
                    field: props["orderByField"], direction: props["orderDirection"]
                )
                let sortDefault = includeSortDefault(
                    field: props["orderByField"], direction: props["orderDirection"]
                )
                out += "    /// Follow the `\(rname)` relationship (hasMany → `\(targetModel)`):\n"
                out += "    /// every `\(targetType)` whose `\(fk)` points back at this record,\n"
                out += "    /// across all open documents, applying any emitted\n"
                out += "    /// `order_by_field` / `order_direction`. Mirrors the JS\n"
                out += "    /// `\(method)()` instance accessor.\n"
                out += "    \(access) func \(method)() throws -> [\(targetType)] {\n"
                out += "        try JsBaoClient.requireDefault()\n"
                out += "            .codegen.hasMany(\n"
                out += "                target: \(targetType).primitiveSchema,\n"
                out += "                relatedIdField: \(quoted(fk)),\n"
                out += "                sourceId: id\(orderArgs)\n"
                out += "            )\n"
                out += "            .compactMap { \(targetType)(row: $0) }\n"
                out += "    }\n\n"
                out += "    /// Typed query-time include payload for `\(rname)`, when present in `related`.\n"
                out += "    \(access) var \(relatedAccessor): [\(targetType)] {\n"
                out += "        if related.contains(\(quoted(rname))) {\n"
                out += "            return related.many(\(quoted(rname)), as: \(targetType).self)\n"
                out += "        }\n"
                out += "        return related.many(\(targetType).modelName, as: \(targetType).self)\n"
                out += "    }\n\n"
                out += "    /// Build a query-time include for `\(rname)`.\n"
                out += "    \(access) static func include\(Naming.pascalCase(rname))(\n"
                out += "        filter: DocumentFilter? = nil,\n"
                out += "        sort: [String: Int]? = \(sortDefault),\n"
                out += "        limit: Int? = nil,\n"
                out += "        projection: [String: Int]? = nil,\n"
                out += "        resultKey: String? = \(quoted(rname)),\n"
                out += "        include: [Include]? = nil\n"
                out += "    ) -> Include {\n"
                out += "        Include(\n"
                out += "            type: .hasMany,\n"
                out += "            target: JsBaoClient.requireDefault().codegen.includeTarget(for: \(targetType).primitiveSchema),\n"
                out += "            foreignKey: \(quoted(fk)),\n"
                out += "            localField: \"id\",\n"
                out += "            filter: filter,\n"
                out += "            sort: sort,\n"
                out += "            limit: limit,\n"
                out += "            projection: projection,\n"
                out += "            resultKey: resultKey,\n"
                out += "            include: include\n"
                out += "        )\n"
                out += "    }\n\n"
            case "hasManyThrough":
                guard let joinModel = props["joinModel"],
                      let localField = props["joinModelLocalField"],
                      let relatedField = props["joinModelRelatedField"] else { continue }
                let joinType = swiftTypeName(forModel: joinModel)
                let joinOrderArgs = relationshipOrderArgs(
                    field: props["joinModelOrderByField"],
                    direction: props["joinModelOrderDirection"],
                    fieldLabel: "joinModelOrderByField",
                    directionLabel: "joinModelOrderDirection"
                )
                out += "    /// Follow the `\(rname)` relationship (hasManyThrough → `\(targetModel)`)\n"
                out += "    /// via the `\(joinModel)` join model, across all open documents,\n"
                out += "    /// applying any emitted `join_model_order_by_field` /\n"
                out += "    /// `join_model_order_direction` to the join leg. Mirrors the JS\n"
                out += "    /// `\(method)()` instance accessor.\n"
                out += "    \(access) func \(method)() throws -> [\(targetType)] {\n"
                out += "        try JsBaoClient.requireDefault()\n"
                out += "            .codegen.hasManyThrough(\n"
                out += "                target: \(targetType).primitiveSchema,\n"
                out += "                joinModel: \(joinType).primitiveSchema,\n"
                out += "                sourceId: id,\n"
                out += "                joinModelLocalField: \(quoted(localField)),\n"
                out += "                joinModelRelatedField: \(quoted(relatedField))\(joinOrderArgs)\n"
                out += "            )\n"
                out += "            .compactMap { \(targetType)(row: $0) }\n"
                out += "    }\n\n"
                out += "    /// Paginated `\(method)` — pages the `\(joinModel)` join leg by its\n"
                out += "    /// declared order (default `id ASC`) through the shared\n"
                out += "    /// composite-cursor engine, then `$in`-resolves the page against\n"
                out += "    /// `\(targetModel)`. The cursor is the engine's opaque `String`\n"
                out += "    /// token (a composite `(field, id)` cursor), so it round-trips\n"
                out += "    /// through the same decoder as the JS client; `limit:` is required\n"
                out += "    /// so the bare `\(method)()` overload above still binds. Mirrors the\n"
                out += "    /// JS `\(method)({ limit, afterCursor, beforeCursor, direction })`\n"
                out += "    /// paginated accessor. `hasMore` is the over-fetch signal for more\n"
                out += "    /// rows in the current paging direction.\n"
                out += "    \(access) func \(method)(\n"
                out += "        limit: Int,\n"
                out += "        afterCursor: String? = nil,\n"
                out += "        beforeCursor: String? = nil,\n"
                out += "        direction: CursorDirection = .forward\n"
                out += "    ) throws -> PagedQueryResult<\(targetType)> {\n"
                out += "        let page = try JsBaoClient.requireDefault()\n"
                out += "            .codegen.hasManyThrough(\n"
                out += "                target: \(targetType).primitiveSchema,\n"
                out += "                joinModel: \(joinType).primitiveSchema,\n"
                out += "                sourceId: id,\n"
                out += "                joinModelLocalField: \(quoted(localField)),\n"
                out += "                joinModelRelatedField: \(quoted(relatedField))\(joinOrderArgs),\n"
                out += "                limit: limit,\n"
                out += "                afterCursor: afterCursor,\n"
                out += "                beforeCursor: beforeCursor,\n"
                out += "                direction: direction\n"
                out += "            )\n"
                out += "        return PagedQueryResult(\n"
                out += "            data: page.data.compactMap { \(targetType)(row: $0) },\n"
                out += "            nextCursor: page.nextCursor,\n"
                out += "            prevCursor: page.prevCursor,\n"
                out += "            hasMore: page.hasMore\n"
                out += "        )\n"
                out += "    }\n\n"
                out += "    /// Typed query-time include payload for `\(rname)`, when present in `related`.\n"
                out += "    /// Query-time includes do not yet build `hasManyThrough` payloads, so\n"
                out += "    /// this is populated only if `_related[\(quoted(rname))]` was attached manually.\n"
                out += "    \(access) var \(relatedAccessor): [\(targetType)] {\n"
                out += "        if related.contains(\(quoted(rname))) {\n"
                out += "            return related.many(\(quoted(rname)), as: \(targetType).self)\n"
                out += "        }\n"
                out += "        return related.many(\(targetType).modelName, as: \(targetType).self)\n"
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

    /// Render the trailing order-argument fragment for a relationship
    /// accessor — empty when no order is declared. Leading comma + newline
    /// so it folds into the multi-line call. The labels default to
    /// `hasMany`'s `orderByField:` / `orderDirection:`; the `hasManyThrough`
    /// join leg overrides them with `joinModelOrderByField:` /
    /// `joinModelOrderDirection:`.
    private func relationshipOrderArgs(
        field: String?,
        direction: String?,
        fieldLabel: String = "orderByField",
        directionLabel: String = "orderDirection"
    ) -> String {
        guard let field else { return "" }
        var s = ",\n                \(fieldLabel): \(quoted(field))"
        if let direction {
            s += ",\n                \(directionLabel): \(quoted(direction))"
        }
        return s
    }

    private func includeSortDefault(field: String?, direction: String?) -> String {
        guard let field else { return "nil" }
        let descending = direction?.uppercased() == "DESC"
        return "[\(quoted(field)): \(descending ? "-1" : "1")]"
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

    /// Emit one stored property per schema field, each carrying a `didSet`
    /// that records the assignment in `_changedFields` (#2459).
    ///
    /// This is the Swift analogue of js-bao's `setValue` → `_localChanges`:
    /// `save(in:)` writes only the fields the caller actually assigned, so
    /// two devices editing different fields of the same record merge instead
    /// of clobbering. Property observers do not fire for the initializers'
    /// own assignments, which is exactly right — each init below sets
    /// `_changedFields` explicitly to what that construction path means.
    private func storedProperties(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = ""
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname] else { continue }
            out += "    \(access) var \(propName(fname)): \(swiftStoredType(f, fieldName: fname)) {\n"
            out += "        didSet { _changedFields.insert(\(quoted(fname))) }\n"
            out += "    }\n"
        }
        return out
    }

    // MARK: - Change tracking (#2459)

    /// Emit the non-persisted `_changedFields` set plus `discardChanges()`.
    /// Mirrors js-bao's `_localChanges` / `discardChanges()`: the write
    /// facade passes the set to the runtime, which writes only those fields
    /// when the record already exists.
    private func changeTrackingMembers(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = ""
        out += "    /// Fields assigned since this value was constructed or read\n"
        out += "    /// from the store — js-bao's `_localChanges`. `save(in:)` writes\n"
        out += "    /// only these when the record already exists, so a save built\n"
        out += "    /// from a stale read can't clobber another device's concurrent\n"
        out += "    /// edit to a field you never touched. A record built through an\n"
        out += "    /// initializer starts with every field it carries marked changed\n"
        out += "    /// (it's new data); one read back out of the store starts clean.\n"
        out += "    /// Inserting a record that doesn't exist yet always writes every\n"
        out += "    /// field, whatever this holds.\n"
        out += "    /// Not part of the record's persisted/equatable identity.\n"
        out += "    \(access) private(set) var _changedFields: Set<String> = []\n\n"
        out += "    /// Forget the pending field changes without writing them, so a\n"
        out += "    /// later `save(in:)` treats this value as unmodified. Mirrors\n"
        out += "    /// js-bao's `discardChanges()`. The field values themselves are\n"
        out += "    /// left alone — re-read the record to get the stored ones back.\n"
        out += "    \(access) mutating func discardChanges() {\n"
        out += "        _changedFields = []\n"
        out += "    }\n\n"
        out += "    /// Mark every field this record carries as changed, so the next\n"
        out += "    /// `save(in:)` writes all of them even if nothing was assigned.\n"
        out += "    /// The counterpart to `discardChanges()`.\n"
        out += "    ///\n"
        out += "    /// Use it to force a whole-record write: saving a record you READ\n"
        out += "    /// out of the store into another document that already holds it is\n"
        out += "    /// an update with an empty change set, so it writes nothing. Call\n"
        out += "    /// this first when you mean \"copy the whole record over\":\n"
        out += "    ///\n"
        out += "    ///     var copy = try Model.find(id)!\n"
        out += "    ///     copy.markAllChanged()\n"
        out += "    ///     try copy.save(in: otherDocId)\n"
        out += "    ///\n"
        out += "    /// Every field it writes wins last-writer-wins against a concurrent\n"
        out += "    /// remote edit to that field, which is the cost of a full copy.\n"
        out += "    \(access) mutating func markAllChanged() {\n"
        out += "        _changedFields = Set(primitiveValues().keys)\n"
        out += "    }\n"
        return out
    }

    /// Emit an explicit `init(from:)` so a decoded value is treated like a
    /// constructed one: every decoded field counts as a change. The
    /// compiler's synthesized decode would leave `_changedFields` at its
    /// empty default, and a decoded record would then silently save nothing
    /// over an existing record (#2459). `encode(to:)` stays synthesized.
    private func codableDecodeInit(schema: ParsedSchema) -> String {
        let access = options.accessLevel
        var out = ""
        out += "    /// Decode a record. A decoded value is treated like a\n"
        out += "    /// constructed one — every decoded field is marked changed, so\n"
        out += "    /// `save(in:)` writes all of them.\n"
        out += "    \(access) init(from decoder: Decoder) throws {\n"
        out += "        let container = try decoder.container(keyedBy: CodingKeys.self)\n"
        for fname in displayFieldOrder(schema) {
            guard let f = schema.fields[fname] else { continue }
            let stored = swiftStoredType(f, fieldName: fname)
            let base = stored.hasSuffix("?") ? String(stored.dropLast()) : stored
            let call = stored.hasSuffix("?") ? "decodeIfPresent" : "decode"
            out += "        self.\(propName(fname)) = try container.\(call)(\(base).self, forKey: .\(propName(fname)))\n"
        }
        out += "        self.related = .empty\n"
        out += "        self._changedFields = Set(primitiveValues().keys)\n"
        out += "    }\n"
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
        out += "        self.related = .empty\n"
        // A constructed record is new data: every field it carries counts as
        // a change, matching js-bao's `new Model({...})` (#2459).
        out += "        self._changedFields = Set(primitiveValues().keys)\n"
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
        out += "        self.related = .empty\n"
        // Read back from the store: nothing is pending. A later `save(in:)`
        // writes only what the caller assigns from here on (#2459).
        out += "        self._changedFields = []\n"
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
        out += "        self.related = RelatedRecords(raw: row[\"_related\"] as? [String: Any] ?? [:])\n"
        // Read back from the store: nothing is pending (#2459).
        out += "        self._changedFields = []\n"
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
