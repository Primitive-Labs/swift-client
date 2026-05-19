# Cross-language E2E parity harness

A pair of mini-app CLIs — one Swift, one JS — driven by JSON over
stdin/stdout, plus an XCTest driver that spawns both as subprocesses
to verify cross-language query parity against a **shared TOML
schema** consumed by **both codegens**.

```
                   schema.toml  ← single source of truth
                  /            \
                 /              \
                ▼                ▼
      swift-bao-codegen      js-bao-codegen-v2
                │                │
                ▼                ▼
        TaskRecord (struct)    TaskRecord (class shell + interface)
                │                │
                ▼                ▼
       TypedModel<TaskRecord>   TaskRecord.query(...) (BaseModel)
                │                │
                └─── E2EQueryParityTests.swift (XCTest driver)
                          │
                          ▼
              spawns both as subprocesses,
              feeds same query, asserts
              byte-equivalent JSON results
```

## What this catches

The existing `CrossPlatform/` harness proves wire-format parity using
**hand-built** schemas + raw Y.Map reads. This harness proves it
end-to-end through the **codegen + runtime** path on both sides:

- `swift-bao-codegen` materializes a `TaskRecord` from `schema.toml`
  at build time (real plugin invocation via the `E2EMiniApp`
  executable target's plugin attachment in `swift-client/Package.swift`).
- `js-bao-codegen-v2` materializes a parallel `TaskRecord` from the
  same `schema.toml` (run by `js/codegen.mjs` once per test process,
  outputs land in `js/generated/`). The barrel auto-registers every
  class with js-bao via `attachAndRegisterModel` as a side effect of
  `import "./generated"`.
- The XCTest spawns both CLIs and asserts identical JSON results from
  identical queries against records the *other* client wrote.

Every `[models.X]` in the TOML carries an explicit
`class_name = "..."` so both codegens emit *the same class name* for
each model — see [`schema.toml`](swift/Models/schema.toml). That
lets `CodegenOutputParityTests` assert structural parity at the
artifact layer too: same set of class names, same field set per
model, same relationship method names.

## Layout

```
E2E/
├── README.md                ← this file
├── swift/
│   ├── Models/schema.toml   ← single source of truth
│   └── main.swift           ← Swift CLI
└── js/
    ├── package.json         ← vite-node-driven; "type": "module"
    ├── vite.config.ts       ← present so vite-node finds a project root
    ├── tsconfig.json
    ├── codegen.mjs          ← runs js-bao-codegen-v2 against schema.toml
    ├── main.ts              ← JS CLI (consumes ./generated)
    └── generated/           ← populated by codegen.mjs (not committed)
        ├── schema.toml      ← copy of ../swift/Models/schema.toml
        ├── *.generated.ts   ← one per [models.X]
        └── index.ts         ← barrel; auto-registers all classes
```

The Swift CLI is the `E2EMiniApp` executable target in
`swift-client/Package.swift`. The codegen plugin attached to that
target runs `swift-bao-codegen` on `Models/schema.toml`. The JS CLI
is run via **`vite-node`** (not plain `node`) because the v2-emitted
barrel uses Vite's `?raw` import to inline `schema.toml`. Running
under vite-node exercises the same import path real Primitive apps
use (`sample-app`, `test-app`).

## Running

### XCTest driver (the test of record)

```sh
cd swift-client
swift build --target E2EMiniApp        # build the Swift CLI first
swift build --target SwiftBaoCodegen   # for the codegen-output parity test
swift test --filter "E2EQueryParityTests"
swift test --filter "CodegenOutputParityTests"
```

`E2EQueryParityTests` runs `js-bao-codegen-v2` once per test process
(see `codegenOnce` in the test file), so the JS subprocess always
sees a fresh barrel against the current TOML. No manual `pnpm run
codegen` step is needed — but if you want to re-run it by hand:

```sh
cd swift-client/Tests/JsBaoClientTests/CrossPlatform/E2E/js
node ./codegen.mjs
```

### Manual: drive each CLI by hand

```sh
# Swift side:
echo '{"cmd":"seed","records":[{"id":"t1","title":"x","priority":5,
                                  "completed":false,"tags":["urgent"]}]}' \
  | swift run E2EMiniApp

# JS side (from the js/ dir):
node ./codegen.mjs   # one-time, produces ./generated/
echo '{"cmd":"seed","records":[{"id":"t1","title":"x","priority":5,
                                  "completed":false,"tags":["urgent"]}]}' \
  | node ../../../../../../../node_modules/vite-node/vite-node.mjs main.ts
```

Output is one JSON line — pipe it back into a `query` command via
shell substitution.

## Wire protocol

Both CLIs accept JSON commands on stdin (one per line) and emit JSON
results on stdout (one per command, last line is always the JSON).

Every command supports two optional knobs:

- **`mode`** — `"typed"` (default) or `"dynamic"`. Typed routes through
  `TypedModel<TaskRecord>` (codegen); dynamic routes through
  `DynamicModel(doc:, schema:)` with stringly access via
  `PrimitiveRecord`. Lets one test exercise *both* Swift paths from
  the same fixture.
- **`model`** — `"tasks"` (default) or `"everything"`. The
  comprehensive fixture model lives under `everything` and only
  has dynamic-mode access on Swift (no codegen wrapper).

### Commands

```jsonc
// seed: write records, return Y.Doc update bytes
//   doc:   optional. If provided, NEW records are appended to the
//          existing doc state — lets a test build a doc up across
//          multiple subprocess invocations (Swift seeds A → JS
//          adds B → both query both).
{"cmd":"seed", "records":[{...}], "doc":"<base64?>",
                "mode":"typed|dynamic", "model":"tasks|everything"}
// → {"doc":"<base64 update bytes>"}

// query: load doc, run query, return rows
{"cmd":"query", "doc":"<base64>",
                 "filter":{"priority":{"$gte":3}},
                 "sort":[{"field":"priority","dir":-1}],
                 "limit":10,
                 "mode":"typed|dynamic", "model":"tasks|everything"}
// → {"results":[{...}]}

// find: load doc, find one record by id
{"cmd":"find", "doc":"<base64>", "id":"a",
                "mode":"typed|dynamic", "model":"tasks|everything"}
// → {"record":{...}|null}

// inspect: dump the raw value at every declared field of the
// record's nested Y.Map. Cross-language byte-equality assertions
// run against this output. Stringsets normalize to sorted member
// arrays; scalars are JSON-decoded so Swift's FFI envelope
// (`"\"hello\""`) and JS's auto-decoded value (`"hello"`) emit
// identical native shapes.
{"cmd":"inspect", "doc":"<base64>", "id":"a", "model":"everything"}
// → {"fields":{"label":"...", "intSmall":42, "tags":["a","b"], ...}}

// resolveRelationship: walk a relationship from the source record;
// returns the resolved target(s) as a JSON array.
{"cmd":"resolveRelationship", "doc":"<base64>", "id":"u1",
                                "relationship":"posts", "model":"users"}
// → {"results":[{"id":"p1", ...}]}
```

### Result shape (normalized for cross-language equality)

- Stringsets → sorted arrays
- Optional fields → omitted when nil
- Integer-valued doubles → plain `Int` (matches js-bao's Number behavior)
- Strings → decoded (no JSON envelope)
- JSON object keys aren't ordered — tests use `canonicalize(record)`
  to sort keys before string-comparing.

## Test coverage breakdown

`E2EQueryParityTests.swift` — 29 tests, ~6s end-to-end:

| Group | What it covers |
|---|---|
| Self round-trip (×2) | Each side writes and reads back its own data — sanity |
| Cross-language scalar query (×6) | Swift writes / JS reads + JS writes / Swift reads, per `$eq`/`$gte`/`$contains` |
| Sort + limit parity (×2) | Multi-field sort and limit-only pagination agree |
| Field-by-field byte equivalence (×1) | Every record JSON-equivalent across the boundary |
| Swift typed ↔ Swift dynamic (×2) | Codegen path matches runtime path on Swift |
| Comprehensive everything model (×4) | Chinese/emoji/multiple ISO date formats/integer boundaries/IEEE-754 float precision |
| Wire-byte inspect (×1) | Per-field raw Y.Map values byte-equivalent across clients |
| Shared-doc / merge semantics (×2) | Swift seeds → JS adds → both see both records, both directions |
| Cursor pagination (×1) | Walk every page on each side, assert the row sequences match |
| Relationship resolution (×7) | refersTo / hasMany ordered / hasManyThrough cross-language |
| `_KNOWN_DIVERGENCE` (×2) | Stringset wire format mismatch (issue #561) |

`CodegenOutputParityTests.swift` — 1 test, fast:

| What | What it covers |
|---|---|
| Codegen artifact parity | Runs both codegens against the shared schema.toml; asserts class-name parity, field-set parity, and relationship-name parity per model. Attaches both languages' generated files via `XCTAttachment` so reviewers can read them side by side in the Xcode test report. |

## Known divergences

The harness surfaces real cross-language interop issues. The JS CLI
ships a deliberate workaround for the stringset read path
(`readStringsetRaw` in `main.ts`) so the suite stays green end-to-
end, but the underlying mismatch in *write* format is still real
and tracked separately.

### Stringset wire format differs (issue #561)

**Swift** writes stringsets as a *nested Y.Map* whose keys are the
set members. Concurrent additions from different clients merge
correctly under CRDT semantics — the right primitive for an
unordered set.

**js-bao** writes stringsets as a plain Y.Object value
(`{member: true, …}`). This is a leaf-valued object: `inst.tags.add(x)`
ends up doing a *replace* of the whole object on the parent map,
so two clients adding members concurrently lose data
(last-writer-wins). Wrong primitive for set semantics under
concurrent edit.

Reading docs the *other* client wrote via
`record["tags"]?.asStringSet` (Swift) on a JS-written doc yields
empty. The JS CLI works around the read direction by going to the
raw Y.Map / Y.Object; the Swift side has no analogous workaround
in production code today.

The fix lives upstream in js-bao: adopt Swift's nested-Y.Map shape
on write, with a read-side fallback for legacy Y.Object docs.
Tracked as [issue #561](https://github.com/Primitive-Labs/js-bao-wss/issues/561).

Switching the JS side to `js-bao-codegen-v2` doesn't fix this — the
generated class is just a shell over `BaseModelImpl`, and the bug
lives in the BaseModel runtime's stringset write path.

### Pagination

Both clients support cursor-based pagination natively (Swift's
`QueryOptions.cursor` + `direction`, js-bao's `uniqueStartKey` +
`direction`). The cross-language pagination test
(`testCursorPaginationAgreesAcrossLanguages`) walks every page on
each side and asserts the row sequences match.

Swift's `QueryOptions.offset` field is **deprecated** as of this
PR — offset-based pagination is unstable under concurrent inserts
in CRDT-backed datasets (rows can shift between page reads,
producing duplicates or skipped records). js-bao deliberately never
exposed offset for the same reason. Use cursor pagination instead.

## What does cross-language testing actually verify?

The harness asserts **observable equivalence**, not implementation
equality. For every test, the question is: *given the same TOML and
the same logical query against the same Y.Doc, do both clients
produce the same JSON output?*

Anywhere they don't is a real cross-client interop bug. The two
divergences above are the ones the harness has surfaced so far;
future schema additions or runtime changes that drift will be
caught the same way.

The **comprehensive `everything` model** in particular pins:

- Unicode survival (Chinese, emoji including ZWJ sequences and flag
  emoji) — both clients emit identical decoded strings
- Integer boundaries up to `Number.MAX_SAFE_INTEGER` — both preserve
  exactness through round-trip
- Float precision (`0.1 + 0.2 = 0.30000000000000004`) — both preserve
  the IEEE-754 bit pattern
- ISO date variants (`Z`, `+09:00`, `.123Z`) — strings round-trip raw
  on both sides
- Embedded quotes + newlines in strings — JSON-escape survives both
  encoders

## Adding a new query operator

1. Add a record + filter to `Self.fixtureRecords` in the test file
   that exercises the operator.
2. Write a `testSwiftWrites_JsQueriesByX` and a
   `testJsWrites_SwiftQueriesByX` pair.
3. Run; if both pass you've added cross-language coverage. If one
   fails, you've found a divergence — pin it as a `_KNOWN_DIVERGENCE`
   test like the existing two so the harness keeps flagging it
   without going red on every CI run.

## Adding a new model

1. Add a `[models.<name>]` block to `swift/Models/schema.toml` with an
   explicit `class_name = "..."`. The cross-language identity matters:
   both codegens consume `class_name` directly, so emitting
   identical names from the same TOML is what makes
   `CodegenOutputParityTests` meaningful.
2. Update `expectedModels`, `expectedFields`, and
   `expectedRelationships` in `CodegenOutputParityTests.swift`.
3. Re-run `swift build --target E2EMiniApp` (the SwiftPM plugin will
   regenerate Swift) and `node js/codegen.mjs` (or just re-run the
   tests; the harness re-runs codegen automatically once per process).
4. Reference the new class in the Swift mini-app (`swift/main.swift`)
   if it needs typed-mode access — dynamic-mode access doesn't
   require code changes.

## Why subprocess (vs in-process)

js-bao runs in Node; the Swift test runs in xctest. Subprocess
communication via stdin/stdout keeps the runtimes isolated and
prevents Yjs version skew between Swift's yswift-fork and js-bao's
yjs npm package from contaminating the test. The cost is ~150ms per
subprocess startup (slightly higher under vite-node — ~300ms — for
the transform warmup); the test suite still runs in ~5s end-to-end.

## Why `read-rebuild` better-sqlite3

The CrossPlatformHarness picks the first available Node from
`/usr/local/bin/node`, `/opt/homebrew/bin/node`, then `which node`.
If you have multiple Node versions installed (common on macOS), the
better-sqlite3 native binding may need a rebuild to match the Node
the test driver picks:

```sh
PATH="/usr/local/bin:$PATH" pnpm rebuild better-sqlite3
```

The `node-sqlite` engine is what js-bao uses for its in-memory query
mirror; it's required for `Tasks.query()` and `Tasks.find()` calls.
