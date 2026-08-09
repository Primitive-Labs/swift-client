import Foundation
import XCTest
@testable import JsBaoClient

/// Wire-shape tests for the second API-parity pass (P1 + P2 gaps
/// identified by the source-level audit on branch
/// `swift-events-wire-polish-may-20`).
///
/// Follows the same `CallRecorder` pattern as `ApiParityTests`:
/// instantiate each sub-API with a stub `Transport`, invoke the
/// new method, assert verb + path + body shape against the js-bao
/// counterpart.
final class ApiParityRound2Tests: XCTestCase {

    /// Records the last request and replies with a scripted body. The
    /// sub-APIs speak bytes through `Transport`, while the assertions below
    /// are written against the `JSONSerialization` graph, so the recorder
    /// converts in both directions.
    final class CallRecorder: Transport, @unchecked Sendable {
        private let lock = NSLock()
        private var lastMethod: HTTPMethod?
        private var lastPath: String?
        private var lastBody: Data?
        private var cannedResponse: Any = [String: Any]()

        var method: String? { lock.withLock { lastMethod?.rawValue } }
        var path: String? { lock.withLock { lastPath } }
        var body: Any? {
            guard let data = lock.withLock({ lastBody }) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
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

    // MARK: - MeAPI new list methods

    func test_me_sharedDocuments_buildsQS() async throws {
        let r = CallRecorder()
        let api = MeAPI(transport: r)

        _ = try await api.sharedDocuments()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/me/shared-documents")

        _ = try await api.sharedDocuments(cursor: "abc", limit: 50, tag: "starred")
        XCTAssertEqual(r.path, "/me/shared-documents?cursor=abc&limit=50&tag=starred")
    }

    func test_me_ownedDocuments_buildsQS() async throws {
        let r = CallRecorder()
        let api = MeAPI(transport: r)

        _ = try await api.ownedDocuments()
        XCTAssertEqual(r.path, "/me/owned-documents")

        // JS query order: includeRoot, limit, cursor, tag, forward.
        _ = try await api.ownedDocuments(cursor: "next", limit: 10)
        XCTAssertEqual(r.path, "/me/owned-documents?limit=10&cursor=next")
    }

    /// The widened option set (issue #628 parity): `includeRoot` and
    /// `forward` thread into the query string in JS order, while `localOnly`
    /// / `refreshFromServer == false` short-circuit to the local cache (no
    /// server call). Mirrors js-bao `_listImpl`.
    func test_me_ownedDocuments_optionsThreadIntoQS() async throws {
        let r = CallRecorder()
        let api = MeAPI(transport: r)

        _ = try await api.ownedDocuments(
            cursor: "c1",
            limit: 5,
            tag: "starred",
            options: MeOwnedDocumentsOptions(includeRoot: true, forward: true)
        )
        XCTAssertEqual(
            r.path,
            "/me/owned-documents?includeRoot=true&limit=5&cursor=c1&tag=starred&forward=true"
        )
    }

    /// `localOnly` (and `refreshFromServer: false`) must NOT hit the network.
    func test_me_ownedDocuments_localOnlySkipsServer() async throws {
        let r = CallRecorder()
        let api = MeAPI(transport: r)

        _ = try await api.ownedDocuments(options: MeOwnedDocumentsOptions(localOnly: true))
        XCTAssertNil(r.path, "localOnly must not issue a server request")

        _ = try await api.ownedDocuments(options: MeOwnedDocumentsOptions(refreshFromServer: false))
        XCTAssertNil(r.path, "refreshFromServer: false must not issue a server request")
    }

    /// `ownedDocumentsPage` returns the `{ items, cursor }` envelope, mirroring
    /// JS's `ownedDocuments({ returnPage: true })` overload.
    func test_me_ownedDocumentsPage_returnsCursor() async throws {
        let r = CallRecorder()
        r.response = ["items": [["documentId": "d1"]], "cursor": "next-page"]
        let api = MeAPI(transport: r)

        let page = try await api.ownedDocumentsPage(limit: 1)
        XCTAssertEqual(page.cursor, "next-page")
        XCTAssertEqual(page.items.map { $0.documentId }, ["d1"])
    }

    // MARK: - DocumentsAPI getOrCreateWithAlias

    func test_documents_getOrCreateWithAlias_POST() async throws {
        let r = CallRecorder()
        let api = DocumentsAPI(
            transport: r,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        r.response = [
            "documentId": "doc1",
            "created": true,
            "alias": ["aliasKey": "notes", "scope": "user", "documentId": "doc1"],
        ]
        _ = try await api.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: "notes"),
                title: "Notes",
                tags: ["pinned"]
            )
        )
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/documents/get-or-create-with-alias")
        let body = r.body as? [String: Any]
        let alias = body?["alias"] as? [String: Any]
        XCTAssertEqual(alias?["scope"] as? String, "user")
        XCTAssertEqual(alias?["aliasKey"] as? String, "notes")
        XCTAssertEqual(body?["title"] as? String, "Notes")
        XCTAssertEqual(body?["tags"] as? [String], ["pinned"])
    }

    func test_documents_getOrCreateWithAlias_serializesUserScope() async throws {
        // The typed `DocumentAliasScope` enum makes "bad scope" values
        // (e.g. the JS test's `"bogus"`) unrepresentable at compile time —
        // the type system now enforces what this test used to assert at
        // runtime. We instead pin that the `.user` scope is serialized
        // correctly onto the wire.
        let r = CallRecorder()
        let api = DocumentsAPI(
            transport: r,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        r.response = [
            "documentId": "doc1",
            "created": true,
            "alias": ["aliasKey": "x", "scope": "user", "documentId": "doc1"],
        ]
        _ = try await api.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: "x")
            )
        )
        let alias = (r.body as? [String: Any])?["alias"] as? [String: Any]
        XCTAssertEqual(alias?["scope"] as? String, "user")
        XCTAssertEqual(alias?["aliasKey"] as? String, "x")
    }

    func test_documents_getOrCreateWithAlias_forwardsAliasKey() async throws {
        // The typed Swift surface forwards a non-empty `aliasKey` verbatim.
        let r = CallRecorder()
        let api = DocumentsAPI(
            transport: r,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        r.response = [
            "documentId": "doc1",
            "created": true,
            "alias": ["aliasKey": "notes", "scope": "user", "documentId": "doc1"],
        ]
        _ = try await api.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: "notes")
            )
        )
        let alias = (r.body as? [String: Any])?["alias"] as? [String: Any]
        XCTAssertEqual(alias?["aliasKey"] as? String, "notes")
    }

    func test_documents_getOrCreateWithAlias_requiresAliasKey() async {
        // Parity with JS (`documentsApi.ts:583-584`): an empty `aliasKey`
        // throws client-side before any request is made.
        let r = CallRecorder()
        let api = DocumentsAPI(
            transport: r,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        do {
            _ = try await api.getOrCreateWithAlias(
                options: GetOrCreateWithAliasOptions(
                    alias: AliasRef(scope: .user, aliasKey: "")
                )
            )
            XCTFail("expected an error for empty aliasKey")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertNil(r.method, "no request should be sent when aliasKey is empty")
        } catch {
            XCTFail("expected JsBaoError, got \(error)")
        }
    }

    func test_documents_createWithAlias_requiresAliasKey() async {
        // Parity with JS (`documentsApi.ts:532-533`).
        let r = CallRecorder()
        let api = DocumentsAPI(
            transport: r,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        do {
            _ = try await api.createWithAlias(
                options: CreateWithAliasOptions(
                    title: "Notes",
                    alias: AliasRef(scope: .user, aliasKey: "")
                )
            )
            XCTFail("expected an error for empty aliasKey")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertNil(r.method, "no request should be sent when aliasKey is empty")
        } catch {
            XCTFail("expected JsBaoError, got \(error)")
        }
    }

    // MARK: - CollectionsAPI new list helpers

    /// #2367 removed `CollectionsAPI.init(makeRequest:)`, so this now builds
    /// the API on the typed transport spine. The route assertions are what the
    /// test is for and are unchanged.
    func test_collections_listAll_GET() async throws {
        let r = CallRecorder()
        let api = CollectionsAPI(transport: r)
        r.response = ["items": [[String: Any]]()]
        _ = try await api.listAll()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/admin/collections")

        _ = try await api.listAll(limit: 25, cursor: "tok")
        XCTAssertEqual(r.path, "/admin/collections?limit=25&cursor=tok")
    }

    /// #2367 removed `CollectionsAPI.init(makeRequest:)`, so this now builds
    /// the API on the typed transport spine. The route and unwrap assertions
    /// are what the test is for and are unchanged.
    func test_collections_listPendingInvitations_unwrapsItems() async throws {
        let r = CallRecorder()
        let api = CollectionsAPI(transport: r)
        func invitationJSON(_ id: String) -> [String: Any] {
            [
                "email": "\(id)@example.com", "permission": "reader",
                "invitationId": id, "createdAt": "2024-01-01T00:00:00Z",
                "expiresAt": "2024-01-08T00:00:00Z",
            ]
        }
        r.response = ["items": [invitationJSON("i1"), invitationJSON("i2")]]
        let invitations = try await api.listPendingInvitations(collectionId: "c1")
        XCTAssertEqual(r.path, "/collections/c1/pending-invitations")
        XCTAssertEqual(invitations.count, 2)
        XCTAssertEqual(invitations.first?.invitationId, "i1")
    }

    // MARK: - GroupsAPI new list helpers

    func test_groups_listDatabases_GET() async throws {
        let r = CallRecorder()
        let api = GroupsAPI(transport: r)
        r.response = [[String: Any]]()
        _ = try await api.listDatabases(groupType: "team", groupId: "g1")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/groups/team/g1/databases")
    }

    func test_groups_listPendingInvitations_unwrapsItems() async throws {
        let r = CallRecorder()
        let api = GroupsAPI(transport: r)
        r.response = ["items": [[
            "invitationId": "i1",
            "email": "i1@example.com",
            "role": "member",
            "deferredId": "01JQ0GRANT0000000000000001",
            "createdAt": "2024-01-01T00:00:00Z",
            "expiresAt": "2024-01-08T00:00:00Z",
        ]]]
        let invitations = try await api.listPendingInvitations(
            groupType: "team", groupId: "g1"
        )
        XCTAssertEqual(r.path, "/groups/team/g1/pending-invitations")
        XCTAssertEqual(invitations.count, 1)
    }

    // MARK: - AnalyticsContext

    /// #2367 removed the synchronous `AnalyticsContext.logEvent(_:)` method
    /// (the `logEvent:` closure the context is built with stays). A context
    /// with no async logger falls back to that closure, so `logEventAsync`
    /// still delivers the event to it — which is what this test checks.
    func test_analyticsContext_logsEventThroughClosure() async {
        let captured = LockedBox([[String: JSONValue]]())
        let ctx = AnalyticsContext(
            logEvent: { event in
                captured.withValue { $0.append(event) }
            }
        )
        await ctx.logEventAsync(["action": "click", "feature": "cta"])
        XCTAssertEqual(captured.value.count, 1)
        XCTAssertEqual(captured.value.first?["action"], JSONValue.string("click"))
        XCTAssertTrue(ctx.isEnabled())
    }

    func test_analyticsContext_isEnabledHonorsPhase() {
        let ctx = AnalyticsContext(
            logEvent: { _ in },
            isEnabled: { phase in phase == "success" }
        )
        XCTAssertFalse(ctx.isEnabled())
        XCTAssertFalse(ctx.isEnabled("start"))
        XCTAssertTrue(ctx.isEnabled("success"))
    }
}
