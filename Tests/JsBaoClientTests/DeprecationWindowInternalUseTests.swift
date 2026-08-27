import XCTest
@testable import JsBaoClient

/// #2367 closed the deprecation windows opened by #1913, #1993 and #1994.
/// Every symbol those windows kept alive — `QueryOptions.offset`, the
/// `.remoteUpdate` event and its payload, `client.events`, the untyped
/// `on` / `onAny` / `emit` shim, the free `waitForEvent`, the untyped
/// `KvCache` emit closure, and the synchronous analytics members — is gone.
///
/// This file used to assert the client's own sources still honored those
/// symbols. It now asserts the opposite: the removed spellings must not come
/// back. Alongside the absence guard it keeps the live contracts that
/// outlived the windows and had no coverage anywhere else — the typed
/// callback's delivery order, the `KvCache` emit closure, and the analytics
/// buffering the twins do.
final class DeprecationWindowInternalUseTests: XCTestCase {

    // MARK: - Absence guard

    /// `Sources/JsBaoClient`, derived from this file's path.
    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JsBaoClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift-client
            .appendingPathComponent("Sources/JsBaoClient")
    }

    /// Strip `//` line comments and `/* … */` blocks so a doc comment that
    /// explains what a symbol was replaced BY does not read as the symbol
    /// coming back. String literals are not special-cased: none of the
    /// needles below is a plausible literal.
    private static func stripComments(_ source: String) -> String {
        var kept = ""
        var inBlock = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let characters = Array(rawLine)
            var i = 0
            while i < characters.count {
                if inBlock {
                    if characters[i] == "*", i + 1 < characters.count, characters[i + 1] == "/" {
                        inBlock = false
                        i += 2
                    } else {
                        i += 1
                    }
                    continue
                }
                if characters[i] == "/", i + 1 < characters.count, characters[i + 1] == "*" {
                    inBlock = true
                    i += 2
                    continue
                }
                if characters[i] == "/", i + 1 < characters.count, characters[i + 1] == "/" {
                    break
                }
                kept.append(characters[i])
                i += 1
            }
            kept.append("\n")
        }
        return kept
    }

    /// Every `.swift` file under `root`, at any depth, with paths relative to
    /// `root` and a stable order.
    private func swiftFiles(under root: URL) throws -> [(relativePath: String, url: URL)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        var found: [(String, URL)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            found.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), url))
        }
        return found.sorted { $0.0 < $1.0 }
    }

    private func codeOfEverySourceFile() throws -> [(relativePath: String, code: String)] {
        try swiftFiles(under: sourcesDirectory).map {
            (
                relativePath: $0.relativePath,
                code: Self.stripComments(try String(contentsOf: $0.url, encoding: .utf8))
            )
        }
    }

    /// The removed spellings, each unique enough that a hit anywhere under
    /// `Sources/JsBaoClient` means the symbol itself is back rather than a
    /// same-named member of something else. The synchronous analytics members
    /// are checked separately below because `AnalyticsQueue` legitimately has
    /// methods with those names.
    private static let removedSpellings = [
        // #1913: offset pagination — cursors replaced it.
        "offsetForQuery",
        // #1913 / #1994: the Swift-only `.remoteUpdate` event and its payload.
        "RemoteUpdateEvent",
        "remoteUpdateRawKey",
        "case remoteUpdate",
        // #1994: the untyped event surface.
        "public var events",
        "func onAny(",
        "func waitForEvent(",
        "LegacyEventDictionary",
        "adaptUntypedEmit",
        // #1993: the synchronous untyped analytics entry point on the client.
        // Matches the sync member only — `logAnalyticsEventAsync(` does not
        // contain `logAnalyticsEvent(`.
        "logAnalyticsEvent(",
        // #1991 / #2367: the legacy closure transport.
        "ClosureTransport",
    ]

    func testRemovedDeprecatedSymbolsDoNotReappear() throws {
        let files = try codeOfEverySourceFile()
        XCTAssertFalse(files.isEmpty, "the source sweep found no files — check sourcesDirectory")

        for (relativePath, code) in files {
            for spelling in Self.removedSpellings {
                XCTAssertFalse(
                    code.contains(spelling),
                    """
                    \(relativePath) declares or calls `\(spelling)`, which #2367 removed. \
                    Its deprecation window is closed — use the typed replacement rather \
                    than reviving the old surface.
                    """
                )
            }
        }
    }

    /// `AnalyticsAPI`'s synchronous half is gone; only the `Async` twins
    /// remain. Scoped to that one file because `AnalyticsQueue` — the actor
    /// the twins call into — has its own `logEvent` / `flush` /
    /// `setPlanOverride`, which are not the removed surface.
    func testRemovedSynchronousAnalyticsMembersDoNotReappear() throws {
        let url = sourcesDirectory.appendingPathComponent("API/AnalyticsAPI.swift")
        let code = Self.stripComments(try String(contentsOf: url, encoding: .utf8))

        for spelling in [
            "func logEvent(", "func logSnapshot(", "func flush(",
            "func setPlanOverride(", "func setAppVersionOverride(",
        ] {
            XCTAssertFalse(
                code.contains(spelling),
                "AnalyticsAPI declares `\(spelling)` again — the synchronous half was removed by #2367"
            )
        }
    }

    // MARK: - Live contracts that were only covered here

    /// Typed callbacks fire synchronously inside `emit`, in registration
    /// order — the delivery contract the client's own listeners,
    /// `observeOnMainActor` and `nextEvent` are all built on. The untyped
    /// `on` / `onAny` shim this used to be written against is gone, but the
    /// contract belongs to `subscribe` and is unchanged.
    func testTypedCallbacksKeepSynchronousRegistrationOrderDelivery() {
        let emitter = EventEmitter()
        let order = ThreadSafeBox<[String]>([])

        let first = emitter.subscribe(DocumentClosedEvent.self) { _ in
            order.mutate { $0.append("first") }
        }
        let second = emitter.subscribe(DocumentClosedEvent.self) { _ in
            order.mutate { $0.append("second") }
        }
        let third = emitter.subscribe(DocumentClosedEvent.self) { _ in
            order.mutate { $0.append("third") }
        }
        defer {
            first.cancel()
            second.cancel()
            third.cancel()
        }

        emitter.emit(DocumentClosedEvent(documentId: "d1"))
        // Asserted immediately after `emit` returns, with no awaiting: if
        // delivery had become asynchronous this would still be empty.
        XCTAssertEqual(order.value, ["first", "second", "third"],
                       "callbacks must fire synchronously inside emit, in registration order")
    }

    /// `KvCache`'s injected emit closure receives the payload, and the key it
    /// carries comes from the payload's own type. The closure is typed now
    /// (`(any JsBaoEventPayload) -> Void`); the routing it guards is the same.
    ///
    /// Supplied through `init(emit:)` since #1993 Phase D2: `KvCache` is an
    /// actor, so `setEmitter` (a synchronous mutation of actor state) is gone
    /// and construction is the only place the emitter is attached.
    func testKvCacheEmitClosureReceivesEventsKeyedFromThePayloadType() async {
        let seen = ThreadSafeBox<[String]>([])
        let cache = KvCache(emit: { (payload: any JsBaoEventPayload) in
            seen.mutate { $0.append(Swift.type(of: payload).eventKey.rawValue) }
        })

        // Drive the closure directly: it must receive the payload, and the key
        // must be derivable from the payload's type.
        await cache.emitForTesting(CacheUpdatedEvent(key: "k", updatedAt: "2026-01-01", value: 1))
        XCTAssertEqual(seen.value, [JsBaoEvent.cacheUpdated.rawValue],
                       "the emit closure must receive the event, keyed from the payload type")
    }

    // MARK: - Analytics

    /// An awaited event and an awaited snapshot both land in the buffer, with
    /// any override that was in force before the call applied to each. Awaiting
    /// makes this deterministic — the buffer is readable straight after the
    /// call rather than after a poll.
    func testAnalyticsSurfaceBuffersEventsAndSnapshots() async throws {
        let queue = AnalyticsQueue(logger: Logger(level: .none, scope: "analytics-surface"))
        let api = AnalyticsAPI(queue: queue, resolveUserUlid: { "user-1" })

        await api.setPlanOverrideAsync("pro")
        await api.logEventAsync(AnalyticsEventInput(action: "click", feature: "cta"))
        await api.logSnapshotAsync(context: .object(["screen": .string("home")]))

        let buffered = await queue.bufferedEvents
        let actions = buffered.compactMap { $0["action"]?.stringValue }
        XCTAssertTrue(actions.contains("click"), "logEventAsync must buffer, got \(actions)")
        XCTAssertTrue(actions.contains("_snapshot"), "logSnapshotAsync must buffer, got \(actions)")
        XCTAssertTrue(
            buffered.allSatisfy { $0["plan"] == .string("pro") },
            "an override in force before the call must reach every event"
        )
    }

    /// The `Async` twins do their work on the caller's task, so an event
    /// logged immediately before a flush is in **that** batch. A change that
    /// made the twins unordered against each other would otherwise be
    /// invisible.
    func testAsyncTwinsAreOrderedAgainstEachOther() async throws {
        let sent = ThreadSafeBox<[String]>([])
        let queue = AnalyticsQueue(
            logger: Logger(level: .none, scope: "analytics-surface"),
            sendMessage: { message in sent.mutate { $0.append(message) } },
            getConnectionId: { "conn-1" }
        )
        let api = AnalyticsAPI(queue: queue, resolveUserUlid: { "user-1" })

        await api.setPlanOverrideAsync("pro")
        await api.logEventAsync(AnalyticsEventInput(action: "ordered", feature: "cta"))
        await api.flushAsync()

        let batches = sent.value.joined(separator: "\n")
        XCTAssertTrue(batches.contains("\"ordered\""),
                      "an awaited event must be in the batch the next awaited flush sends, got \(batches)")
        XCTAssertTrue(batches.contains("\"pro\""),
                      "and it must carry the override awaited before it")
        let leftOver = await queue.bufferedEvents
        XCTAssertTrue(leftOver.isEmpty, "the awaited flush must have drained the buffer")
    }

    /// The client's untyped top-level analytics member forwards to the same
    /// buffer, carrying each field of the caller's dictionary. This drives the
    /// real facade member on a real client (constructed against an unreachable
    /// URL, so it never touches the network) rather than re-performing the two
    /// steps it does internally — so it would fail, not pass, if the member
    /// itself went away.
    func testUntypedClientLogCarriesEveryFieldToTheBuffer() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "test-app",
            token: "test-token",
            offline: false,
            logLevel: .error,
            storageConfig: .memory,
            autoNetwork: false
        ))

        await client.logAnalyticsEventAsync([
            "action": "legacy_click", "feature": "cta", "count": 2,
        ])

        // Filtered by action because the client logs its own lifecycle events.
        let buffered = await client.analyticsQueue.bufferedEvents
            .filter { $0["action"] == .string("legacy_click") }
        XCTAssertEqual(buffered.first?["action"], .string("legacy_click"))
        XCTAssertEqual(buffered.first?["count"], .number(2))
        XCTAssertEqual(buffered.first?["feature"], .string("cta"))
    }
}
