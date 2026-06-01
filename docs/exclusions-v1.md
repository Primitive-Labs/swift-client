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

### ✅ Closed in #790 (was here in v1)

The bulk of the original v1 exclusions landed via the API-parity pass:

- **App-level invitations** (`InvitationsAPI`, 8 methods incl. deferred-grant browse/revoke)
- **Blob buckets** (`BlobBucketsAPI`, 10 methods incl. raw upload/download)
- **Cron triggers** (`CronTriggersAPI`, 8 methods)
- **Type configs** (`CollectionTypeConfigsAPI` + `DatabaseTypeConfigsAPI`, 10 methods)
- **DocumentsAPI access-requests** + **pending-creates** + **getOwner** + **revokeGroupPermission** + **local-state methods** (`isOpen`, `isPendingCreate`, `hasLocalCopy`, `getDocumentPermission`, `getLocalMetadata`) (~13 methods)
- **DatabasesAPI operational** (CEL context, managers, group permissions, executeBatch, importRows) (~10 methods)
- **UsersAPI**: `getProfiles` + `lookup`
- **WorkflowsAPI**: `listStepRuns` + `forceRerun` + `forward` + `contextDocId` + `terminate(contextDocId:)`
- **MeAPI**: `uploadAvatar` now respects `contentType`

See [parity/api-methods.md](parity/api-methods.md) for the per-method table.

### Still open

#### `listLocalDocuments` and offline-metadata browsing

These let JS clients browse what's been persisted locally without going to the server:

| JS method | Notes |
|---|---|
| `listLocalDocuments()` | enumerate offline metadata |
| `evictLocalDocument(id)` | clear a specific doc from local cache |
| `setRetentionPolicy(...)` | configure cache eviction |
| `markMetadataDeleted(id)` | tombstone for offline-deleted docs |

Swift has the underlying offline store but no public top-level surface for browsing it. (`getLocalMetadata` did land on `client.documents.*` in #790.) Could be added in v1.1.

#### `waitFor*` family

| JS method | Purpose |
|---|---|
| `waitForWriteConfirmation(docId, timeoutMs?)` | "did my recent writes commit on the server?" |
| `waitForInitialSync(docId)` | "is the doc fully synced from the server?" |
| `waitForSync(docId)` | one-shot sync gate |
| `waitForInSync(docId)` | continuous sync state |
| `waitForAuthBootstrap()` | initial-auth-flow handoff |

Swift has `waitForAuthReady()` but its return type is `Void` whereas JS returns `{userId, mode}`. The other `waitFor*` are entirely absent. These are mainly UX affordances — "did my write land before I navigate away?" — and some are easier in Swift via async/await directly. Worth filling in for v1.1.

#### `MeAPI.bookmarks` sub-API + `MeAPI.getProfile()`

**Auto-closed by a JS-side removal.** When the parity doc was seeded, `client.me.bookmarks.*` existed on the JS client and was a real Swift gap. **PR #702 removed bookmarks from the JS client as a breaking change** (and `getProfile()` is also no longer in the JS source). Swift never implemented either, so the gap closed without any Swift work — but the reasoning matters for future audits: if bookmarks ever return to the JS surface, this row becomes a real Swift gap again, not a doc bug.

#### `DatabasesAPI.subscribe`

WebSocket-based per-database subscription. Significantly more involved than the HTTP wrappers closed in #790. Tracked separately for a v1.1 follow-up.

#### `TypedModel<T>` minimal v1 surface

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
- `setNetworkMode` / `syncMetadata` options objects (currently bare-bones)
- ~~`WorkflowsAPI` options: `forceRerun`, `contextDocId`, `forward`~~ — closed in #790
- ~~`StorageRecord.updatedAtMs` field~~ — closed in #789
- ~~`client.getDocumentPermission(...)`~~ — closed in #790 (lives on `client.documents.*`)
- `DatabasesAPI.subscribe` (WebSocket-based)
- `importCsv` raw-CSV variant with schema-aware coercion (current Swift takes pre-parsed rows)
- `addTag` / `removeTag` returning `[String]` instead of raw dict
- `client.deleteDocument(forceCloseIfOpen:)` parameter

---

## Notes for maintainers

If you add a feature to the Swift client that was on this list, **remove it from this doc** and file the entry in [parity/api-methods.md](parity/api-methods.md) instead.

If you find a JS feature that's missing on Swift and isn't in this doc, **add it here** with a status (one of the four categories above) before opening a parity issue. That way the doc stays the source of truth for "is this a gap or a choice?"
