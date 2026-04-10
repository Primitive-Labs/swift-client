# BaoModels & Queries

## Overview

`BaoModel<T>` provides typed, protocol-based access to records stored in Yjs documents — the Swift mirror of `js-bao`'s `BaseModel`. Each model is backed by a `Y.Map` where records are nested `Y.Map` instances keyed by record ID. On top of this CRDT layer, a **SQLite query engine** mirrors the data into an in-memory relational database, enabling MongoDB-style filtering, sorting, and aggregation.

> **Naming note:** This used to be called `Collection<T>`, but that conflicted with both Swift's standard library `Collection` protocol and `CollectionsAPI` (the Primitive platform feature for grouping documents — a different concept). The rename to `BaoModel<T>` matches the JS client's `BaseModel` from `js-bao`.

## Defining a BaoModel Record

Conform to `BaoModelRecord` to define your schema:

```swift
struct Page: BaoModelRecord {
    static let modelName = "pages"
    static let fields: [FieldDefinition] = [
        FieldDefinition("title", .string),
        FieldDefinition("priority", .number),
        FieldDefinition("done", .boolean),
        FieldDefinition("tags", .json, optional: true),
    ]

    let id: String
    var title: String
    var priority: Int
    var done: Bool
    var tags: [String]?

    init(fields: [String: Any]) {
        self.id = fields["id"] as? String ?? ""
        self.title = fields["title"] as? String ?? ""
        self.priority = fields["priority"] as? Int ?? 0
        self.done = fields["done"] as? Bool ?? false
        self.tags = fields["tags"] as? [String]
    }

    func toFields() -> [String: Any] {
        var f: [String: Any] = [
            "id": id,
            "title": title,
            "priority": priority,
            "done": done,
        ]
        if let tags { f["tags"] = tags }
        return f
    }
}
```

## CRUD Operations

```swift
let doc = try await client.openDocument(docId: docId)
let pages = BaoModel<Page>(doc: doc)

// Create
let page = try pages.create(Page(fields: [
    "id": "page-1",
    "title": "My Page",
    "priority": 1,
    "done": false,
]))

// Read
let found = try pages.find("page-1")

// Read all
let all = try pages.findAll()

// Update
try pages.update("page-1", fields: ["done": true])

// Delete
try pages.delete("page-1")
```

All writes go through Yjs transactions, so they're automatically synced to other clients via CRDT.

## Query Engine

After mutations, sync the data to the query engine, then run MongoDB-style filters:

```swift
// Sync CRDT data → SQLite mirror
try pages.syncToQueryEngine()

// Simple equality
let done = try pages.filter(["done": true])

// Comparison operators
let highPriority = try pages.filter(["priority": ["$gte": 3]])

// Text search
let matching = try pages.filter(["title": ["$containsText": "review"]])

// Logical operators
let complex = try pages.filter([
    "$or": [
        ["done": true],
        ["priority": ["$gte": 5]],
    ]
])
```

### Supported Filter Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `$eq` | Equal (also bare value) | `["status": "active"]` or `["status": ["$eq": "active"]]` |
| `$ne` | Not equal | `["status": ["$ne": "archived"]]` |
| `$gt` | Greater than | `["priority": ["$gt": 3]]` |
| `$gte` | Greater than or equal | `["priority": ["$gte": 3]]` |
| `$lt` | Less than | `["priority": ["$lt": 3]]` |
| `$lte` | Less than or equal | `["priority": ["$lte": 3]]` |
| `$in` | In array | `["status": ["$in": ["active", "pending"]]]` |
| `$nin` | Not in array | `["status": ["$nin": ["archived"]]]` |
| `$containsText` | Case-insensitive substring | `["title": ["$containsText": "review"]]` |
| `$startsWith` | Starts with | `["title": ["$startsWith": "Draft"]]` |
| `$endsWith` | Ends with | `["title": ["$endsWith": ".md"]]` |
| `$exists` | Field exists / is non-null | `["tags": ["$exists": true]]` |
| `$and` | All conditions match | `["$and": [filter1, filter2]]` |
| `$or` | Any condition matches | `["$or": [filter1, filter2]]` |

### Aggregation

```swift
let stats = try pages.aggregate(
    groupBy: "done",
    operations: [
        .count("total"),
        .avg("priority", as: "avgPriority"),
        .sum("priority", as: "totalPriority"),
    ]
)
// → [["done": true, "total": 5, "avgPriority": 2.4, ...], ...]
```

## How It Works Internally

1. `BaoModel<T>` reads/writes directly to `Y.Map` instances inside the `YDocument`
2. `BaoModelQueryEngine` maintains a separate in-memory SQLite database
3. The mirror is rebuilt **lazily and only when dirty**: `BaoModel<T>` subscribes to `YDocument.observeUpdate` at init time and flips an internal dirty flag whenever the doc commits any transaction (local OR remote). The next call to `query` / `count` / `aggregate` claims the flag and rebuilds the SQLite table from the current Y.Map state. Repeated queries with no intervening mutations are O(result-set), not O(n) — they reuse the existing mirror.
4. `filter()` calls `QueryTranslator` to convert the `DocumentFilter` dictionary into a SQL `WHERE` clause with parameterized bindings
5. Results are read from SQLite and converted back to `T` instances via `init(fields:)`

The SQLite mirror is **read-only from the query engine's perspective** — all writes go through Yjs. You normally don't need to do anything to keep it current; the dirty flag handles it. The escape hatch `refreshQueryIndex()` exists for cases where you've mutated the underlying Y.Doc by some path that bypasses the doc's update notifications (rare — `observeUpdate` covers every committed transaction).

## Why Use BaoModel Instead of Raw YDocument

`BaoModel<T>` is the recommended API for storing structured data in Primitive documents. Beyond the typed records and SQL-backed queries, it also handles a non-obvious correctness rule for you:

> **yrs's underlying lock is not reentrant.** If you call `YDocument`'s doc-level factory methods (`getOrCreateText/Array/Map(named:)`) from inside an already-open `transactSync { ... }` closure on the same thread, the lock acquisition deadlocks the calling thread against itself with no error. This is a [known footgun](yswift-fork.md#transaction-aware-get-or-insert-deadlock-fix) inherited from yswift's port of Yjs's API surface.

`BaoModel<T>` sidesteps this by caching the root `Y.Map` reference once at init time (outside any transaction) and using the held transaction for all reads/writes. As a `BaoModel` user, you never have to think about the rule — your code just works.

### When you DO need to write raw `Y.Map` / `Y.Text` / `Y.Array` directly

If `BaoModel` doesn't fit (e.g. you're embedding a rich text editor or building a custom CRDT structure), use the **transaction-aware factory methods** on `YDocument` from inside any `transactSync` closure:

```swift
// ✅ Safe — works inside any open transaction
doc.transactSync { txn in
    let map: YMap<String> = doc.getOrInsertMap(named: "myKey", transaction: txn)
    let text: YText = doc.getOrInsertText(named: "body", transaction: txn)
    let arr: YArray<String> = doc.getOrInsertArray(named: "items", transaction: txn)

    map.updateValue("hello", forKey: "greeting", transaction: txn)
    text.append("world", in: txn)
    arr.insert(at: 0, value: "first", transaction: txn)
}
```

The `getOrInsert*(named:transaction:)` methods take an explicit `YrsTransaction` parameter, so the type system makes it impossible to call them outside an open transaction. They route through the held `TransactionMut` instead of taking a fresh doc lock — no deadlock possible.

**Avoid:**

```swift
// ⚠️ DEADLOCKS — never do this
doc.transactSync { txn in
    let map = doc.document.getMap(name: "myKey")  // ← hangs forever
    // ...
}

// ⚠️ ALSO DEADLOCKS
doc.transactSync { txn in
    let map: YMap<String> = doc.getOrCreateMap(named: "myKey")  // ← hangs forever
    // ...
}
```

The doc-level `getOrCreate*(named:)` methods are still useful **outside** any transaction (e.g. cached at object init time, like `BaoModel<T>` does internally) — but inside a transaction you must use the `getOrInsert*(named:transaction:)` variants. See [yswift-fork.md](yswift-fork.md#transaction-aware-get-or-insert-deadlock-fix) for the full technical history of why.
