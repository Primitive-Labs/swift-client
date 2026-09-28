import XCTest
@testable import JsBaoClient

/// The Swift alias creates carry the whole create vocabulary, and
/// `CreateDocumentOptions` stops putting a client-only flag on the wire (#3757).
///
/// Names mirror the JS client's, per the intent's Swift-surface decision: a
/// developer who has read
/// `documents.getOrCreateWithAlias({ documentFormat: 2, tags })` should be able
/// to guess `GetOrCreateWithAliasOptions(alias:..., documentFormat: 2, tags:)`.
///
/// Driven through the proven `CallRecorder` shape — a stub `Transport` that
/// records the method, path and decoded body — so "encoded only when set" is a
/// claim about the bytes that leave, not about the struct.
final class Format2AliasOptionsHermeticTests: XCTestCase {

    /// Records the last request and replies with a scripted body.
    /// `ApiParityRound2Tests.CallRecorder`'s shape, which is `private` to that
    /// file's test class.
    final class CallRecorder: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var lastMethod: HTTPMethod?
        private var lastPath: String?
        private var lastBody: Data?
        private var cannedResponse: Any = [String: Any]()

        var method: String? { lock.withLock { lastMethod?.rawValue } }
        var path: String? { lock.withLock { lastPath } }
        var body: [String: Any]? {
            guard let data = lock.withLock({ lastBody }) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        var response: Any {
            get { lock.withLock { cannedResponse } }
            set { lock.withLock { cannedResponse = newValue } }
        }

        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            lock.withLock {
                lastMethod = method
                lastPath = path
                lastBody = body
            }
            let data = try JSONSerialization.data(
                withJSONObject: response, options: [.fragmentsAllowed]
            )
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
    }

    private static func aliasResult(_ extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "documentId": "doc-1",
            "title": "Ledger",
            "createdBy": "u-1",
            "createdAt": "2026-01-01T00:00:00Z",
            "modifiedAt": "2026-01-01T00:00:00Z",
            "alias": [
                "scope": "user",
                "aliasKey": "ledger",
                "documentId": "doc-1",
                "userId": "u-1",
                "createdAt": "2026-01-01T00:00:00Z",
                "updatedAt": "2026-01-01T00:00:00Z",
            ] as [String: Any],
        ]
        for (key, value) in extra { body[key] = value }
        return body
    }

    /// The HTTP-only path needs no `DocumentManager`; `BlobManager` has to be
    /// wired but is never exercised (`ApiParityTests`' shape).
    private func documentsAPI(_ recorder: CallRecorder) -> DocumentsAPI {
        DocumentsAPI(
            transport: recorder,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
    }

    private let ledger = AliasRef(scope: .user, aliasKey: "ledger")

    // MARK: - Behavior 21 — encoded only when set

    func testCreateWithAliasEncodesTheNewOptionsOnlyWhenTheyAreSet() async throws {
        let recorder = CallRecorder()
        recorder.response = Self.aliasResult()
        let api = documentsAPI(recorder)

        // Unset: the body is exactly what it was before these three existed.
        _ = try await api.createWithAlias(
            options: CreateWithAliasOptions(title: "Ledger", alias: ledger)
        )
        XCTAssertEqual(recorder.method, "POST")
        XCTAssertEqual(recorder.path, "/documents/create-with-alias")
        let bare = try XCTUnwrap(recorder.body)
        XCTAssertNil(bare["tags"], "an unset `tags` must not reach the wire")
        XCTAssertNil(bare["metadata"], "an unset `metadata` must not reach the wire")
        XCTAssertNil(
            bare["documentFormat"],
            "an unset `documentFormat` must not reach the wire"
        )
        XCTAssertEqual(bare["title"] as? String, "Ledger")

        // Set: each one travels.
        _ = try await api.createWithAlias(options: CreateWithAliasOptions(
            title: "Ledger",
            alias: ledger,
            tags: ["ledger", "q3"],
            metadata: .object(["owner": .string("finance")]),
            documentFormat: 2
        ))
        let full = try XCTUnwrap(recorder.body)
        XCTAssertEqual(full["tags"] as? [String], ["ledger", "q3"])
        XCTAssertEqual(
            (full["metadata"] as? [String: Any])?["owner"] as? String, "finance"
        )
        XCTAssertEqual(full["documentFormat"] as? Int, 2)
    }

    func testGetOrCreateWithAliasEncodesTheNewOptionsOnlyWhenTheyAreSet() async throws {
        let recorder = CallRecorder()
        recorder.response = Self.aliasResult(["created": true])
        let api = documentsAPI(recorder)

        _ = try await api.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(alias: ledger)
        )
        XCTAssertEqual(recorder.method, "POST")
        XCTAssertEqual(recorder.path, "/documents/get-or-create-with-alias")
        let bare = try XCTUnwrap(recorder.body)
        XCTAssertNil(bare["documentFormat"])
        XCTAssertNil(bare["metadata"])
        XCTAssertNil(bare["tags"], "an unset `tags` must not reach the wire")

        _ = try await api.getOrCreateWithAlias(options: GetOrCreateWithAliasOptions(
            alias: ledger,
            title: "Ledger",
            tags: ["ledger"],
            documentFormat: 2,
            metadata: .object(["owner": .string("finance")])
        ))
        let full = try XCTUnwrap(recorder.body)
        XCTAssertEqual(full["documentFormat"] as? Int, 2)
        XCTAssertEqual(full["tags"] as? [String], ["ledger"])
        XCTAssertEqual(
            (full["metadata"] as? [String: Any])?["owner"] as? String, "finance"
        )
        XCTAssertEqual(full["title"] as? String, "Ledger")
    }

    func testAnEmptyTagListIsNotSentAsAKey() async throws {
        // The routes refuse a key they do not read, and they read `tags` — but
        // the JS client has always dropped an empty array rather than sending
        // one, and the two clients must put the same body on the wire.
        let recorder = CallRecorder()
        recorder.response = Self.aliasResult(["created": true])
        let api = documentsAPI(recorder)

        _ = try await api.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(alias: ledger, tags: [])
        )
        XCTAssertNil(try XCTUnwrap(recorder.body)["tags"])

        _ = try await api.createWithAlias(
            options: CreateWithAliasOptions(title: "Ledger", alias: ledger, tags: [])
        )
        XCTAssertNil(try XCTUnwrap(recorder.body)["tags"])
    }

    // MARK: - Behavior 21 — the existing initializers still compile

    func testEveryPreExistingInitializerCallStillCompiles() {
        // Additive: each new parameter is defaulted, so the argument lists that
        // existed before this child are still valid calls.
        let create = CreateWithAliasOptions(title: "t", alias: ledger)
        XCTAssertNil(create.tags)
        XCTAssertNil(create.metadata)
        XCTAssertNil(create.documentFormat)
        XCTAssertEqual(create.title, "t")

        let bare = GetOrCreateWithAliasOptions(alias: ledger)
        XCTAssertNil(bare.title)
        XCTAssertNil(bare.tags)
        XCTAssertNil(bare.documentFormat)
        XCTAssertNil(bare.metadata)

        let titled = GetOrCreateWithAliasOptions(alias: ledger, title: "t")
        XCTAssertEqual(titled.title, "t")

        let tagged = GetOrCreateWithAliasOptions(
            alias: ledger, title: "t", tags: ["a"]
        )
        XCTAssertEqual(tagged.tags, ["a"])
        XCTAssertNil(tagged.documentFormat)
    }

    // MARK: - Behavior 21 — the results decode the three new members

    func testCreateWithAliasResultDecodesTheNewMembersAndStillDecodesWithout() throws {
        let full = try XCTUnwrap("""
        {"documentId":"d","title":"t","createdBy":"u","createdAt":"c","modifiedAt":"m",
         "alias":{"aliasKey":"k","scope":"user","documentId":"d","userId":"u",
                  "createdAt":"c","updatedAt":"u2"},
         "documentFormat":2,"tags":["ledger"],"metadata":{"owner":"finance"}}
        """.data(using: .utf8))
        let decoded = try JSONDecoder().decode(CreateWithAliasResult.self, from: full)
        XCTAssertEqual(decoded.documentFormat, 2)
        XCTAssertEqual(decoded.tags, ["ledger"])
        XCTAssertEqual(decoded.metadata, .object(["owner": .string("finance")]))

        // An ordinary create's 201 carries none of the three, so absent must
        // decode rather than throw.
        let without = try XCTUnwrap("""
        {"documentId":"d","title":"t","createdBy":"u","createdAt":"c","modifiedAt":"m",
         "alias":{"aliasKey":"k","scope":"user","documentId":"d","userId":"u",
                  "createdAt":"c","updatedAt":"u2"}}
        """.data(using: .utf8))
        let plain = try JSONDecoder().decode(CreateWithAliasResult.self, from: without)
        XCTAssertNil(plain.documentFormat)
        XCTAssertNil(plain.tags)
        XCTAssertNil(plain.metadata)
    }

    func testGetOrCreateWithAliasResultDecodesTheNewMembersAndStillDecodesWithout() throws {
        let full = try XCTUnwrap("""
        {"documentId":"d","alias":{"aliasKey":"k","scope":"user","documentId":"d",
          "userId":"u","createdAt":"c","updatedAt":"u2"},"created":false,
         "documentFormat":2,"tags":["ledger"],"metadata":{"owner":"finance"}}
        """.data(using: .utf8))
        let decoded = try JSONDecoder().decode(
            GetOrCreateWithAliasResult.self, from: full
        )
        XCTAssertEqual(decoded.documentFormat, 2)
        XCTAssertEqual(decoded.tags, ["ledger"])
        XCTAssertEqual(decoded.metadata, .object(["owner": .string("finance")]))
        XCTAssertFalse(decoded.created)

        // The existing branch's 200 carries exactly three keys today.
        let minimal = try XCTUnwrap("""
        {"documentId":"d","alias":{"aliasKey":"k","scope":"user","documentId":"d",
          "userId":"u","createdAt":"c","updatedAt":"u2"},"created":false}
        """.data(using: .utf8))
        let plain = try JSONDecoder().decode(
            GetOrCreateWithAliasResult.self, from: minimal
        )
        XCTAssertNil(plain.documentFormat)
        XCTAssertNil(plain.tags)
        XCTAssertNil(plain.metadata)
    }

    // MARK: - Behavior 22 / E8 — `localOnly` leaves the wire

    func testCreateDocumentOptionsEncodesNoLocalOnlyKeyWhateverItsValue() throws {
        // `localOnly` is a CLIENT-side flag: the server has never read it, and
        // the wired create path (`JsBaoClient.createDocument` →
        // `DocumentManager.commitOfflineCreate`) never sent it. Under the
        // stray-key refusal a body carrying it would now be refused outright.
        for value in [false, true] {
            let encoded = try Self.encode(
                CreateDocumentOptions(title: "t", localOnly: value)
            )
            XCTAssertNil(
                encoded["localOnly"],
                "`localOnly: \(value)` must not reach the wire"
            )
            // And the flag is still readable on the struct — only its ENCODING
            // changed, so `documents.open`'s own local-only rules are untouched.
            XCTAssertEqual(
                CreateDocumentOptions(title: "t", localOnly: value).localOnly, value
            )
        }
    }

    func testCreateDocumentOptionsStillEncodesEverythingTheServerReads() throws {
        let encoded = try Self.encode(CreateDocumentOptions(
            title: "t",
            tags: ["a"],
            localOnly: false,
            metadata: .object(["k": .string("v")]),
            documentFormat: 2
        ))
        XCTAssertEqual(encoded["title"] as? String, "t")
        XCTAssertEqual(encoded["tags"] as? [String], ["a"])
        XCTAssertEqual((encoded["metadata"] as? [String: Any])?["k"] as? String, "v")
        XCTAssertEqual(encoded["documentFormat"] as? Int, 2)
        XCTAssertNil(encoded["localOnly"])
    }

    func testE8TheIsolatedCreateFallbackBodyIsAcceptedByTheRefusingRoute() async throws {
        // `DocumentsAPI.create` with no client wired falls back to a direct
        // `POST /documents` with `CreateDocumentOptions` AS the body. That body
        // is the one place Swift could send a key the route does not read, and
        // under #3757 the route would refuse it.
        let recorder = CallRecorder()
        recorder.response = ["documentId": "d"]
        let api = documentsAPI(recorder)

        _ = try await api.create(options: CreateDocumentOptions(title: "t"))
        XCTAssertEqual(recorder.path, "/documents")
        let body = try XCTUnwrap(recorder.body)
        XCTAssertNil(body["localOnly"], "the fallback body would be refused for it")

        // Every key it DOES send is one of the route's accepted keys.
        let accepted: Set<String> = [
            "title", "documentId", "tags", "createdBy", "metadata",
            "documentFormat", "thumbnailBlobId",
        ]
        for key in body.keys {
            XCTAssertTrue(
                accepted.contains(key),
                "the isolated create fallback sends `\(key)`, which the route refuses"
            )
        }
    }

    private static func encode(_ options: CreateDocumentOptions) throws -> [String: Any] {
        let data = try JSONEncoder().encode(options)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
