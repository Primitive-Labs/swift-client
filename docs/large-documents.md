# Large documents on the Swift client

A **large document** (`documentFormat: 2`) is a Primitive document whose records
live in SQLite rather than in the Yjs document. The Yjs document holds only the
*current epoch's overlay* — the changes since the last rotation — and the
records themselves are rows in the client's own database, materialized from a
base snapshot the server builds and from the overlays sealed since.

That is what lets one document hold far more than a CRDT document can: validated
at 320 MB, designed for 2 GB. It is also why an ordinary document and a large
one behave differently in a few places, all of which are listed below.

**Ordinary (format-1) documents are untouched by everything on this page.** A
client that never opens a large document builds none of this machinery: no
record store, no observer, no extra table in its database.

## Opening one

A large document is created with `documentFormat: 2` and opened like any other:

```swift
let client = JsBaoClient(options: JsBaoClientOptions(
    apiUrl: apiUrl,
    wsUrl: wsUrl,
    appId: appId,
    token: jwt,
    // A large document IS its local store, so the client needs somewhere to
    // keep it. `.memory` is refused — see "Storage" below.
    storageConfig: .sqlite(directory: databaseDirectory)
))
client.registerModels([noteSchema])
try await client.connect()

let created = try await client.createDocument(options: CreateDocumentOptions(
    title: "Field notes",
    documentFormat: 2
))
let documentId = created.metadata?["documentId"]?.stringValue ?? ""
let doc = try await client.openDocument(documentId)

// The generated facade, exactly as on an ordinary document.
let notes = client.sharedModel("Note")?.member(docId: documentId)
_ = try notes?.create(id: "n1", values: ["title": .string("first")])
```

`CreateDocumentOptions.documentFormat` accepts `1` or `2`; it is written to the
local metadata row and to the commit the client posts. `DocumentInfo
.documentFormat` reports what a document is.

## What the client does behind that

- **It declares what it reads.** Every `syncStep1` carries `formats: [1, 2]` and
  `manifestVersion: 3`. A room hosting a large document closes any connection
  whose handshake does not declare `2`, with WebSocket close code **4426** and
  an `error` frame carrying `CLIENT_UPGRADE_REQUIRED`. The client surfaces that
  as `ConnectionErrorEvent(messageType: "syncStep1")` and a
  `JsBaoError(code: .clientUpgradeRequired)` from the waiting `openDocument`,
  and it does **not** reconnect on 4426 — the refusal is of this client build,
  not of this moment.
- **It raises the socket's receive limit.** `epoch.info` grows with the sealed
  chain, so it is the frame most likely to exceed Foundation's 1 MiB default,
  and `URLSessionWebSocketTask` fails the *receive* rather than the handler on
  an oversized message. The limit is settled to 16 MiB before the socket is
  built, for any session that is not known to hold only format-1 documents. A
  client whose documents all resolve locally as format 1 keeps Foundation's
  default.
- **It holds everything local until the room answers.** From the moment a
  socket opens (or a large document binds, whichever is first) until that
  connection's `epoch.info` has been handled, nothing this client holds locally
  goes out on it: not the reconnect flush, not the queued updates, not the
  `syncStep2` answer. Held means **kept** — the frames go out, in order, when
  the hold releases.
- **It stamps what each frame carries.** An outbound `update` for a large
  document carries `seq`, `seqFrom` and `ackedSeq`, and the room answers
  `update.ack { maxContiguousSeq }`. That acknowledgement is the only thing
  that prunes the durable log of writes this client still owes.

## Storage

A large document needs persistent on-device storage, because the document IS
the local store. Opening one on a client configured with `.memory` storage
throws before a single frame goes out:

```swift
JsBaoError(code: .format2StorageUnavailable, details: ["reason": "not-persistent"])
```

The capability is a conformance, not a probe: a provider that keeps nothing on
disk does not implement the record store's host protocol, so the question is
answered by the type system.

## Reading and writing

Reads and writes go through the same generated facade as an ordinary document.
`find`, `findAll`, `query`, `count`, `aggregate`, `create`, `update`, `delete`
and the record handle's accessors all answer from the merged view.

Two rules are worth knowing:

- **A write commits before it publishes.** The merged row and the pending-op
  entry are written in one SQLite transaction, and only then is the change
  applied to the epoch's Yjs document — which is what sends it. A SQLite
  failure therefore publishes nothing: no peer sees a write this client could
  not record. Read-your-writes holds, because the commit precedes the return.
- **A filtered read is scoped.** A model with members in both an ordinary and a
  large document at once cannot answer an unscoped `query`/`count`/`aggregate`
  — the rows live in different engines — and refuses with
  `JsBaoError(code: .format2QueryScope)`. Scope the read to the documents you
  mean. With members of one kind only, nothing changes.

## The cold load

A client that has never seen a large document does not replay its history;
there is none to replay. It streams the chunks of the latest base snapshot into
its own records table, and the load is:

- **resumable** — each chunk's rows and its mark commit together, so an
  interrupted load re-fetches only what never landed;
- **verified** — a chunk's byte length and SHA-256 are checked *before* it is
  decompressed, and a chunk that is still wrong after one re-fetch ends the
  load rather than completing a wrong one;
- **progressive** — `document:snapshot-load` reports `started`, `progress`,
  `model` and `loaded` phases, so an app can show a base arriving rather than a
  spinner that might be a hang.

```swift
client.eventEmitter.subscribe(DocumentSnapshotLoadEvent.self) { event in
    print(event.phase, event.rows, "/", event.totalRows)
}
```

Manifests are read at version 2 and 3, including the sourced chunk-path form a
build writes when it carries a chunk forward from an earlier one. A manifest
this client cannot read is refused by name:
`JsBaoError(code: .snapshotManifestUnsupported)` says "upgrade the client";
`.snapshotManifestInvalid` says the manifest is not internally consistent.

## When a document stops

Some states cannot be advanced in place by this client build. In all of them
the document is **stopped**, not broken: reads keep answering from the local
merged view, the writes this client owes are still owed and still recorded, and
nothing local is discarded.

- The sealed chain cannot be trusted — it skips an epoch, or retention has
  pruned an archive it needs — **and no base is on offer to start from
  instead**. When one is, the document reloads from it rather than stopping;
  see "Reloading from a base".
- An archive the chain needs cannot be READ, twice.

A stopped document refuses writes with
`JsBaoError(code: .format2ReloadRequired)`, whose `details.plan` names why, and
emits `ConnectionErrorEvent` with `messageType: "epoch.info"` or
`"epoch.seal"`. A later `snapshot.ready` is the retry: a build completing is
exactly the base a stopped document was waiting for, and it reloads then.

A bulk load is **not** a stop. A document whose only obstacle is a
`baseDiscontinuity` is *held* — reads answer, local writes commit, nothing goes
out — until the base the ingest produced is announced. See "Crossing a bulk
load".

A seal that skips epochs is **not** a stop: the sealed chain between this
client and the room is applied and then the document moves — see "Catching up
over the sealed chain" below. Nor is an ordinary `epoch.seal` on a client that
is on the epoch being sealed; that is "Following a rotation".

An `epoch.resync` naming the epoch the document is already on is *not* a stop:
the room could not integrate one frame and is asking for self-contained state,
which the client answers with the whole overlay.

## Following a rotation

When the room seals epoch E it replaces its overlay with an empty one, so this
client's further deltas against the sealed overlay cannot be integrated there.
A state-complete resync would be the wrong answer: it would seed E+1 with
everything E held, and the overlay would never actually be bounded.

What the client owes the new epoch is narrow — the writes the server has not
acknowledged — so that is what travels. It moves onto a fresh overlay with
those writes carried onto it, keeps the merged view it already has (the records
are the document; the overlay is only the current epoch's changes), and goes on
writing. Nothing is refused and nothing is downloaded.

**The `YDocument` handle is replaced.** For a large document that handle IS the
current epoch's overlay, so a rotation puts a fresh one in its place and writes
on a handle kept from before the move are not forwarded. Read records through
the model facade, which follows the replacement:

```swift
let note = try Note.find(id: "n1", in: documentId)   // always the current view
```

## Catching up over the sealed chain

A client that was away while the room rotated is behind by whole epochs. It
does not need the document back: the overlays sealed between the epoch it holds
and the one the room is on are exactly the changes it missed, each a bounded,
rotation-sized artifact, and applying them in order converges its merged view
on the server's records with no base crossing the wire.

The chain runs from the epoch the client HOLDS, not the one after it — writes
landed in that epoch after the client went away, and its archive is the only
place they exist now. It is applied oldest first, and the epoch mark moves only
once the last archive has landed, so a chain that fails halfway leaves the
client exactly where it was: behind, readable, and told to reload. A read that
fails is retried once.

A cold client whose base was cut BELOW the room's epoch loads the base and then
applies the same chain above it, and the open epoch's overlay is refolded last.

**While a document is behind the room, nothing the room sends for its current
epoch is merged into the local overlay.** That overlay belongs to an epoch the
room has archived, and the move reads this client's owed values off it; merging
two independent epoch documents could let a peer's value win a key first. The
frames are not lost — the fresh overlay's resync re-delivers the current epoch.
Local writes still commit and read back as usual, and the outbound queue is
HELD until the move, because a delta against an archived overlay is a frame the
room cannot integrate.

## Judging what was written offline

A returning client does not replay its offline writes unconditionally: that
would silently overwrite whatever anyone else wrote in between, including
writes made days later. Instead the move DEFERS them, and once the joined
epoch's content has arrived each write is weighed against the sealed overlays
the catch-up just applied — which are precisely the touched records and fields
of the epochs it missed, with each epoch's window running from the previous
epoch's seal to its own.

- Clearly newer than the online write it raced: it stands, silently.
- Clearly older: it is **dropped** and reported.
- Inside the window, where the order is genuinely unknown: it stands and is
  reported.
- Onto a record deleted meanwhile: dropped, whatever the clock says. An edit
  lost is recoverable; a resurrected record is not.
- With no chain to check against (retention pruned it): it stands whole and is
  reported `unverifiable`.

Nothing is ever dropped on a clock this client has no reason to trust: with
no measured server offset, "clearly older" degrades to the ambiguous case and
the write stands.

What did not simply apply reaches the app as
`DocumentOfflineWritesResolvedEvent`, field for field the JS client's
`documentOfflineWritesResolved` payload. Silence means every offline write
replayed cleanly — the event carries notices or it is not sent:

```swift
let subscription = client.on(DocumentOfflineWritesResolvedEvent.self) { event in
    for notice in event.notices {
        print(notice.model, notice.recordId, notice.field ?? "-",
              notice.outcome.rawValue, notice.reason.rawValue)
    }
}
```

While a judgement is owed the writes it covers are held off the overlay AND
withheld from every claim, so the room cannot acknowledge a write whose content
no frame carries. The debt is durable: a relaunch between the move and the
judgement keeps those writes off the overlay until the next handshake has
re-read the chain and judged them.

## Replaying a relaunch's unacknowledged writes

The client id is minted per `JsBaoClient` instance and never persisted, so a
relaunch is a different client and the previous instance's unacknowledged
writes are somebody else's rows. They are **adopted** when the document binds:
re-keyed into this instance's sequence space, classified key by key against
what the overlay held when each was written, and the ones still owed are put
back on the overlay and claimed on the join, so the room acknowledges them.

A write the previous instance's own later write superseded is restored only in
the part that survived, and one info line per skipped sequence names the record
and the reason.

One process per database file is the rule. Two `JsBaoClient` instances in one
process over one file is not prevented: the second adopts the first's owed
writes, because a row under another client id reads as a session that has
ended.

## The offline write window

A client writes while it is offline, and the reconnect replays those writes
onto whatever epoch the room has reached. What makes that replay resolvable is
the sealed-overlay chain back to the epoch each write was made against — and
retention releases an overlay once a base covers it and it is older than the
window. So a client away for longer than the window is writing against a past
the server can no longer reconcile it with.

Past the window the document is **read-only** rather than a growing pile of
writes that will be resolved by guesswork:

- the window is the server's number, delivered on `epoch.info` and persisted
  locally — 7 days by default, clamped to 1–14, the same range retention prunes
  archives by;
- `Model.create`, `update`, `save`, `addStringsetMember` and
  `removeStringsetMember` throw
  `JsBaoError(code: .documentOfflineWindowExpired)` with `lastSyncAt`,
  `windowDays` and `overdueMs` in `details`;
- `Model.delete(id:)` and the `PrimitiveRecord` field setters cannot throw, so
  they write nothing and emit `DocumentWriteRefusedEvent` instead;
- `find` and `query` keep answering, and a sync restores writes at once;
- a refused write leaves nothing behind — no merged row, no pending op, no
  projected row, nothing on the wire — so the refusal cannot itself become a
  write that replays later.

```swift
subscription = client.observeOnMainActor(DocumentWriteRefusedEvent.self) { event in
    // event.error.code == .documentOfflineWindowExpired
    banner.show("\(event.model) \(event.recordId) was not saved: \(event.error.message)")
}
```

A client with no sync mark at all is writable, and so is one whose mark is in
the future: the honest failure direction here is to keep accepting writes.

## Reloading from a base

Two things make a document impossible to advance in place, and both reload
from the newest base the room has offered rather than giving up:

- the sealed chain between the epoch this client holds and the room's cannot
  be trusted — an epoch missing from it, or an archive retention has taken;
- a replay's resolution would DROP a delete. Dropping a delete means the record
  has to be there again, and a merged view the delete has already been folded
  into cannot put it back from anything it holds.

A reload discards the merged view **and the query tables it is projected
into**, loads the base whole, applies every sealed overlay from the base's
epoch through the room's, and then either moves onto a fresh overlay (when this
client was behind the room, whose held overlay belongs to an epoch the room
archived) or refolds the open one (when it was current).

Applying the chain above the base is not optional. A base announced at epoch B
while the room is already on R is B..R−1 overlays short of the document, and a
client that installed it and called itself current would have dropped every
write living only in them.

`DocumentSnapshotLoadEvent.mode` stays `"load"`: a reload is a whole load, not
a range replacement.

What this client still owes is judged at the end. A write made below the base's
epoch has no chain left to weigh it against, so it is **kept** and surfaced as
`unverifiable` rather than silently trusted.

## Crossing a bulk load

An operator can replace ranges of a document's rows wholesale
(`primitive documents ingest`). The room seals the epoch that was open with
`baseDiscontinuity`, which says the sum of the overlays on either side of it is
**not** the document — so no chain crosses it, and the ordinary recency rules
cannot judge anything written through it either.

What this client does:

1. records the boundary durably, **before** it moves, so a relaunch still knows
   it crossed one;
2. moves onto the next epoch with its carry **deferred** — the owed writes stay
   off the fresh overlay and their sequences are withheld from every claim, so
   no frame can get them acknowledged before anything has judged them;
3. keeps answering reads from the view it has and keeps taking local writes;
4. when a base past the boundary is announced, rebuilds from it and judges the
   deferred writes by **presence**, the only fact a replaced range leaves.

The verdicts reach the app as ordinary `DocumentOfflineWritesResolvedEvent`
notices with reason `bulkIngest`: a write onto a record the ingest removed is
dropped, one onto a record it kept is applied and surfaced, and an offline
create at an id the server never held is kept — it is absent because nobody
wrote it, not because the ingest took it.

A relaunch between the seal and the base is safe: the bind reads the boundary,
keeps the affected writes off the overlay, and the rebuild judges them.

## How much room a document may have

Before the first chunk of a base is fetched, the client asks what this device
can hold. It reads the capacity the system will give important data on the
volume the client's database is on, and plans:

- everything fits, or the platform reports no capacity → load it whole;
- not everything, but the models you named do → load those, and say in a log
  line which were left behind;
- not even those → refuse with `.format2StorageUnavailable`, reason
  `over-quota`, **before** a single chunk is fetched.

```swift
let client = JsBaoClient(options: JsBaoClientOptions(
    apiUrl: apiUrl,
    wsUrl: wsUrl,
    appId: appId,
    largeDocumentStorage: LargeDocumentStorageOptions(
        // Omit `capability` to probe the database's own volume.
        models: ["Note", "Comment"]
    )
))
```

A capped load is durable: the models it left out stay out across a relaunch and
across a reload, so a later overlay cannot quietly repopulate one with the
handful of records that epoch touched. `find(id:)` and every filtered read on a
model this device does not hold refuse with `.format2ModelNotHydrated` rather
than answering from a fragment.

A resumed load does not pay twice for chunks it has already committed.

## When the local view cannot be trusted

If a fold of an arriving update fails — a SQL error, a disk error — the merged
view no longer matches the document, and the client cannot tell by looking.
That state is **sticky**: every read and write on that document is refused with
`JsBaoError(code: .format2FoldBroken)` carrying the underlying error, one log
line names it, and a `ConnectionErrorEvent` is emitted. It clears when the
document is re-bound and its whole-overlay catch-up commits.

## Purging

An ordinary `closeDocument` keeps everything — that is what makes the next open
cheap. Two calls remove a large document's local data:

- `client.documents.evict(documentId)` drops that document's own tables, its
  rows in every shared table, its projected query rows, and the writes the
  server has not acknowledged;
- `logout(wipeLocal: true)` does the same for every large document in the
  database, including documents this session never opened.

## The typed errors

| Code | When |
| --- | --- |
| `.clientUpgradeRequired` | the room refused this client build (close 4426) |
| `.format2StorageUnavailable` | this client's storage cannot hold a large document |
| `.format2ReloadRequired` | the document is stopped pending a reload |
| `.format2QueryScope` | an unscoped filtered read spans both document kinds |
| `.format2ModelNotHydrated` | a model this device's load left out |
| `.format2FoldBroken` | the merged view is untrustworthy and stays refused |
| `.snapshotManifestInvalid` | a base manifest is not internally consistent |
| `.snapshotManifestUnsupported` | a base manifest is newer than this client |
| `.format2SnapshotLoadIncomplete` | a load could not be made complete |
| `.documentOfflineWindowExpired` | a local write past the offline window |

They are the JS client's codes, spelled the same way on the wire.

## Not in this build

Deferred under principle 11 (do the smallest thing that closes the gap): Swift
ingest and inspection verbs — an operator drives a bulk load and inspects
snapshot builds from the CLI (`primitive documents ingest`,
`primitive documents snapshots`), and web-admin does not show them.
