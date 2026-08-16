# Changelog

## How this package is versioned

**There are no version numbers and no tags.** The Swift client is published by
branch, not by release: `scripts/publish-swift-packages.sh` pushes the built
tree to a branch of the `Primitive-Labs/swift-client` mirror, and apps depend
on that branch (`branch: "main"` for production, `branch: "alpha"` for the
alpha channel — issue #1934). There is no `Package.swift` version field, no git
tag, and therefore no older surface an app can pin to.

The practical consequence: **a breaking change reaches every app on its next
`swift package update`.** Breaking changes are recorded here so you can read
what moved before you take the update, but reading this file is the whole
mitigation — there is nothing to pin.

(Earlier revisions of this file claimed the package "is versioned by git tag …
so downstream apps can migrate when they bump the tag they pin". That was never
true: the mirror has no tags. Corrected in #2367.)

## Unreleased

### `AuthFailedEvent.reason` on a rejected refresh matches the JS client (#2723)

A refresh the server rejects used to deliver `reason: "invalid_token"` whatever
drove it. The JS client — the reference — reports a different value per cause,
and it always did; this client simply had its own vocabulary. An app that
switches on `reason` needs to read the new values:

| what drove the refresh                    | before          | now                          |
|-------------------------------------------|-----------------|------------------------------|
| the 401 retry on an authenticated request | `invalid_token` | `refresh_failed`, no message |
| a manual or background refresh            | `invalid_token` | the refresh cause, e.g. `networkMode:online` |
| the launch-time refresh                   | (no event)      | (no event, unchanged)        |

`message` changes with it: the request-path event carries none, and the others
carry `"Authentication refresh failed"` rather than the HTTP status text. The
diagnostic detail moves to the log, where JS keeps it.

Since the reason on that middle row IS the cause, the two entry points into the
online-auth handoff no longer share one: the user pinning online
(`goOnline()` / `setNetworkMode(.online)`) refreshes with cause
`networkMode:online` as before, while an automatic restore — reachability
returning, or re-entering `.auto` while reachable — now refreshes with
`auto-network:online`, the name JS gives that path. An app that distinguishes
"I asked to go online" from "the network came back" reads it off `reason`.

Which events fire is unchanged — one per rejection, none at launch — so an app
that only observes `authFailed` sees no difference. Sign-out is untouched: a
rejected refresh still ends the session (#2655).

### Disconnect now resets sync state and presence; `connect()` no longer overrides `disconnect()` (#2663)

The client's disconnect handling now matches the JS client's, which is the
reference. Four changes, all observable from an app:

- **Open documents go unsynced on a disconnect.** On a transport `connecting`,
  on a close, and at the initiation of a deliberate `disconnect()`, every open
  document's sync state is set to `false` and a `SyncEvent(synced: false)` is
  delivered for it; the reconnect delivers `synced: true` again. Previously
  `isSynced(_:)` kept reporting `true` while offline and no event fired, so a
  "synced" badge stayed lit with the network down.
- **Remote presence is cleared on a close**, with an `AwarenessEvent` whose
  `removed` lists the departed client IDs. Previously peer cursors stayed on
  screen until the document was closed.
- **One `.disconnected` status per close.** The client's close handler no
  longer emits its own on top of the transport manager's, so subscribers see
  one per close instead of two — plus one at the initiation of a deliberate
  `disconnect()`, which previously reported nothing until the socket actually
  closed (up to 500ms later).
- **`connect()` returns without doing anything while `shouldConnect` is
  false** — that is, after a `disconnect()` or a `logout()`. An explicit
  disconnect means "stay down". Use `setShouldConnect(true)` (or
  `forceReconnectAsync()`) to come back up; a sign-in after a logout re-arms
  the connection on its own, as it does in JS.

**What to change in your app:** if you reconnect with `try await
client.connect()` after calling `disconnect()`, switch that call to `await
client.setShouldConnect(true)`. Code that only ever calls `connect()` at
startup is unaffected. If you drove a "synced" indicator off `isSynced(_:)` and
worked around it sticking at `true`, you can drop the workaround.

### The query row currency is `[String: JSONValue]` (#2546)

The split-out remainder of the #2367 batch below. A query row was
`[String: Any]`; it is now `[String: JSONValue]`, so `PrimitiveRow` is
`Sendable` by checked conformance instead of by a written safety argument, and
a row value is read by accessor rather than by cast.

What moved: `PrimitiveRow.raw` and its `subscript` / `one` / `many`,
`PrimitiveRowDecodable.init?(row:)`, `DocumentFilter`,
`IncludeTarget.query(_:options:)`, and the `DynamicModel` / `MultiDocModel` /
`client.codegen` row returns (`query`, `queryPaged`, `find`, `findByUnique`,
`queryOne`, `aggregate`, the relationship traversals).

**Regenerate your models first** — the emitter writes the row reads, so codegen
output changes. For most apps that is the whole migration. After that:

```swift
let title = row["title"]?.stringValue        // was: row["title"] as? String
let priority = row["priority"]?.numberValue  // was: as? Double
let done = row["done"]?.rowBoolValue         // was: as? Bool
let tags = row["tags"]?.stringArrayValue     // was: as? [String]
```

Every row number is a `.number(Double)`, including a SQLite INTEGER column;
booleans are stored as INTEGER, which is why they read through `rowBoolValue`.
Filter literals bind unchanged (`["priority": ["$gte": 4]]`); a filter value
held in a variable needs its case spelled out
(`["authorId": .string(authorId)]`). `JSONValue.toAny()` is public now for
boundaries that still need the loose `Any` graph.

### The batched breaking API cleanup (#2367)

One deliberate source break covering everything that had been queued behind
"the next major". Since there is no version to sit on (see above), the point of
batching is to make the number of unavoidable breaks **exactly one**, not to
let anyone migrate on their own schedule.

A full symbol-by-symbol migration table is in the migration guide:
<https://primitive-labs.github.io/primitive-docs-site/getting-started/swift-client-migration>.
The headlines:

- **Every symbol marked for removal in the next major was removed.** All 61
  `next major` markers, and 76 of the 96 `@available(*, deprecated)`
  declarations went with them: the untyped `EventEmitter` surface and
  `client.events`, `makeRequest` / `makeRawRequest`, the sync/async twins, the
  legacy closure-taking `init`s and `ClosureTransport`, `QueryOptions.offset`,
  the never-emitted `.auth` / `.blobsUploadQueued` cases and the Swift-only
  `.remoteUpdate` event, the six dead list-option fields from #2360 (five on
  `ListDocumentsOptions`, plus `MeOwnedDocumentsOptions.returnPage`), the #619
  per-document invitation verbs, the legacy `databases` permission /
  import-bulk verbs, and `waitForSync`.

  **20 deprecation warnings still exist**, and your build will still emit them.
  18 describe **server-side** deprecations that were never queued behind this
  batch (the metadata-category surface, the direct LLM/Gemini APIs) — those
  still work. The other two are client-side and stay deprecated because their
  replacement already shipped: `documents.list(...)` and `documents.listPage(...)`
  point at `client.me.ownedDocuments(...)` / `client.me.sharedDocuments(...)`.
- **No sub-API is an implicitly-unwrapped optional any more.** `client.documents`
  and its 25 siblings used to be typed `DocumentsAPI!`. Reads are unchanged.
- **`get*()` accessors became properties**, and the millisecond `Int` input
  parameters became `TimeInterval` **in seconds** — `waitForInitialSync(timeoutMs: 10_000)`
  is now `waitForInitialSync(timeout: 10)`. Response and telemetry `*Ms` fields
  are untouched, and the request bodies keep their `ttlMs` / `timeoutMs` JSON
  keys. `TimeInterval` can express values the old `Int` could not, so the
  conversion saturates rather than trapping: negatives and `.nan` floor to `0`,
  and `.infinity` (or anything above ~292 years) clamps to the maximum
  representable millisecond count.
- **The event / awareness / analytics payloads are `[String: JSONValue]`**, not
  `[String: Any]`, which makes several `@unchecked Sendable` conformances real.
- **`databases.subscribe` returns an `EventSubscription`**, not a discardable
  closure. Hold the handle: releasing it unsubscribes.
- **`JsBaoNetworkError` is public** and replaces the raw `URLError` that used to
  escape the HTTP paths. It also replaces the `HttpError(status: 401)` a
  *failed token refresh* used to raise: when a request's 401 triggers a refresh
  and that refresh times out, returns 5xx, or fails to decode, the underlying
  failure is now rethrown as a retryable `JsBaoNetworkError` instead of reading
  as invalid credentials. A refresh the server rejects with 401/403 still
  throws `HttpError(status: 401, message: "Invalid credentials")`.
- **`RefreshOutcome` changed shape** to carry that failure. It is no longer a
  `String`-raw-valued enum — `rawValue` and `init(rawValue:)` are gone — and
  `.network` now has an associated value: `case network(JsBaoNetworkError?)`.
  A comparison spelled `outcome == .network` no longer compiles; match it with
  `if case .network = outcome` (or bind the error). The other cases are
  unchanged and the enum is still `Equatable`.
- **The codegen-backing `*Shared` methods moved to `client.codegen`** and
  dropped the suffix.

#### Two breaks this batch does NOT close

**Workflow `input` / `meta` on the positional call forms.** The batch split
this surface rather than moving all of it, so be precise about which call site
you have:

| Call site | Currency now |
| --- | --- |
| `workflows.start(workflowKey:input:options:)` — the `input` parameter | still `[String: Any]` |
| `workflows.start(workflowKey:input:runKey:contextDocId:meta:forceRerun:)` — the generic `Encodable` form, `meta` | still `[String: Any]` |
| `workflows.runSync(workflowKey:input:…:meta:…)` — both overloads | still `[String: Any]` |
| `StartWorkflowOptions.input` / `.meta` | **now `[String: JSONValue]`** |

The options struct moved because its `@unchecked Sendable` conformance was
false while it held `[String: Any]`, and this batch was making those
conformances real. The positional parameters did not, because `JSONValue` has a
single `.number(Double)` case and retyping them would silently lose integer
exactness past 2^53.

The consequence is worth stating plainly: **the same logical field now has two
fidelities depending on which form you call.** Every form that takes `meta`
positionally — both `runSync` overloads and the generic `Encodable` `start` —
serializes an `Int64` exactly, because those values reach `JSONSerialization`
without passing through `JSONValue`. `start(StartWorkflowOptions(meta:))` does
route through `JSONValue`, so an integer past 2^53 loses its low bits there.
If you pass large integer IDs in `input` or `meta`, use one of the positional
forms until `JSONValue` gains an integer case. Finishing the job — retyping the
positional parameters too — is the **known future break** this migration does
not cover.

**The query/storage row currency** was in this batch's original scope and was
split into **issue #2546** rather than landed on top of a migration that
already touches every generated artifact. It has since landed — see "The query
row currency is `[String: JSONValue]`" below. `DatabaseChangeEvent.data` /
`.previousData` stay `Any?`: they are the DoDb subscription payload, a separate
surface, tracked in **#2579**.
### A refresh-time network outage is no longer reported as a 401 (#2366)

When a request got a 401 and the token refresh that followed could not reach
the server, the client threw `HttpError(status: 401, message: "Refresh
deferred due to network failure")`. A transient outage was therefore
indistinguishable from an expired session — and `BlobManager` treats a 401 as
a permanent rejection, so an upload caught by a network blip had its retained
bytes evicted and reported a terminal `willRetry: false` instead of being
requeued. The blob was lost.

That branch now throws the retryable `JsBaoNetworkError` (public since the
#2367 batch above) instead of a synthetic 401, so blob uploads requeue and
retry. This matches the JS client, which throws `JsBaoNetworkError` on the
same branch.

Migration: app code that inspects the status of a failed request and treats a
401 as "signed out" no longer sees a 401 for this case — which is the point.
A refresh the server actually *rejects* (401/403) is unchanged: it still
throws `HttpError(status: 401, message: "Invalid credentials")`, and that is
the case to sign out on.

**No new public API beyond #2367's.** This fix originally shipped the failure
under a module-internal representation so it would not add a public symbol
outside #2367's single breaking batch; with that batch landed, the failure is
spelled with #2367's public `JsBaoNetworkError` and the internal representation
is gone.
### Cached reads never wait on the network; the reconnect ceiling defaults to 5 minutes (#2364)

Two behavior changes that bring the Swift client onto js-bao's defaults. This
fix changes no signatures itself (the `refreshIfOlderThan` / `serverTimeout`
spellings come from the #2367 batch above), so there is nothing to migrate —
but both changes are observable at runtime.

**A cache hit returns immediately, and any refresh runs behind it.** When a
cached entry was older than `refreshIfOlderThan`, the Swift cache used to
fall through to an *awaited* network fetch, so every expiry of the shared
5-minute `me.get()` / `users.getBasic()` TTL blocked the caller on a round
trip. It now returns the cached value straight away and refreshes in the
background, so the *next* read is current — which is what js-bao has always
done. `refreshNetwork: true` changed the same way: it forces the background
refresh regardless of age rather than bypassing the cache and waiting.

If a call site needs to wait for fresh server data, ask for it explicitly:

```swift
let profile = try await client.me.get(
    options: FetchCachedOptions(waitForLoad: .network))
```

`waitForLoad: .network` is unchanged — it still skips the cache and awaits the
server. A cache *miss* also still awaits, because there is nothing to serve —
and so does a due entry that cached "no such record" (an empty 2xx body, stored
as JSON `null`), for the same reason.

**`maxReconnectDelay` now defaults to 300 seconds**, up from 30, matching
js-bao's `300_000` ms. Both clients use the same backoff formula, so the old
default made a Swift app retry roughly ten times as often — forever — against a
server that is down. Apps that want a tighter ceiling can still pass one:

```swift
JsBaoClientOptions(apiUrl: …, wsUrl: …, appId: …, maxReconnectDelay: 30)
```

### `me.ownedDocuments` is local-first by default; five `ListDocumentsOptions` fields are deprecated (#2360)

**Freshness change — read this if you call `me.ownedDocuments(...)` /
`me.ownedDocumentsPage(...)`.** `MeOwnedDocumentsOptions.waitForLoad` and
`.serverTimeoutMs` were declared and never read: every online call blocked on
the server. They now work, and the default `waitForLoad`
(`.localIfAvailableElseNetwork`) means what it means in js-bao — **when the
local metadata cache has owner rows, the call returns them immediately and
refreshes from the server in the background** (one bounded fetch, merged into
the cache, so the next call is fresh). A call with an empty local cache still
blocks on the server.

If a call site needs the old "always wait for the server" behavior, pass
`waitForLoad: .network`:

```swift
let docs = try await client.me.ownedDocuments(
    options: MeOwnedDocumentsOptions(waitForLoad: .network))
```

The rest of the resolution order:

| Option | Behavior |
| --- | --- |
| `localOnly: true`, `refreshFromServer: false`, `waitForLoad: .local` | local cache rows only, no HTTP request, `cursor == nil` |
| offline, `waitForLoad: .network` | throws `JsBaoError(code: .listUnavailableOffline)` |
| offline, any other mode | local cache rows |
| `serverTimeout` (a `TimeInterval` in **seconds**, default 10 — renamed from `serverTimeoutMs` in #2367) | bounds every server fetch; exceeding it throws `JsBaoError(code: .listTimeout)`. `0` means unbounded |

`limit` / `cursor` are ignored on local paths — the cache isn't paginated —
and the returned `cursor` is `nil` there. Because of that,
`ownedDocumentsPage(...)` is excluded from the local-first short-circuit: under
the default `waitForLoad` the paged form always fetches from the server, so a
paginating caller gets a real page and a real cursor instead of a `nil` cursor
it would read as "no more pages" (js-bao gates the same branch on
`!returnPage`). The cache-only modes still answer the paged form locally, with
`cursor == nil`. A server-fetched page is also returned as-is rather than
merged with the local-only rows, so a page never exceeds `limit` and a cursor
walk doesn't see the same local rows repeated on every page (js-bao returns its
page before the same merge). The flat `ownedDocuments(...)` keeps the merge.

One deliberate divergence from js-bao: `waitForLoad: .local` returns local rows
and does **not** fire a background refresh, where js-bao's `"local"` does. Only
`localOnly` / `refreshFromServer: false` suppress the refresh in js-bao. This is
what the approved plan for #2360 specifies — `.local` in Swift means "no network
at all".

**The app root document is filtered the same way on every path.** Local rows
and server rows alike drop the root unless `includeRoot: true` is passed,
matched by id (`getRootDocId()`) or the `__ROOT_TAG__` sentinel rather than by
permission — the root's permission is `read-write`, never `owner`. And
`includeRoot: true` against a local cache that doesn't hold the root falls
through to the server rather than answering without it (js-bao parity).

**Deprecations (removed since — see #2367 above).** `documents.list(...)` is a
blocking server fetch and never implemented the local-first half of
`ListDocumentsOptions`, so `refreshFromServer`, `localOnly`, `serverTimeoutMs`,
`waitForLoad` and `returnPage` carried a deprecation warning naming the
replacement, as did `MeOwnedDocumentsOptions.returnPage` (use
`ownedDocumentsPage(...)`). All six were **removed** in #2367; they no longer
compile.

**Fixed:** `documents.listGroupPermissions(documentId:includeSystem: true)` now
sends `?includeSystem=true`. It previously filtered client-side only, and the
server had already stripped the `_`-prefixed system groups — so the flag could
not return a system group at any input.

### Workflow run status comes from the server, unreconciled by the client (#2348)

The server now returns one canonical, already-reconciled run status in
`status.status`, from exactly this vocabulary:

`queued` | `running` | `apply_pending` | `apply_claimed` | `completed` |
`failed` | `terminated` | `missing`

Raw Cloudflare spellings (`complete`, `errored`) no longer reach the wire, and a
terminal run is never rolled back to `running`. The client's own reconciliation
is therefore gone:

- `workflows.getStatus` (and the runId-keyed status fetch behind `waitFor`)
  report the server's `status` verbatim. They no longer map `complete` →
  `completed` / `errored` → `failed`, and no longer fall back to `run.status`
  when the top-level status looks non-terminal.
- `workflows.waitFor` settles only on a server-declared terminal status
  (`completed`, `failed`, `terminated`, `apply_pending`, `apply_claimed`). A run
  row with `endedAt` set but a non-terminal status no longer settles the wait,
  and a terminal state is no longer guessed from `run.errorMessage`.

The `workflowStatus` WebSocket frame still maps `needsApply == true` to
`apply_pending` — the frame is the one surface where the apply state is only
recoverable from that flag.

Apps talking to an up-to-date server see no behavior change. An app that pins a
new client tag against an older server would see the raw statuses that server
sends, since nothing rewrites them anymore.

### `WebSocketManager` is an `actor`; `client.forceReconnect()` is deprecated (#2171)

The WebSocket transport and its reconnect state machine no longer run behind an
`NSLock`. `WebSocketManager` is a Swift `actor`, and every `URLSession` delegate
callback plus the receive loop's failure path now enters through one unbounded,
FIFO `AsyncStream` consumed by a single pump task — so the callback ordering a
class got from `URLSession`'s serial delegate queue is preserved by
construction rather than by convention.

The manager, its delegate protocol and the client's conformance methods went
module-internal in #2363, so almost all of this is invisible to apps. **Two
public changes:**

| Deprecated (still works) | Twin |
| --- | --- |
| `client.forceReconnect()` | `await client.forceReconnectAsync()` |

The synchronous spelling can only *start* the reconnect and return, so an
`isConnected` read immediately after it may still observe the old socket. The
twin returns once the reconnect has been initiated. This rides the existing
next-major window — see the policy section below; `forceReconnect` is class 1
(caller-observable ordering).

`WebSocketError` gains a `.transportFailure(message:code:)` case. It carries the
`Sendable` reduction of the `URLSession` error across the delegate boundary, and
its `errorDescription` returns the original `localizedDescription` **verbatim**,
so `ConnectionErrorEvent.message` reads exactly as it did before. An exhaustive
`switch` over `WebSocketError` needs a new case; a `catch`/`default` does not.

**`try await client.connect()` now throws that reduction instead of the original
`URLError`.** Before this release a transport failure resumed the connect call
with the `URLError` `URLSession` reported; it now resumes with
`WebSocketError.transportFailure(message:code:)`. Nothing about this is caught
by the compiler and the text is unchanged (`localizedDescription` is verbatim,
so logs read identically), so a `catch` that matched on the error's *type* stops
matching silently:

```swift
// Before — no longer entered.
do { try await client.connect() }
catch let error as URLError where error.code == .notConnectedToInternet { … }

// After — the URLError code rides along in the `code` payload.
do { try await client.connect() }
catch let error as WebSocketError {
    if case .transportFailure(_, let code) = error,
       code == URLError.notConnectedToInternet.rawValue { … }
}
```

`(error as NSError).domain` / `.code` shift the same way.

**Not changed:** `client.isConnected` and the manager's four synchronous reads
(`isConnected`, `isConnecting`, `connectionStatus`, `isSocketOpen`) stay
synchronous **permanently**, backed by a `nonisolated` snapshot box (sponsor
decision, 2026-08-02). They keep their exact values and their SwiftUI-callable
shape; undeprecated `…Async` twins sit beside them for callers that would rather
take an actor hop for a strictly-current read. `isSocketOpen` still reads the
socket's live `state`, not a cached boolean.

### The whole package builds in the Swift 6 language mode (#2310)

#1946 put the `JsBaoClient` target in the `.v6` language mode with a per-target
setting and pinned the package default at `[.v5]` so nothing else moved. That
pin is gone: the package now declares `swiftLanguageModes: [.v6]`, and
`SwiftBaoCodegen`, `JsBaoCodegenPlugin`, `JsBaoClientTests`,
`SwiftBaoCodegenTests` and `E2EMiniApp` build in Swift 6 mode with it. There is
no per-target opt-in left in the manifest, so a target added later inherits the
mode instead of silently landing in Swift 5.

Measured before committing to the shape: `SwiftBaoCodegen`,
`SwiftBaoCodegenTests` and `E2EMiniApp` were already clean at `.v6`;
`JsBaoClientTests` had 91 error sites. Those were test-side fixes only — no
library source and no public API changed:

- raw `NSLock.lock()`/`unlock()` inside `async` helpers → scoped `withLock`;
- `DispatchSemaphore.wait` / `Thread.sleep` inside a `Task` → an async wait and
  `Task.sleep`;
- locals mutated from a `@Sendable` callback, and `NSCountedSet` captured by
  one, → the shared `LockedBox` / `FireCounter` containment boxes in
  `Tests/JsBaoClientTests/Helpers/SendableBoxes.swift`;
- lock-guarded `static var` in the `URLProtocol` test stubs → one `LockedBox`
  per stub (a `static var` is global shared mutable state under `.v6` however
  carefully it is locked);
- `YDocument` crossing a `TaskGroup` boundary → the library's own
  `ConfinedYDocument` holder — including the two GCD-based deadlock regression
  markers and the shared watchdog in `Helpers/DeadlockWatchdog.swift`, which
  were the last warning-level sites left in the test target.

The app-layer packages moved with it (`swift-tools-version: 5.9` → `6.0` plus
the same `swiftLanguageModes: [.v6]` pin): `packages/swift-primitive-app`, the
iOS starter template, and the demo. `PrimitiveApp` measured 41 error sites, all
in the DEBUG-only inspector: its HTTP server and response writer are now
`Sendable` (their one mutable property each is lock-guarded, the shape
`SSEChannel` already used), and every route serializes its payload on the main
actor so the value crossing back to the request's `Task` is `Data` rather than
a `[String: Any]`. **An app scaffolded from the template now compiles in the
Swift 6 language mode by default, on both of its build paths** — the SPM pin in
`Package.swift` and `SWIFT_VERSION: "6.0"` in `project.yml`, which is what the
Xcode build (`./run-ios.sh`) reads. Change both if you would rather start in
Swift 5 mode; changing one leaves Xcode and `swift build` disagreeing about the
same source file. The docs example compile harness moved with them, so
documented snippets are graded in the mode the template ships.

`scripts/v6-sendable-gate.sh` moved with the pin: it now asserts the
package-level mode is `[.v6]` and that no target overrides it back — checked
across every target in the manifest, and covering the `-swift-version` unsafe
flag as well as the `swiftLanguageMode` setting — instead of asserting the old
target-scoped shape.

One non-concurrency change to watch for if you flip your own package: under the
Swift 6 language mode `#file` is the *concise* `<module>/<file>` form, not the
full source path. Anything that builds a filesystem path out of `#file` starts
resolving against the working directory instead of the source tree — use
`#filePath` there. That is what it did to this package's cross-platform test
harness locator, where the symptom was silent skips rather than a failure.

**Your app still does not have to adopt the Swift 6 language mode** — the mode
is per-target, so a Swift 5 package can depend on this one. The toolchain floor
is unchanged from #1946 (`swift-tools-version: 6.0`).

### Policy — when a synchronous public member gets an `async` twin (#2244)

The rule the actorization epic (#1993, #1994) has been applying, written down
so it stops being re-decided per phase. **Two classes, and every member falls in
one of them:**

1. **Deprecate + add an `async` twin** when a caller can observe the difference:
   the member returns a result, or it is ordered against another call the caller
   can make. The synchronous form keeps working for one release and is removed
   in the next major. `client.flushAnalytics()`, `client.analytics.logEvent(_:)`,
   `client.setBlobUploadConcurrency(_:)` and — new in this release —
   `AnalyticsContext.logEvent(_:)` are all in this class.
2. **Permanent, documented carve-out** when the member is a pure hand-off with
   no caller-observable ordering **and** making it `async` would break a
   correctness property. A carve-out names its reason here and in the type's
   docstring; it carries no deprecation and gets no twin.

The carve-outs, with their reasons:

| Member | Why it stays synchronous |
| --- | --- |
| `WebSocketManagerDelegate`'s synchronous methods (`webSocketManagerOnStatusChange`, `webSocketManagerOnConnected`, `webSocketManagerShouldReconnect(code:reason:)`, …) | They are called from `URLSession`'s socket callbacks and their answers gate the very next step of the connection. An `async` delegate method would let the socket advance past a `shouldReconnect` decision that has not been made yet. |
| `WebSocketManager`'s four transport reads (`isConnected`, `isConnecting`, `connectionStatus`, `isSocketOpen`) and the `client.isConnected` facade over them | Pure status reads with no result about a pending mutation. They serve from a `nonisolated` snapshot box written from inside the actor on every transition, so the values are identical to the lock version's — including the same snapshot-only caveat the class already documented. They are read from SwiftUI `body`, from `DebugInspector`, and through `DatabasesAPI`'s `isWebSocketOpen: () -> Bool` closure, none of which can `await`. Undeprecated `…Async` twins exist for callers that want a strictly-current read. |
| `BlobManager.downloadUrl` | Reads only the API-URL and app-ID closures, so it is `nonisolated`. It is the blob member most likely to be called straight from a SwiftUI `body` (it feeds an `AsyncImage` URL), where `async` is not available. |
| `AnalyticsQueue.prepared(_:)` | Lowering an event on the caller's thread is the *point*: it is where the `Any` graph stops and where the event's timestamp is taken. Hopping first would stamp the wrong instant. |
| `EventEmitter` subscription and emit | Callbacks run inside `emit` by contract, and `observeOnMainActor`'s hop is enqueued synchronously inside it so cross-event order holds. `async` would replace that ordering with the scheduler's. |

Twins carry a distinct name (`…Async`) rather than being `async` overloads:
Swift prefers the `async` overload in an asynchronous context, so a same-name
twin turns every existing un-`await`ed call inside an `async` function into a
compile error — the source break the window exists to avoid.

### `AnalyticsContext` gains `logEventAsync(_:)`; its synchronous `logEvent` is deprecated (#2244, consolidating #2272)

The handle returned by `client.getLlmAnalyticsContext()` /
`getGeminiAnalyticsContext()` was the last analytics entry point left out of the
Phase D3 window (#1993): its `logEvent` handed the work to an unstructured task
with no twin to await and no compiler nudge, while the same app's
`client.analytics.logEvent` had both. It now matches the rest of the surface.

| Deprecated (still works) | Twin |
| --- | --- |
| `context.logEvent(_:)` | `await context.logEventAsync(_:)` |

The deprecation rides the existing Phase D/E next-major window — no new window,
no separate migration note. What the twin adds is the same thing it adds
elsewhere: it returns once the event has reached the analytics buffer, so it is
ordered against a following flush.

`AnalyticsContext.init` takes an optional `logEventAsync:` closure between the
existing `logEvent:` and `isEnabled:` parameters. It is defaulted, so a
hand-constructed context keeps compiling unchanged; such a context's
`logEventAsync` falls back to the synchronous closure, calling it exactly once.

Also fixed here, in the same family: the `logAnalytics` closures the client
hands `LlmAPI` and `GeminiAPI` passed the event straight to the actor, so
`ingest` stamped its `timestamp` whenever the unstructured task happened to run
rather than when the call site logged it. They now lower the event with
`prepared(_:)` on the caller's thread, the way `getLlmAnalyticsContext()`
already did.

### `observeOnMainActor(_:withDelivery:)` reports when the client emitted (#2244)

New, additive. `observeOnMainActor(_:handler:)` delivers one main-actor hop
after the emit, so a handler that takes its own `Date()` measures that hop along
with the client's work. Anything building a timeline — a debug inspector, a
latency report — wants the emit's own instant instead. It can have it now:

```swift
subscription = client.observeOnMainActor(DocumentLoadedEvent.self, withDelivery: { event, delivery in
    rows.append(Row(at: delivery.emittedAt, order: delivery.sequence, id: event.documentId))
})
```

`EventDelivery` carries two fields, both captured inside the emit before any
handler or stream sees the payload:

- `emittedAt` — the wall-clock instant of the emit. Wall clock, so it can be
  compared with timestamps from outside the process, which also means it can
  move backwards if the system clock is adjusted between two emits.
- `sequence` — position in this emitter's **emit** order, from 1, increasing by
  one per emit across all event keys. Emit order, never delivery order: a
  handler that emits a second event synchronously gives that nested event a
  *higher* sequence even though the nested delivery finishes first. Sort a
  timeline on `sequence` and it cannot invert — including when the system clock
  moves backwards between two emits, which `emittedAt` alone cannot survive.
  The count is per emitter, so per client — two `JsBaoClient` instances in one
  process count independently and their sequences must not be compared.

Nothing changes for existing code. `observeOnMainActor(_:handler:)` keeps its
signature and is now written as a wrapper over the metadata form, so the two
share one delivery path — same main-actor isolation, same emit ordering, same
cancellation. A distinct argument label rather than an overload of the same
name, because two same-arity `observeOnMainActor` overloads would make a call
site whose closure takes anonymous parameters ambiguous.

`stream(for:)` gets no metadata in this pass. Delivering it there would first
need an answer for `replayingLatest:` — whether a replayed value reports its
original emit instant or the replay's — and there is no consumer waiting on it.

Cost: one wall-clock read, one counter increment and one struct initialization
per emit, inside the critical section the emit already entered. No new lock
acquisition and nothing per subscriber. Measured at ~25 ns per emit on an
Apple-silicon debug build.

### The WebSocket plumbing and the logger are internal (#2363)

`WebSocketManagerDelegate`, `WebSocketManager`, `Logger` and `createLogger` were
`public` by accident — they live in `Internal/` and nothing outside the module
implements or calls them. Because the delegate protocol was public,
`JsBaoClient`'s conformance also put its 13 `webSocketManagerOn*` /
`webSocketManagerBuild*` methods on the client's public API, where app code
could read the bearer token out of
`webSocketManagerBuildConnectionRequest(connectionId:)`'s `?token=` URL or call
the `On*` methods to inject connection-lifecycle events the app's own observers
treat as real. All of these are now `internal`.

Two types that *are* public API kept their access and moved out of `Internal/`:
`LogLevel` (now `Types/LogLevel.swift`) and `WebSocketError` (now in
`Types/Errors.swift`, with the client's other public errors). Nothing about
either declaration changed.

**Migration.** Nothing to do unless your app referenced one of the internal
symbols above, which it should not have. Two consequences worth naming:

- `WorkflowsAPI`'s two public initializers no longer take `logger:` — the
  parameter's type is now internal. Drop the argument; an internal overload
  carries the logger inside the module. Set the client's log level with
  `JsBaoClientOptions.logLevel` or `client.setLogLevel(_:)` as before.
- The initializers of the `Internal/` helpers (`AnalyticsQueue`, `AuthController`,
  `BlobManager`, `DocumentManager`, `HttpClientConfig`) are internal too, since
  each takes the now-internal `Logger`. Those types were never meant to be
  constructed from an app.

Unrelated to the `?token=` handshake itself: the WS URL still carries the token
as a query parameter for protocol compatibility with the JS client. Moving to an
Authorization header needs a coordinated server change and is tracked separately.

### Fixed — `databases.executeOperation(timing:)` now actually asks for timings (#2359)

`timing` was encoded as a field in the request body. The server reads the flag
from the `X-Timing` request header, so it never saw it and the response carried
no `_timing` block — the option did nothing. It is sent as `X-Timing: true` now
(and left out of the body, which is where the JS client has always put it), so
`timing: true` returns the per-phase breakdown the docs describe.

No source change is needed in your app: `ExecuteOperationOptions.timing` and
the `timing:` argument on the typed `executeOperation<Params, Output>` overload
keep the same shape. Only the wire changes — a request that used to carry a
`timing` body field the server ignored now carries the header instead.

One caveat if you are still on the deprecated closure init: `DatabasesAPI(makeRequest:)`
cannot carry request headers, so `executeOperation` with `timing: true` now
throws `CLIENT_LEGACY_TRANSPORT_UNSUPPORTED_OPTIONS` from the adapter instead of
silently returning an untimed result. Move to `init(transport:)` (what
`JsBaoClient` already does for you), or drop the `timing` flag. No other
`executeOperation` call shape is affected, and instances built from a
`JsBaoClient` never hit this path.

### Fixed — `documents.validateAccess` and `documents.getRoot` called routes the server doesn't have (#2358)

Both calls always failed with an HTTP 404:

- `validateAccess(documentId:)` sent `GET /documents/{id}/access`. It now sends
  `POST /documents/{id}/validate-access`, the route the server registers and the
  one js-bao uses.
- `getRoot()` sent `GET /documents/root`, which the server resolved as a document
  whose id is the literal string `"root"`. It now resolves the root document id
  from the JWT via `client.getRootDocId()` and fetches that document, matching
  js-bao. When the token carries no `rootDocId` it throws
  `JsBaoError(code: .notFound)` locally instead of issuing a doomed request, and
  on a `DocumentsAPI` with no wired client it throws `JsBaoError(code: .unavailable)`
  — the same guard `openRoot()` already had.

### Requires a Swift 6 toolchain — the package manifest is at tools-version 6.0 (#1946, Phase F)

`Package.swift` moves from `swift-tools-version: 5.9` to `6.0`, and the
`JsBaoClient` target opts into the Swift 6 language mode
(`swiftSettings: [.swiftLanguageMode(.v6)]`). **Resolving this package now needs
Swift 6.0 or later (Xcode 16+)** — that is the floor the manifest imposes, and
it is the only thing this change asks of a downstream app.

The toolchain the package is actually built and tested against is **Swift 6.3
(Xcode 26)**. Toolchains between 6.0 and 6.3 satisfy the manifest but are not
part of our verification. The target builds warning-free under 6.3 — the 11
warning-level `#SendableClosureCaptures` diagnostics this entry used to caveat
were cleared in #2318, so there is no diagnostic left for an older 6.x to grade
as an error.

No public API shape changes. The `Sendable` conformances the mode enforces were
all added by the earlier phases of this epic (#1988, #1991, #1992, #1993,
#1994), each recorded in its own entry below; this entry is the mode itself
becoming the compiler's job rather than a gate script's.

**Your app does not have to adopt the Swift 6 language mode.** The language mode
is per-target: a package in Swift 5 mode can depend on a target in Swift 6 mode.
(The rest of this package followed in #2310 — see the entry above.)

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
