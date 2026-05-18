# Typed model authoring

How to define typed records and query them.

The Swift client has three layers of model access. Pick the one that fits your use case.

| Layer | Use when | Source of typing |
|---|---|---|
| **`TypedModel<T>`** | You have a typed struct (usually codegen-emitted from a TOML schema) | Compile-time |
| **`DynamicModel`** | The schema isn't known at compile time, OR you need a method `TypedModel<T>` doesn't expose yet | Runtime (`PrimitiveSchema`) |
| **Raw `YDocument`** | Real-time text editing (Y.Text), custom CRDT structures, anything below the model layer | None |

Most app code uses `TypedModel<T>`.

## Defining a model — the codegen path

Author a TOML schema, run `swift-bao-codegen` (build-time SwiftPM plugin, see #509), get a struct that conforms to `PrimitiveModel`:

```toml
# schema.toml
[models.tasks]
class_name = "TaskRecord"

[models.tasks.fields.id]
type = "id"

[models.tasks.fields.title]
type = "string"
required = true

[models.tasks.fields.priority]
type = "number"
indexed = true

[models.tasks.fields.completed]
type = "boolean"

[models.tasks.fields.tags]
type = "stringset"
```

Codegen emits `TaskRecord.swift`:

```swift
internal struct TaskRecord: PrimitiveModel, Equatable, Hashable, Codable {
    internal static let modelName = "tasks"
    internal static let primitiveSchema = PrimitiveSchema(...)

    internal var id: String
    internal var title: String
    internal var priority: Double?
    internal var completed: Bool?
    internal var tags: Set<String>?

    internal init(...) { ... }
    internal init?(record: PrimitiveRecord) { ... }
    internal init?(row: [String: Any]) { ... }
    internal func primitiveValues() -> [String: PrimitiveValue] { ... }
}
```

You don't write any of the boilerplate — codegen produces it from the TOML.

## CRUD via `TypedModel<T>`

```swift
let doc = try await client.openDocument(docId: docId)
let tasks = TypedModel<TaskRecord>(doc: doc)

// Create
let task = TaskRecord(id: "t-1", title: "Write docs", priority: 5, completed: false, tags: nil)
try tasks.create(task)

// Read
if let found = tasks.find(id: "t-1") {
    print(found.title)
}

// Read all
for t in tasks.findAll() {
    print(t.title)
}

// Query (filter + sort)
let highPriority: [TaskRecord] = tasks.query(
    ["priority": ["$gte": 3]],
    options: QueryOptions(sortOrder: ["priority": -1])
)

// Delete
tasks.delete(id: "t-1")
```

`TypedModel<T>.query(...)` returns `[T]` already hydrated — no manual `compactMap(T.init(row:))` needed.

For **paginated queries** (cursor + nextCursor), drop to `tasks.dynamic.queryPaged(...)`. `TypedModel<T>.query(...)` returns `[T]` but currently drops the cursor — see [`parity/query-engine.md`](parity/query-engine.md). v1.1 will lift this into the typed surface.

## When to use `DynamicModel`

Either you don't have a codegen wrapper for the model, or you need an op that `TypedModel<T>` doesn't surface yet:

```swift
// schemaless: schema loaded at runtime
let schema = try TomlSchemaLoader.parse(toml)
let dyn = DynamicModel(doc: doc, schema: schema)

// CRUD via stringly-typed PrimitiveRecord
try dyn.create(id: "rec-1", values: [
    "title": .string("Hello"),
    "priority": .number(1)
])

if let rec = dyn.find(id: "rec-1") {
    let title = rec["title"]?.asString    // optional, stringly-typed
}

// Pagination — the typed surface lacks this currently, dynamic has it
let page = try dyn.queryPaged(filter, options: opts)
print(page.data, page.nextCursor)
```

`DynamicModel` is also where **subscriptions**, **observers**, and **batch reconciliation** live — see `Sources/JsBaoClient/Schema/DynamicModel.swift`.

> **⚠️ The 1,431-line file is intentionally bundling 7 concerns** (CRUD / query / observers / listeners / reconciliation / internals / helpers). It's structurally fine but worth splitting in a v1.1 cleanup.

## Relationships

Defined in TOML:

```toml
[models.users.relationships.posts]
type = "hasMany"
model = "posts"
related_id_field = "userId"
order_by_field = "createdAt"
order_direction = "ASC"

[models.posts.relationships.author]
type = "refersTo"
model = "users"
related_id_field = "userId"

[models.posts.relationships.tags]
type = "hasManyThrough"
model = "tags"
join_model = "post_tag_links"
join_model_local_field = "postId"
join_model_related_field = "tagId"
```

Resolution:

```swift
// On a typed instance
let user: UserRecord = ...
let posts = try await user.posts(in: doc)         // [PostRecord]
let post: PostRecord = ...
let author = try await post.author(in: doc)        // UserRecord?
let tags = try await post.tags(in: doc)            // [TagRecord]

// Or batch via Include (efficient — single batch lookup, no N+1)
let postsWithAuthors = users.findAll().map {
    Include($0, [\.author])
}
```

Status: `refersTo`, `hasMany`, `hasManyThrough` all parity with js-bao. The lazy `record.posts()` path uses `findAll().filter` (O(N), no pagination); the batch `Include` path uses the query engine. See [`parity/schema-and-models.md`](parity/schema-and-models.md).

## Multi-doc indexing

Sometimes you want to query records across **all** documents the user has access to, not just one:

```swift
let multi = MultiDocModel<TaskRecord>(client: client)
let all = try await multi.query(["completed": false])
```

`MultiDocModel` is the Swift counterpart of js-bao's `BaseModel.dbInstance`. Same indexing layer, different namespace. Used heavily by storylens for cross-document task lists.

## What's in / out of v1

- **In:** TOML codegen, `TypedModel<T>` CRUD, `DynamicModel` full surface, three relationship types, multi-doc indexing, Mongo-style filters, sort, cursor pagination, batch `Include`, observers.
- **Out for v1:** `update`/`queryOne`/`findByUnique` on `TypedModel<T>` (use `model.dynamic.*`), function defaults in TOML, `refersToMany` relationship type.

See [`exclusions-v1.md`](exclusions-v1.md).

## When to drop below the model layer

Use raw `YDocument` directly for:
- **Y.Text** rich text editors
- **Custom CRDT structures** that don't fit the record model
- **Existing Yjs migrations** where you need direct access

```swift
doc.transactSync { txn in
    // IMPORTANT: inside an open transaction, use getOrInsertMap(named:transaction:),
    // NOT the doc-level getOrCreateMap(named:). The latter re-acquires the
    // underlying yrs lock and deadlocks the calling thread. See yswift-fork.md.
    let map: YMap<String> = doc.getOrInsertMap(named: "myData", transaction: txn)
    map.updateValue("world", forKey: "hello", transaction: txn)
}
```

## Further reading

- [`parity/schema-and-models.md`](parity/schema-and-models.md) — js-bao parity per concept
- [`parity/query-engine.md`](parity/query-engine.md) — operator/sort/cursor parity
- [`parity/wire-format.md`](parity/wire-format.md) — wire-format invariants
- [`yswift-fork.md`](yswift-fork.md) — why the YSwift fork exists
- `Sources/JsBaoClient/Schema/` — the source
