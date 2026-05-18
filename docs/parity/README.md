# Parity with the JS client

This directory is the canonical reference for "what's in v1 of the Swift client, what's intentionally out, and where the two clients differ subtly." If you're trying to figure out whether a JS feature exists on Swift, start here.

## How to read these tables

Every parity table uses the same status legend:

| Symbol | Meaning |
|---|---|
| ✅ | **Parity.** Same shape, same semantics. A caller migrating between clients won't see a difference. |
| 🔀 | **Different shape, same capability.** The feature exists but is reached through a different namespace, name, or call signature. (Example: JS `client.invitations.list()` vs Swift `client.documents.listInvitations(...)`.) |
| ⚠️ | **Same shape, different semantics.** Subtle. Same call signature, different result. These are the dangerous parity gaps because they look fine until they bite. (Example: `$ne` operator NULL handling.) |
| ⛔ | **Out for v1.** The feature doesn't exist on Swift and that's the current intention. Mostly things that don't make sense on Apple platforms (e.g. `webauthn-large-blob` browser internals) or that aren't on the v1 roadmap. |
| ❌ | **Missing — oversight.** Should be present but isn't. Action items, not deliberate choices. |

The default for unknowns is ⛔. Anything that should actually be ❌ gets flipped during review.

## What lives where

| File | Scope |
|---|---|
| [api-methods.md](api-methods.md) | The big one. Every JS sub-API method, Swift counterpart (or lack of one), with status. |
| [schema-and-models.md](schema-and-models.md) | Field types, validation, relationships, the typed-model layer (`PrimitiveModel`/`TypedModel`/`DynamicModel` ↔ js-bao `BaseModel`). |
| [query-engine.md](query-engine.md) | Filter operators, sort, cursor pagination, projections. |
| [wire-format.md](wire-format.md) | Byte-level invariants — what survives a Swift→JS or JS→Swift round trip, and where the formats diverge. |
| [events.md](events.md) | Event-name table. Strings must match across languages for cross-platform code to subscribe consistently. |
| [errors.md](errors.md) | Error-code taxonomy. |
| [test-coverage.md](test-coverage.md) | Swift test files mapped to their JS equivalents. |

## What's NOT here

- **Internal implementation differences** (URLSession vs fetch, `DispatchQueue` vs Promise, etc.) live in [`../architecture.md`](../architecture.md). They aren't parity issues — they're how each language naturally expresses the same behavior.
- **Concurrency model** (actors, async-throws, transaction lifetimes) lives in `../architecture.md` too.
- **Build / packaging / deployment** lives in [`../../README.md`](../../README.md) at the project root, not here.

If you're auditing whether the Swift client *behaves* like the JS client, this directory is the single source. If you're authoring Swift code and need API guidance, you want [`../baomodels.md`](../baomodels.md) and the API documentation, not the parity tables.
