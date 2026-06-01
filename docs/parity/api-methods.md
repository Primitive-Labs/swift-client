# API method parity

Per-sub-API parity table. Every method on `JsBaoClient` (JS) is listed with its Swift counterpart (or lack of one).

Status legend: see [README.md](README.md). Default for unknowns is ⛔ (intentionally out for v1).

> **Note.** This table was seeded from the per-group review in `pr349-review/03-api.md`. Where a method is marked ⛔ but you intend it as ❌, flip the symbol.

## Top-level client surface

The JS client exposes 17 sub-APIs. Swift exposes 14. The ones not present as Swift sub-APIs:

| JS sub-API | Status | Where on Swift, if anywhere |
|---|---|---|
| `client.documents` | ✅ | `client.documents` (DocumentsAPI) |
| `client.databases` | ✅ | `client.databases` (DatabasesAPI) |
| `client.collections` | ✅ | `client.collections` (CollectionsAPI) |
| `client.me` | ✅ | `client.me` (MeAPI) |
| `client.session` | ✅ | `client.session` (SessionAPI) — endpoint fixed in #789's predecessor commit |
| `client.users` | ✅ | `client.users` (UsersAPI) |
| `client.groups` | ✅ | `client.groups` (GroupsAPI) |
| `client.groupTypeConfigs` | ✅ | `client.groupTypeConfigs` (GroupTypeConfigsAPI) |
| `client.ruleSets` | ✅ | `client.ruleSets` (RuleSetsAPI) |
| `client.gemini` | ✅ | `client.gemini` (GeminiAPI) |
| `client.llm` | ✅ | `client.llm` (LlmAPI) |
| `client.prompts` | ✅ | `client.prompts` (PromptsAPI) |
| `client.workflows` | ✅ | `client.workflows` (WorkflowsAPI) |
| `client.integrations` | ✅ | `client.integrations` (IntegrationsAPI) — structured request/response/error contract restored in a predecessor commit. |
| `client.invitations` | ✅ | `client.invitations` (InvitationsAPI) — added in the API-parity pass. Per-document invitation methods stay on `client.documents.*` (acceptInvitation, declineInvitation, listInvitations, inviteUser, …). |
| `client.blobBuckets` | ✅ | `client.blobBuckets` (BlobBucketsAPI) — added in the API-parity pass; raw upload/download routed through the same closure pattern as `BlobManager`. |
| `client.cronTriggers` | ✅ | `client.cronTriggers` (CronTriggersAPI) — added. |
| `client.collectionTypeConfigs` | ✅ | `client.collectionTypeConfigs` (CollectionTypeConfigsAPI) — added. |
| `client.databaseTypeConfigs` | ✅ | `client.databaseTypeConfigs` (DatabaseTypeConfigsAPI) — added. |

**Top-level methods on `JsBaoClient` itself** (not under a sub-API namespace):

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `client.connect()` | `client.connect()` | ✅ | |
| `client.disconnect()` | `client.disconnect()` | ✅ | |
| `client.destroy()` | `client.destroy()` | ✅ | |
| `client.openDocument(id)` | `client.openDocument(docId:)` | ✅ | |
| `client.openDocumentByAlias(alias)` | — | ⛔ | |
| `client.closeDocument(id)` | `client.closeDocument(docId:)` | ✅ | |
| `client.createDocument(...)` | `client.createDocument(...)` | ⚠️ | Return shape changed: JS `{metadata}`, Swift `(documentId, doc?)` |
| `client.deleteDocument(id, opts)` | `client.deleteDocument(documentId:)` | ⚠️ | Swift drops `forceCloseIfOpen` |
| `client.document(id)` | `client.document(id)` | ✅ | document handle for blobs / typed access |
| `client.getRootDocId()` | `client.getRootDocId()` | ⚠️ | JS sync-cached, **Swift async + network call** — chatty surprise |
| `client.setNetworkMode(mode, opts)` | `client.setNetworkMode(mode)` | ⚠️ | Swift loses entire options object |
| `client.syncMetadata(opts)` | `client.syncMetadata()` | ⚠️ | Swift loses entire options object |
| `client.waitForAuthReady()` | `client.waitForAuthReady()` | ⚠️ | JS returns `{userId, mode}`, Swift returns `Void` |
| `client.waitForAuthBootstrap()` | — | ⛔ | |
| `client.waitForWriteConfirmation(...)` | — | ⛔ | |
| `client.waitForInitialSync(...)` | — | ⛔ | |
| `client.waitForSync(...)` | — | ⛔ | |
| `client.waitForInSync(...)` | — | ⛔ | |
| `client.listLocalDocuments()` | — | ⛔ | offline metadata browsing |
| `client.evictLocalDocument(id)` | — | ⛔ | |
| `client.setRetentionPolicy(...)` | — | ⛔ | |
| `client.getLocalMetadata(id)` | — | ⛔ | |
| `client.markMetadataDeleted(id)` | — | ⛔ | |
| `client.getDocumentPermission(...)` | `client.documents.getDocumentPermission(documentId:)` | 🔀 | Exposed via DocumentsAPI rather than top-level. Closed in #790. |
| `client.events.on(...)` / `off(...)` | `client.events.on(...) / off(...)` | ✅ | See [events.md](events.md) for event-name parity |
| `passkey*` (7 methods) | — | ⛔ | iOS has its own passkey/AuthorizationServices flow |

---

## DocumentsAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get(id)` | `get(id:)` | ✅ | |
| `list()` | `list()` | ✅ | |
| `update(id, params)` | `update(documentId:, params:)` | ✅ | |
| `delete(id, opts)` | `delete(documentId:)` | ⚠️ | Swift drops `forceCloseIfOpen` |
| `addTag(id, tag)` | `addTag(documentId:, tag:)` | ⚠️ | Swift returns raw dict instead of `[String]` |
| `removeTag(id, tag)` | `removeTag(documentId:, tag:)` | ⚠️ | same as above |
| `inviteUser(...)` | `inviteUser(...)` | ✅ | |
| `acceptInvitation(id)` | `acceptInvitation(documentId:)` | ✅ | |
| `declineInvitation(...)` | `declineInvitation(documentId:, invitationId:)` | ✅ | |
| `listInvitations(id)` | `listInvitations(documentId:)` | ✅ | |
| `getInvitationByEmail(...)` | `getInvitationByEmail(documentId:, email:)` | ✅ | client-side filter from list |
| `updateInvitation(...)` | `updateInvitation(...)` | ✅ | |
| `deleteInvitation(...)` | `deleteInvitation(documentId:, invitationId:)` | ✅ | |
| `isOpen(id)` | `isOpen(documentId:)` | ✅ | local-only, delegates to `DocumentManager`. Closed in #790. |
| `requestAccess(id)` | `requestAccess(documentId:, params:)` | ✅ | Closed in #790. |
| `cancelAccessRequest(id)` | — | ⛔ | JS uses `removePermission` for cancellation flows — there's no dedicated `cancelAccessRequest` server route. Tracked as a name-shape mismatch, not a missing endpoint. |
| `listAccessRequests(id)` | `listAccessRequests(documentId:)` | ✅ | Closed in #790. |
| `approveAccessRequest(id, requestId)` | `approveAccessRequest(documentId:, requestId:, params:)` | ✅ | Closed in #790. |
| `rejectAccessRequest(id, requestId)` | `denyAccessRequest(documentId:, requestId:, params:)` | 🔀 | JS calls it `denyAccessRequest`. Swift matches the JS method name (the parity doc had `reject`; the actual JS surface is `deny`). Closed in #790. |
| `getPendingCreate(id)` | `isPendingCreate(documentId:)` | 🔀 | Swift exposes `isPendingCreate(id) -> Bool`; the JS `getPendingCreate` returns the entry. v1.1: surface the full entry. |
| `cancelPendingCreate(id)` | `cancelPendingCreate(documentId:)` | ✅ | Closed in #790. |
| `listPendingCreates()` | `listPendingCreates() -> [String]` | 🔀 | Swift returns ID strings only; JS returns richer entries. v1.1: expose `{documentId, title?, createdAt}` rows. |
| `revokeGroupPermission(...)` | `revokeGroupPermission(documentId:, groupType:, groupId:)` | ✅ | Closed in #790. |
| `getOwner(id)` | `getOwner(documentId:)` | ✅ | Closed in #790 — convenience wrapper over `get(documentId:)`. |
| `transferOwnership(...)` | `transferOwnership(documentId:, newOwnerId:)` | ✅ | Already present pre-#790. |
| `hasLocalCopy(id)` | `hasLocalCopy(documentId:)` | ✅ | Closed in #790. |
| `getDocumentPermission(id)` | `getDocumentPermission(documentId:)` | ✅ | Closed in #790. |
| `getLocalMetadata(id)` | `getLocalMetadata(documentId:)` | ✅ | Closed in #790. |

## DatabasesAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get(id)` | `get(id:)` | ✅ | |
| `list()` | `list()` | ✅ | |
| `create(params)` | `create(params:)` | ✅ | |
| `update(id, params)` | `update(databaseId:, params:)` | ✅ | |
| `delete(id)` | `delete(databaseId:)` | ✅ | |
| `query(...)` | `query(...)` | ✅ | |
| `executeBatch(...)` | `executeBatch(databaseId:, operationName:, batch:)` | ✅ | Closed in #790. |
| `importCsv(...)` | `importRows(databaseId:, operationName:, rows:, batchSize:)` | 🔀 | Swift takes pre-parsed rows + batches via `executeBatch`. JS handles raw CSV parsing + schema-aware coercion + progress callbacks too — that richer surface is a v1.1 follow-up. |
| `subscribe(id, ...)` | — | ⛔ | WebSocket-based subscriptions. Deferred (see Notes below). |
| `getCelContext(...)` | `getCelContext(databaseId:)` | ✅ | Closed in #790. |
| `setCelContext(...)` | `updateCelContext(databaseId:, celContext:)` | ✅ | Closed in #790. Named to match the JS `updateCelContext` (the parity doc had `setCelContext`; JS surface is `updateCelContext`). |
| `listManagers(id)` | `listManagers(databaseId:)` | ✅ | Closed in #790. Convenience wrapper over `listPermissions` that filters to `manager` rows. |
| `addManager(...)` | `addManager(databaseId:, userId:)` | ✅ | Closed in #790. |
| `removeManager(...)` | `removeManager(databaseId:, userId:)` | ✅ | Closed in #790. |
| `listGroupPermissions(id)` | `listGroupPermissions(databaseId:, includeSystem:)` | ✅ | Closed in #790. |
| `addGroupPermission(...)` | `grantGroupPermission(databaseId:, params:)` | ✅ | Closed in #790. Named to match JS (`grantGroupPermission`). |
| `removeGroupPermission(...)` | `revokeGroupPermission(databaseId:, groupType:, groupId:)` | ✅ | Closed in #790. |

## CollectionsAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get(id)` | `get(id:)` | ✅ | |
| `list()` | `list()` | ✅ | |
| `create(params)` | `create(params:)` | ✅ | |
| `update(id, params)` | `update(...)` | ✅ | |
| `delete(id)` | `delete(...)` | ✅ | |
| `addToCollection(...)` | `addToCollection(...)` | ✅ | |
| `removeFromCollection(...)` | `removeFromCollection(...)` | ✅ | |
| `listMembers(id)` | `listMembers(id:)` | ✅ | |

## MeAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get()` | `get()` | ✅ | |
| `update(params)` | `update(params:)` | ✅ | |
| `uploadAvatar(data, contentType)` | `uploadAvatar(data:, contentType:)` | ✅ | `contentType` now wired through the raw-HTTP closure as `Content-Type`. Closed in #790. |
| `pendingDocumentInvitations()` | `pendingDocumentInvitations()` | ✅ | |
| `bookmarks.*` | — | ✅ resolved by JS-side removal | The JS client *had* `me.bookmarks.*` when the parity doc was seeded; **PR #702 removed it as a breaking change.** Swift never implemented it, so the gap auto-closed when JS dropped the API. If bookmarks come back later, this row gets a new ⛔ entry. |
| `getProfile()` | — | ✅ resolved by JS-side removal | Same as bookmarks — not in current JS source. May have been removed alongside (or never landed there to begin with). |

## UsersAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get(userId)` | `get(userId:)` | ✅ | |
| `getProfiles(userIds)` | `getProfiles(userIds:)` | ✅ | Closed in #790. Server caps at 100 ids per call. |
| `lookup(email)` | `lookup(email:)` | ✅ | Closed in #790. |

## GroupsAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get(id)` | `get(id:)` | ✅ | |
| `list(opts)` | `list(filters:)` | ⚠️ | Swift uses `[String: Any]?`; other Swift APIs use typed structs — pattern inconsistency |
| `create(params)` | `create(params:)` | ✅ | |
| `update(id, params)` | `update(...)` | ✅ | |
| `delete(id)` | `delete(...)` | ✅ | |
| `addMember(...)` | `addMember(...)` | ✅ | |
| `removeMember(...)` | `removeMember(...)` | ✅ | |
| `listMembers(id)` | `listMembers(id:)` | ✅ | |

## GroupTypeConfigsAPI

| JS method | Swift method | Status |
|---|---|---|
| `get(type)` | `get(type:)` | ✅ |
| `list()` | `list()` | ✅ |
| `create(params)` | `create(params:)` | ✅ |
| `update(...)` | `update(...)` | ✅ |
| `delete(type)` | `delete(type:)` | ✅ |

## RuleSetsAPI

| JS method | Swift method | Status |
|---|---|---|
| `get(id)` | `get(id:)` | ✅ |
| `list()` | `list()` | ✅ |
| `create(params)` | `create(params:)` | ✅ |
| `update(...)` | `update(...)` | ✅ |
| `delete(id)` | `delete(...)` | ✅ |

## SessionAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get()` | `get()` | ✅ | Endpoint fixed in commit 7feda61b. |

## GeminiAPI / LlmAPI

| JS method | Swift method | Status |
|---|---|---|
| LlmAPI: `chat(...)` | `chat(...)` | ✅ |
| LlmAPI: `complete(...)` | `complete(...)` | ✅ |
| GeminiAPI: `generate(...)` | `generate(...)` | ✅ |
| GeminiAPI: `embed(...)` | `embed(...)` | ✅ |

## PromptsAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get(id)` | `get(id:)` | ✅ | |
| `list()` | `list()` | ✅ | |
| `execute(id, params)` | `execute(promptId:, ...)` | ⚠️ | Swift uses positional args where JS uses options object. Cosmetic; functionally equivalent. v1.1 signature polish. |

## IntegrationsAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `call(spec)` | `call(request:)` | ✅ | Structured `IntegrationCallRequest` (method/path/query/headers/body), `IntegrationCallResponse` unwrapping, typed error throwing on non-OK responses. Closed in commit 7feda61b. |
| `list()` | — | ⛔ | Not implemented. |
| `get(id)` | — | ⛔ | Not implemented. |

## WorkflowsAPI

The biggest API on both sides. Swift adds features that don't exist in JS (`runAndApply`, `awaitRun`, `recheckPendingRuns`).

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `start(workflowId, params)` | `start(workflowKey:, input:, options:)` | ✅ | `StartWorkflowOptions.forceRerun` added in #790. |
| `getStatus(runId)` | `getStatus(workflowKey:, runKey:, contextDocId:)` | ⚠️ | Swift doesn't normalize CF/DB status codes the way JS does. Returns the raw envelope. v1.1 polish. |
| `terminate(runId, opts?)` | `terminate(workflowKey:, runKey:, contextDocId:)` | ✅ | `contextDocId` added in #790. |
| `listRuns(opts)` | `listRuns(options:)` | ✅ | `ListWorkflowRunsOptions.forward` + `.contextDocId` added in #790. |
| `listStepRuns(runId)` | `listStepRuns(runId:)` | ✅ | Closed in #790. |
| `(definition CRUD)` | `(definition CRUD)` | ✅ | |
| — | `runAndApply(...)` | Swift-only | apply-after-run fan-out |
| — | `awaitRun(runId, ...)` | Swift-only | typed waiter |
| — | `recheckPendingRuns()` | Swift-only | reconnect recovery |

> **WorkflowsAPI deep dive:** the file is 858 lines but ~300 are docstrings; the rest is genuine state-machine plumbing. Followup recommendation: extract a `WorkflowApplyOrchestrator` so `WorkflowsAPI` itself is just the wire facade. Not blocking for this PR.

---

## New sub-APIs added in #790

All five fully implemented:

### InvitationsAPI (app-level invitations) — ✅ all closed

App-level invitation flow + deferred-grant browsing for the #466 grant flow. Distinct from the per-document invitation methods on `client.documents.*`.

| JS method | Swift | Status |
|---|---|---|
| `quota()` | `quota()` | ✅ |
| `create(params)` | `create(params:)` | ✅ |
| `list(opts)` | `list(limit:, cursor:)` | ✅ |
| `get(id)` | `get(invitationId:)` | ✅ |
| `delete(id)` | `delete(invitationId:)` | ✅ |
| `accept(token)` | `accept(inviteToken:)` | ✅ |
| `listDeferredGrants(opts)` | `listDeferredGrants(type:, email:, limit:)` | ✅ |
| `revokeDeferredGrant(id, type)` | `revokeDeferredGrant(deferredId:, type:)` | ✅ |

### BlobBucketsAPI — ✅ all closed

App-level blob namespaces (not the same as per-document blobs on `client.document(id).blobs()`).

| JS method | Swift | Status |
|---|---|---|
| `createBucket(...)` | `createBucket(params:)` | ✅ |
| `listBuckets()` | `listBuckets()` | ✅ |
| `getBucket(id)` | `getBucket(bucketIdOrKey:)` | ✅ |
| `deleteBucket(id)` | `deleteBucket(bucketIdOrKey:)` | ✅ |
| `upload(...)` | `upload(bucketIdOrKey:, data:, filename:, contentType:, tags:)` | ✅ — via raw-HTTP closure |
| `list(...)` | `list(bucketIdOrKey:, cursor:, limit:)` | ✅ |
| `getMetadata(...)` | `getMetadata(bucketIdOrKey:, blobId:)` | ✅ |
| `download(...)` | `download(bucketIdOrKey:, blobId:)` | ✅ — returns `Data` via raw-HTTP closure |
| `delete(...)` | `delete(bucketIdOrKey:, blobId:)` | ✅ |
| `signedUrl(...)` | `getSignedUrl(bucketIdOrKey:, blobId:, expiresInSeconds:)` | ✅ |

### CronTriggersAPI — ✅ all closed

| JS method | Swift | Status |
|---|---|---|
| `list()` | `list()` | ✅ |
| `get(id)` | `get(triggerId:)` | ✅ |
| `create(...)` | `create(params:)` | ✅ |
| `update(...)` | `update(triggerId:, params:)` | ✅ |
| `delete(id)` | `delete(triggerId:)` | ✅ |
| `pause(id)` | `pause(triggerId:)` | ✅ |
| `resume(id)` | `resume(triggerId:)` | ✅ |
| `test(...)` | `test(triggerId:)` | ✅ |

### CollectionTypeConfigsAPI / DatabaseTypeConfigsAPI — ✅ all closed

Both 5-method CRUD APIs, fully implemented. See `CollectionTypeConfigsAPI.swift` / `DatabaseTypeConfigsAPI.swift`.

---

## Cross-cutting patterns flagged

These are noted in the per-group reviews and worth tracking even though they're not single-method gaps:

1. **3 different API styles** across the 14 implemented Swift sub-APIs:
   - **Style A** (thin dict facade): most files
   - **Style B** (typed-options + cache-aware): MeAPI, UsersAPI
   - **Style C** (orchestration + state): WorkflowsAPI

   Worth picking one and converging — this is a P3 cleanup, not a blocker.

2. **Pagination** is handled 3 different ways across files. Pick one.

3. **Validation** is inconsistent — some methods validate args before HTTP, some let the server tell them.

4. **`MeAPI.uploadAvatar`** has a `contentType` parameter that's accepted but never used.

These belong in a "v1.1 polish pass" issue.
