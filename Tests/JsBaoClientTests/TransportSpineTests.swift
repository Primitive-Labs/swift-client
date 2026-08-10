import XCTest
@testable import JsBaoClient

/// Server-free tests for the typed transport spine (#1991 Phase B1).
///
/// The `Transport` protocol has one requirement (`execute`), so a fake only
/// scripts raw bytes + status and automatically inherits the real
/// encode/decode/empty/non-2xx policy from the protocol extension. These tests
/// pin that policy — the empty/malformed matrix (behavior 9), the non-2xx
/// mapping, and the raw-bytes contract of `requestData` (behavior 8).
final class TransportSpineTests: XCTestCase {

    // MARK: - Fixtures

    struct Payload: Codable, Sendable, Equatable {
        let name: String
    }

    /// The shared fake lives in `Helpers/RecordingTransport.swift` so every
    /// suite injects the same one; these aliases keep the spine tests reading
    /// in their original vocabulary.
    typealias RecordedCall = RecordedRequest
    typealias ScriptedTransport = RecordingTransport

    private func httpError(_ block: () async throws -> Void) async -> HttpError? {
        do {
            try await block()
            return nil
        } catch let error as HttpError {
            return error
        } catch {
            XCTFail("expected HttpError, got \(error)")
            return nil
        }
    }

    // MARK: - Happy path (behavior 1)

    func testTypedRequestEncodesAndDecodesWithoutAnAnyGraph() async throws {
        let transport = ScriptedTransport(json: #"{"name":"decoded"}"#)

        let result: Payload = try await transport.request(
            method: .post,
            path: "/things",
            body: Payload(name: "sent")
        )

        XCTAssertEqual(result, Payload(name: "decoded"))
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.method, .post)
        XCTAssertEqual(call.path, "/things")
        // The body reaching `execute` is already wire bytes — the API layer no
        // longer builds a `JSONSerialization` dictionary first.
        let sentBody = try XCTUnwrap(call.body)
        XCTAssertEqual(try JSONCoding.decodeData(Payload.self, from: sentBody), Payload(name: "sent"))
    }

    func testNoBodyOverloadSendsNoBody() async throws {
        let transport = ScriptedTransport(json: #"{"name":"x"}"#)
        let _: Payload = try await transport.request(method: .get, path: "/things/1")
        XCTAssertNil(try XCTUnwrap(transport.calls.first).body)
    }

    // MARK: - Empty / malformed matrix (behavior 9)

    func testEmptyBodyThrowsForRequiredResponse() async throws {
        let transport = ScriptedTransport(body: Data())
        let error = await httpError {
            let _: Payload = try await transport.request(method: .get, path: "/me")
        }
        XCTAssertEqual(error?.serverCode, HttpError.emptyBodyCode)
    }

    func testEmptyBodyIsNilForOptionalResponse() async throws {
        let transport = ScriptedTransport(body: Data())
        let result: Payload? = try await transport.requestOptional(method: .get, path: "/me")
        XCTAssertNil(result)
    }

    func testWhitespaceOnlyBodyCountsAsEmpty() async throws {
        let transport = ScriptedTransport(json: "  \n\t ")
        let optional: Payload? = try await transport.requestOptional(method: .get, path: "/me")
        XCTAssertNil(optional, "a body of nothing but JSON whitespace has no document to decode")

        let error = await httpError {
            let _: Payload = try await transport.request(method: .get, path: "/me")
        }
        XCTAssertEqual(error?.serverCode, HttpError.emptyBodyCode)
    }

    func testJsonNullIsNilForOptionalAndThrowsForRequired() async throws {
        let transport = ScriptedTransport(json: "null")
        let optional: Payload? = try await transport.requestOptional(method: .get, path: "/me")
        XCTAssertNil(optional)

        let error = await httpError {
            let _: Payload = try await transport.request(method: .get, path: "/me")
        }
        XCTAssertEqual(error?.serverCode, HttpError.decodingFailedCode)
    }

    func testJsonNullWithSurroundingWhitespaceIsNil() async throws {
        let transport = ScriptedTransport(json: "  null\n")
        let optional: Payload? = try await transport.requestOptional(method: .get, path: "/me")
        XCTAssertNil(optional)
    }

    func testMalformedJsonThrowsForBothRequiredAndOptional() async throws {
        let transport = ScriptedTransport(json: "{not json")

        let required = await httpError {
            let _: Payload = try await transport.request(method: .get, path: "/me")
        }
        XCTAssertEqual(required?.serverCode, HttpError.decodingFailedCode)
        XCTAssertEqual(required?.body, "{not json", "the raw body is preserved for diagnosis")

        let optional = await httpError {
            let _: Payload? = try await transport.requestOptional(method: .get, path: "/me")
        }
        XCTAssertEqual(optional?.serverCode, HttpError.decodingFailedCode)
    }

    func testScalarJsonFragmentsDecode() async throws {
        let intTransport = ScriptedTransport(json: "42")
        let number: Int = try await intTransport.request(method: .get, path: "/count")
        XCTAssertEqual(number, 42)

        let stringTransport = ScriptedTransport(json: #""hello""#)
        let text: String = try await stringTransport.request(method: .get, path: "/greeting")
        XCTAssertEqual(text, "hello")
    }

    func testSendIgnoresBodyIncludingEmptyAndMalformed() async throws {
        try await ScriptedTransport(body: Data()).send(method: .delete, path: "/things/1")
        try await ScriptedTransport(json: "{not json").send(method: .delete, path: "/things/1")
        try await ScriptedTransport(json: "null").send(method: .post, path: "/things", body: Payload(name: "x"))
    }

    // MARK: - Non-2xx policy

    func testNonSuccessStatusThrowsHttpErrorWithParsedServerFields() async throws {
        let transport = ScriptedTransport(
            status: 403,
            json: #"{"code":"INVITATION_REQUIRED","error":"This app is invite-only"}"#
        )
        let error = await httpError {
            let _: Payload = try await transport.request(method: .get, path: "/things")
        }
        XCTAssertEqual(error?.status, 403)
        // Extraction goes through the existing HttpError.parseBody (#850) —
        // the extension does not re-implement the body parse.
        XCTAssertEqual(error?.serverCode, "INVITATION_REQUIRED")
        XCTAssertEqual(error?.serverMessage, "This app is invite-only")
        XCTAssertEqual(error?.authCode, .invitationRequired)
    }

    func testSendThrowsOnNonSuccessStatus() async throws {
        let transport = ScriptedTransport(status: 404, json: #"{"error":"nope"}"#)
        let error = await httpError {
            try await transport.send(method: .delete, path: "/things/1")
        }
        XCTAssertEqual(error?.status, 404)
    }

    // MARK: - requestRaw

    func testRequestRawReturnsFullResponseWithoutThrowing() async throws {
        let transport = ScriptedTransport(status: 409, json: #"{"conflict":true}"#)
        let response = try await transport.requestRaw(method: .get, path: "/integrations/x")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.status, 409)
        XCTAssertEqual(response.data, .object(["conflict": .bool(true)]))
        XCTAssertEqual(response.text, #"{"conflict":true}"#)
    }

    func testRequestRawOnNonJsonBodyMatchesTheLegacyClassification() async throws {
        // Parity guard, not a design statement: a non-JSON content type has
        // always classified to the body's text, which then round-trips into a
        // `.string` JSONValue. `requestRaw` must keep doing exactly that.
        let transport = ScriptedTransport(status: 200, contentType: "text/plain", body: Data("plain".utf8))
        let response = try await transport.requestRaw(method: .get, path: "/thing")
        XCTAssertEqual(response.data, .string("plain"))
        XCTAssertEqual(response.text, "plain")
    }

    // MARK: - requestData raw bytes (behavior 8)

    func testRequestDataReturnsBytesByteForByteIncludingInvalidUtf8() async throws {
        // 0xFF/0xFE are not valid UTF-8 — reconstructing this body from text
        // (what the shipping `makeRawRequest` does) corrupts it.
        let binary = Data([0x00, 0xFF, 0xFE, 0x42, 0x00, 0x80])
        XCTAssertNil(String(data: binary, encoding: .utf8), "fixture must not be valid UTF-8")

        let transport = ScriptedTransport(contentType: "application/octet-stream", body: binary)
        let (data, status) = try await transport.requestData(method: .get, path: "/blobs/1")

        XCTAssertEqual(data, binary)
        XCTAssertEqual(status, 200)
    }

    func testRequestDataForcesRawBodyAndDoesNotThrowOnNonSuccess() async throws {
        let transport = ScriptedTransport(status: 404, contentType: nil, body: Data("missing".utf8))
        let (data, status) = try await transport.requestData(
            method: .put,
            path: "/blobs/1",
            body: Data([1, 2, 3]),
            options: RequestOptions(customHeaders: ["X-Test": "1"], timeout: 5)
        )
        XCTAssertEqual(status, 404, "raw byte transfers report the status instead of throwing")
        XCTAssertEqual(data, Data("missing".utf8))

        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.body, Data([1, 2, 3]))
        XCTAssertEqual(call.options?.rawBody, true)
        // RequestOptions (not a bare header dict) so timeouts survive.
        XCTAssertEqual(call.options?.customHeaders["X-Test"], "1")
        XCTAssertEqual(call.options?.timeout, 5)
    }

    // MARK: - Credential-bearing decode failures keep the token out of the error

    /// A 2xx that fails to decode carries the raw body on `HttpError.body`,
    /// which is `public let` and printed by `String(describing:)` — so on the
    /// auth and passkey endpoints, whose success bodies carry a live access
    /// token, the body is redacted. Decode failures are exactly what an app
    /// forwards to a crash reporter.
    func testDecodeFailureOnAnAuthPathRedactsTheBody() async throws {
        let secret = #"{"token":"eyJhbGciOiJIUzI1NiJ9.SECRET.sig","user":42}"#
        for path in ["/auth/otp/verify", "/passkey/auth/finish", "https://proxy.example/auth/magic-link/verify"] {
            let transport = ScriptedTransport(json: secret)
            let raised = await httpError {
                let _: Payload = try await transport.request(method: .post, path: path)
            }
            let error = try XCTUnwrap(raised)
            XCTAssertEqual(error.serverCode, HttpError.decodingFailedCode)
            let body = try XCTUnwrap(error.body)
            XCTAssertFalse(body.contains("SECRET"), "\(path) leaked the access token on HttpError.body")
            XCTAssertTrue(body.contains(HttpError.redactedBodyPlaceholder))
        }
    }

    /// Non-credential paths are unchanged — the raw body is still the most
    /// useful thing a decode failure can carry.
    func testDecodeFailureOnAnOrdinaryPathKeepsTheBody() async throws {
        let transport = ScriptedTransport(json: #"{"name":42}"#)
        let error = await httpError {
            let _: Payload = try await transport.request(method: .get, path: "/documents/1")
        }
        XCTAssertEqual(try XCTUnwrap(error).body, #"{"name":42}"#)
    }

    // MARK: - Pre-encoded bodies (exactness past 2^53)

    /// `request(bodyData:)` sends the caller's bytes verbatim, which is how
    /// `workflows.start` keeps an `Int64` exact — routing the same value
    /// through `JSONValue` would round it to the nearest `Double`.
    func testPreEncodedBodyIsSentByteForByte() async throws {
        let transport = ScriptedTransport(json: #"{"name":"ok"}"#)
        let exact = Data(#"{"rootInput":{"id":9007199254740993}}"#.utf8)

        let result: Payload = try await transport.request(
            method: .post, path: "/workflows/k/start", bodyData: exact
        )

        XCTAssertEqual(result, Payload(name: "ok"))
        XCTAssertEqual(try XCTUnwrap(transport.lastCall).body, exact)
    }

    /// The workflow `meta` fidelity table in `swift-client/CHANGELOG.md` and
    /// the migration guide is a claim about bytes, so it is asserted here
    /// rather than only described there.
    ///
    /// A `meta` taken positionally reaches `JSONSerialization` without passing
    /// through `JSONValue`, so an `Int64` past 2^53 survives.
    /// `StartWorkflowOptions.meta` is `[String: JSONValue]`, whose single
    /// `.number(Double)` case rounds it. #2367's re-review found the generic
    /// `start` on the wrong side of that line: it declared `meta: [String:
    /// Any]` like `origin/main` but built a `StartWorkflowOptions` internally,
    /// so the value was rounded with no signature change to warn anyone. This
    /// pins both halves — the exactness that was restored, and the one lossy
    /// form the docs tell readers to avoid for large integer IDs.
    func testWorkflowMetaFidelityMatchesTheDocumentedTable() async throws {
        let exact = "9007199254740993"
        let started = #"{"runId":"r","runKey":"k","status":"queued"}"#

        let positional = ScriptedTransport(json: started)
        _ = try await WorkflowsAPI(transport: positional).start(
            workflowKey: "k",
            input: ["a": 1] as [String: Int],
            meta: ["id": Int64(9_007_199_254_740_993)]
        )
        let positionalBody = String(
            decoding: try XCTUnwrap(XCTUnwrap(positional.lastCall).body), as: UTF8.self
        )
        XCTAssertTrue(
            positionalBody.contains(exact),
            "a positional `meta` must reach the wire exactly; got \(positionalBody)"
        )

        let viaOptions = ScriptedTransport(json: started)
        _ = try await WorkflowsAPI(transport: viaOptions).start(
            StartWorkflowOptions(
                workflowKey: "k",
                input: ["a": .number(1)],
                meta: ["id": .number(9_007_199_254_740_993)]
            )
        )
        let optionsBody = String(
            decoding: try XCTUnwrap(XCTUnwrap(viaOptions.lastCall).body), as: UTF8.self
        )
        XCTAssertFalse(
            optionsBody.contains(exact),
            """
            `StartWorkflowOptions.meta` is documented as the lossy form. If it \
            is exact now, `JSONValue` gained an integer case — update the \
            fidelity table in the CHANGELOG and the migration guide.
            """
        )
    }

    // MARK: - Converted call sites (behavior 3 grep assertion)

    /// `swift-client`, derived from this file's path.
    private var packageDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JsBaoClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift-client
    }

    /// `Sources/JsBaoClient` root, derived from this file's path.
    private var sourcesDirectory: URL {
        packageDirectory.appendingPathComponent("Sources/JsBaoClient")
    }

    /// Comments don't ship any `Any` — the assertion is about code, and
    /// several converted files legitimately cite the old shape in a doc
    /// comment explaining what replaced it.
    ///
    /// Both comment forms are stripped: whole-line and trailing `//`, and
    /// `/* … */` blocks. Prefix-only filtering left trailing and block
    /// comments counting as code, which inflates a budget — and an inflated
    /// budget can be paid off later by deleting a comment while adding a real
    /// usage, netting out to the same number.
    static func stripComments(_ source: String) -> [String] {
        var lines: [String] = []
        var inBlock = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let characters = Array(rawLine)
            var kept = ""
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
            lines.append(kept)
        }
        return lines
    }

    private func codeLines(of url: URL) throws -> [String] {
        Self.stripComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// Match with **all whitespace removed** from both the line and the
    /// needle. Swift accepts `[String:Any]`, `[String : Any]` and
    /// `[String: Any]` interchangeably, and this repo has no formatter or
    /// linter (`.swift-format` / `.swiftformat` / `.swiftlint.yml` are all
    /// absent) enforcing the canonical spacing — so a spelling-sensitive
    /// check could be defeated by a single missing space.
    private func count(_ needle: String, in lines: [String]) -> Int {
        let squeezedNeedle = needle.filter { !$0.isWhitespace }
        return lines.reduce(0) { total, line in
            let squeezed = line.filter { !$0.isWhitespace }
            return total + squeezed.components(separatedBy: squeezedNeedle).count - 1
        }
    }

    /// Every spelling of an untyped string-keyed dictionary, so a converted
    /// file can't quietly come back as `[String: Any?]` or
    /// `Dictionary<String, Any>` and pass a check that only knows the
    /// canonical form. Spacing variants need no entry — `count` compares
    /// whitespace-free.
    private static let untypedDictionarySpellings = [
        "[String: Any]",
        "[String: Any?]",
        "Dictionary<String, Any>",
    ]

    private func untypedDictionaryCount(in lines: [String]) -> Int {
        Self.untypedDictionarySpellings.reduce(0) { $0 + count($1, in: lines) }
    }

    /// Every `.swift` file under `Sources/JsBaoClient`, at any depth —
    /// `FileManager.contentsOfDirectory` is non-recursive, so a file in a new
    /// subdirectory used to be invisible to the sweep.
    private func allSourceFiles() throws -> [(relativePath: String, url: URL)] {
        try swiftFiles(under: sourcesDirectory)
    }

    /// Every `.swift` file under `root`, at any depth, with paths relative to
    /// `root` and a stable order.
    private func swiftFiles(under root: URL) throws -> [(relativePath: String, url: URL)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var found: [(String, URL)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path
                .replacingOccurrences(of: root.path + "/", with: "")
            found.append((relative, url))
        }
        return found.sorted { $0.0 < $1.0 }
    }

    /// Every API class converted to the typed spine (B1's `CollectionsAPI`,
    /// all of B2, and B3's `DoDb` / `MeAPI`) carries no untyped dictionary,
    /// no `JSONSerialization`, and no call into the deprecated closure.
    func testConvertedApiSourceHasNoUntypedDictionariesOrJsonSerialization() throws {
        let converted = [
            "BlobBucketsAPI.swift",
            "CollectionsAPI.swift",
            "CollectionTypeConfigsAPI.swift",
            "CronTriggersAPI.swift",
            "DatabaseTypeConfigsAPI.swift",
            "DocumentsAPI.swift",
            "DoDb.swift",
            "GeminiAPI.swift",
            "GroupsAPI.swift",
            "GroupTypeConfigsAPI.swift",
            "IntegrationsAPI.swift",
            "InvitationsAPI.swift",
            "LlmAPI.swift",
            "MeAPI.swift",
            "NotificationsAPI.swift",
            "PromptsAPI.swift",
            "RuleSetsAPI.swift",
            "SessionAPI.swift",
            "UsersAPI.swift",
        ]
        let apiDirectory = sourcesDirectory.appendingPathComponent("API")

        for file in converted {
            let lines = try codeLines(of: apiDirectory.appendingPathComponent(file))
            XCTAssertEqual(
                untypedDictionaryCount(in: lines), 0,
                "\(file) still uses an untyped [String: Any] dictionary"
            )
            XCTAssertEqual(count("JSONSerialization", in: lines), 0, "\(file) still uses JSONSerialization")
            XCTAssertEqual(
                count("await makeRequest(", in: lines), 0,
                "\(file) still calls the deprecated makeRequest closure"
            )
        }
    }

    /// The sites that still hold untyped values, each with the reason and an
    /// exact budget. The budgets only ever go down: B3 took `DoDb`, `MeAPI`,
    /// `AuthController`, `AuthAPI` and `BlobManager` down, and this test
    /// fails until the numbers are updated — so nothing can be quietly left
    /// behind, and nothing can quietly grow back.
    ///
    /// The sweep has three layers, and between them nothing new can arrive
    /// unnoticed anywhere under `Sources/JsBaoClient`:
    ///
    /// 1. the budgeted files below — exact counts, so any movement (up *or*
    ///    down) has to be acknowledged;
    /// 2. every other file in `API/`, **recursively** — must be zero on all
    ///    three counts, so a new API class (or a new `API/Sub/` directory)
    ///    cannot arrive holding untyped values or the legacy closure;
    /// 3. every remaining file in the tree — must not call the deprecated
    ///    closure at all, and their untyped-dictionary total is capped so the
    ///    pre-existing non-HTTP surfaces (`Schema/`, `Query/`, `Events`,
    ///    `DocumentManager` — the ones #1992/#1993 take) can shrink but never
    ///    grow.
    func testRemainingUntypedSitesMatchTheirDocumentedBudget() throws {
        // path → (untyped dictionaries, JSONSerialization uses, legacy calls)
        let budget: [String: (dictionaries: Int, jsonSerialization: Int, legacyCalls: Int)] = [
            // The `credential:` parameters of the public passkey methods are
            // the authenticator's own WebAuthn JSON, plus the two
            // `PasskeyWire` bridging accessors. AuthenticationServices speaks
            // dictionaries, so changing these is a public-signature break
            // deferred to a later phase.
            "API/AuthAPI.swift": (6, 0, 0),
            // The two WebSocket control frames (`db.subscribe` /
            // `db.unsubscribe`) and the `JSONSerialization` that encodes them.
            // #2367 typed the public `params` to `[String: JSONValue]`, so what
            // is left is the wire-encoding boundary itself, not public surface.
            // The review of this PR took it 2 -> 3: `sendSubscribeFrame`'s
            // lowering is a `do`/`catch` that logs the encode failure rather
            // than a `try?` that silently sent an empty `params` bag, which
            // needs the declaration and the cast on separate lines.
            "API/DatabasesAPI.swift": (3, 2, 0),
            // Public `rootInput` / `meta` signatures. The two
            // `JSONSerialization` uses are deliberate: `start`/`runSync`
            // compose the opaque caller payload straight to request bytes,
            // because routing it through `JSONValue` would collapse an
            // `Int64` to `Double` and lose exactness past 2^53. #2367
            // deliberately left this one surface untyped for that reason and
            // recorded it in the CHANGELOG as the batch's one known remaining
            // break; it took the count 11 -> 10 by typing
            // `StartWorkflowOptions`.
            // The re-review of this PR took it 10 -> 11: the three public
            // `start` forms now funnel through one private `startRequest` body
            // composer, whose `input: [String: Any]` parameter is the added
            // line. That is what lets the generic `start<Input: Encodable>`
            // hand its declared-`[String: Any]` `meta` straight to
            // `JSONSerialization` instead of raising it into
            // `StartWorkflowOptions` and back — a round trip that rounded an
            // `Int64` past 2^53 on a signature that had not changed. The file
            // set is net zero on this commit: `JsBaoClient.swift` gave one back
            // (22 -> 21) below.
            "API/WorkflowsAPI.swift": (11, 2, 0),
            // JWT payload parsing (the serialization boundary the design
            // sanctions). Every HTTP response `AuthController` reads is typed.
            // Phase E (#1994) took it 12 -> 4: the eight event payloads emitted
            // as bare dictionaries — `auth-refresh-deferred` and the five
            // `offlineAuth:*` events — are typed `JsBaoEventPayload` structs
            // now, so what remains is JWT parsing only.
            "Internal/AuthController.swift": (4, 1, 0),
            // Phase E (#1994) took it 3 -> 0: the three `blobs:queue-drained`
            // emits (including the terminal-4xx exit added by #2056) now emit
            // `BlobsQueueDrainedEvent`. Nothing untyped is left — the blob HTTP
            // path was already `requestData`.
            "Internal/BlobManager.swift": (0, 0, 0),
            // The client's own remaining untyped surfaces: the WS message
            // payloads it parses, and the `Any` graphs it lowers typed values
            // into at the wire boundary. #2367 took it 38 -> 21 by removing the
            // whole deprecated surface, retyping the event/awareness/analytics
            // payloads to `[String: JSONValue]`, and moving the 20
            // codegen-backing `*Shared` methods to `API/CodegenAPI.swift`
            // (budgeted above). The deprecated-closure count stays 0, which is
            // what proves the client does not call a deprecated entry point of
            // its own. The review of this PR took it 21 -> 22: `setAwareness`
            // lowers its typed state in a `do`/`catch` that logs the encode
            // failure rather than a `try?` that silently published an empty
            // state, which needs the declaration and the cast on separate
            // lines. The re-review took it back 22 -> 21: the two
            // analytics-context closures each carried their own lowering cast,
            // and both now call one `prepareAnalyticsEvent` helper that logs
            // the encode failure instead of dropping it, so the two casts
            // became one.
            "JsBaoClient.swift": (21, 5, 0),
            // The cache-key / query-string helpers on `CacheFacade` (see
            // `testCacheFacadeUsesTheTransport`) plus the one validity check
            // that guards the generic `fetchCached<T>` bridge. No HTTP
            // response body is read here. Phase D1 (#1993) took the
            // `JSONSerialization` count 6 -> 5: the store's own persistence
            // coding now goes through `JSONCoding` on `JSONValue` (the cache's
            // value type), which removed the two hand-rolled
            // serialize/deserialize hops in `saveToStorage`/`loadFromStorage`
            // and added one `isValidJSONObject` guard in `cacheValue(from:)`.
            // Phase D3 took it 5 -> 4: `cacheValue(from:)` is a one-line call to
            // the shared `JSONValue(jsonAny:subject:)` now (the analytics queue
            // needed the same lowering), and that initializer converts
            // containers structurally instead of round-tripping them through
            // `JSONSerialization`.
            // The review of PR #2266 took the dictionary count 3 -> 5, both in
            // `decodeConsumedSourceKeys`: it compares the keys of a decoded
            // model's re-encoded graph against the cached entry's, so that an
            // all-optional `Codable` cannot decode from an unrelated entry and
            // turn a cache miss into an all-defaults model. Both sites are
            // `as? [String: Any]` casts of a `JSONSerialization` graph the
            // function is handed — internal shape checks on a value that is
            // already untyped, not new untyped surface.
            "Internal/KvCache.swift": (5, 4, 0),
        ]
        let sources = sourcesDirectory

        for (file, expected) in budget {
            let lines = try codeLines(of: sources.appendingPathComponent(file))
            XCTAssertEqual(
                untypedDictionaryCount(in: lines), expected.dictionaries,
                "\(file): untyped-dictionary count changed — update the budget (and its reason)"
            )
            XCTAssertEqual(
                count("JSONSerialization", in: lines), expected.jsonSerialization,
                "\(file): JSONSerialization count changed — update the budget (and its reason)"
            )
            XCTAssertEqual(
                count("await makeRequest(", in: lines), expected.legacyCalls,
                "\(file): deprecated-closure call count changed — update the budget"
            )
        }

        // Layers 2 and 3, over the whole tree (recursively).
        //
        // The out-of-scope total covers the client's pre-existing non-HTTP
        // untyped surfaces — `Schema/`, `Query/`, `Events`, `DocumentManager`,
        // `PasskeyWire`, the analytics and storage layers. Phase B never
        // claimed them (they are #1992/#1993), so they carry a ceiling rather
        // than exact per-file numbers: a cleanup elsewhere shouldn't fail this
        // test, but nothing may grow.
        // Lowered 143 → 138 by #1992 (Phase C): the five
        // `PagedQueryResult<[String: Any]>` returns in `Schema/DynamicModel`,
        // `Schema/MultiDocModel` and `Query/BaoModelQueryEngine` now carry the
        // shared `Sendable` row bag. Ratcheting the ceiling down is the point
        // of the phases — Phase D (#1993) lowers it again.
        //
        // Unchanged by Phase E (#1994): its `legacyDictionary` bridge lives in
        // `Types/JsBaoEventPayload.swift`, which carries an exact budget entry
        // above rather than counting against this ceiling. Phase E's net effect
        // on the budgeted files was −11 (`AuthController` 12 → 4,
        // `BlobManager` 3 → 0).
        // Lowered 138 → 131 by #1993 Phase D3, net of two movements:
        // `Internal/AnalyticsQueue.swift` is an actor, so its buffer, its
        // persistence and its test hooks all carry `[String: JSONValue]` and
        // only the one untyped entry point the deprecated public surface feeds
        // is left; `Types/JSONValue.swift` gains the three `[String: Any]`
        // spellings of the shared `Any` → `JSONValue` lowering that entry point
        // (and `KvCache.cacheValue`) now share, which is the seam where an
        // untyped graph is *converted* rather than carried.
        // Raised 131 → 134 after the fact: #2244 (PR #2390) added the
        // `AnalyticsContext.logEventAsync` twin in `Types/Events.swift` — the
        // `asyncLogger` stored property, the `logEventAsync:` init parameter,
        // and the `logEventAsync(_:)` method each carry the same untyped
        // `[String: Any]` event parameter as the existing `logEvent(_:)`
        // surface they mirror. That PR's validation ran filtered Swift suites
        // that did not include this one, so the failure surfaced on `main`
        // only after merge. The untyped analytics event surface goes away with
        // the rest of the `Any` surface in the next major; until then these
        // three sites are budgeted here like the surface they twin.
        // Raised 134 → 136 by #2360: `Internal/LocalFirstListing.swift`'s
        // `serverDocumentPayload(_:)` builds the untyped row that
        // `DocumentManager.handleServerDocuments([[String: Any]])` consumes —
        // its return type and the `payload` local are the two sites. That
        // consumer is a public entry point whose untyped signature this issue
        // does not change, so the payload builder has to speak its shape;
        // typing it would mean typing `handleServerDocuments`, which belongs
        // with the rest of the `Any` surface in the next major. Both sites go
        // away with it.
        // Lowered 136 -> 103 by #2367, which is the "next major" every entry
        // above was waiting for. The batch removed the whole deprecated
        // surface, retyped the event / awareness / analytics-context payloads
        // and `DatabaseSubscribeOptions.params` to `[String: JSONValue]`, and
        // deleted `Internal/ClosureTransport.swift` and the
        // `Types/JsBaoEventPayload.swift` legacy bridge outright — so those two
        // budget entries are gone rather than zeroed.
        // Lowered 103 -> 41 by #2546, the split-out remainder of that batch:
        // the query/storage row currency is `[String: JSONValue]` now, so
        // `Schema/` and `Query/` are clear and `API/CodegenAPI.swift`'s budget
        // entry is deleted rather than zeroed (it now passes the `API/` must-be-
        // zero rule below like every other API file). What is left is
        // `Internal/DocumentManager` + `Internal/LocalFirstListing` (the server
        // document payload), `Utils/PasskeyWire`, and the scattered
        // `JSONSerialization` shape checks.
        let outOfScopeUntypedDictionaryCeiling = 41
        var outOfScopeUntypedDictionaries = 0

        for (relativePath, url) in try allSourceFiles() where budget[relativePath] == nil {
            let lines = try codeLines(of: url)
            XCTAssertEqual(
                count("await makeRequest(", in: lines), 0,
                "\(relativePath) calls the deprecated makeRequest closure"
            )
            if relativePath.hasPrefix("API/") {
                XCTAssertEqual(
                    untypedDictionaryCount(in: lines), 0,
                    "\(relativePath) uses [String: Any]"
                )
                XCTAssertEqual(
                    count("JSONSerialization", in: lines), 0,
                    "\(relativePath) uses JSONSerialization"
                )
            } else {
                outOfScopeUntypedDictionaries += untypedDictionaryCount(in: lines)
            }
        }

        XCTAssertLessThanOrEqual(
            outOfScopeUntypedDictionaries, outOfScopeUntypedDictionaryCeiling,
            """
            The untyped-dictionary total outside the transport surface grew \
            (\(outOfScopeUntypedDictionaries) > \(outOfScopeUntypedDictionaryCeiling)). \
            Either type the new site or, if it is a deliberate non-HTTP \
            surface, lower the ceiling with a reason.
            """
        )
    }

    // MARK: - App-layer callers of the deprecated hatches (#2133)

    /// The in-repo Swift app layer, relative to the repository root. These are
    /// sibling packages of `swift-client` in the monorepo — they consume
    /// `JsBaoClient` as a local SPM dependency, so a deprecated call here is a
    /// caller we own and can fix, not a third-party app we can only warn.
    private static let appLayerSourceRoots = [
        "packages/swift-primitive-app/Sources",
        "templates/primitive-swift-template/Sources",
        "demo-apps/swift-template-demo/Sources",
    ]

    /// The deprecated hatches, matched **without** a leading `.` on purpose.
    ///
    /// The in-client checks above look for `await makeRequest(` because inside
    /// `JsBaoClient` the call is unqualified. An app-layer caller always goes
    /// through the instance (`client.makeRequest(…)`), and may put the receiver
    /// on its own line — so neither `await makeRequest(` nor `.makeRequest(`
    /// reliably fires there. No app-layer package *declares* either symbol
    /// (they live on `JsBaoClient`), so any occurrence of the bare name applied
    /// to an argument list is a call, whatever the receiver looks like.
    private static let deprecatedHatchSpellings = ["makeRequest(", "makeRawRequest("]

    /// The app layer must not call the deprecated untyped hatches either
    /// (#2133). `JsBaoClient.makeRequest` / `makeRawRequest` are removed in the
    /// next major (see `CHANGELOG.md`); this extends the client's own
    /// zero-callers guard to the packages we ship alongside it, so the app
    /// layer can't quietly grow the surface back before then.
    ///
    /// Skipped rather than failed when the sibling packages are absent:
    /// `swift-client` is mirrored to its own SPM repository *with* its tests
    /// (`scripts/publish-swift-packages.sh` excludes only `.git` / build
    /// artifacts / `yswift-fork`), and in that standalone checkout there is no
    /// `packages/` directory to scan.
    func testAppLayerPackagesDoNotCallTheDeprecatedHatches() throws {
        let repoRoot = packageDirectory.deletingLastPathComponent()
        let roots = Self.appLayerSourceRoots
            .map { (path: $0, url: repoRoot.appendingPathComponent($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }

        try XCTSkipIf(
            roots.isEmpty,
            "no in-repo Swift app layer next to this package — standalone SPM checkout"
        )

        for root in roots {
            for (relativePath, url) in try swiftFiles(under: root.url) {
                let lines = try codeLines(of: url)
                for spelling in Self.deprecatedHatchSpellings {
                    XCTAssertEqual(
                        count(spelling, in: lines), 0,
                        """
                        \(root.path)/\(relativePath) calls the deprecated \
                        \(spelling.dropLast()) hatch — use request(method:path:body:), \
                        requestJSON(method:path:) or requestData(method:path:body:options:)
                        """
                    )
                }
            }
        }
    }

    // MARK: - Deprecation guards (behavior 7, server-free)
    //
    // These two live here rather than in `TypedEscapeHatchesB4Tests` because
    // that class's `setUp` stands up a live dev-server app: XCTest runs
    // `setUp` before *every* test method, so a source assertion parked there
    // never runs in a server-free lane — exactly where an anti-regression
    // grep is most useful.

    private var jsBaoClientSource: String {
        get throws {
            try String(
                contentsOf: sourcesDirectory.appendingPathComponent("JsBaoClient.swift"),
                encoding: .utf8
            )
        }
    }

    /// Both legacy entry points are GONE. This used to assert they carried a
    /// deprecation attribute during the window; #2367 is the removal that
    /// window existed for, so the assertion inverts — they must not come back.
    func testLegacyEntryPointsAreRemoved() throws {
        let source = try jsBaoClientSource

        for symbol in ["public func makeRequest(", "public func makeRawRequest("] {
            XCTAssertNil(
                source.range(of: symbol),
                "\(symbol) was removed by #2367 — do not reintroduce the untyped hatch"
            )
        }
    }

    /// And the client does not call its own deprecated surface: the sites that
    /// still need the loose JSON graph go through the private
    /// `legacyJSONGraph` hop, which is why the build stays warning-free.
    func testTheClientDoesNotCallItsOwnDeprecatedSurface() throws {
        let code = Self.stripComments(try jsBaoClientSource).joined(separator: "\n")

        XCTAssertFalse(
            code.contains("await makeRequest(") || code.contains("await self.makeRequest("),
            "JsBaoClient should route internal calls through legacyJSONGraph, not the deprecated makeRequest"
        )
        XCTAssertTrue(
            code.contains("private func legacyJSONGraph("),
            "the single internal untyped hop should still be the private legacyJSONGraph"
        )
    }

    /// `JsBaoNetworkError` (#2367) is only worth its name if `URLError` can no
    /// longer escape, and that holds only while every `URLSession` data call
    /// goes through the one `NetworkSession` helper. A new call site added
    /// straight against `URLSession` would leak a raw `URLError` again — and
    /// nothing else in the suite would notice, because the leak only shows up
    /// against a network that is actually failing.
    /// Keyed on the `URLSession` METHOD names rather than on a receiver
    /// spelling: `session.data(for:` matched only the receiver the client
    /// happens to use today, so `httpSession.data(for:)`, `dataTask(`,
    /// `upload(for:)` and `download(for:)` all slipped past it. Each label
    /// below is unique to `URLSession` (unlike a bare `.data(`, which
    /// `String.data(using:)` also spells), so the scan is specific without
    /// depending on what the receiver is called.
    func testAllURLSessionDataCallsGoThroughTheOneHelper() throws {
        // The helper itself is the one legitimate caller.
        let helperFile = "Types/Errors.swift"
        let spellings = [
            ".data(for:", ".data(from:",
            ".dataTask(", ".uploadTask(", ".downloadTask(",
            ".upload(for:", ".upload(from:",
            ".download(for:", ".download(from:",
            ".bytes(for:", ".bytes(from:",
        ]
        // The one sanctioned receiver: `NetworkSession` IS the helper.
        let sanctionedReceiver = "NetworkSession"

        for (relativePath, url) in try allSourceFiles() where relativePath != helperFile {
            let lines = try codeLines(of: url)
            for spelling in spellings {
                let offending = lines.filter { line in
                    line.contains(spelling)
                        && !line.contains(sanctionedReceiver + spelling)
                }
                XCTAssertTrue(
                    offending.isEmpty,
                    """
                    \(relativePath) calls \(spelling) on something other than \
                    NetworkSession — route it through NetworkSession so the \
                    failure surfaces as JsBaoNetworkError rather than a raw \
                    URLError. Offending line(s): \(offending)
                    """
                )
            }
        }
    }

    /// `CacheFacade` (B2) holds a `Transport`, not the legacy closure. Its
    /// remaining `Any` is the cache-key/query-string surface, which describes
    /// the caller's own parameters rather than a response.
    func testCacheFacadeUsesTheTransport() throws {
        let url = sourcesDirectory.appendingPathComponent("Internal/KvCache.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let facade = try XCTUnwrap(
            source.range(of: "public final class CacheFacade").map { String(source[$0.lowerBound...]) },
            "CacheFacade not found in KvCache.swift"
        )
        let lines = facade
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        XCTAssertTrue(
            facade.contains("private let transport: any Transport"),
            "CacheFacade should hold a Transport"
        )
        XCTAssertEqual(
            count("await makeRequest(", in: lines), 0,
            "CacheFacade still calls the deprecated makeRequest closure"
        )
        XCTAssertEqual(
            untypedDictionaryCount(in: lines), 3,
            "CacheFacade's untyped surface is the cache-key/query helpers only"
        )
    }
}
