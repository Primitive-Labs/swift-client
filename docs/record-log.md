# Record-log documents on the Swift client

A **record-log document** (`documentFormat: 3`) keeps its records in the
client's own SQLite database and syncs them as *entries*: each save is one
entry the room numbers, applies, and relays to every other client. The client
answers reads from its local view at once, sends entries in the background,
and learns the room's verdict on each.

You use one through the same model facade as any document.

```swift
let client = JsBaoClient(options: JsBaoClientOptions(
    apiUrl: apiUrl, wsUrl: wsUrl, appId: appId, token: jwt,
    storageConfig: .sqlite(directory: databaseDirectory)
))
client.registerModels([noteSchema])
try await client.connect()

let created = try await client.createDocument(options: CreateDocumentOptions(
    title: "Field notes", documentFormat: 3
))
let documentId = created.metadata?["documentId"]?.stringValue ?? ""
_ = try await client.openDocument(documentId)

let notes = client.sharedModel("Note")?.member(docId: documentId)
_ = try notes?.create(id: "n1", values: ["title": .string("first")])
let open = try notes?.query(["done": false])
```

`create`, `update`, `save`, `upsert`, `delete`, `addStringsetMember`,
`removeStringsetMember`, `find`, `findAll`, `findByUnique`, `query`,
`queryPaged`, `count`, `aggregate`, the `PrimitiveRecord` accessors and
`subscribe` all work as they do on an ordinary document. A save returns once it
is applied locally; reads answer from the local store, offline included.

A device that never saw the document learns its format from the documents API
before it opens it, as long as it may use the network.

## Storage

The document's records live in the provider's SQLite file, so the client needs
`.sqlite` storage: opening one on `.memory` throws
`JsBaoError(code: .format2StorageUnavailable)` with `details.reason`
`"not-persistent"`, before anything is sent. `documentFormat: 3` cannot be
combined with `localOnly: true` (`.localOnlyUnsupportedOption`).

Closing a document keeps its store, and the next open catches up from where it
left off. Evicting it, or `logout(wipeLocal: true)`, removes it; writes the room
had not received are handed back as one `DocumentWriteRefusedEvent` with
`.documentStorePurged`.

### What a crash can lose

Saves issued together share one commit, made at `synchronous=NORMAL` within a
few milliseconds of the first. An app or process crash loses nothing that was
saved. An OS crash or a power loss may lose the last few commits — the saves of
the last moments before it. Anything a save's `confirm: true` returned for is
held by the room.

### Signing in as someone else

The store belongs to the user it was written for. When another user signs in on
the same client — or a relaunch over the same directory signs in as someone
else — the store is reset: the previous user's rows, unsent writes and query
rows are removed, and nothing is raised for those writes, which were theirs. The
same user signing back in keeps everything, and their unsent writes are sent.

## When the room refuses a write

A write that succeeded locally can still be refused by the room. The client
reverts it and reports it once, as a `DocumentWriteRefusedEvent`:

```swift
let refusals = client.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { event in
    switch event.error.code {
    case .documentConstraintViolated:
        // Another record took the unique key first: event.conflictingRecord.
        break
    case .documentOfflineWindowExpired, .documentEpochFrozen:
        // This client was away too long; nothing it wrote meanwhile applied.
        break
    default:
        break
    }
    for write in event.writes ?? [] {
        // model, recordId, kind (.create/.patch/.delete), fields, stringSetDeltas
    }
}
```

`writes` carries every write handed back, in the order it was made, with its
values. A constraint refusal also reverts the later writes that depended on the
refused one, and the writes saved together with them; records outside that are
untouched. `error.details` carry `documentId`, `scope`, and when known `from`,
`seq`, `constraint` and `conflicting`.

Some writes are refused before they are saved, and throw:

| Code | Why |
|---|---|
| `UniqueConstraintViolationError` | A record this client can see already holds the key |
| `.documentEpochBudget` | Offline long enough to fill two epochs' worth of writes; connect so the room can rotate |
| `.documentEntryTooLarge` | The write is over 1 MiB of JSON |
| `.documentEntryInvalid` | A field named `type` or starting with `_` (the room reserves them; rename the field), or a value the wire cannot carry exactly: a non-finite number, or an integer outside ±2^53 |
| `.accessDenied` | The room allows this client to read the document only |

The three `.document…` refusals are also reported as a
`DocumentWriteRefusedEvent` carrying the one write.

## Upserts

`upsert(_:on:)` on a unique field resolves locally against the records this
client can see. When none holds the value, the create travels as an upsert and
the room resolves it: two clients that upsert the same key while apart end with
one record holding both clients' fields. A handle on the id that lost reads the
record it was merged into.

## Waiting for the room

```swift
let saved = try await notes?.save(id: "n1", values: ["title": .string("final")], confirm: true)
```

With `confirm: true` the save returns once the room has acknowledged it, and
throws the refusal's `JsBaoError` if the room refuses it (or `.notFound` if the
document closes first). On other documents `confirm` changes nothing.

`PrimitiveRecord.syncState` says where a record stands: `.pending` while a write
of this client touching it is unacknowledged, `.refused` when the save that
returned this handle was handed back, `.confirmed` otherwise, and `nil` on other
documents. A model's `subscribe` listeners hear a record become confirmed.

## Saving together

```swift
try notes?.transact {
    try notes?.update(id: "n1", values: ["status": .string("done")])
    _ = try tags?.create(id: "t1", values: ["label": .string("done")])
}
```

The saves a `transact` makes on the document, on any of its models, are one
entry: the room applies or refuses them together. They are committed when the
outermost `transact` returns — even when its body throws. Unique constraints
inside the body see its own saves (two creates with one key: the second
throws; deleting a holder frees its key), and each model's `subscribe`
listeners hear the batch once, after it is applied.

## Bulk loads and checkpoint segments

Rows that arrive in bulk reach the client as compressed chunks rather than one
by one over the socket: a load committed through the document's ingest routes
(`primitive documents ingest`, or `client.documents.ingests`), and the room's
checkpoint segment when the client was away long enough to fall behind it.
Nothing changes in how you read them:

```swift
let stop = notes?.subscribe {
    // Heard once per chunk while a load arrives.
    reload()
}
```

A connected client is told when a load completes and reads its chunks through
a short-lived link the room grants. A client that was offline reads the same
chunks when it reconnects. Either way the load's rows, with every write ordered
after the load applied on top and the rows the room refused left out, become
queryable within about 10 seconds at 100,000 rows. Saves made while the chunks
arrive apply locally at once and are sent when the receipt completes.

To load rows from the app itself, build the chunks with
`client.documents.ingests.buildChunks(rows:)` and drive the session with
`create(documentId:options:)`, `uploadChunk`, `commit` and `get` until it reads
`complete`, `failed` or `aborted`; `abort` gives one up. Which writes come
after the load is the session's `reserveEpoch`: with `.open` (the default) the
load is ordered when the session is created, so every write made while it
uploads and applies wins over it; with `.commit` it is ordered at commit, so a
write made while the chunks were uploading loses to it.

If a receipt fails twice in a row (the link expired, a chunk could not be read),
the next open asks for rows instead, so the document always catches up. A
receipt cut short (the app quit, the connection dropped) is not lost work: the
next open reads the load again, or, when the room answers it with rows, reads
the whole table once to drop anything the cut-short receipt applied that the
room did not keep.

## Gotchas

- A filtered read (`query`, `count`, `aggregate`) on a model with members in a
  record-log document and an ordinary document at once throws
  `.format2QueryScope`. Scope it with `QueryOptions.documents`; `find(id:)` and
  `findAll()` read both.
- A large document (`documentFormat: 2`) is no longer served. A create that
  asks for one, and an open of one, throws `.documentFormatUnsupported` before
  anything is sent; whatever an older build stored for it stays on the device
  until `logout(wipeLocal: true)`. An export of one made by an earlier
  release loads into a record-log document with
  `primitive documents ingest <document-id> --input <export-dir>`.
- A write into the document's `YDocument` directly is never sent: the room
  refuses Yjs traffic for a record-log document.
- Give each `JsBaoClient` its own storage directory. Two clients over one
  database file are not supported: when one is replacing the document's rows,
  the other waits up to 30 seconds before opening the document again.
