# Changelog

The Swift client is versioned by git tag (there is no `Package.swift` version
field). Breaking changes are recorded here so downstream apps can migrate when
they bump the tag they pin.

## Unreleased

### Breaking — generated model reads are now synchronous (#1156)

The generated cross-document model facade previously split its static reads
into two conventions: `find` and `findAll` were `async throws` while
`query`, `queryOne`, `count`, `aggregate`, `findByUnique`, and `queryPaged`
were synchronous `throws`. The generated relationship instance accessors
(`task()`, `profile()`, `viaJoin()`, etc.) were likewise `async throws`.

All of these now emit **synchronous `throws`**. None of them ever suspended —
every method delegates to a synchronous in-process CRDT read — so the `async`
was cosmetic. Decode-loudness is unchanged: `find`/`findAll` still throw
`PrimitiveDecodeError` when a stored row no longer decodes as the typed model.

**Migration:** drop `await` from calls to these methods. Because the methods
were never truly suspending, a stale `await` produces a "no `async` operations
occur within `await`" warning rather than a hard error, so existing call sites
keep compiling until updated.

```swift
// Before
let note = try await Note.find(id)
let all  = try await Note.findAll()
let author = try await post.author()

// After
let note = try Note.find(id)
let all  = try Note.findAll()
let author = try post.author()
```

Synchronous SwiftUI `body` / computed-property contexts can now read a model
inline without a `Task { }` wrapper.

This deliberately reverses #992's JS call-shape parity for `find`/`findAll`:
the Swift facade reads an in-process synchronous store, so a synchronous API is
the truthful shape. The internal `DynamicModel` / `MultiDocModel` `find(id:)`
method is unrelated and unchanged.
