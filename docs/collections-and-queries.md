# Collections & Queries

## Overview

Collections provide typed, protocol-based access to data stored in Yjs documents. Each collection is backed by a `Y.Map` where records are nested `Y.Map` instances keyed by record ID. On top of this CRDT layer, a **SQLite query engine** mirrors the data into an in-memory relational database, enabling MongoDB-style filtering, sorting, and aggregation.

## Defining a Collection Record

Conform to `CollectionRecord` to define your schema:

```swift
struct Page: CollectionRecord {
    static let collectionName = "pages"
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
let pages = Collection<Page>(document: doc)

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

1. `Collection<T>` reads/writes directly to `Y.Map` instances inside the `YDocument`
2. `CollectionQueryEngine` maintains a separate in-memory SQLite database
3. `syncToQueryEngine()` iterates all records in the Y.Map and upserts them into SQLite
4. `filter()` calls `QueryTranslator` to convert the `DocumentFilter` dictionary into a SQL `WHERE` clause with parameterized bindings
5. Results are read from SQLite and converted back to `T` instances via `init(fields:)`

The SQLite mirror is **read-only from the query engine's perspective** — all writes go through Yjs. Call `syncToQueryEngine()` or `refreshQueryIndex()` after mutations to keep the mirror current.
