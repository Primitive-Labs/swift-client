# Testing

## Overview

The Swift client has **81 integration test files** (~13,200 lines) that run against a live dev server, organized as:

- **Top-level operational tests** (~14 files with content): networking, lifecycle, recovery, etc.
- **`Schema/`** (38 files): the typed-model layer — every test opens with a docstring linking to the js-bao reference path it mirrors
- **`CrossPlatform/`** (8 files): Swift↔JS wire-format parity tests that spawn a Node subprocess for live comparison
- **`Setup/` + `Helpers/`** (3 files): shared fixture setup

There are no mocks per the project's "live APIs only" policy in CLAUDE.md — tests exercise real HTTP, WebSocket, Yjs sync, and SQLite paths against a real dev server.

For test coverage parity vs the JS client, see [`parity/test-coverage.md`](parity/test-coverage.md).

## Two flavors of tests

Not every test needs the dev server. The suite splits into two categories:

| Category | Needs backend? | Where it lives | What it does |
|---|---|---|---|
| **Pure-Swift unit tests** | No | `Tests/SwiftBaoCodegenTests/`, most of `Tests/JsBaoClientTests/Schema/` (e.g. `PrimitiveSchemaTests`, `TomlSchemaLoaderTests`, `PrimitiveValueTests`, `TypedModelTests`, `CodegenAcceptanceTests`, `CodegenGauntletTests`) | Exercise schema parsing, value coding, codegen output, in-memory `YDocument` round-trips. No HTTP, no WebSocket, no SQLite file. The codegen suite — `CodegenAcceptanceTests` + `CodegenGauntletTests` — is documented in detail in [`codegen.md` → Testing](codegen.md#testing). |
| **Backend integration tests** | Yes — dev server + `.env.tests` | The rest of `Tests/JsBaoClientTests/` (everything in the suite table at the bottom of this doc) | Hit the live dev server over HTTP/WS, mint test apps and users via the admin API. |

To run only the no-backend tests (handy in CI or in a fresh worktree where the dev server isn't wired up):

```bash
swift test --filter "SwiftBaoCodegenTests|Schema\."
```

The backend integration tests require the setup below.

> **Note on `swift-testing` output.** Both XCTest and the new `swift-testing` framework run by default. If you only have XCTest tests in scope (which is the case for everything in this repo today), you'll see a trailing `✔ Test run with 0 tests in 0 suites passed` line — that's `swift-testing` reporting it found nothing to do, not a failure.

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

## Top-level test suites

| Suite | Notes |
|-------|-------|
| Core | `JsBaoClientTests.swift` — init, connect, document CRUD, two-client sync |
| Sync | `MergeTests.swift`, `InterleavedTests.swift` — CRDT merge scenarios |
| Concurrent | `ConcurrentWritesTests.swift` — parallel writes from multiple clients |
| Reconnection | `DisconnectReconnectTests.swift` — backoff, session recovery |
| Auth | `OAuthTests.swift`, `RefreshTests.swift`, `SessionTests.swift` |
| Permissions | `DocumentPermissionsTests.swift`, `InvitationTests.swift` |
| Collections | `CollectionsTests.swift` |
| Databases | `DatabaseTests.swift` |
| Blobs | `BlobTests.swift` |
| Workflows | `WorkflowTests.swift`, `WorkflowRecoveryTests.swift` |
| Lifecycle / cleanup | `LifecycleTests.swift`, `AppCleanupTests.swift` |
| Awareness | `AwarenessTests.swift` |
| Y.Text semantics | `YTextSemanticsTests.swift` |
| Per-doc deadlocks | `YDocumentDeadlockTests.swift` — guards against the lock issue that drove the YSwift fork |
| Codegen acceptance | `Schema/CodegenAcceptanceTests.swift` — TaskRecord golden compiles + round-trips through `TypedModel`. See [`codegen.md` → Testing](codegen.md#testing). |
| Codegen gauntlet | `Schema/CodegenGauntletTests.swift` — 35 tests stressing every TOML knob the emitter touches (stringsets, unique constraints, defaults, relationships literal, reserved keyword fields, `init?(row:)` vs `init?(record:)`, codegen-emitted Equatable/Hashable/Codable, free-function helper pattern, `dynamic.update`). See [`codegen.md` → Testing](codegen.md#testing). |

## Schema test directory (38 files)

Lives at `Tests/JsBaoClientTests/Schema/`. Each file exercises one piece of the typed-model layer (`PrimitiveSchema`, `TypedModel`, `DynamicModel`, `IncludeResolver`, `TomlSchemaLoader`, etc.) against `js-bao` parity. Each test docstring points at its js-bao reference. See [`parity/schema-and-models.md`](parity/schema-and-models.md) and [`parity/test-coverage.md`](parity/test-coverage.md) for the full mapping.

## Cross-platform parity tests

Lives at `Tests/JsBaoClientTests/CrossPlatform/`. Spawns Node subprocesses to verify Swift↔JS wire-format equivalence. Required by [`parity/wire-format.md`](parity/wire-format.md).

The harness JS scripts `require("js-bao")` from the repo's `node_modules` — make sure `pnpm install` ran at the project root first, otherwise these tests fail with a `HarnessError` instead of an `XCTSkip`.
