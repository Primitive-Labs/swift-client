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

        _ = try await api.ownedDocuments(cursor: "next", limit: 10)
        XCTAssertEqual(r.path, "/me/owned-documents?cursor=next&limit=10")
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
        _ = try await api.getOrCreateWithAlias(
            alias: ["scope": "app", "aliasKey": "notes"],
            title: "Notes",
            tags: ["pinned"]
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

    func test_documents_getOrCreateWithAlias_rejectsBadScope() async {
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
                alias: ["scope": "bogus", "aliasKey": "x"]
            )
            XCTFail("expected throw on bad scope")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        } catch {
            XCTFail("expected JsBaoError, got \(error)")
        }
    }

    func test_documents_getOrCreateWithAlias_requiresAliasKey() async {
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
                alias: ["scope": "app", "aliasKey": ""]
            )
            XCTFail("expected throw on empty aliasKey")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        } catch {
            XCTFail("expected JsBaoError, got \(error)")
        }
    }

    // MARK: - CollectionsAPI new list helpers

    func test_collections_listAll_GET() async throws {
        let r = CallRecorder()
        let api = CollectionsAPI(makeRequest: r.make)
        _ = try await api.listAll()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/admin/collections")

        _ = try await api.listAll(limit: 25, cursor: "tok")
        XCTAssertEqual(r.path, "/admin/collections?limit=25&cursor=tok")
    }

    func test_collections_listPendingInvitations_unwrapsItems() async throws {
        let r = CallRecorder()
        let api = CollectionsAPI(makeRequest: r.make)
        r.response = ["items": [["invitationId": "i1"], ["invitationId": "i2"]]]
        let invitations = try await api.listPendingInvitations(collectionId: "c1")
        XCTAssertEqual(r.path, "/collections/c1/pending-invitations")
        XCTAssertEqual(invitations.count, 2)
        XCTAssertEqual(invitations.first?["invitationId"] as? String, "i1")
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
        r.response = ["items": [["invitationId": "i1"]]]
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
