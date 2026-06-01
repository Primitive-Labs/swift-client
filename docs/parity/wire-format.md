# Wire-format parity

The most important parity surface — and the one that bites silently when it diverges. If Swift and JS write the same logical record into a Y.Doc differently, then a record written by one client and read by the other won't query equivalently. The 9-agent review of PR #349 surfaced these:

## What's verified parity ✅

These are byte-equivalent across the language boundary, confirmed by either the cross-platform parity tests in `Tests/JsBaoClientTests/CrossPlatform/` or by direct code inspection.

| Layer | Verified shape |
|---|---|
| Y.Doc CRDT updates | Same wire bytes — both clients delegate to `yrs::Update::decode_v1` / `encode_v1` (Swift via the YSwift fork's FFI; JS via `yjs` npm). |
| `OffsetKind::Utf16` | Both use UTF-16 offsets (browser-compatible). Swift hardcodes this; JS uses it natively via `yjs`. |
| Cursor pagination format | Same `{values, sortFields, direction}` JSON shape, same base64 transport. A cursor produced by either side decodes on the other. (Verified in `testCursorPaginationAgreesAcrossLanguages`.) |
| Sort + tiebreaker | Default `id ASC`, implicit `id` appended unless caller supplies it; lexicographic multi-field WHERE for cursor pagination. (Verified against js-bao `CursorManager`.) |
| Error code strings | All 19 `JsBaoErrorCode` cases match exactly. See [errors.md](errors.md). |
| `_meta_*` synthesis | The schema metadata js-bao writes alongside records (`_meta_<modelname>` map entries) is emitted by Swift in the same shape. Swift's `NSMapTable`-with-weak-keys cache is even more careful than js-bao's `WeakMap` (handles `ObjectIdentifier` re-issue). |
| Single-record CRUD round-trip | Swift writes → JS reads → Swift reads (and vice-versa) for scalar fields: string, number, boolean, date. |

## What diverges ⚠️ — fix before declaring v1 wire-stable

### 1. Stringset member values (P1)

| | js-bao | Swift |
|---|---|---|
| Wire shape | nested Y.Map keyed by member, value `true` | nested Y.Map keyed by member, value JSON-encoded member name |
| Read tolerance | reads either shape | reads either shape |
| Write parity | Same data, different bytes |

**Source:** `Sources/JsBaoClient/Schema/DynamicModel.swift:1218`. One-line fix: change the value-side encoding to boolean `true` to match js-bao.

**Why this matters:** even though both clients can *read* either shape, byte-equality assertions in cross-platform tests fail, and any downstream tooling that does raw Y.Doc inspection sees different content for "the same" record.

### 2. `$ne` and `$nin` NULL handling (P1) — ✅ closed in [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)

Result sets now agree with js-bao: `$ne`/`$nin` exclude NULL rows. Regression coverage at `WireFormatGapFixesTests.test_A_*` / `test_B_*`.

### 3. Substring operators on non-strings (P1) — ✅ closed in [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)

Result sets agree:
- `BaoModelQueryEngine` now tracks per-model scalar string fields (`stringFieldsByModel`); substring ops on a non-string field emit `0` (no match) instead of `1=1` (every row).
- `prepareSubstringQuery` trims whitespace and caps inputs at 1024 chars before building the LIKE pattern, matching js-bao's `browser.ts`.

Error semantics still differ: Swift's `dynamic.query` is non-throwing, so bad input → "no match"; js-bao throws. Lifting to throws is a v1.1 follow-up tied to making `dynamic.query` throws-aware. Regression coverage at `WireFormatGapFixesTests.test_C_*` through `test_G_*`.

### 4. TOML loader strict mode (P1) — ✅ closed in [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)

`TomlSchemaLoader.load(tomlString:strict:)` is strict-by-default. Allowlists for model / field / relationship / unique-constraint tables ported from js-bao's `tomlLoader.ts`. `strict: false` is available for callers loading legacy/third-party TOML. Regression at `WireFormatGapFixesTests.test_H_*`.

### 5. TOML loader required-field divergences (P2) — ✅ closed in [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)

`hasMany.related_id_field`, `hasManyThrough.join_model_local_field`, and `hasManyThrough.join_model_related_field` are all required at parse time. Regression at `WireFormatGapFixesTests.test_I_*` / `test_J_*`.

### 6. Stringset write semantics (P2 — architectural)

| | js-bao | Swift |
|---|---|---|
| Add member | nested Y.Map `set(member, true)` | overwrite entire nested Y.Map |
| Concurrent writes | union (CRDT-merge) | last-writer-wins (overwrite race) |

**Architectural fix needed:** Swift `DynamicModel` needs `addMember(_:)` / `removeMember(_:)` APIs that do per-member writes instead of full-replace. Without this, two offline Swift clients adding members to the same set will lose each other's adds when they reconnect.

### 7. Number encoding for large magnitudes (P3)

| | js-bao | Swift |
|---|---|---|
| `Number.toString()` for `1e20` | `"100000000000000000000"` (full digits via `JSON.stringify`) | `"1e+20"` (scientific notation via `String(Double)`) |

Both parse to the same `lib0::Any::Number` value. Byte snapshots differ. Affects nothing semantically but breaks byte-equality tests.

### 8. Single-doc `_meta_doc_id` (P3, SQLite-only)

| | js-bao | Swift |
|---|---|---|
| Default value | `"__legacy_default__"` | `""` (empty string) |

Doesn't affect Y.Doc CRDT — only the SQLite mirror's `_meta_doc_id` column. SQLite-only, internal, but worth aligning.

### 9. `StorageRecord` field divergence (P1) — ✅ closed in [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)

- `updatedAtMs: Double?` added to `StorageRecord<T>` (matches js-bao's epoch-ms shape used by `KvCache.refreshIfOlderThanMs`). Coexists with the legacy `updatedAt: String?` for back-compat.
- Custom `init(from:)` tolerates non-string `metadata` values: scalars stringified (`42 → "42"`), nested objects/arrays preserved as JSON text. Public type stays `[String: String]?` so Swift writers don't change.

Regression at `WireFormatGapFixesTests.test_K_*` / `test_L_*`.

### 10. Event names — see [events.md](events.md)

16 places where event-name parity diverges. Not a Y.Doc wire-format issue per se, but it's the same class of contract mismatch — both clients have to agree on the strings.

## Summary table

| # | Issue | Severity | Status |
|---|---|---|---|
| 1 | Stringset member value (boolean vs JSON-encoded string) | P1 | ⚠️ open |
| 2 | `$ne` / `$nin` NULL handling | P1 | ✅ closed ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| 3 | Substring operators on non-strings | P1 | ✅ closed ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) — result sets agree; throw-vs-no-match still differs |
| 4 | TOML loader strict mode | P1 | ✅ closed ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| 5 | TOML loader required-field validation | P2 | ✅ closed ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| 6 | Stringset write semantics (full-replace) | P2 (arch) | ⚠️ open |
| 7 | Number encoding for large magnitudes | P3 | ⚠️ open |
| 8 | `_meta_doc_id` default | P3 | ⚠️ open |
| 9 | `StorageRecord` field divergence | P1 | ✅ closed ([#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789)) |
| 10 | Event names | P1 | ⚠️ open (see events.md) |

Six of ten gaps closed in the [#789](https://github.com/Primitive-Labs/js-bao-wss/pull/789) wire-format alignment pass. Stringset member-value encoding (#1) and write semantics (#6) are architectural and tracked separately; events (#10) gets its own follow-up; number-encoding (#7) and `_meta_doc_id` (#8) are byte-equality-only nits.

## Notes for maintainers

When you add or change anything in:
- `Sources/JsBaoClient/Schema/DynamicModel.swift` (especially how fields are written)
- `Sources/JsBaoClient/Schema/PrimitiveValue.swift` (encoding/decoding)
- `Sources/JsBaoClient/Schema/TomlSchemaLoader.swift` (validation)
- `Sources/JsBaoClient/Query/QueryTranslator.swift` (operator translation)

…ask "does the JS side write the same bytes here?" If yes, write a cross-platform parity test. If no, flag it in this doc.
