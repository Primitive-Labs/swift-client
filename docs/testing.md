# Testing

## Overview

The Swift client has **81 integration test files** (~13,200 lines) that run against a live dev server, organized as:

- **Top-level operational tests** (~14 files with content): networking, lifecycle, recovery, etc.
- **`Schema/`** (38 files): the typed-model layer — every test opens with a docstring linking to the js-bao reference path it mirrors
- **`CrossPlatform/`** (8 files): Swift↔JS wire-format parity tests that spawn a Node subprocess for live comparison
- **`Setup/` + `Helpers/`** (3 files): shared fixture setup

There are no mocks per the project's "live APIs only" policy in CLAUDE.md — tests exercise real HTTP, WebSocket, Yjs sync, and SQLite paths against a real dev server.

For test coverage parity vs the JS client, see the docstrings in `Tests/JsBaoClientTests/CrossPlatform/`.

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

2. **Environment file** (optional) — copy the example:
   ```bash
   cd swift-client
   cp .env.tests.example .env.tests
   ```
   You normally **don't** need a hand-minted JWT: the suite mints its own
   short-lived super-admin token at setup time, signed with `TEST_JWT_SECRET`
   (default `test-jwt-secret-only-for-agents`, matching the dev server's
   `JWT_SECRET` in the repo root `.dev.vars`). The server accepts it because
   `AdminAuthService.validateToken` builds a virtual super-admin from a JWT
   carrying both `adminId` and `email` when no `AdminUser` record exists.

   To override with your own token instead, set `TEST_SUPERADMIN_JWT`. Mint one with:
   ```bash
   node -e "const jwt = require('jsonwebtoken'); console.log(jwt.sign({adminId:'YOUR_ADMIN_ID',email:'you@example.com',name:'Your Name',role:'super-admin',isSuperAdmin:true,appCreationLimit:50,type:'admin',enableTestFeatures:true},'test-jwt-secret-only-for-agents',{expiresIn:'24h'}))"
   ```
   The JWT secret (`test-jwt-secret-only-for-agents`) comes from the dev
   server's `JWT_SECRET`; keep `TEST_JWT_SECRET` in sync with it.

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

## Concurrency gates

Two gate scripts guard the concurrency work (#1910, #1993, #1994). They are not
ordinary test suites: each enforces a *budget* that only moves in one direction.

### `scripts/v6-sendable-gate.sh` — the Swift 6 `Sendable` regression gate

Every target in this package builds in the **Swift 6 language mode**, so strict
concurrency checking is `complete`. The diagnostics the compiler grades as
errors under that mode — the `Sendable` conformance failures the epic's
851-error cascade was made of — now fail `swift build` on their own. #1946
flipped `JsBaoClient` with a per-target setting; #2310 cleared the remaining
targets (`JsBaoClientTests` needed 91 sites; `SwiftBaoCodegen`,
`SwiftBaoCodegenTests` and `E2EMiniApp` were already clean) and moved the mode
to the package-level `swiftLanguageModes: [.v6]` pin, so a target added later
inherits it with no opt-in to remember.

Not every strict-concurrency diagnostic is error-level, though, so "builds
clean" is narrower than "no `Sendable` violations". The flip landed with 11
warning-level `#SendableClosureCaptures` diagnostics still in the target, all
from one site (`Storage/SQLiteStorageProvider.swift`, the `work` parameter of
`onQueue`), behind a green build *and* a green gate — the gate counted `error:`
lines only, so its "0 sites" verdict was a statement about errors. #2318 cleared
the site (the closure now crosses the queue hop in a contained `QueueWork` box,
with no change to the public `StorageProvider` protocol) and closed the blind
spot that hid it: the gate counts warning-level strict-concurrency sites too,
at budget **zero**.

The gate adds four things `swift build` does not:

1. It confirms the mode is still committed — the package pin reads `.v6` and no
   target overrides it back, by a `swiftLanguageMode` setting or a
   `-swift-version` unsafe flag — reading all of that out of `swift package
   dump-package` rather than the source text. Every target is checked, not just
   `JsBaoClient`: the gate's own build is `--target JsBaoClient`, so an override
   on a test target would never be compiled here. A revert to `.v5` would
   compile clean and report zero sites, which is the one failure a build cannot
   catch.
2. It counts warning-level strict-concurrency sites in `Sources/JsBaoClient`,
   which a green build says nothing about. Deliberately wider than the one
   group that produced #2318: a sibling group appearing after a toolchain bump
   is the event this exists to surface. Scoped to the target's own sources, so
   a dependency's warnings cannot fail our build.
3. It attributes both counts per file, so a regression reads at a glance.
4. It fails before the test build starts, with a gate-shaped message.

It also touches the target's sources before building. An incremental build over
an up-to-date module re-emits no warnings, so a warm `.build` would otherwise
hand the warning counter an empty log and read as PASS. (Errors do not have
that problem — a module with errors has no valid output to be up to date.)

`run-tests.sh` invokes it in assertion mode before every full-suite run, with
the error budget in `V6_MAX_SITES`, the warning budget in
`V6_MAX_WARNING_SITES`, and the per-file list in `V6_ZERO_FILES`. All are at
**zero**. Set `SKIP_V6_SENDABLE_GATE=1` to skip it while iterating; never raise
a budget to make a change pass.

```bash
scripts/v6-sendable-gate.sh                                  # measure only
scripts/v6-sendable-gate.sh --max 0 --max-warnings 0 --require-zero Internal/KvCache.swift
```

Before #1946 the target compiled in `.v5` and this script installed `.v6`
itself, by rewriting `Package.swift` into a scratch build and restoring it
afterwards. That is how the epic's per-phase "this file is at zero sites"
claims were checkable at all. The rewrite is gone — the mode it simulated is
now the one the package builds in.

### `scripts/tsan-gate.sh` — the ThreadSanitizer baseline diff

Runs the concurrency suites under ThreadSanitizer. The baseline on `main` is
**not** clean, so this is a baseline-*diff* gate rather than a clean-run gate:
it splits the TSan output into per-race blocks and classifies each as KNOWN
(matching a signature in `BASELINE_RACE_SIGNATURES`) or NEW. Only a NEW race
fails it.

**Shrinking the baseline.** When a change genuinely fixes one of the documented
races, remove its signature — but only under two conditions, both of which the
existing removals follow:

1. **Remove only after a clean run confirms the signature is gone.** Removing an
   entry on the strength of the reasoning alone leaves the gate green whether or
   not the fix worked.
2. **Add the suite that exercises the race to the default filter.** The
   signatures are type- or method-level, so a removed entry only means anything
   if something in the default run actually hammers that code. `EventStreamTests`
   (#1994 Phase E2) and `AnalyticsQueueFlushTimerRaceTests` (#1993 Phase D3)
   were both added for exactly this reason.

Removals so far: the two `EventEmitter` / `EventSubscription` races (#1994
Phase E2) and the `AnalyticsQueue` / `flushTimer` pair (#1993 Phase D3, once the
type became an actor). A race in any of them now **fails** the gate.

```bash
scripts/tsan-gate.sh              # default concurrency-suite filter
scripts/tsan-gate.sh MyTests      # custom XCTest filter
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

Lives at `Tests/JsBaoClientTests/Schema/`. Each file exercises one piece of the typed-model layer (`PrimitiveSchema`, `TypedModel`, `DynamicModel`, `IncludeResolver`, `TomlSchemaLoader`, etc.) against `js-bao` parity. Each test docstring points at its js-bao reference. Each test docstring points at its js-bao reference.

## Cross-platform parity tests

Lives at `Tests/JsBaoClientTests/CrossPlatform/`. Spawns Node subprocesses to verify Swift↔JS wire-format equivalence. 

The harness JS scripts `require("js-bao")` from the repo's `node_modules` — make sure `pnpm install` ran at the project root first, otherwise these tests fail with a `HarnessError` instead of an `XCTSkip`.
