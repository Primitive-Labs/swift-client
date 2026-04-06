# Testing

## Overview

The Swift client has **35+ integration test files** (~5,400 lines) that run against a live dev server. There are no mocks — tests exercise real HTTP, WebSocket, and Yjs sync paths.

## Prerequisites

1. **Dev server running on HTTP** — the Swift client's `URLSession` does not trust self-signed certs, so run the dev server without `LOCAL_HTTPS`:
   ```bash
   # From the project root
   node debug-server.js
   ```

2. **Environment file** — copy the example and fill in your JWT:
   ```bash
   cd swift-client
   cp .env.tests.example .env.tests
   ```
   Edit `.env.tests` and set `TEST_SUPERADMIN_JWT` to a local super-admin token. To mint one:
   ```bash
   node -e "const jwt = require('jsonwebtoken'); console.log(jwt.sign({adminId:'YOUR_ADMIN_ID',email:'you@example.com',name:'Your Name',role:'super-admin',isSuperAdmin:true,appCreationLimit:50,type:'admin',enableTestFeatures:true},'test-jwt-secret-only-for-tests',{expiresIn:'24h'}))"
   ```
   The JWT secret (`test-jwt-secret-only-for-tests`) and your `adminId` come from `wrangler.toml` and DynamoDB respectively.

## Running Tests

Use the wrapper script which loads `.env.tests` automatically:

```bash
cd swift-client

# All tests
./run-tests.sh

# A specific test class
./run-tests.sh AvailabilityTests

# A specific test method
./run-tests.sh JsBaoClientTests.SyncTests/testTwoClientSync
```

Or pass env vars manually:

```bash
TEST_HTTP_URL=http://localhost:8787 \
TEST_WS_URL=ws://localhost:8787 \
TEST_SUPERADMIN_JWT="your-jwt" \
swift test
```

## Test Infrastructure

### `TestContext`

Most tests use a shared `TestContext` that:

- Creates a temporary app via the admin API
- Creates test users with JWTs
- Provides pre-configured `JsBaoClient` instances
- Cleans up after the test

### `TestConfig`

Reads server URL and admin JWT from environment variables. Defaults to `http://localhost:8787`.

## Test Suites

| Suite | File | What it covers |
|-------|------|----------------|
| Core | `JsBaoClientTests.swift` | Init, connect, document CRUD, two-client sync |
| Sync | `MergeTests.swift`, `InterleavedTests.swift` | CRDT merge scenarios, interleaved writes |
| Concurrent | `ConcurrentWritesTests.swift` | Parallel writes from multiple clients |
| Large updates | `LargeUpdateTests.swift` | Bulk data sync |
| Offline | `OfflineTests.swift`, `OfflineFirstTests.swift` | Offline workflows, pending creates, local-only docs |
| Persistence | `PersistenceTests.swift`, `StorageProviderTests.swift` | SQLite storage, metadata restoration |
| Reconnection | `DisconnectReconnectTests.swift` | Backoff, session recovery, state after reconnect |
| Auth | `OAuthTests.swift`, `RefreshTests.swift`, `SessionTests.swift` | OAuth, token refresh, session info |
| Permissions | `DocumentPermissionsTests.swift`, `InvitationTests.swift`, `InviteOnlyTests.swift` | Sharing, access control, invitations |
| Collections | `CollectionsTests.swift` | Collection CRUD, queries, aggregations |
| Databases | `DatabaseTests.swift` | Database CRUD and permissions |
| Blobs | `BlobTests.swift` | Upload, download, queue management |
| Awareness | `AwarenessTests.swift` | Presence state sync between clients |
| Events | `EventTests.swift` | Event emission and subscriptions |
| Analytics | `AnalyticsTests.swift` | Event persistence and flushing |
| Lifecycle | `LifecycleTests.swift` | Client destroy, resource cleanup |
| Groups | `GroupsTests.swift` | Group management and memberships |
| LLM | `LlmTests.swift` | LLM API integration |
| Workflows | `WorkflowTests.swift` | Workflow start/status |
| Freshness | `FreshnessTests.swift` | Cache freshness and staleness |
| Users | `UserTests.swift` | User profile operations |
| Root docs | `RootDocTests.swift` | Root document access |
| Metadata WS | `DocMetadataWSTests.swift` | Document metadata over WebSocket |
| Invitations WS | `InvitationWSTests.swift` | Invitation events over WebSocket |
| App cleanup | `AppCleanupTests.swift` | App teardown and resource cleanup |
| Availability | `AvailabilityTests.swift` | Document availability checks |
