# Intentional exclusions for v1

This is the canonical list of "JS client features that are deliberately not in the v1 Swift client." Reviewers should consult this **before** flagging something as a missing feature.

> **Default for unknowns is "intentionally excluded for v1."** If you're reviewing this document and notice something here that you actually want in v1, flip its status to "in scope" and that becomes an action item rather than a documented choice. Until then, every entry below is the current call.

## Categories

Items group into four buckets:

1. **Out of scope for v1, planned for later** — recognize the gap, plan to fix
2. **No Apple-platform use case** — the feature fundamentally doesn't apply to iOS/macOS apps
3. **Different shape than JS, intentional** — the capability exists but is reached differently
4. **Deferred — capability could exist but no demand yet** — file an issue if you need it

---

## 1. Out of scope for v1, planned for later

### App-level invitations + deferred grants (`InvitationsAPI`)

JS has a top-level `client.invitations.*` for **app-level** invitations: invite someone to join the whole app, optionally with deferred document/group grants that activate when they accept.

| JS method | Notes |
|---|---|
| `quota()`, `create(...)`, `list(...)`, `get(...)`, `delete(...)`, `accept(token)` | App-level invitation lifecycle |
| `listDeferredGrants(...)` | Browse pending grants |
| (deferred-grant accept flow) | |

**Per-document invitations are present** on the Swift side — they live on `client.documents.*` (acceptInvitation, declineInvitation, listInvitations, inviteUser, etc.) and `client.me.pendingDocumentInvitations()`. Storylens and other sample apps use the per-document flow extensively.

The app-level flow is the planned v1.1 addition.

### Blob buckets (`BlobBucketsAPI`)

Per-document blobs are fully present (`client.document(id).blobs().upload(...)`, `.read(blobId:)`). Used extensively by storylens-ios for cover images and page images.

App-level blob *buckets* (separate namespace, signed URLs, configurable TTL tiers, access policies) are not exposed.

### `listLocalDocuments` and offline-metadata browsing

These let JS clients browse what's been persisted locally without going to the server:

| JS method | Notes |
|---|---|
| `listLocalDocuments()` | enumerate offline metadata |
| `evictLocalDocument(id)` | clear a specific doc from local cache |
| `setRetentionPolicy(...)` | configure cache eviction |
| `getLocalMetadata(id)` | inspect cached metadata |
| `markMetadataDeleted(id)` | tombstone for offline-deleted docs |

Swift has the underlying offline store but no public surface for browsing it. Could be added in v1.1.

### `waitFor*` family

| JS method | Purpose |
|---|---|
| `waitForWriteConfirmation(docId, timeoutMs?)` | "did my recent writes commit on the server?" |
| `waitForInitialSync(docId)` | "is the doc fully synced from the server?" |
| `waitForSync(docId)` | one-shot sync gate |
| `waitForInSync(docId)` | continuous sync state |
| `waitForAuthBootstrap()` | initial-auth-flow handoff |

Swift has `waitForAuthReady()` but its return type is `Void` whereas JS returns `{userId, mode}`. The other `waitFor*` are entirely absent. These are mainly UX affordances — "did my write land before I navigate away?" — and some are easier in Swift via async/await directly. Worth filling in for v1.1.

### Cron triggers (`CronTriggersAPI`)

Cron-scheduled workflow triggers. Not present on Swift.

| JS method |
|---|
| `list()`, `get(id)`, `create(...)`, `update(...)`, `delete(id)`, `pause(id)`, `resume(id)`, `test(...)` |

Workflows themselves are present (`client.workflows.*`); the cron-triggering layer on top isn't.

### Type configs (`CollectionTypeConfigsAPI`, `DatabaseTypeConfigsAPI`)

Configure which TOML model types are valid for app-defined collections / databases.

| JS method |
|---|
| `list()`, `get(type)`, `create(...)`, `update(...)`, `delete(type)` |

Both APIs are 5 methods each, fully ⛔ on Swift.

### `MeAPI.bookmarks` sub-API

| JS method |
|---|
| `list()`, `add(...)`, `remove(...)`, `update(...)` |

Personal bookmarks for the current user. Not in v1.

### Document open-state checks, access requests, pending creates

On `client.documents.*`:

| JS method |
|---|
| `isOpen(id)` |
| `requestAccess(id)` / `cancelAccessRequest(id)` |
| `listAccessRequests(id)` / `approveAccessRequest(...)` / `rejectAccessRequest(...)` |
| `getPendingCreate(id)` / `cancelPendingCreate(id)` / `listPendingCreates()` |
| `getOwner(id)` / `transferOwnership(...)` |
| Group permission revoke + several related methods |

About 13 methods grouped here. Some (open-state, getOwner) are quick wins; others (access requests as a feature) are larger surface.

### Database operational methods

On `client.databases.*`:

| JS method |
|---|
| `executeBatch(...)`, `importCsv(...)`, `subscribe(id, ...)` |
| CEL context: `getCelContext(...)`, `setCelContext(...)` |
| Managers: `listManagers(id)`, `addManager(...)`, `removeManager(...)` |
| Group permissions: `listGroupPermissions(id)`, `addGroupPermission(...)`, `removeGroupPermission(...)` |

About 10 methods.

### `WorkflowsAPI.listStepRuns`

Inspecting per-step runs of a workflow. Useful for debugging UI.

### `UsersAPI.getProfiles` (batch) + `lookup` (by email)

Batch-fetch user profiles, look up a user by email.

### `TypedModel<T>` minimal v1 surface

`TypedModel<T>` only has `create`, `find`, `findAll`, `delete`. The richer js-bao `BaseModel` surface (`update`, `query`, `queryOne`, `findByUnique`, etc.) requires dropping to `model.dynamic.*`. v1.1 polish: lift the common methods up to `TypedModel<T>`.

---

## 2. No Apple-platform use case

### Passkeys (7 methods)

| JS method |
|---|
| `passkeyAuth.start()`, `passkeyAuth.finish(...)` |
| `passkeyRegister.start()`, `passkeyRegister.finish(...)` |
| `listPasskeys()`, `deletePasskey(...)`, `updatePasskey(...)` |

iOS has its own passkey + WebAuthn integration via `AuthorizationServices` (`ASAuthorizationPlatformPublicKeyCredentialProvider` etc.). The JS client implements WebAuthn over the wire because browsers don't have a clean SDK; iOS apps go through the system framework directly. The right v1 story is "use Apple's passkey UI, hand the resulting attestation to your server." No JsBaoClient methods needed.

If a future use case demands JsBaoClient-mediated passkey flows on Apple platforms, file an issue.

### `webauthn-large-blob`

Browser internals for storing data in WebAuthn credentials. iOS doesn't expose this surface in any practical way for SDK use. ⛔ permanent.

---

## 3. Different shape than JS, intentional

### Per-document invitations folded into DocumentsAPI / MeAPI

JS has both `client.invitations.*` (app-level) and per-document invitation methods on `client.documents.*`. Swift keeps the per-document methods on `client.documents.*` and `client.me.*` but doesn't have the top-level namespace.

This is deliberate: the per-document flow is by far the more common use case (storylens uses it heavily). Lifting per-document methods up into a top-level namespace would force callers to import a separate class for what's clearly a document-scoped operation. The shape choice is fine.

### Sub-API styles

The 14 Swift sub-APIs use 3 different styles: thin dict facade, typed-options + cache-aware, orchestration + state. Worth converging in v1.1, but the current mix reflects per-feature complexity.

### `client.workflows` extra methods

`runAndApply`, `awaitRun`, `recheckPendingRuns` are Swift-only. They're not gaps the other direction — they're additions for a Swift-shaped UX (typed waiters around async/await).

---

## 4. Deferred — file an issue if you need it

Capabilities not currently planned but reasonable to add. If you find yourself wanting any of these, file an issue:

- `client.openDocumentByAlias(alias)` — open by URL alias
- `client.getDocumentPermission(...)` — inspect current user's permission on a doc
- `setNetworkMode` / `syncMetadata` options objects (currently bare-bones)
- `WorkflowsAPI` options: `forceRerun`, `contextDocId`, `forward`
- TypedModel `updatedAtMs` field on `StorageRecord`

---

## Notes for maintainers

If you add a feature to the Swift client that was on this list, **remove it from this doc** and file the entry in [parity/api-methods.md](parity/api-methods.md) instead.

If you find a JS feature that's missing on Swift and isn't in this doc, **add it here** with a status (one of the four categories above) before opening a parity issue. That way the doc stays the source of truth for "is this a gap or a choice?"
