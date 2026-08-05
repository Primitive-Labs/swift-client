import XCTest
@testable import JsBaoClient
import YSwift

/// Phase D1 of the concurrency-modernization epic (#1993): the two async-domain
/// files that still carried Swift 6 `Sendable` errors are typed honestly —
/// `KvCache`'s cache-value path moves from `Any` to `JSONValue` (and
/// `withTimeout` gains its `R: Sendable` constraint), and `DocumentManager`'s
/// in-flight open `Task` carries the shared `ConfinedYDocument` holder Phase C
/// (#1992) landed rather than a bare `YDocument`.
///
/// What each kind of check here is worth is the same as in
/// `Schema/SendableModelLayerTests`: the `requireSendable(_:)` calls document
/// the intended conformance and only bite under `.v6` (Phase F, #1946); the
/// check that can fail today is `scripts/v6-sendable-gate.sh`, run in assertion
/// mode from `run-tests.sh`. Everything else below is ordinary behavior
/// coverage for the retyping — the round-trips that must survive it.
///
/// All server-free.
final class SendableAsyncManagerTypingTests: XCTestCase {

    /// Records the intended `Sendable` conformance at a call site. A compile
    /// error since #2310 put this test target in the Swift 6 language mode
    /// alongside the rest of the package; silent before that, under `.v5`.
    private func requireSendable<T: Sendable>(_ value: T) -> T { value }

    /// Thread-safe counter for asserting how many times a fetcher ran.
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.withLock { _value += 1 } }
        var value: Int { lock.withLock { _value } }
    }

    // MARK: - Behavior 1 — the gate holds both Phase D1 files at zero

    /// The compiler catches a regression in this phase's files, but not by
    /// name — the gate script is what reports the offending file. Make sure
    /// this phase's two files are still named in its assertion, and that the
    /// budget stayed at zero with them.
    func testV6GateHoldsThePhaseD1FilesAtZero() throws {
        var root = URL(fileURLWithPath: #filePath)
        // .../Tests/JsBaoClientTests/<this file> → the package root.
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let runner = try String(contentsOf: root.appendingPathComponent("run-tests.sh"), encoding: .utf8)

        XCTAssertTrue(runner.contains("v6-sendable-gate.sh --max"),
                      "run-tests.sh must invoke the gate in assertion mode")
        for file in ["Internal/KvCache.swift", "Internal/DocumentManager.swift"] {
            XCTAssertTrue(runner.contains("\"\(file)\""),
                          "run-tests.sh must hold \(file) at zero .v6 Sendable sites")
        }
        XCTAssertTrue(runner.contains("V6_MAX_SITES=0"),
                      "Phase D1 clears the last 23 sites — the target-wide budget is 0")
    }

    /// `withTimeout`'s result type is constrained, not free: it crosses a task
    /// group boundary. Checked as source text because the constraint is only a
    /// compile error under `.v6`.
    func testWithTimeoutConstrainsItsResultToSendable() throws {
        let source = try Self.clientSource("Internal/AsyncTimeout.swift")
        XCTAssertTrue(
            source.contains("func withTimeout<R: Sendable>"),
            "withTimeout's result crosses a task-group boundary and must be constrained to Sendable"
        )
    }

    // MARK: - The retyped values are Sendable

    func testCacheAndDocumentHandoffTypesAreSendable() throws {
        _ = requireSendable(JSONValue.object(["a": .number(1)]))
        _ = requireSendable(
            KvCacheRecord(key: "k", value: .string("v"), updatedAt: nil, updatedAtMs: nil)
        )
        _ = requireSendable(ConfinedYDocument(YDocument()))
    }

    // MARK: - KvCache: the generic surface still round-trips

    /// A JSON object handed in as `[String: Any]` comes back as `[String: Any]`
    /// — the shape every `CacheFacade.fetchHttp` caller uses.
    func testDictionaryRoundTripsThroughFetchCached() async throws {
        let cache = KvCache()
        // `[String: Any]` is not `Sendable`, so the fetcher hands its dictionary
        // over in a `SendingBox` rather than capturing a local `let` directly.
        let stored = SendingBox<[String: Any]>([
            "name": "Ada",
            "score": 42,
            "active": true,
            "tags": ["a", "b"],
            "nested": ["deep": "value"],
        ])

        let written: [String: Any]? = try await cache.fetchCached(key: "dict", fetcher: { stored.value })
        let readBack: [String: Any]? = try await cache.fetchCached(key: "dict", fetcher: {
            XCTFail("fetcher must not run on a cache hit")
            return [:] as [String: Any]
        })

        for value in [written, readBack] {
            let row = try XCTUnwrap(value)
            XCTAssertEqual(row["name"] as? String, "Ada")
            XCTAssertEqual(row["score"] as? Int, 42)
            XCTAssertEqual(row["active"] as? Bool, true)
            XCTAssertEqual(row["tags"] as? [String], ["a", "b"])
            XCTAssertEqual((row["nested"] as? [String: Any])?["deep"] as? String, "value")
        }
    }

    /// Fragments — a bare string, number, bool and array — survive too. These
    /// are the values the pre-#1993 storage tier could not persist at all
    /// (`JSONSerialization.data(withJSONObject:)` rejects a fragment), so this
    /// is where the retyping is strictly better than what it replaced.
    func testFragmentValuesRoundTripThroughFetchCached() async throws {
        let cache = KvCache()

        let string: String? = try await cache.fetchCached(key: "s", fetcher: { "v1" })
        XCTAssertEqual(string, "v1")

        let number: Int? = try await cache.fetchCached(key: "n", fetcher: { 7 })
        XCTAssertEqual(number, 7)

        let flag: Bool? = try await cache.fetchCached(key: "b", fetcher: { true })
        XCTAssertEqual(flag, true)

        let list: [Int]? = try await cache.fetchCached(key: "a", fetcher: { [1, 2, 3] })
        XCTAssertEqual(list, [1, 2, 3])
    }

    /// `T == Any` — the shape `UsersAPI.getBasic` uses — must come back as the
    /// `JSONSerialization` graph, NOT as the `JSONValue` enum. The distinction
    /// is invisible to the type checker (everything is an `Any`) and only
    /// shows up downstream, where the caller feeds the value to
    /// `JSONSerialization` and gets an `__SwiftValue` crash. `materialize`
    /// therefore hands back the enum only for an exact `JSONValue` request.
    func testAnyTypedCallerGetsTheJSONGraphNotTheEnum() async throws {
        let cache = KvCache()
        let value: Any? = try await cache.fetchCached(
            key: "any-typed",
            fetcher: { () async throws -> Any in
                try JSONCoding.jsonObject(from: JSONValue.object(["name": .string("Ada")]))
            }
        )
        let graph = try XCTUnwrap(value)
        XCTAssertFalse(graph is JSONValue, "an `Any` caller must not receive the JSONValue enum")
        XCTAssertEqual((graph as? [String: Any])?["name"] as? String, "Ada")
        // The downstream step that crashed: decoding the returned value.
        XCTAssertEqual(try JSONCoding.decode(AnyNamed.self, from: graph).name, "Ada")

        // Asking for `JSONValue` explicitly still returns the enum.
        let asEnum: JSONValue? = KvCache.materialize(.object(["name": .string("Ada")]), as: JSONValue.self)
        XCTAssertEqual(asEnum, .object(["name": .string("Ada")]))
    }

    /// A `Codable` model handed straight to the cache round-trips as itself.
    /// The old `value as? T` only managed this while the value stayed in the
    /// memory tier; `materialize(_:as:)` decodes it from the cached JSON.
    func testCodableModelRoundTripsThroughFetchCached() async throws {
        let cache = KvCache()
        let model = CachedModel(id: "m1", count: 3)

        let written: CachedModel? = try await cache.fetchCached(key: "model", fetcher: { model })
        XCTAssertEqual(written, model)

        let readBack: CachedModel? = try await cache.fetchCached(key: "model", fetcher: {
            XCTFail("fetcher must not run on a cache hit")
            return CachedModel(id: "x", count: 0)
        })
        XCTAssertEqual(readBack, model)
    }

    /// The other side of the `Decodable` fallback (review of PR #2266): a model
    /// whose stored properties are all optional decodes successfully from *any*
    /// JSON object, so an unchecked `try?` would hand back an all-defaults value
    /// where the pre-#1993 `value as? T` returned `nil` and the caller
    /// refetched. A shape mismatch must still read as a cache miss.
    func testShapeMismatchedEntryReadsAsAMissNotAnAllDefaultsModel() async throws {
        let cache = KvCache()
        await cache.set(key: "collision", value: .object([
            "totally": .string("different"),
            "n": .number(9),
        ]))

        let materialized: AllOptionalModel? = KvCache.materialize(
            await cache.get(key: "collision"),
            as: AllOptionalModel.self
        )
        XCTAssertNil(materialized,
                     "an entry sharing no field with the model must be a miss, not defaults")

        // And that is what the caller sees through the public surface: `nil`,
        // the same answer `value as? T` gave before #1993, so a caller that
        // treats `nil` as "not cached" refetches exactly as it used to.
        let throughFetchCached: AllOptionalModel? = try await cache.fetchCached(
            key: "collision",
            fetcher: { AllOptionalModel(theme: "dark", pageSize: 20) }
        )
        XCTAssertNil(throughFetchCached,
                     "a shape mismatch must surface as nil, not as a defaults-filled model")
    }

    /// The guard above must not reject a *partial* match — an entry that
    /// carries one of the model's fields is still a legitimate hit.
    func testPartiallyMatchingEntryStillMaterializes() async throws {
        let cache = KvCache()
        await cache.set(key: "partial", value: .object([
            "theme": .string("dark"),
            "unrelated": .bool(true),
        ]))

        let materialized: AllOptionalModel? = KvCache.materialize(
            await cache.get(key: "partial"),
            as: AllOptionalModel.self
        )
        XCTAssertEqual(materialized, AllOptionalModel(theme: "dark", pageSize: nil))
    }

    /// `JSONValue` has one numeric case, `.number(Double)`, so the cache's value
    /// domain is exact only to 2^53 — the bound `JSONValue`'s own header states
    /// and the one the `KvCache` header now names explicitly (review of PR
    /// #2266). Pinned rather than left to prose: before #1993 the memory tier
    /// handed an `Int` straight back.
    func testIntegersWiderThanTwoToTheFiftyThreeLoseTheirLowBits() async throws {
        let cache = KvCache()
        let wide = 1_234_567_890_123_456_789

        let readBack: Int? = try await cache.fetchCached(key: "wide-int", fetcher: { wide })
        XCTAssertNotNil(readBack)
        XCTAssertEqual(readBack, Int(Double(wide)),
                       "documented: integers cross Double, so the low bits are lost")
        XCTAssertNotEqual(readBack, wide,
                          "if this ever holds, the cache gained an exact integer path — update the docs")

        // Within 2^53 the value is exact, which is why this is a documented
        // bound rather than a blanket 'don't cache numbers'.
        let safe = 9_007_199_254_740_991  // 2^53 - 1
        let exact: Int? = try await cache.fetchCached(key: "safe-int", fetcher: { safe })
        XCTAssertEqual(exact, safe)

        // The documented workaround.
        let asString: String? = try await cache.fetchCached(key: "wide-string", fetcher: { String(wide) })
        XCTAssertEqual(asString.flatMap(Int.init), wide)
    }

    /// A value that is neither JSON nor `Encodable` is rejected with a clear
    /// error rather than silently cached as its `String(describing:)` text —
    /// which is what the pre-#1993 storage tier did.
    func testNonJSONRepresentableValueIsRejected() {
        XCTAssertThrowsError(try KvCache.cacheValue(from: NotJSON())) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
        }
    }

    /// A cached JSON `null` reads back as `nil` on the typed path, matching the
    /// `NSNull` sentinel the pre-#1993 implementation stored for "no such
    /// record".
    func testNullIsCachedAndReadsBackAsNil() async throws {
        let cache = KvCache()
        await cache.set(key: "null-key", value: .null)
        let cached = await cache.get(key: "null-key")
        XCTAssertEqual(cached, JSONValue.null)

        let materialized: [String: Any]? = KvCache.materialize(.null, as: [String: Any].self)
        XCTAssertNil(materialized)
    }

    /// The dedup region still coalesces concurrent callers onto one fetcher and
    /// hands every one of them the same value — now through a
    /// `Task<JSONValue, Error>` instead of `Task<Any?, Error>`.
    func testConcurrentFetchesStillDedupeThroughTheTypedTask() async throws {
        let cache = KvCache()
        let fetcherCalls = AtomicCounter()
        let callerCount = 50

        // Child results cross an isolation boundary, and `[String: Any]` is not
        // `Sendable` — each one is handed over in a `SendingBox`.
        let results = try await withThrowingTaskGroup(of: SendingBox<[String: Any]?>.self) { group in
            for _ in 0..<callerCount {
                group.addTask {
                    SendingBox(try await cache.fetchCached(key: "typed-dedup", fetcher: {
                        fetcherCalls.increment()
                        try await Task.sleep(nanoseconds: 200_000_000)
                        return ["v": "shared"] as [String: Any]
                    }))
                }
            }
            var collected: [SendingBox<[String: Any]?>] = []
            for try await value in group { collected.append(value) }
            return SendingBox(collected.map(\.value))
        }.value

        XCTAssertEqual(fetcherCalls.value, 1, "concurrent callers must dedupe to one fetcher invocation")
        XCTAssertEqual(results.count, callerCount)
        XCTAssertTrue(results.allSatisfy { ($0?["v"] as? String) == "shared" })
    }

    // MARK: - KvCache: the persistent tier

    /// A value written through one `KvCache` is readable through a second one
    /// sharing the storage provider — the memory tier is bypassed, so this is
    /// the encode/decode pair (`saveToStorage` / `loadFromStorage`) under test.
    func testValuesSurviveThePersistentTier() async throws {
        let provider = MemoryStorageProvider()
        try await provider.initialize(namespace: "kv-typing-tests")

        let writer = KvCache()
        await writer.setStorageProvider(provider)
        await writer.set(key: "persisted", value: .object([
            "name": .string("Ada"),
            "score": .number(42),
            "tags": .array([.string("a")]),
        ]))
        await writer.set(key: "fragment", value: .string("bare"))

        let reader = KvCache()
        await reader.setStorageProvider(provider)
        let persisted = await reader.get(key: "persisted")
        XCTAssertEqual(
            persisted,
            .object(["name": .string("Ada"), "score": .number(42), "tags": .array([.string("a")])])
        )
        let fragment = await reader.get(key: "fragment")
        XCTAssertEqual(fragment, .string("bare"))
    }

    /// Entries written by a pre-#1993 build stored a non-JSON value as its bare
    /// `String(describing:)` text, which does not parse as JSON. The reader
    /// still loads them, as a string, instead of dropping the entry.
    func testLegacyBareStringEntryStillLoads() async throws {
        let provider = MemoryStorageProvider()
        try await provider.initialize(namespace: "kv-legacy-tests")
        // Exactly what the old `saveToStorage` fallback wrote: unquoted text.
        try await provider.put(
            store: "kv",
            key: "legacy",
            value: KvCache.CacheValue(json: "legacy-value"),
            metadata: ["updatedAt": "2026-01-01T00:00:00Z", "updatedAtMs": "1767225600000"]
        )

        let cache = KvCache()
        await cache.setStorageProvider(provider)
        let legacy = await cache.get(key: "legacy")
        XCTAssertEqual(legacy, .string("legacy-value"))

        let info = await cache.info(key: "legacy")
        XCTAssertEqual(info.updatedAt, "2026-01-01T00:00:00Z")
    }

    // MARK: - DocumentManager: the confined handoff

    /// The in-flight open `Task` carries `ConfinedYDocument`, and unwrapping it
    /// still yields the ONE live document every coalesced caller must share.
    /// (`DocumentManagerCoalescingTests` covers the coalescing itself; this is
    /// the same invariant asserted specifically across the holder.)
    func testCoalescedOpensShareTheConfinedDocument() async throws {
        let manager = DocumentManager(logger: Logger(level: .none, scope: "d1-test"))
        manager.appId = "test-app"
        manager.userId = "test-user"
        let options = OpenDocumentOptions(
            waitForLoad: .localIfAvailableElseNetwork,
            enableNetworkSync: false
        )

        let docs = try await withThrowingTaskGroup(of: ConfinedYDocument.self) { group -> [YDocument] in
            for _ in 0..<50 {
                group.addTask {
                    // Wrapping in the holder is what lets the opened document
                    // leave the child task at all.
                    ConfinedYDocument(
                        try await manager.openDocument(documentId: "confined-doc", options: options)
                    )
                }
            }
            var collected: [YDocument] = []
            for try await confined in group { collected.append(confined.document) }
            return collected
        }

        XCTAssertEqual(docs.count, 50)
        let first = try XCTUnwrap(docs.first)
        XCTAssertTrue(docs.allSatisfy { $0 === first },
                      "every coalesced caller must receive the same live YDocument")
        XCTAssertTrue(manager.getDocument("confined-doc") === first)
    }

    /// `pendingOpens` is typed on the holder, not on the bare document — the
    /// point of adopting Phase C's type rather than adding a second one.
    func testPendingOpensUsesTheSharedConfinementHolder() throws {
        let source = try Self.clientSource("Internal/DocumentManager.swift")
        XCTAssertTrue(
            source.contains("private var pendingOpens: [String: Task<ConfinedYDocument, Error>]"),
            "the in-flight open table must carry the shared ConfinedYDocument holder"
        )
        XCTAssertFalse(
            source.contains("Task<YDocument, Error>"),
            "no second, parallel way of moving a YDocument across a Task boundary"
        )
    }

    // MARK: - Helpers

    // Implementation in `Helpers/ClientSourceText.swift` (one copy for the
    // whole epic, consolidated in Phase D4).
    private static func clientSource(_ relativePath: String) throws -> String {
        try ClientSourceText.clientSource(relativePath)
    }
}

/// A caller-owned `Codable` model cached as itself.
private struct CachedModel: Codable, Equatable {
    let id: String
    let count: Int
}

/// Minimal decode target standing in for `BasicUserInfo` on the `Any`-typed
/// cache path.
private struct AnyNamed: Codable {
    let name: String
}

/// A model whose stored properties are all optional: it decodes from *any*
/// JSON object, which is what makes an unchecked `Decodable` fallback able to
/// return wrong data instead of a cache miss.
private struct AllOptionalModel: Codable, Equatable {
    var theme: String?
    var pageSize: Int?
}

/// Neither a JSON graph nor `Encodable` — the one thing the cache now refuses.
private struct NotJSON {
    let handler: () -> Void = {}
}
