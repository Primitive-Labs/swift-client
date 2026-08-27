import XCTest
@testable import JsBaoClient

/// #1994 Phase E1 — the payload/event association and its drift guards.
///
/// The association is only worth having if it stays complete. These tests are
/// what makes that mechanical: a newly added `JsBaoEvent` case with no payload
/// type fails here, a payload whose declared key does not match the key its emit
/// lands on fails here, and a Swift event key the JS client does not know about
/// has to be listed as a deliberate divergence.
final class JsBaoEventPayloadTests: XCTestCase {

    // MARK: - Sample payloads

    /// One instance of every `JsBaoEventPayload` conformance.
    ///
    /// Emitting each one is how the emit side gets checked: the typed
    /// `emit(_ payload:)` derives the key from the payload's type, so a
    /// subscriber registered on the declared `eventKey` must fire for every
    /// entry. Kept in step with `allJsBaoEventPayloadTypes` by
    /// `testSamplePayloadsCoverEveryConformance`.
    private static let samples: [any JsBaoEventPayload] = [
        StatusChangedEvent(status: .connected),
        NetworkModeEvent(mode: .online, isOnline: true, reason: "test"),
        AuthSuccessEvent(token: "t", previousToken: nil, cause: "login"),
        AuthFailedEvent(message: "m", reason: "r"),
        AuthStateEvent(authenticated: true, mode: .online, userId: "u1"),
        AuthLogoutEvent(reason: "explicit"),
        AuthLogoutCompleteEvent(),
        AuthOnlineRequiredEvent(reason: "grant-expired"),
        AuthRefreshDeferredEvent(status: "backoff", cause: "network", nextAttemptMs: 2000, error: "boom"),
        OfflineAuthEnabledEvent(method: "signed"),
        OfflineAuthUnlockedEvent(userId: "u1"),
        OfflineAuthFailedEvent(reason: "expired"),
        OfflineAuthRenewedEvent(),
        OfflineAuthRevokedEvent(wipeLocal: true),
        OfflineAuthExpiringSoonEvent(expiresAtMs: 1, remainingMs: 2),
        DocumentLoadedEvent(documentId: "d1", source: "server", hadData: true, bytes: 3, elapsedMs: 4),
        DocumentClosedEvent(documentId: "d1"),
        DocumentOpenedEvent(documentId: "d1"),
        DocumentCreateCommitFailedEvent(documentId: "d1", reason: "nope"),
        PendingCreateCommittedEvent(documentId: "d1"),
        PendingCreateFailedEvent(documentId: "d1", error: "nope"),
        DocumentMetadataChangedEvent(documentId: "d1", action: "updated", source: "server"),
        DocumentSyncStateChangedEvent(documentId: "d1", state: "synced"),
        SyncEvent(documentId: "d1", synced: true),
        SyncPerfEvent(documentId: "d1", timings: ["totalMs": 5]),
        AwarenessEvent(documentId: "d1", added: ["1"], updated: [], removed: []),
        PermissionEvent(documentId: "d1", permission: .owner),
        SchemaDiscoveredEvent(documentId: "d1", modelNames: ["Todo"]),
        ConnectionCloseEvent(code: 1000, reason: "bye"),
        ConnectionErrorEvent(message: "boom"),
        GenericErrorEvent(scope: "ws", message: "boom"),
        MeUpdatedEvent(value: ["name": "Ada"]),
        MeUpdateFailedEvent(reason: "conflict"),
        InvitationEvent(action: "created", invitationId: "i1", documentId: "d1", permission: "reader"),
        NotificationEvent(notificationId: "n1", title: "t", body: "b", createdAt: "2026-01-01"),
        WorkflowStatusEvent(workflowKey: "w", workflowId: "wid", runKey: "rk", runId: "rid", status: "completed"),
        WorkflowStartedEvent(workflowKey: "w", runId: "rid"),
        blobProgress,
        blobCompleted,
        blobFailed,
        blobPaused,
        blobResumed,
        BlobsQueueDrainedEvent(),
        CacheUpdatedEvent(key: "k", updatedAt: "2026-01-01", value: 1),
        CacheUpdateFailedEvent(key: "k", error: "boom"),
    ]

    private static let blobProgress = BlobUploadProgressEvent(
        documentId: "d1", blobId: "b1", queueId: "q1", filename: "f", contentType: "text/plain",
        numBytes: 1, status: "queued", attempts: 0, nextAttemptAt: 0, updatedAt: 0
    )
    private static let blobCompleted = BlobUploadCompletedEvent(
        documentId: "d1", blobId: "b1", queueId: "q1", filename: "f", contentType: "text/plain",
        numBytes: 1, attempts: 1, updatedAt: 0
    )
    private static let blobFailed = BlobUploadFailedEvent(
        documentId: "d1", blobId: "b1", queueId: "q1", filename: "f", contentType: "text/plain",
        numBytes: 1, attempts: 1, lastError: "boom", willRetry: false, nextAttemptAt: 0, updatedAt: 0
    )
    private static let blobPaused = BlobUploadPausedEvent(
        documentId: "d1", blobId: "b1", queueId: "q1", filename: "f", contentType: "text/plain",
        numBytes: 1, attempts: 1, updatedAt: 0
    )
    private static let blobResumed = BlobUploadResumedEvent(
        documentId: "d1", blobId: "b1", queueId: "q1", filename: "f", contentType: "text/plain",
        numBytes: 1, attempts: 1, updatedAt: 0
    )

    // MARK: - Behavior 1: every emitted key has exactly one payload type

    /// Every `JsBaoEvent` case declared in `Types/Events.swift` has exactly one
    /// `JsBaoEventPayload` conformance, except any key listed in
    /// `unpayloadedJsBaoEventKeys` (empty since #2367 removed the three
    /// deprecated, never-emitted cases).
    ///
    /// The case list is read out of the source rather than from `CaseIterable`
    /// (which the compiler declines to synthesize for an enum with `@available`
    /// cases), so adding an event without a payload type fails here.
    func testEveryDeclaredEventKeyHasExactlyOnePayloadType() throws {
        let declared = try declaredEventKeys()
        XCTAssertGreaterThan(declared.count, 40, "the case scan should have found the whole enum")

        var byKey: [String: [String]] = [:]
        for type in allJsBaoEventPayloadTypes {
            byKey[type.eventKey.rawValue, default: []].append("\(type)")
        }

        let missing = declared.subtracting(byKey.keys).subtracting(unpayloadedJsBaoEventKeys)
        XCTAssertTrue(
            missing.isEmpty,
            "these event keys have no JsBaoEventPayload type: \(missing.sorted()) — add one (and its entry in allJsBaoEventPayloadTypes), or list the key in unpayloadedJsBaoEventKeys with a reason"
        )

        let duplicated = byKey.filter { $0.value.count > 1 }
        XCTAssertTrue(
            duplicated.isEmpty,
            "an event key must carry exactly one payload type, otherwise stream(for:) is ambiguous: \(duplicated)"
        )

        let unknown = Set(byKey.keys).subtracting(declared)
        XCTAssertTrue(unknown.isEmpty, "these payload types name a key that is not a JsBaoEvent case: \(unknown.sorted())")

        // The exempt keys must genuinely have no payload — otherwise the
        // exemption is stale.
        for key in unpayloadedJsBaoEventKeys {
            XCTAssertNil(byKey[key], "\(key) is listed as unpayloaded but has a payload type")
            XCTAssertTrue(declared.contains(key), "\(key) is exempted but is not a JsBaoEvent case")
        }
    }

    /// The sample table stays complete, so `testTypedEmitLandsOnDeclaredKey`
    /// below actually covers every conformance.
    func testSamplePayloadsCoverEveryConformance() {
        let sampled = Set(Self.samples.map { "\(Swift.type(of: $0))" })
        let declared = Set(allJsBaoEventPayloadTypes.map { "\($0)" })
        XCTAssertEqual(
            declared.subtracting(sampled), [],
            "add a sample instance for these payload types so the emit-key guard covers them"
        )
        XCTAssertEqual(sampled.subtracting(declared), [], "these sampled types are not in allJsBaoEventPayloadTypes")
    }

    // MARK: - Behavior 2: the typed emit lands on the declared key

    /// For every payload type, the typed `emit(_ payload:)` delivers to a
    /// subscriber registered on that payload's own `eventKey`.
    ///
    /// This is what replaced the old "the emit site names a key and the handler
    /// names a type, and nothing checks them against each other" arrangement: the
    /// key is derived from the type, and this asserts the derivation is the one
    /// subscribers see.
    func testTypedEmitLandsOnDeclaredKey() {
        for payload in Self.samples {
            assertEmitLandsOnDeclaredKey(payload)
        }
    }

    /// One sample's check. Generic so the payload's concrete type is available
    /// to `subscribe(_:)`; the existential elements of `samples` are opened
    /// implicitly at the call site above. Registering by type rather than by a
    /// raw key string is the only registration `EventEmitter` still offers
    /// after #2367 removed the untyped shim.
    private func assertEmitLandsOnDeclaredKey<E: JsBaoEventPayload>(
        _ payload: E,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let emitter = EventEmitter()
        let hits = AtomicInt()
        let sub = emitter.subscribe(E.self) { _ in hits.increment() }
        defer { sub.cancel() }

        emitter.emitErased(payload)
        XCTAssertEqual(
            hits.value, 1,
            "emit(\(E.self)) must reach a subscriber on \(E.eventKey.rawValue)",
            file: file, line: line
        )
    }

    /// `remoteUpdate` was a Swift-only event with no JS counterpart, kept alive
    /// through a raw-key escape hatch. #2367 removed the case, its payload type
    /// and the escape hatch, so the guard is now that none of them came back:
    /// a re-added Swift-only key would otherwise slip past
    /// `testConformanceSetMatchesTheJsEventMap`'s allowlist unnoticed.
    func testTheRemoteUpdateEventWasRemoved() throws {
        let declared = try declaredEventKeys()
        XCTAssertFalse(
            declared.contains("remoteUpdate"),
            "the remoteUpdate case was removed in #2367"
        )
        XCTAssertFalse(
            swiftOnlyJsBaoEventKeys.contains("remoteUpdate"),
            "remoteUpdate must not be allowlisted as a Swift-only key any more"
        )
        for source in try ClientSourceText.allClientSources() {
            XCTAssertFalse(source.contains("RemoteUpdateEvent"), "the payload type was removed")
            XCTAssertFalse(source.contains("remoteUpdateRawKey"), "the raw-key escape hatch was removed")
        }
    }

    // MARK: - The legacy dictionary bridge is gone

    /// #2367 removed `LegacyEventDictionary` along with the `on` / `onAny` shim
    /// that consumed it. Nine payload types carried the bridge so that a
    /// handler still annotated `[String: Any]` kept receiving its
    /// pre-conversion dictionary; with no untyped subscription left, there is
    /// nothing for it to feed. The guard is that neither the protocol nor its
    /// `legacyDictionary` witness came back.
    func testTheLegacyDictionaryBridgeWasRemoved() throws {
        for source in try ClientSourceText.allClientSources() {
            XCTAssertFalse(
                source.contains("LegacyEventDictionary"),
                "the legacy dictionary bridge was removed in #2367"
            )
            XCTAssertFalse(
                source.contains("legacyDictionary"),
                "the bridge's witness was removed in #2367"
            )
        }
    }

    /// A subscriber takes the typed payload — the shape the bridge used to be a
    /// fallback for, and now the only one.
    func testTypedSubscriptionDeliversThePayload() {
        let emitter = EventEmitter()
        let received = ThreadSafeBox<[String]>([])
        let sub = emitter.subscribe(OfflineAuthEnabledEvent.self) { event in
            received.mutate { $0.append(event.method) }
        }
        defer { sub.cancel() }

        emitter.emit(OfflineAuthEnabledEvent(method: "signed"))
        XCTAssertEqual(received.value, ["signed"])
    }

    /// An unset optional stays `nil` rather than becoming a present-but-empty
    /// value — the distinction `AuthRefreshBackoffSchedulerTests` reads to mean
    /// "no next attempt promised". The dictionary bridge used to express this as
    /// an absent KEY; the typed payload expresses it as a `nil` field.
    func testUnsetOptionalFieldsStayNil() {
        let event = AuthRefreshDeferredEvent(status: "offline", cause: "cap-reached")
        XCTAssertNil(event.nextAttemptMs, "an unset optional must stay nil")
        XCTAssertNil(event.error)
        XCTAssertEqual(event.status, "offline")
        XCTAssertEqual(event.cause, "cap-reached")
    }

    // MARK: - Behavior 15: parity with the JS `JsBaoEvents` map

    /// The Swift conformance set stays aligned with the JS client's
    /// `JsBaoEvents` map (`src/client/JsBaoClient.ts`).
    ///
    /// Two directions:
    /// - a JS-mapped key that Swift also declares must have a Swift payload type,
    ///   so the two clients cannot diverge on what is observable;
    /// - a Swift key the JS map does not have must be listed in
    ///   `swiftOnlyJsBaoEventKeys`, so a new Swift-only event is a decision
    ///   rather than an accident.
    ///
    /// Skips when the monorepo's JS source is not present — the published SwiftPM
    /// mirror ships the package without it.
    func testConformanceSetMatchesTheJsEventMap() throws {
        let jsKeys = try jsEventMapKeys()
        let swiftKeys = try declaredEventKeys()
        let payloadKeys = Set(allJsBaoEventPayloadTypes.map { $0.eventKey.rawValue })

        // A broken parse would make every assertion below vacuously true, so
        // pin what a healthy parse looks like: the JS map has ~40 keys and the
        // two clients share most of them.
        XCTAssertGreaterThan(jsKeys.count, 30, "the JsBaoEvents parse looks broken — found \(jsKeys.sorted())")
        XCTAssertGreaterThan(jsKeys.intersection(swiftKeys).count, 30, "the two key sets barely overlap; one parse is wrong")

        let sharedKeys = jsKeys.intersection(swiftKeys)
        let sharedWithoutPayload = sharedKeys.subtracting(payloadKeys).subtracting(unpayloadedJsBaoEventKeys)
        XCTAssertTrue(
            sharedWithoutPayload.isEmpty,
            "these keys exist in both clients but have no Swift payload type: \(sharedWithoutPayload.sorted())"
        )

        let swiftOnly = swiftKeys.subtracting(jsKeys)
        let undeclaredSwiftOnly = swiftOnly.subtracting(swiftOnlyJsBaoEventKeys)
        XCTAssertTrue(
            undeclaredSwiftOnly.isEmpty,
            "these Swift event keys are not in the JS JsBaoEvents map: \(undeclaredSwiftOnly.sorted()) — port them to JS, or list them in swiftOnlyJsBaoEventKeys with a reason"
        )

        let staleAllowlist = swiftOnlyJsBaoEventKeys.subtracting(swiftOnly)
        XCTAssertTrue(
            staleAllowlist.isEmpty,
            "these keys are allowlisted as Swift-only but the JS map now has them — drop them from swiftOnlyJsBaoEventKeys: \(staleAllowlist.sorted())"
        )
    }

    // MARK: - Source scanning

    /// The repo root, derived from this file's own path.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/swift-client/Tests/JsBaoClientTests/<this file>
            .deletingLastPathComponent()          // JsBaoClientTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // swift-client
            .deletingLastPathComponent()          // repo root
    }

    /// Raw values of every case declared in the `JsBaoEvent` enum, read from
    /// `Types/Events.swift`. `case foo` yields `"foo"`; `case foo = "bar"` yields
    /// `"bar"`.
    private func declaredEventKeys() throws -> Set<String> {
        let url = Self.repoRoot
            .appendingPathComponent("swift-client/Sources/JsBaoClient/Types/Events.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        guard let enumStart = source.range(of: "public enum JsBaoEvent: String") else {
            XCTFail("could not find the JsBaoEvent declaration in \(url.path)")
            return []
        }
        // The enum ends at the first line that is a closing brace in column 0.
        let body = source[enumStart.upperBound...]
        guard let enumEnd = body.range(of: "\n}\n") else {
            XCTFail("could not find the end of the JsBaoEvent declaration")
            return []
        }

        var keys: Set<String> = []
        for line in body[..<enumEnd.lowerBound].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            let declaration = trimmed.dropFirst("case ".count)
            if let equals = declaration.firstIndex(of: "=") {
                let raw = declaration[declaration.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                keys.insert(raw)
            } else {
                keys.insert(declaration.trimmingCharacters(in: .whitespaces))
            }
        }
        return keys
    }

    /// Keys of the JS client's `JsBaoEvents` interface.
    private func jsEventMapKeys() throws -> Set<String> {
        let url = Self.repoRoot.appendingPathComponent("src/client/JsBaoClient.ts")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("JS client source not present (published SwiftPM mirror) — parity check skipped")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "export interface JsBaoEvents {") else {
            XCTFail("could not find the JsBaoEvents interface in \(url.path)")
            return []
        }
        let body = source[start.upperBound...]
        guard let end = body.range(of: "\n}\n") else {
            XCTFail("could not find the end of the JsBaoEvents interface")
            return []
        }

        var keys: Set<String> = []
        // Only depth-0 lines are event keys; a nested object literal (the inline
        // payload shapes the map uses for a few events) contributes field names,
        // not keys. Quoted keys are read to their closing quote because several
        // contain a colon (`"auth:state"`).
        var depth = 0
        for line in body[..<end.lowerBound].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer {
                depth += trimmed.filter { $0 == "{" }.count
                depth -= trimmed.filter { $0 == "}" }.count
            }
            guard depth == 0, !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }

            let key: String
            if trimmed.hasPrefix("\"") {
                let afterQuote = trimmed.dropFirst()
                guard let closing = afterQuote.firstIndex(of: "\"") else { continue }
                key = String(afterQuote[..<closing])
            } else {
                guard let colon = trimmed.firstIndex(of: ":") else { continue }
                key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty, !key.contains(" ") else { continue }
            keys.insert(key)
        }
        return keys
    }

}
