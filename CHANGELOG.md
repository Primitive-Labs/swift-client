# Changelog

The Swift client is versioned by git tag (there is no `Package.swift` version
field). Breaking changes are recorded here so downstream apps can migrate when
they bump the tag they pin.

## Unreleased

### Requires a Swift 6 toolchain — the package manifest is at tools-version 6.0 (#1946, Phase F)

`Package.swift` moves from `swift-tools-version: 5.9` to `6.0`, and the
`JsBaoClient` target opts into the Swift 6 language mode
(`swiftSettings: [.swiftLanguageMode(.v6)]`). **Resolving this package now needs
Swift 6.0 or later (Xcode 16+)** — that is the floor the manifest imposes, and
it is the only thing this change asks of a downstream app.

The toolchain the package is actually built and tested against is **Swift 6.3
(Xcode 26)**. Toolchains between 6.0 and 6.3 satisfy the manifest but are not
part of our verification, and one caveat is worth knowing before you pin to
one: the target still carries 11 warning-level `#SendableClosureCaptures`
diagnostics in `SQLiteStorageProvider` (tracked in #2318). They are warnings in
6.3; a 6.x that grades that diagnostic group as an error would fail the build.
If you are on an older 6.x, build once before you commit to the bump.

No public API shape changes. The `Sendable` conformances the mode enforces were
all added by the earlier phases of this epic (#1988, #1991, #1992, #1993,
#1994), each recorded in its own entry below; this entry is the mode itself
becoming the compiler's job rather than a gate script's.

**Your app does not have to adopt the Swift 6 language mode.** The language mode
is per-target: a package in Swift 5 mode can depend on a target in Swift 6 mode.
The rest of this package stays in Swift 5 mode too — the pin is
`swiftLanguageModes: [.v5]`, and `SwiftBaoCodegen`, both test targets and the
E2E mini-app are unchanged.

### Breaking — `BlobManager` is an actor; the synchronous blob-queue surface is deprecated or removed (#2172)

`BlobManager` was `final class` + `NSLock` + `@unchecked Sendable`; it is an
`actor` now, with no lock and no `Sendable` opt-out left. This is the Phase D
follow-up split out of #1993, and it follows the same Fork 1 Option C policy the
`AnalyticsQueue` entry below established — with one addition, because the blob
surface has synchronous *reads* and synchronous *result-returning mutators*
that a deprecated shim cannot answer honestly.

**`downloadUrl` is unaffected and stays synchronous permanently.** It reads only
the API-URL and app-ID closures, so it is `nonisolated`. That is deliberate: it
is the blob member most likely to be called straight from a SwiftUI `body`
(it feeds an `AsyncImage` URL), and it carries no deprecation and no twin.
`upload`, `uploadFile`, `list`, `get`, `read`, `prefetch` and `delete` were
already `async` and are unchanged.

**Three void-returning verbs keep working, deprecated, beside an `Async`
twin** — six spellings between the client-wide, app-wide and per-document
forms. They are removed in the next major release.

| Deprecated (still works) | Twin |
| --- | --- |
| `client.setBlobUploadConcurrency(_:)` | `await client.setBlobUploadConcurrencyAsync(_:)` |
| `client.documents.pauseAllUploads(documentId:)` | `await client.documents.pauseAllUploadsAsync(documentId:)` |
| `client.documents.resumeAllUploads(documentId:)` | `await client.documents.resumeAllUploadsAsync(documentId:)` |
| `client.documents.setUploadConcurrency(_:)` | `await client.documents.setUploadConcurrencyAsync(_:)` |
| `client.document(id).blobs().pauseAll()` | `await client.document(id).blobs().pauseAllAsync()` |
| `client.document(id).blobs().resumeAll()` | `await client.document(id).blobs().resumeAllAsync()` |

While you stay on the deprecated forms the work is handed to an unstructured
task, so it is not ordered against **anything** that follows it — not a read,
and not another deprecated call:

- A following read may not see it: an `uploadsAsync()` issued straight after
  `pauseAll()` may not see the pause yet.
- **Two deprecated calls are not ordered against each other.** Swift makes no
  FIFO guarantee for two independent tasks reaching the same actor, so
  `pauseAll()` followed by `resumeAll()` can apply in either order. If the
  resume lands first it finds nothing paused and does nothing, then the pause
  applies — leaving every upload for the document paused, with no
  `blobs:upload-resumed` event and no armed retry timer. `setUploadConcurrency(1)`
  then `setUploadConcurrency(5)` can likewise settle on 1.

Use the twins whenever ordering matters. `await` makes both hazards go away.

**The reads and the result-returning mutators cannot survive the window, so they
become `@available(*, unavailable, renamed:)` stubs.** The call is a compile
error with a one-click rename fix-it in Xcode rather than "no such member". A
synchronous read would have to answer from a published mirror of the queue — a
second source of truth — and a synchronous `pauseUpload` would have to return a
`Bool` describing the queue *before* the mutation it just scheduled. Neither is
honest, so neither ships.

| Removed (compile error + rename fix-it) | Use |
| --- | --- |
| `client.getBlobUploadConcurrency()` | `await client.getBlobUploadConcurrencyAsync()` |
| `client.documents.uploads(documentId:)` | `await client.documents.uploadsAsync(documentId:)` |
| `client.documents.getUploadConcurrency()` | `await client.documents.getUploadConcurrencyAsync()` |
| `client.documents.pauseUpload(blobId:documentId:)` | `await client.documents.pauseUploadAsync(blobId:documentId:)` |
| `client.documents.resumeUpload(blobId:documentId:)` | `await client.documents.resumeUploadAsync(blobId:documentId:)` |
| `client.document(id).blobs().uploads()` | `await client.document(id).blobs().uploadsAsync()` |
| `client.document(id).blobs().pauseUpload(blobId:)` | `await client.document(id).blobs().pauseUploadAsync(blobId:)` |
| `client.document(id).blobs().resumeUpload(blobId:)` | `await client.document(id).blobs().resumeUploadAsync(blobId:)` |

The twins carry a distinct name rather than being `async` overloads of the same
one for the reason the D3 entry gives: Swift prefers the `async` overload in an
asynchronous context, so a same-name twin turns every existing un-`await`ed call
into a compile error.

**If you hold a `BlobManager` directly, every member in the table below is
`async` now.** (`downloadUrl` is the exception — it is `nonisolated`, so it
stays synchronous there too.) That is a source break in the same shape as
`AnalyticsQueue`'s below, and it is separate from the accessor's deprecation —
`client.getBlobManager()` returns an `actor`, so calls through it are `await`ed
regardless of what the accessor is annotated with:

| Was | Now |
| --- | --- |
| `manager.listUploads(documentId:)` | `await manager.listUploads(documentId:)` |
| `manager.pauseUpload(_:documentId:)` / `resumeUpload(_:documentId:)` | `await manager.pauseUpload(_:documentId:)` / `await manager.resumeUpload(_:documentId:)` |
| `manager.pauseAll(documentId:)` / `resumeAll(documentId:)` | `await manager.pauseAll(documentId:)` / `await manager.resumeAll(documentId:)` |
| `manager.setUploadConcurrency(_:)` / `getUploadConcurrency()` | `await manager.setUploadConcurrency(_:)` / `await manager.getUploadConcurrency()` |
| `manager.clearCache()` | `await manager.clearCache()` |

`clearCache()` gets no twin at all: a direct manager holder is taking the
all-members-async break anyway, and the facade path
(`client.evictAllLocal()`) was already `async`.

Two more changes:

- **`client.getBlobManager()` is deprecated.** Everything it was used to reach is
  already on `client.documents` (the app-wide queue verbs) and
  `client.document(id).blobs()` (the per-document ones). Removed in the next major
  release; no new namespace is added in this window.
- **`BlobManager`'s initializer takes its collaborators.** It was six
  post-construction `var` setters plus an emitter; an actor has no synchronous
  setter, so they are `init` parameters (all defaulted). Only `JsBaoClient` ever
  constructed one. The dead `getCurrentUserId` dependency is gone — it was
  assigned and never read.

### `DatabaseSubscriptionRegistry` loses two unused methods (#1993, Phase D4)

`has(databaseId:subscriptionKey:)` and `clear()` are removed. Both were
`internal` with no caller anywhere in the client or its tests. The registry
itself stays a `final class` + `NSLock` deliberately — it does no I/O, so an
actor would buy nothing and would cost `databases.subscribe(...)` its
synchronous shape. Its `@unchecked Sendable` conformance and `AuthController`'s
now carry written safety arguments naming the state each lock confines.

### Breaking — `AnalyticsQueue` is an actor; the synchronous analytics surface is deprecated (#1993, Phase D3)

`AnalyticsQueue` was `final class` + `NSLock` + `@unchecked Sendable`; it is an
`actor` now, with no lock and no `Sendable` opt-out left.

**Two things break: `AnalyticsAPI`'s initializer** (see the bottom of this
entry) **and `AnalyticsQueue`'s own members** (table below). Only `JsBaoClient`
ever constructed an `AnalyticsAPI`, and the queue is normally reached through
`client.analytics` rather than directly, so unless you hold one of these two
types by hand neither reaches you.

`AnalyticsQueue` is `public`, so its conversion is a source break in the same
shape as `OfflineStore`/`KvCache` in the D2 entry below:

| Was | Now |
| --- | --- |
| `queue.logEvent(["action": "x"])` (`[String: Any]`) | removed — use `logEvent(AnalyticsEventInput)`, `logEvent([String: JSONValue])` or `logEvent(PreparedEvent)` |
| `queue.destroy()` | `await queue.destroy()` |
| `queue.flush()` | `await queue.flush()` |
| `queue.setPlanOverride(p)` | `await queue.setPlanOverride(p)` |
| `queue.setAppVersionOverride(v)` | `await queue.setAppVersionOverride(v)` |
| `queue.persistBuffer()` / `queue.restoreBuffer()` | `await queue.persistBuffer()` / `await queue.restoreBuffer()` |

These get no deprecated synchronous twin, for the reason the D2 entry gives:
a synchronous member on an actor has to read a lock-guarded mirror, which for a
mutating member means the write lands somewhere the actor cannot see.

**Nothing you call on `JsBaoClient` or `client.analytics` stops compiling.**
Every synchronous member on those two surfaces survives the deprecation window
and is removed in the next major release. Each gained an `Async` twin:

| Deprecated (still works) | Twin |
| --- | --- |
| `client.logAnalyticsEvent(_:)` | `await client.logAnalyticsEventAsync(_:)` |
| `client.flushAnalytics()` | `await client.flushAnalyticsAsync()` |
| `client.setAnalyticsPlanOverride(_:)` | `await client.setAnalyticsPlanOverrideAsync(_:)` |
| `client.setAnalyticsAppVersionOverride(_:)` | `await client.setAnalyticsAppVersionOverrideAsync(_:)` |
| `client.analytics.logEvent(_:)` | `await client.analytics.logEventAsync(_:)` |
| `client.analytics.logSnapshot(context:)` | `await client.analytics.logSnapshotAsync(context:)` |
| `client.analytics.flush()` | `await client.analytics.flushAsync()` |
| `client.analytics.setPlanOverride(_:)` | `await client.analytics.setPlanOverrideAsync(_:)` |
| `client.analytics.setAppVersionOverride(_:)` | `await client.analytics.setAppVersionOverrideAsync(_:)` |

Two reasons the twins carry a distinct name rather than being `async` overloads
of the same one. Swift **prefers** the `async` overload in an asynchronous
context, so a same-name twin would turn every existing un-`await`ed call inside
an `async` function into a compile error — the source break the window exists to
avoid (verified by compile probe on Swift 6.3.1). And `flushAsync()` genuinely
differs from `flush()`: it returns only once the batch has reached the socket,
where the synchronous one returns as soon as the send is scheduled.

**What differs while you stay on the synchronous members.** They hand the work
to an unstructured task, so two consecutive calls are not ordered against each
other: an event logged immediately before a `flush()` may miss *that* batch. It
is not lost — it goes out with the next one — but if you need the ordering, use
the twins, which do the work on your task. The event's `timestamp` is stamped
when you call, either way.

Two more changes:

- **`AnalyticsAPI`'s initializer takes the queue.** It was five injected
  closures; it is `AnalyticsAPI(queue:resolveUserUlid:)` now. The closures could
  not carry the `async` twins, and a facade that silently dropped half its
  surface would be worse than a compile error. Only `JsBaoClient` ever
  constructed one.
- **`AnalyticsEventInput.asJSONObject()`** is the queue's entry shape now
  (`asDictionary()` is still there for callers on the `Any` graph). Related:
  `JSONValue(jsonAny:subject:)` and `JSONValue.typedRow(from:subject:)` lower an
  `Any` graph structurally, without a `JSONSerialization` round trip.

### Breaking — `OfflineStore` and `KvCache` are actors (#1993, Phase D2)

Both types were `final class` + `NSLock` + `@unchecked Sendable`; both are
`actor`s now, with no lock and no `Sendable` opt-out left. Every member that was
synchronous is actor-isolated, so a caller reaching one of these types directly
adds `await`:

| Was | Now |
| --- | --- |
| `offlineStore.setStorageProvider(p)` | `await offlineStore.setStorageProvider(p)` |
| `offlineStore.setAuthStorageProvider(p)` | `await offlineStore.setAuthStorageProvider(p)` |
| `offlineStore.getStorageProvider()` | `await offlineStore.getStorageProvider()` |
| `kvCache.setStorageProvider(p)` | `await kvCache.setStorageProvider(p)` |
| `kvCache.setUserId(id)` | `await kvCache.setUserId(id)` |

These five members get no deprecated synchronous twin. A synchronous member on
an actor has to read a lock-guarded mirror of the actor's state, which for a
*setter* means the write lands somewhere the actor does not see — a correctness
hazard rather than a compatibility win. And a same-name `async` twin does not
buy source compatibility either: in an asynchronous context Swift prefers the
`async` overload, so an existing un-`await`ed call becomes a compile error
whether or not the synchronous original survives (verified by compile probe on
Swift 6.3.1). Neither type is reachable from `JsBaoClient`'s public surface, and
nothing in the Primitive app layer touches them.

Three related changes:

- **`KvCache.setEmitter` is removed.** The emitter is supplied at construction:
  `KvCache(emit:)`, in both its typed and deprecated-untyped forms. Setting it
  afterwards would be a synchronous mutation of actor state, which is exactly
  what the conversion removes.
- **`CacheFacade`'s initializers no longer take `emit:`.** The facade used to
  forward the closure into `KvCache` after the fact and cannot any more. A
  parameter that quietly dropped the caller's closure would be worse than no
  parameter, so it is gone rather than deprecated. Supply the emitter where the
  `KvCache` is constructed.
- **`OfflineStore`'s analytics payload is typed.**
  `persistAnalyticsQueue(appId:userId:events:)` takes `[[String: JSONValue]]`
  and `loadAnalyticsQueue(appId:userId:)` returns it, instead of
  `[[String: Any]]` — an `Any` cannot cross the new isolation boundary. The
  persisted JSON on disk is unchanged, so a queue written by an earlier build
  still restores.

### The cache's value type is `JSONValue`, and its fetcher is `@Sendable` (#1993, Phase D1)

`KvCache` and `CacheFacade` carry cached values as `JSONValue` rather than
`Any`. The generic `fetchCached<T>` / `fetchHttp<T>` signatures are unchanged
apart from their fetcher closure, which is now `@Sendable` — it has always run
inside the in-flight-dedup `Task`, that just wasn't stated in the type. A
closure literal needs no edit; a closure capturing non-`Sendable` state gets a
warning today (an error once the package moves to Swift 6).

Four behavior notes:

- Values that are not JSON-representable are now rejected with
  `JsBaoError(.invalidArgument)` instead of being cached as their
  `String(describing:)` text. In practice this only ever "worked" until the
  process restarted — the persistent tier has always stored JSON.
- A `Codable` model cached directly now survives the persistent tier too; it
  previously round-tripped only while it stayed in memory. It is materialized
  by decoding the cached JSON, and the decode is accepted only if it read at
  least one key that was actually in the entry — an all-optional model read
  from an entry of a different shape reads back as `nil` (the same answer the
  pre-#1993 dynamic cast gave, so a caller treating `nil` as "not cached"
  refetches as before) rather than as a model with every field `nil`.
- **Integers are exact only to 2^53.** `JSONValue` has one numeric case,
  `.number(Double)`, so `1234567890123456789` cached and read back is
  `1234567890123456768`, with nothing thrown. Before this change the memory
  tier handed your own fetcher's value straight back, so an `Int` survived
  until the process restarted. Cache a wider integer as a `String`. (An
  `Int64` field on a `Codable` model does not help here: a model cached
  through `KvCache` is lowered to `JSONValue` on the way in.)
- **`CacheUpdatedEvent.value` carries the JSON graph now**, not the value your
  fetcher returned. The payload is typed `Any?`, so `event.value as? MyModel`
  in a `.cacheUpdated` subscriber compiles and returns `nil` at runtime; read
  it as `[String: Any]` (or re-decode it) instead. This only affects callers
  who pass their own typed fetcher to `CacheFacade.fetchCached` *and*
  subscribe to `.cacheUpdated` — the client's own cache users were already on
  the graph.

On-disk cache entries written by earlier builds still load: every entry an
earlier build could write is a valid JSON object or array, and those decode
unchanged. (An earlier draft of this entry credited compatibility to a
non-JSON `String(describing:)` fallback; that fallback could not in fact
produce an on-disk entry, because `JSONSerialization` raises rather than throws
for a scalar top level. The loader is nonetheless still forgiving: stored text
that is not valid JSON at all reads back as a string, and a bare JSON scalar
such as `42` or `true` reads back as `.number` / `.bool` rather than as the
text of the entry.)

### Breaking — the untyped event surface is deprecated; events are `AsyncStream`s now (#1994)

`client.events` and everything reached through it — `on(_:handler:)`,
`onAny(_:handler:)`, `emit(_:_:)`, and the free
`waitForEvent(emitter:event:timeout:predicate:)` — are `@available(*,
deprecated)` and are **removed in the next major release**. They keep working,
with the delivery they have always had (synchronous, inside `emit`, in
registration order), for the whole window.

Three replacements, all on `JsBaoClient`. Each derives the event key from the
payload type, so a mis-annotated handler is now a compile error rather than a
handler that silently never fires:

```swift
// every occurrence — the subscription lives as long as the loop
.task {
    for await status in client.stream(for: StatusChangedEvent.self) {
        isConnected = status.status == .connected
    }
}

// a callback that runs on the main actor; hold the subscription or it cancels
statusSubscription = client.observeOnMainActor(StatusChangedEvent.self) { event in
    isConnected = event.status == .connected
}

// one occurrence
let loaded = try await client.nextEvent(DocumentLoadedEvent.self, timeout: 30) {
    $0.documentId == docId
}
```

Migration, by shape:

| Before | After |
| --- | --- |
| `client.events.on(.status) { (e: StatusChangedEvent) in … }` | `for await e in client.stream(for: StatusChangedEvent.self)`, or `client.observeOnMainActor(StatusChangedEvent.self) { e in … }` |
| `client.events.onAny(.status) { payload in … }` | `client.stream(for: StatusChangedEvent.self)` — the payload arrives typed |
| `try await waitForEvent(emitter: client.events, event: .sync)` | `try await client.nextEvent(SyncEvent.self)` |

Notes:

- `stream(for:)` takes `buffering:` (default `.unbounded`, which never drops;
  pass `.bufferingNewest(1)` for high-frequency events where only the latest
  value matters) and `replayingLatest:` (default off; the last value is retained
  only for `StatusChangedEvent`, `NetworkModeEvent` and `AuthStateEvent`).
- Ordering is per-stream FIFO. Two streams have no order relative to each other
  — a change from `on()`, where every callback ran inside one `emit`. Use one
  `observeOnMainActor` per event, or await both in a single task, when you need
  cross-event order: `observeOnMainActor` handlers on one client run in emit
  order, including across event types.
- A stream's subscription lives as long as the stream value, which is
  `AsyncStream`'s own rule. `for await e in client.stream(for: …)` unsubscribes
  when the loop ends because the stream is a temporary the loop owns; if you
  instead store it (`let events = client.stream(for: …)`), breaking out of the
  loop leaves `events` subscribed and buffering until that variable is released.
- `nextEvent` throws `JsBaoError(code: .unavailable)` on timeout and
  `CancellationError` if the calling task is cancelled.
- `observeOnMainActor` is deliberately **not** `@discardableResult`: dropping the
  returned `EventSubscription` cancels the subscription. Cancelling on the main
  actor is immediate — a handler cannot run for an event emitted before the
  cancel.

### Breaking — nine events changed from `[String: Any]` to typed payloads (#1994)

`meUpdated`, `pendingCreateFailed`, `authRefreshDeferred`, the five
`offlineAuth*` events and `blobsQueueDrained` are typed structs now
(`MeUpdatedEvent`, `PendingCreateFailedEvent`, …). A handler still annotated
`[String: Any]` keeps receiving the pre-conversion dictionary, key for key, for
the whole deprecation window — so existing `on`/`onAny` subscribers do not break
before the removal.

`MeUpdatedEvent` mirrors the JS payload: `value` is the me record, plus
`source` and `updatedAt`. The legacy dictionary is still the whole
`{"type": "meUpdated", "value": …}` WebSocket frame, which is what the
pre-conversion emit delivered.

### Breaking — `CacheFacade`'s `emit:` parameter is typed (#1994)

`CacheFacade.init(kvCache:getNetworkMode:transport:emit:)` and
`KvCache.init(emit:)` / `setEmitter(_:)` take
`@Sendable (any JsBaoEventPayload) -> Void` instead of
`@Sendable (JsBaoEvent, Any) -> Void`. Deprecated overloads taking the old
closure shape ship alongside, so an existing call site warns rather than fails
to compile.

Superseded later in this same unreleased window by the #1993 Phase D2 entry
above: `CacheFacade` no longer takes `emit:` at all, and `KvCache.setEmitter`
is gone — the emitter reaches the cache through `KvCache.init(emit:)`, in both
its typed and deprecated-untyped forms.

### Breaking — paginated query results carry `PrimitiveRow` instead of `[String: Any]` (#1992)

Every untyped paginated query now returns `PagedQueryResult<PrimitiveRow>`
rather than `PagedQueryResult<[String: Any]>`:

- `DynamicModel.queryPaged(_:options:)` and `queryPaged(_:options:include:)`
- `BaoModelQueryEngine.queryPaged(modelName:…)`
- `JsBaoClient.queryPagedShared(_:filter:options:)` (and the `include:` overload)
- `JsBaoClient.hasManyThroughShared(…, limit:…)`

`PrimitiveRow` is the shared row bag — the type `RelatedRecords` was
generalized into (`RelatedRecords` is now a spelling of `PrimitiveRow`, so
generated models and existing `_related` code are unchanged). It is
`@unchecked Sendable` with a written safety argument, which is what makes a
page of untyped rows able to cross an isolation boundary at all.

**Migrating:** field reads are unchanged — `row["title"] as? String` works on
the bag exactly as it did on the dictionary, and generated
`compactMap { Model(row: $0) }` call sites bind unchanged. Only code that
*named* the type has to change:

```swift
// before
let page: PagedQueryResult<[String: Any]> = try model.queryPaged(nil)
let dicts: [[String: Any]] = page.data

// after
let page: PagedQueryResult<PrimitiveRow> = try model.queryPaged(nil)
let dicts: [[String: Any]] = page.data.map(\.raw)
```

**`PrimitiveRow` compares equal and hashes identically regardless of content.**
This is deliberate — it is inherited from `RelatedRecords`, and it is what
keeps a generated model's synthesized `==` from varying with whether an
include was requested — but it is a sharp edge now that the same type is the
element of every paginated result:

```swift
XCTAssertEqual(pageA.data, pageB.data)  // passes for ANY two same-length pages
Set(page.data)                          // collapses to one element
page.data.contains(row)                 // true for any non-empty page
page.data.firstIndex(of: row)           // always 0
```

Compare fields out of `raw` instead (`page.data.map(\.raw) as NSArray`, or an
explicit per-field check), and don't use rows as `Set` members or `Dictionary`
keys.

The **unpaginated** `query` / `queryShared` / `findAll` returns are unchanged
(`[[String: Any]]`) — they make no `Sendable` claim, so there was nothing to
make honest.

Also in #1992: `DynamicModel.subscribe`, `MultiDocModel.subscribe` and
`JsBaoClient.subscribeShared` now take (and return) `@Sendable` closures.
Callbacks run on whichever thread committed the change, so this states a
requirement that was always in force. Under Swift 5 language mode a
non-`@Sendable` callback is a warning, not an error.

The requirement is carried all the way to app code, not just the client
boundary: **codegen now emits**

```swift
static func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void
```

so regenerate your models when you bump the tag. `swift-primitive-app`'s
`ModelSubscribable.subscribe` and `LoaderTrigger.onModel(subscribe:)` widen to
match, which keeps `.onModel(subscribe: MyRecord.subscribe)` and
`extension DynamicModel: ModelSubscribable {}` binding. A callback of your own
that captures thread-bound state now has to say so.

`OpenDocumentResult` gains `confinedDoc` (a `ConfinedYDocument`) and is now
plainly `Sendable`; `.doc` still works and returns the same live document.

### Breaking — the untyped `Any` HTTP surface is deprecated, and part of it changes shape now (#1991)

Every API class in the client used to be built on one injected closure —
`makeRequest(_ method: String, _ path: String, _ data: Any?) async throws -> Any`
— so request bodies were `[String: Any]` dictionaries and responses were
`JSONSerialization` graphs that each call site cast by hand. That closure is
replaced by a typed `Transport`: bodies are `Encodable`, responses are
`Decodable`, and dynamic payloads use `JSONValue`.

Most apps are unaffected: the documented `client.auth.*`, `client.documents.*`,
`client.databases.*`, … signatures are unchanged, and the old initializers and
methods still compile.

**What is deprecated (still works, removed in the next major):**

- `client.makeRequest(_:_:_:)` — use `client.request(method:path:body:)` for a
  typed response, or `client.requestJSON(method:path:)` when the shape is
  genuinely dynamic.
- `client.makeRawRequest(_:_:_:headers:)` — use
  `client.requestData(method:path:body:options:)`.
- Every API class's closure-taking init — use `init(transport:)`. Most take
  `init(makeRequest:)`; `IntegrationsAPI`'s is `init(makeRawRequest:)`, and
  `MeAPI` / `BlobBucketsAPI` take both. "Still works" is conditional for the
  two that need raw bytes: a `BlobBucketsAPI(makeRequest:)` or
  `MeAPI(makeRequest:)` built without the matching `makeRawRequest` closure
  now throws `CLIENT_LEGACY_TRANSPORT_UNSUPPORTED_OPTIONS` at runtime from
  `upload` / `download` / `uploadAvatar`, where it previously threw a
  `JsBaoError(.unavailable)`.

The new escape hatches:

```swift
// Typed — decode straight into your own type.
struct Health: Decodable { let ok: Bool }
let health: Health = try await client.request(method: .get, path: "/health")

// Dynamic — a Codable, Sendable JSONValue instead of an Any graph.
let me = try await client.requestJSON(method: .get, path: "/me")
let userId = me?["userId"]?.stringValue

// Bytes — untouched, with the status, no throw on non-2xx.
let (bytes, status) = try await client.requestData(method: .get, path: "/blobs/\(id)")
```

**Bug fix on the deprecated path:** `makeRawRequest` used to rebuild the
response from decoded text (`(response.text ?? "").data(using: .utf8)`), which
corrupted any download that was not valid UTF-8. It now returns the response
bytes untouched, like `requestData`. Binary blob downloads that came back
corrupted are fixed; code that relied on the corrupted bytes is not.

**Source breaks in this release** — these are compile errors, not
deprecations, and are why this change belongs to a major:

1. **`AuthController` is `public`, and its methods changed.** They now return
   the typed DTOs instead of `[String: Any]`. Construction is *not* affected:
   the `public init(appId:apiUrl:logger:offlineStore:emitter:refreshProxy:persistConfig:)`
   is unchanged. The transport is now injected afterwards with the new
   `public func setTransport(_:)`, which may be called **once** — a second
   call trips a `precondition` (a runtime abort, not a compile error). The
   `var makeRequest` it replaces was `internal`, so its removal is invisible
   to consumers. Most apps never touch any of this — it is internal plumbing
   behind `client.auth` — but the methods are public API, so the break is
   real.
2. **`AuthAPI`'s closure-taking `public init` changed signature.** It now takes
   typed closures. `client.auth` itself is unchanged.
3. **Five top-level `JsBaoClient` methods return typed DTOs instead of
   `[String: Any]`:**

   | Method | Was | Now |
   |---|---|---|
   | `handleOAuthCallback` | `[String: Any]` | `OAuthCallbackResult` |
   | `magicLinkVerify` | `[String: Any]` | `MagicLinkVerifyResult` |
   | `otpVerify` | `[String: Any]` | `OtpVerifyResult` |
   | `enableOfflineAccess` | `[String: Any]` | `EnableOfflineAccessResult` |
   | `handleAppleCallback` | `[String: Any]` | `OAuthCallbackResult` |

   The first four are `public`; `JsBaoClient.handleAppleCallback` is
   `internal` (the public Apple entry point is
   `signInWithApple(presentationAnchor:)`, which is unchanged), so it breaks
   nothing on its own — but its `public` counterpart
   `AuthController.handleAppleCallback` changed the same way, which break 1
   covers.

   Read fields off the returned struct instead of subscripting a dictionary.
   **`magicLinkVerify` and `otpVerify` no longer expose the raw `token`.** The
   client applies it internally as before, so sign-in works unchanged; call
   `client.auth.getToken()` if you need the token itself.

4. **Two public `AuthController` passkey methods changed a *parameter* type**,
   not just a return type:

   ```swift
   // was
   public func passkeyAuthFinish(credential: [String: Any], challengeToken: String) async throws -> [String: Any]
   public func passkeyRegisterFinish(credential: [String: Any], challengeToken: String, deviceName: String?, inviteToken: String?) async throws -> [String: Any]

   // now
   public func passkeyAuthFinish(credential: JSONValue, challengeToken: String) async throws -> PasskeySignInResult
   public func passkeyRegisterFinish(credential: JSONValue, challengeToken: String, deviceName: String?, inviteToken: String?) async throws -> PasskeyRegistrationResult
   ```

   This needs the *opposite* repair from the advice above: the return value is
   read off a struct, but the argument must now be **constructed**. Convert
   the WebAuthn dictionary you hold before the call:

   ```swift
   let credential = try JSONDecoder().decode(
       JSONValue.self,
       from: JSONSerialization.data(withJSONObject: credentialDictionary)
   )
   // or, from a Codable credential model:
   let credential = try JSONValue(encoding: myCredentialModel)
   ```

   Callers of `client.auth.passkeyAuthFinish` / `passkeyRegisterFinish` are
   **not** affected — those wrappers still take `[String: Any]` and do the
   conversion internally — and neither are the native entry points
   (`signInWithPasskey` / `registerPasskey`).

   Counting these two, ten methods change shape in this release, not the
   four in the table above.

**Numeric precision, worth knowing before you use `JSONValue`:** it has a
single `.number(Double)` case, matching JavaScript's `number` (which is what
the servers and the JS client speak). Integers are exact to 2^53. Dynamic
payloads — `DoDb` record fields, document `metadata` — that need larger exact
integers should carry them as strings, or be modeled with a typed `Codable`
struct using `Int64`, which decodes from the wire bytes and never passes
through `JSONValue`. Workflow `input`/`meta` are exempt: `workflows.start` and
`workflows.runSync` serialize the caller's dictionary straight to the request
bytes, so an `Int64` there goes out exactly as it did before.

### Breaking — generated model reads are now synchronous (#1156)

The generated cross-document model facade previously split its static reads
into two conventions: `find` and `findAll` were `async throws` while
`query`, `queryOne`, `count`, `aggregate`, `findByUnique`, and `queryPaged`
were synchronous `throws`. The generated relationship instance accessors
(`task()`, `profile()`, `viaJoin()`, etc.) were likewise `async throws`.

All of these now emit **synchronous `throws`**. None of them ever suspended —
every method delegates to a synchronous in-process CRDT read — so the `async`
was cosmetic. Decode-loudness is unchanged: `find`/`findAll` still throw
`PrimitiveDecodeError` when a stored row no longer decodes as the typed model.

**Migration:** drop `await` from calls to these methods. Because the methods
were never truly suspending, a stale `await` produces a "no `async` operations
occur within `await`" warning rather than a hard error, so existing call sites
keep compiling until updated.

```swift
// Before
let note = try await Note.find(id)
let all  = try await Note.findAll()
let author = try await post.author()

// After
let note = try Note.find(id)
let all  = try Note.findAll()
let author = try post.author()
```

Synchronous SwiftUI `body` / computed-property contexts can now read a model
inline without a `Task { }` wrapper.

This deliberately reverses #992's JS call-shape parity for `find`/`findAll`:
the Swift facade reads an in-process synchronous store, so a synchronous API is
the truthful shape. The internal `DynamicModel` / `MultiDocModel` `find(id:)`
method is unrelated and unchanged.
