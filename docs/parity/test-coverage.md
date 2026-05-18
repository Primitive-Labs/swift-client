# Test coverage parity

`Tests/JsBaoClientTests/` has **86 test files** in the PR. Of those:

- 23 are pure renames (no content)
- ~53 have substantive content
- The 38-file `Schema/` directory is **uniformly high quality** — each test opens with a docstring linking to the js-bao reference path it mirrors

## Top-level structure

```
Tests/JsBaoClientTests/
├── Setup/
│   ├── TestContext.swift (413 lines)   ← every test depends on this
│   └── TestConfig.swift (43 lines)
├── Helpers/
│   └── TestHelper.swift
├── CrossPlatform/                       ← Swift↔JS wire-format parity
│   ├── CrossPlatformRoundTripTests.swift (386)
│   ├── CrossPlatformTomlSchemaParityTests.swift (243)
│   ├── CrossPlatformHarness.swift (204)
│   ├── E2EQueryParityTests.swift           (extended in stack PR #509/#651)
│   └── harness/{reader,writer,schema-loader}.cjs + fixtures
├── Schema/                              ← 38 deep schema tests
└── <top-level operational tests>
```

## TestContext.swift — what every test depends on

| Concern | Behavior |
|---|---|
| Setup | Each test gets a **fresh app** via admin API |
| Auth | JWTs minted via `mint-test-jwt`. `forgeRefreshJwt` (used only by `RefreshTests`) signs JWTs locally with a hard-coded fallback secret — fine for dev, ideally replaced by a server endpoint later |
| Cleanup | Idempotent, but **swallows DELETE failures silently** |
| Process-global state | `HTTPCookieStorage.shared` + `SchemaSync.clearCache()` (called 199 times across the suite) |
| Parallelism | Suite is **quietly dependent on serial execution** because of process-global state |

Worth tightening, but the contract works for the current suite.

## Schema tests (38 files) — the strong half ✅

Uniformly high quality. Each test:
- Opens with a docstring linking to its js-bao reference path
- Has a contract bullet list
- Asserts load-bearing properties (not just "didn't crash")

The deepest:

| Swift test file | Lines | What it pins | js-bao counterpart |
|---|---|---|---|
| `IncludeResolverTests.swift` | 557 | batch lookups for `Include`s, no N+1 | `relationshipManager.test.ts` |
| `TomlSchemaLoaderTests.swift` | 490 | parse errors, validation | `tomlLoader.test.ts` |
| `SchemaSyncTests.swift` | 444 | `_meta_*` synthesis | `metaSync.test.ts` |
| `CursorPaginationTests.swift` | 359 | cursor format + walking | js-bao query tests |
| `MultiDocModelTests.swift` | 317 | cross-doc indexing | `BaseModel.dbInstance` tests |
| `UpsertTests.swift` | 311 | upsert semantics | upsert tests |
| `SchemaDiscoveryTests.swift` | 276 | runtime schema discovery | discovery tests |
| `UniqueConstraintEnforcementTests.swift` | 267 | compound unique | compound-unique tests |
| `SchemaAcceptanceTests.swift` | 257 | end-to-end schema | acceptance tests |
| `UniqueConstraintReconciliationTests.swift` | 252 | unique reconciliation | reconciliation tests |

Status: ✅ — assertions are real, contracts are pinned, no XCTSkip traps in this directory.

## CrossPlatform tests — wire-format parity ✅ (concept), ⚠️ (env)

These spawn Node subprocesses to verify Swift↔JS wire-format equivalence. Conceptually excellent; one operational concern:

| Test | What it checks | Status |
|---|---|---|
| `CrossPlatformRoundTripTests` | scalar field round-trip via `reader.cjs` / `writer.cjs` | ✅ |
| `CrossPlatformTomlSchemaParityTests` | both loaders accept the same TOML | ✅ |
| `E2EQueryParityTests` (in stack PR #651) | full end-to-end query parity through codegen | ✅ |

⚠️ **Operational gotcha**: harness scripts `require("js-bao")` from `node_modules` but don't pre-check for it. In CI without `pnpm install` first, the test reports a `HarnessError` instead of cleanly skipping.

## Operational tests — mixed quality

The integration-style tests at the top level. Quality split:

### ✅ Strong

| File | Lines | Notes |
|---|---|---|
| `WorkflowRecoveryTests.swift` | 315 | 4 distinct recovery paths, real assertions on each |
| `RefreshTests.swift` | 213 | iOS-specific cold-start regression test (`testColdStartRestoresViaRefreshCookie` is a meaty regression for a real bug) |
| `ConcurrentWritesTests.swift` | 194 | 2 well-asserted CRDT-convergence tests |
| `BaoModelDirtyFlagTests.swift` | 237 | tracks dirty-flag invariant |

### ⚠️ Mixed

| File | Notes |
|---|---|
| `DisconnectReconnectTests.swift` (416 lines) | Mostly real, but two soft spots: line 200 has a commented-out load-bearing `XCTAssertFalse(client.isSynced(docId))` replaced with `_ = client.isSynced(docId) // Just verify it doesn't crash`. And `SKIP_testDocumentsRemainOpenAfterDisconnect` uses a name prefix instead of `XCTSkip` — XCTest doesn't see it as a test, so when the underlying YSwift FFI use-after-free is fixed nobody will know to flip it back on. |
| `WorkflowTests.swift` | tests "pass on either 200 or 404" — that's not really an assertion |
| `RootDocTests.swift` | same "200 or 404" pattern in places |

### ❌ Zero-assertion (P1 cleanup)

| File | Notes |
|---|---|
| `AnalyticsTests.swift` | 0 assertions across 9 tests. Every test ends with "No crash = success". JS counterpart has 18 detailed tests using DI to assert payload structure. **Either expose internals or delete.** |
| `InvitationWSTests.swift` | 0 assertions. Sets `var invitationReceived = false`, never asserts on it. Comment says "may or may not be received depending on server config" — that's not a test. |

## Coverage parity vs JS client tests

JS client tests live in `tests/client/`. This is a sample mapping (not exhaustive — the full enumeration would be its own document):

| JS test area | Swift counterpart | Coverage |
|---|---|---|
| `tests/client/auth/*` | `RefreshTests.swift`, `OAuthTests.swift` (empty) | ⚠️ partial — JS has 11 disconnect-reconnect scenarios; Swift covers 5–6 plus adds awareness/status-event scenarios JS doesn't have |
| `tests/client/analytics-*` | `AnalyticsTests.swift` (zero-assertion) | ❌ — JS has 18 detailed tests via DI; Swift has 9 "no crash" tests |
| `tests/client/database-*` | `DatabaseTests.swift` | ⚠️ — Swift covers basics; JS has CEL-context, managers, executeBatch tests with no Swift equivalent |
| `tests/client/document-*` | `DocumentPermissionsTests.swift`, `DocumentManagerTests` | ⚠️ |
| `tests/client/workflow-*` | `WorkflowTests.swift`, `WorkflowRecoveryTests.swift` | ✅ Swift coverage is solid |
| `tests/client/cursor-pagination-*` | `Schema/CursorPaginationTests.swift` | ✅ |
| `tests/client/state-vector-*` | — | ⛔ no Swift equivalent |
| `tests/client/unified-removal-*` | — | ⛔ |
| `tests/client/user-switch-*` | — | ⛔ |
| `tests/client/document-perf-*` | — | ⛔ |
| `tests/client/passkey-*` | — | ⛔ (passkey suite intentionally out — see exclusions-v1.md) |

**Coverage gaps to file as followup issues** (not blocking):

1. Analytics — replace zero-assertion tests with real DI-style assertions
2. Database — add CEL-context, executeBatch, importCsv tests once those APIs land
3. Disconnect-reconnect — port the 5–6 missing scenarios from JS

## CLAUDE.md compliance

**Zero mocks** found in test files. The only `mock` keyword hit is a comment in `OAuthTests.swift` explaining why JS-side mocks don't translate. The "live APIs only" rule from CLAUDE.md is honored. ✅

## XCTSkip audit

| Total occurrences | 6 |
| Documented (Node missing, fixture missing, env var unset) | 5 |
| Anti-pattern (name-prefix `SKIP_*` instead of `XCTSkip`) | 1 (`SKIP_testDocumentsRemainOpenAfterDisconnect`) |

The name-prefix anti-pattern is a P1 cleanup — XCTest can't see those tests, so when the underlying bug is fixed, nobody will know to re-enable them.

## Summary

| Category | Status |
|---|---|
| TestContext setup | ✅ solid |
| Schema tests (38 files) | ✅ uniformly excellent |
| Cross-platform parity tests | ✅ conceptually + ⚠️ env friction |
| Operational tests | mixed (3 strong, 3 soft, 2 zero-assertion) |
| Coverage parity vs JS | ⚠️ ~70% — gaps in analytics, database operational, disconnect-reconnect |
| Mocks compliance | ✅ zero |
| XCTSkip hygiene | ⚠️ one anti-pattern |

## Notes for maintainers

When adding tests:
- Open with a docstring linking to the js-bao reference path being mirrored. The Schema/ tests do this consistently — match that pattern.
- Use `XCTSkip("reason")`, never the `SKIP_test*` name-prefix workaround.
- Cross-platform parity tests go in `Tests/JsBaoClientTests/CrossPlatform/E2E*` — they spawn Node and compare wire format.
- Tests with no assertions other than "didn't crash" are not tests. Either assert a real invariant or expose internals via DI.
