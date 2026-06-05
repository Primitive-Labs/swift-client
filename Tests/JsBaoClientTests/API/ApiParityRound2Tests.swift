import XCTest
@testable import JsBaoClient

/// Wire-shape tests for the second API-parity pass (P1 + P2 gaps
/// identified by the source-level audit on branch
/// `swift-events-wire-polish-may-20`).
///
/// Follows the same `CallRecorder` pattern as `ApiParityTests`:
/// instantiate each sub-API with a stub `makeRequest`, invoke the
/// new method, assert verb + path + body shape against the js-bao
/// counterpart.
final class ApiParityRound2Tests: XCTestCase {

    final class CallRecorder: @unchecked Sendable {
        var method: String?
        var path: String?
        var body: Any?
        var response: Any = [String: Any]()
        func make(_ method: String, _ path: String, _ data: Any?) async throws -> Any {
            self.method = method
            self.path = path
            self.body = data
            return response
        }
    }

    // MARK: - MeAPI new list methods

    func test_me_sharedDocuments_buildsQS() async throws {
        let r = CallRecorder()
        let api = MeAPI(makeRequest: r.make)

        _ = try await api.sharedDocuments()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/me/shared-documents")

        _ = try await api.sharedDocuments(cursor: "abc", limit: 50, tag: "starred")
        XCTAssertEqual(r.path, "/me/shared-documents?cursor=abc&limit=50&tag=starred")
    }

    func test_me_ownedDocuments_buildsQS() async throws {
        let r = CallRecorder()
        let api = MeAPI(makeRequest: r.make)

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
        let api = MeAPI(makeRequest: r.make)

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
        r.path = nil
        let api = MeAPI(makeRequest: r.make)

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
        let api = MeAPI(makeRequest: r.make)

        let page = try await api.ownedDocumentsPage(limit: 1)
        XCTAssertEqual(page.cursor, "next-page")
        XCTAssertEqual(page.items.map { $0.documentId }, ["d1"])
    }

    // MARK: - DocumentsAPI getOrCreateWithAlias

    func test_documents_getOrCreateWithAlias_POST() async throws {
        let r = CallRecorder()
        let api = DocumentsAPI(
            makeRequest: r.make,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        r.response = [
            "documentId": "doc1",
            "created": true,
            "alias": ["aliasKey": "notes", "scope": "app", "documentId": "doc1"],
        ]
        _ = try await api.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .app, aliasKey: "notes"),
                title: "Notes",
                tags: ["pinned"]
            )
        )
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/documents/get-or-create-with-alias")
        let body = r.body as? [String: Any]
        let alias = body?["alias"] as? [String: Any]
        XCTAssertEqual(alias?["scope"] as? String, "app")
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
            makeRequest: r.make,
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
            makeRequest: r.make,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        r.response = [
            "documentId": "doc1",
            "created": true,
            "alias": ["aliasKey": "notes", "scope": "app", "documentId": "doc1"],
        ]
        _ = try await api.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .app, aliasKey: "notes")
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
            makeRequest: r.make,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        do {
            _ = try await api.getOrCreateWithAlias(
                options: GetOrCreateWithAliasOptions(
                    alias: AliasRef(scope: .app, aliasKey: "")
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
            makeRequest: r.make,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        do {
            _ = try await api.createWithAlias(
                options: CreateWithAliasOptions(
                    title: "Notes",
                    alias: AliasRef(scope: .app, aliasKey: "")
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

    func test_collections_listAll_GET() async throws {
        let r = CallRecorder()
        let api = CollectionsAPI(makeRequest: r.make)
        r.response = ["items": [[String: Any]]()]
        _ = try await api.listAll()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/admin/collections")

        _ = try await api.listAll(limit: 25, cursor: "tok")
        XCTAssertEqual(r.path, "/admin/collections?limit=25&cursor=tok")
    }

    func test_collections_listPendingInvitations_unwrapsItems() async throws {
        let r = CallRecorder()
        let api = CollectionsAPI(makeRequest: r.make)
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
        let api = GroupsAPI(makeRequest: r.make)
        r.response = [[String: Any]]()
        _ = try await api.listDatabases(groupType: "team", groupId: "g1")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/groups/team/g1/databases")
    }

    func test_groups_listPendingInvitations_unwrapsItems() async throws {
        let r = CallRecorder()
        let api = GroupsAPI(makeRequest: r.make)
        r.response = ["items": [[
            "invitationId": "i1",
            "email": "i1@example.com",
            "role": "member",
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

    func test_analyticsContext_logsEventThroughClosure() {
        var captured: [[String: Any]] = []
        let ctx = AnalyticsContext(
            logEvent: { event in
                captured.append(event)
            }
        )
        ctx.logEvent(["action": "click", "feature": "cta"])
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?["action"] as? String, "click")
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
