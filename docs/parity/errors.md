# Error taxonomy parity

Errors are how cross-platform code handles failures consistently. The error code strings (and their conditions) need to match between Swift and JS.

## Status: ✅ Exemplary

All 19 error codes match exactly between Swift `JsBaoErrorCode` and JS `JsBaoErrorCode`, in the same order. This was the cleanest single layer reviewed in the whole PR.

| Swift `JsBaoErrorCode` | JS `JsBaoErrorCode` | Status |
|---|---|---|
| `unknown` | `unknown` | ✅ |
| `invalidArgument` | `invalidArgument` | ✅ |
| `notFound` | `notFound` | ✅ |
| `notAuthenticated` | `notAuthenticated` | ✅ |
| `notAuthorized` | `notAuthorized` | ✅ |
| `conflict` | `conflict` | ✅ |
| `validationFailed` | `validationFailed` | ✅ |
| `quotaExceeded` | `quotaExceeded` | ✅ |
| `unavailable` | `unavailable` | ✅ |
| `serverError` | `serverError` | ✅ |
| `networkError` | `networkError` | ✅ |
| `timeout` | `timeout` | ✅ |
| `cancelled` | `cancelled` | ✅ |
| `documentClosed` | `documentClosed` | ✅ |
| `documentResolution` | `documentResolution` | ✅ |
| `recordNotFound` | `recordNotFound` | ✅ |
| `uniqueConstraintViolation` | `uniqueConstraintViolation` | ✅ |
| `schemaValidation` | `schemaValidation` | ✅ |
| `featureNotEnabled` | `featureNotEnabled` | ✅ |

## What this enables

Cross-platform code can reason about failures uniformly:

```swift
// Swift
do {
    try await client.documents.get(id: someId)
} catch let error as JsBaoError where error.code == .notFound {
    // ...
}
```

```ts
// JS
try {
    await client.documents.get(someId)
} catch (error) {
    if (error.code === "notFound") { /* ... */ }
}
```

Same code string, same conditions raise it. No translation layer needed at the application boundary.

## Source files

- Swift: [`Sources/JsBaoClient/Types/Errors.swift`](../../Sources/JsBaoClient/Types/Errors.swift) (91 lines)
- JS: [`src/client/errors.ts`](../../../src/client/errors.ts)

## Swift-only codes

None — the code set matches JS exactly. (The former Swift-only `UNSYNCED_CHANGES` was removed; `DocumentsAPI.evict` now throws `JsBaoError(.invalidArgument, "Cannot evict …: has unsynced local changes (use force to override)")`, mirroring JS's plain `Error` from `documentManager.evictLocalDocument`.)

## `details`

`JsBaoError.details` is `[String: JSONValue]?`, mirroring JS's `details?: any` — nested objects, numbers, and bools round-trip while keeping `Sendable` real.

## Notes for maintainers

If you add a new error code:
1. Add it to **both** files in the same order.
2. Update this table.
3. Add a paragraph above describing when it's raised.
4. Make sure both clients raise it under the same conditions — a code that means different things in each language is worse than no code at all.
