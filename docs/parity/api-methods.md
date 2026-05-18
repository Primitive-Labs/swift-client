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
| `client.session` | ⚠️ | `client.session` (SessionAPI) — **wrong endpoint:** SessionAPI.swift:14 calls `GET /me` instead of `GET /session` |
| `client.users` | ✅ | `client.users` (UsersAPI) |
| `client.groups` | ✅ | `client.groups` (GroupsAPI) |
| `client.groupTypeConfigs` | ✅ | `client.groupTypeConfigs` (GroupTypeConfigsAPI) |
| `client.ruleSets` | ✅ | `client.ruleSets` (RuleSetsAPI) |
| `client.gemini` | ✅ | `client.gemini` (GeminiAPI) |
| `client.llm` | ✅ | `client.llm` (LlmAPI) |
| `client.prompts` | ✅ | `client.prompts` (PromptsAPI) |
| `client.workflows` | ✅ | `client.workflows` (WorkflowsAPI) |
| `client.integrations` | ⚠️ | `client.integrations` (IntegrationsAPI) — **broken contract:** missing structured `IntegrationCallRequest`, response unwrapping, and structured error throwing |
| `client.invitations` | 🔀 | App-level invitations not exposed. Per-document invitations live on `client.documents` (acceptInvitation, declineInvitation, listInvitations, inviteUser, getInvitationByEmail, updateInvitation, deleteInvitation) and `client.me.pendingDocumentInvitations()`. **App-level invite quota / deferred-grant flow is NOT present.** |
| `client.blobBuckets` | ⛔ | App-level blob buckets not exposed. Per-document blobs are on `client.document(id).blobs()` (separate feature — not equivalent). |
| `client.cronTriggers` | ⛔ | Not exposed |
| `client.collectionTypeConfigs` | ⛔ | Not exposed |
| `client.databaseTypeConfigs` | ⛔ | Not exposed |

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
| `client.getDocumentPermission(...)` | — | ⛔ | |
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
| `isOpen(id)` | — | ⛔ | open-state check |
| `requestAccess(id)` | — | ⛔ | |
| `cancelAccessRequest(id)` | — | ⛔ | |
| `listAccessRequests(id)` | — | ⛔ | |
| `approveAccessRequest(id, requestId)` | — | ⛔ | |
| `rejectAccessRequest(id, requestId)` | — | ⛔ | |
| `getPendingCreate(id)` | — | ⛔ | |
| `cancelPendingCreate(id)` | — | ⛔ | |
| `listPendingCreates()` | — | ⛔ | |
| `revokeGroupPermission(...)` | — | ⛔ | |
| `(other group-permission methods)` | — | ⛔ | several |
| `getOwner(id)` | — | ⛔ | |
| `transferOwnership(...)` | — | ⛔ | |

> **~13 methods marked ⛔ here** — flag-and-flip if any are oversights.

## DatabasesAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get(id)` | `get(id:)` | ✅ | |
| `list()` | `list()` | ✅ | |
| `create(params)` | `create(params:)` | ✅ | |
| `update(id, params)` | `update(databaseId:, params:)` | ✅ | |
| `delete(id)` | `delete(databaseId:)` | ✅ | |
| `query(...)` | `query(...)` | ✅ | |
| `executeBatch(...)` | — | ⛔ | |
| `importCsv(...)` | — | ⛔ | |
| `subscribe(id, ...)` | — | ⛔ | server-side subscriptions |
| `getCelContext(...)` | — | ⛔ | CEL-based access control reads |
| `setCelContext(...)` | — | ⛔ | |
| `listManagers(id)` | — | ⛔ | |
| `addManager(...)` | — | ⛔ | |
| `removeManager(...)` | — | ⛔ | |
| `listGroupPermissions(id)` | — | ⛔ | |
| `addGroupPermission(...)` | — | ⛔ | |
| `removeGroupPermission(...)` | — | ⛔ | |

> **~10 methods marked ⛔ here** — flag-and-flip if any are oversights.

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
| `uploadAvatar(data, contentType)` | `uploadAvatar(data:, contentType:)` | ⚠️ | `contentType` param is dead/unused |
| `pendingDocumentInvitations()` | `pendingDocumentInvitations()` | ✅ | |
| `bookmarks.list()` | — | ⛔ | bookmarks sub-API entirely missing (4 methods) |
| `bookmarks.add(...)` | — | ⛔ | |
| `bookmarks.remove(...)` | — | ⛔ | |
| `bookmarks.update(...)` | — | ⛔ | |
| `getProfile()` | — | ⛔ | |

## UsersAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `get(userId)` | `get(userId:)` | ✅ | |
| `getProfiles(userIds)` | — | ⛔ | batch lookup |
| `lookup(email)` | — | ⛔ | |

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
| `get()` | `get()` | ⚠️ | **Calls `GET /me` instead of `GET /session`** — wrong endpoint (SessionAPI.swift:14) |

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
| `execute(id, params)` | `execute(promptId:, ...)` | ⚠️ | Swift uses positional args where JS uses options object |

## IntegrationsAPI

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `call(spec)` | `call(...)` | ⚠️ | **Major contract gap.** Missing: structured `IntegrationCallRequest` (method/path/query/headers/body), response unwrapping into `{status, headers, body, traceId, durationMs, errorCode}`, structured error throwing on non-OK responses. The current Swift surface is much thinner than the JS one. |
| `list()` | — | ⛔ | |
| `get(id)` | — | ⛔ | |

## WorkflowsAPI

The biggest API on both sides. Swift adds features that don't exist in JS (`runAndApply`, `awaitRun`, `recheckPendingRuns`).

| JS method | Swift method | Status | Notes |
|---|---|---|---|
| `start(workflowId, params)` | `start(workflowId:, params:)` | ⚠️ | Swift `StartWorkflowOptions` missing `forceRerun` |
| `getStatus(runId)` | `getStatus(runId:)` | ⚠️ | Swift doesn't normalize CF/DB status codes the way JS does |
| `terminate(runId, opts?)` | `terminate(runId:)` | ⚠️ | Swift drops `contextDocId` |
| `listRuns(opts)` | `listRuns(filters:)` | ⚠️ | Swift `ListWorkflowRunsOptions` missing `forward`, `contextDocId` |
| `listStepRuns(runId)` | — | ⛔ | |
| `(definition CRUD)` | `(definition CRUD)` | ✅ | |
| — | `runAndApply(...)` | Swift-only | apply-after-run fan-out |
| — | `awaitRun(runId, ...)` | Swift-only | typed waiter |
| — | `recheckPendingRuns()` | Swift-only | reconnect recovery |

> **WorkflowsAPI deep dive:** the file is 858 lines but ~300 are docstrings; the rest is genuine state-machine plumbing. Followup recommendation: extract a `WorkflowApplyOrchestrator` so `WorkflowsAPI` itself is just the wire facade. Not blocking for this PR.

---

## Other JS sub-APIs (entirely absent on Swift)

### InvitationsAPI (app-level invitations)

This is the *app-level* invitation flow (invite someone to join the whole app, with optional deferred grants for documents/groups they get when they accept). Distinct from per-document invitations, which are present.

| JS method | Status | Notes |
|---|---|---|
| `quota()` | ⛔ | invitation usage limits |
| `create(params)` | ⛔ | with `DeferredDocumentGrant` / `DeferredGroupGrant` payloads |
| `list(opts)` | ⛔ | |
| `get(id)` | ⛔ | |
| `delete(id)` | ⛔ | |
| `accept(token)` | ⛔ | redeem invite token at signup |
| `listDeferredGrants(opts)` | ⛔ | |

### BlobBucketsAPI

App-level blob namespaces (not the same as per-document blobs, which exist via `client.document(id).blobs()`).

| JS method | Status |
|---|---|
| `createBucket(...)` | ⛔ |
| `listBuckets()` | ⛔ |
| `getBucket(id)` | ⛔ |
| `deleteBucket(id)` | ⛔ |
| `upload(...)` | ⛔ |
| `list(...)` | ⛔ |
| `getMetadata(...)` | ⛔ |
| `download(...)` | ⛔ |
| `delete(...)` | ⛔ |
| `signedUrl(...)` | ⛔ |

### CronTriggersAPI

| JS method | Status |
|---|---|
| `list()` | ⛔ |
| `get(id)` | ⛔ |
| `create(...)` | ⛔ |
| `update(...)` | ⛔ |
| `delete(id)` | ⛔ |
| `pause(id)` | ⛔ |
| `resume(id)` | ⛔ |
| `test(...)` | ⛔ |

### CollectionTypeConfigsAPI / DatabaseTypeConfigsAPI

| JS method | Status |
|---|---|
| `list()` | ⛔ |
| `get(type)` | ⛔ |
| `create(...)` | ⛔ |
| `update(...)` | ⛔ |
| `delete(type)` | ⛔ |

(Both APIs are 5 methods each, identical shape, both fully ⛔.)

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
