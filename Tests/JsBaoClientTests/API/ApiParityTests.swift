import XCTest
@testable import JsBaoClient

/// Wire-shape tests for the API-parity pass that filled in the
/// ⛔ entries from `swift-client/docs/parity/api-methods.md`.
///
/// Each test instantiates a sub-API with a stub `makeRequest` closure
/// that records the `(method, path, body)` triple, then invokes the
/// public method under test and asserts the HTTP shape matches the
/// js-bao counterpart's wire format.
///
/// These don't hit the network — they verify that every new method
/// (a) compiles, (b) routes to the right endpoint with the right HTTP
/// verb, and (c) shapes the body to match the JS client. Integration
/// tests that actually hit the dev server are covered by the existing
/// suites and don't need duplication here.
///
/// Reference: `src/client/api/{invitationsApi,blobBucketsApi,
/// cronTriggersApi,collectionTypeConfigsApi,databaseTypeConfigsApi,
/// usersApi,databasesApi,documentsApi}.ts`.
final class ApiParityTests: XCTestCase {

    // MARK: - Recorder

    /// Captures the most recent HTTP request the stub closure was
    /// asked to make. `body` may be nil for GET/DELETE, a dict for
    /// JSON requests, or `Data` for raw uploads (we don't wire the
    /// raw closure in these tests — those paths are exercised at the
    /// integration level).
    final class CallRecorder: @unchecked Sendable {
        var method: String?
        var path: String?
        var body: Any?
        /// Optional canned response. Defaults to an empty dict so
        /// methods that decode `[String: Any]` don't crash.
        var response: Any = [String: Any]()

        func make(_ method: String, _ path: String, _ data: Any?) async throws -> Any {
            self.method = method
            self.path = path
            self.body = data
            return response
        }
    }

    /// A fully-populated `DocumentAccessRequest` wire payload — used as the
    /// nested `request` in access-request responses so a strict decode of
    /// `DocumentAccessRequestResponse` / `AccessRequestResult` succeeds.
    static func accessRequestJSON() -> [String: Any] {
        [
            "requestId": "r1", "documentId": "d1", "requesterId": "u1",
            "status": "pending", "requestedPermission": "read-write",
            "createdAt": "2024-01-01T00:00:00Z",
        ]
    }

    // MARK: - CollectionTypeConfigsAPI

    func test_collectionTypeConfigs_list_GET() async throws {
        let r = CallRecorder()
        let api = CollectionTypeConfigsAPI(makeRequest: r.make)
        r.response = [[String: Any]]()
        _ = try await api.list()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/collection-type-configs")
    }

    func test_collectionTypeConfigs_get_escapesType() async throws {
        let r = CallRecorder()
        let api = CollectionTypeConfigsAPI(makeRequest: r.make)
        r.response = [
            "appId": "app1", "collectionType": "x", "ruleSetId": "rs1",
            "createdAt": "2024-01-01T00:00:00Z", "modifiedAt": "2024-01-01T00:00:00Z",
            "createdBy": "u1",
        ]
        _ = try await api.get(collectionType: "my type/with slash")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/collection-type-configs/my%20type/with%20slash")
    }

    func test_collectionTypeConfigs_create_POSTsParams() async throws {
        let r = CallRecorder()
        let api = CollectionTypeConfigsAPI(makeRequest: r.make)
        r.response = [
            "appId": "app1", "collectionType": "x", "ruleSetId": "rs1",
            "createdAt": "2024-01-01T00:00:00Z", "modifiedAt": "2024-01-01T00:00:00Z",
            "createdBy": "u1",
        ]
        _ = try await api.create(params: CreateCollectionTypeConfigParams(collectionType: "x", ruleSetId: "rs1"))
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/collection-type-configs")
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["collectionType"] as? String, "x")
        XCTAssertEqual(body?["ruleSetId"] as? String, "rs1")
    }

    func test_collectionTypeConfigs_update_PATCH() async throws {
        let r = CallRecorder()
        let api = CollectionTypeConfigsAPI(makeRequest: r.make)
        r.response = [
            "appId": "app1", "collectionType": "x", "ruleSetId": "rs1",
            "createdAt": "2024-01-01T00:00:00Z", "modifiedAt": "2024-01-01T00:00:00Z",
            "createdBy": "u1",
        ]
        _ = try await api.update(collectionType: "x", params: UpdateCollectionTypeConfigParams(ruleSetId: .clear))
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.path, "/collection-type-configs/x")
    }

    func test_collectionTypeConfigs_delete_DELETE() async throws {
        let r = CallRecorder()
        let api = CollectionTypeConfigsAPI(makeRequest: r.make)
        r.response = ["success": true]
        _ = try await api.delete(collectionType: "x")
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(r.path, "/collection-type-configs/x")
    }

    // MARK: - DatabaseTypeConfigsAPI

    func test_databaseTypeConfigs_routes() async throws {
        let r = CallRecorder()
        let api = DatabaseTypeConfigsAPI(makeRequest: r.make)
        let configJSON: [String: Any] = [
            "appId": "app1", "databaseType": "userDB",
            "createdAt": "2024-01-01T00:00:00Z", "modifiedAt": "2024-01-01T00:00:00Z",
            "createdBy": "u1",
        ]

        r.response = [[String: Any]]()
        _ = try await api.list()
        XCTAssertEqual(r.path, "/databases/types")

        r.response = configJSON
        _ = try await api.get(databaseType: "userDB")
        XCTAssertEqual(r.path, "/databases/types/userDB")

        _ = try await api.create(params: CreateDatabaseTypeConfigParams(databaseType: "x"))
        XCTAssertEqual(r.method, "POST")

        _ = try await api.update(databaseType: "x", params: UpdateDatabaseTypeConfigParams())
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.path, "/databases/types/x")

        r.response = ["success": true]
        _ = try await api.delete(databaseType: "x")
        XCTAssertEqual(r.method, "DELETE")
    }

    // MARK: - CronTriggersAPI

    /// A fully-populated `CronTriggerInfo` wire payload — every required
    /// field present so a strict decode succeeds and a return-type
    /// regression is what fails the test.
    private func cronTriggerJSON() -> [String: Any] {
        [
            "triggerId": "abc", "triggerKey": "k", "displayName": "d",
            "cron": "* * * * *", "timezone": "UTC", "workflowKey": "w",
            "overlapPolicy": "skip", "state": "active",
            "skippedCount": 0, "firedCount": 0,
            "createdBy": "u1", "createdAt": "2024-01-01T00:00:00Z",
            "modifiedAt": "2024-01-01T00:00:00Z",
        ]
    }

    func test_cronTriggers_create_POST() async throws {
        let r = CallRecorder()
        let api = CronTriggersAPI(makeRequest: r.make)
        r.response = cronTriggerJSON()
        _ = try await api.create(params: CreateCronTriggerParams(triggerKey: "k", displayName: "d", cron: "* * * * *", workflowKey: "w"))
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/cron-triggers")
    }

    func test_cronTriggers_update_PUT() async throws {
        let r = CallRecorder()
        let api = CronTriggersAPI(makeRequest: r.make)
        r.response = cronTriggerJSON()
        _ = try await api.update(triggerId: "abc", params: UpdateCronTriggerParams(state: .paused))
        XCTAssertEqual(r.method, "PUT")
        XCTAssertEqual(r.path, "/cron-triggers/abc")
    }

    func test_cronTriggers_pause_resume_test_routes() async throws {
        let r = CallRecorder()
        let api = CronTriggersAPI(makeRequest: r.make)

        r.response = cronTriggerJSON()
        _ = try await api.pause(triggerId: "abc")
        XCTAssertEqual(r.path, "/cron-triggers/abc/pause")
        XCTAssertEqual(r.method, "POST")

        _ = try await api.resume(triggerId: "abc")
        XCTAssertEqual(r.path, "/cron-triggers/abc/resume")

        r.response = ["started": true]
        _ = try await api.test(triggerId: "abc")
        XCTAssertEqual(r.path, "/cron-triggers/abc/test")
    }

    // MARK: - InvitationsAPI

    func test_invitations_quota_GET() async throws {
        let r = CallRecorder()
        let api = InvitationsAPI(makeRequest: r.make)
        r.response = ["used": 1, "limit": 10, "remaining": 9, "unlimited": false]
        _ = try await api.quota()
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/invitations/quota")
    }

    func test_invitations_create_POSTsParams() async throws {
        let r = CallRecorder()
        let api = InvitationsAPI(makeRequest: r.make)
        r.response = [
            "invitationId": "inv1", "email": "alice@example.com", "role": "member",
            "invitedBy": "owner", "invitedAt": "2024-01-01T00:00:00Z", "accepted": false,
        ]
        _ = try await api.create(params: CreateInvitationParams(email: "alice@example.com", role: "member"))
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/invitations")
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["email"] as? String, "alice@example.com")
    }

    func test_invitations_list_buildsCursorQS() async throws {
        let r = CallRecorder()
        let api = InvitationsAPI(makeRequest: r.make)
        // Foundation's `.urlQueryAllowed` doesn't encode `=` (it's a
        // valid sub-delim inside query values, just not as a separator).
        // We assert the actual encoded form rather than the "looks safer"
        // form to pin what Swift will send on the wire.
        _ = try await api.list(limit: 25, cursor: "abc def")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/invitations?limit=25&cursor=abc%20def")
    }

    func test_invitations_accept_POSTsToken() async throws {
        let r = CallRecorder()
        let api = InvitationsAPI(makeRequest: r.make)
        r.response = [
            "status": "accepted", "invitationId": "inv1",
            "grantsResolved": ["groups": 0, "documents": 0],
        ]
        _ = try await api.accept(inviteToken: "tok-1")
        XCTAssertEqual(r.path, "/invitations/accept")
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["inviteToken"] as? String, "tok-1")
    }

    func test_invitations_listDeferredGrants_path() async throws {
        let r = CallRecorder()
        let api = InvitationsAPI(makeRequest: r.make)

        _ = try await api.listDeferredGrants(type: .document, email: nil, limit: nil)
        XCTAssertEqual(r.path, "/deferred-grants?type=document")

        _ = try await api.listDeferredGrants(type: nil, email: nil, limit: nil)
        XCTAssertEqual(r.path, "/deferred-grants")
    }

    func test_invitations_revokeDeferredGrant_DELETE_withType() async throws {
        let r = CallRecorder()
        let api = InvitationsAPI(makeRequest: r.make)
        r.response = ["status": "revoked", "deferredId": "abc"]
        _ = try await api.revokeDeferredGrant(deferredId: "abc", type: .group)
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(r.path, "/deferred-grants/abc?type=group")
    }

    // MARK: - BlobBucketsAPI (JSON paths only — raw upload/download
    // require the raw closure which is tested at the integration level)

    func test_blobBuckets_createBucket_POST() async throws {
        let r = CallRecorder()
        let api = BlobBucketsAPI(makeRequest: r.make)
        r.response = [
            "bucketId": "b1", "appId": "app1", "bucketKey": "k",
            "name": "n", "ttlTier": "permanent", "accessPolicy": "authenticated",
            "createdBy": "u1", "createdAt": "2024-01-01T00:00:00Z",
            "modifiedAt": "2024-01-01T00:00:00Z",
        ]
        _ = try await api.createBucket(params: CreateBlobBucketParams(
            bucketKey: "k", name: "n",
            ttlTier: .permanent, accessPolicy: .authenticated
        ))
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/blob-buckets")
    }

    func test_blobBuckets_listBuckets_unwrapsItems() async throws {
        let r = CallRecorder()
        let api = BlobBucketsAPI(makeRequest: r.make)
        func bucketJSON(_ id: String) -> [String: Any] {
            [
                "bucketId": id, "appId": "app1", "bucketKey": "k-\(id)",
                "name": "n", "ttlTier": "permanent", "accessPolicy": "authenticated",
                "createdBy": "u1", "createdAt": "2024-01-01T00:00:00Z",
                "modifiedAt": "2024-01-01T00:00:00Z",
            ]
        }
        r.response = ["items": [bucketJSON("b1"), bucketJSON("b2")]]
        let buckets = try await api.listBuckets()
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.first?.bucketId, "b1")
    }

    func test_blobBuckets_list_buildsQS() async throws {
        let r = CallRecorder()
        let api = BlobBucketsAPI(makeRequest: r.make)
        _ = try await api.list(bucketIdOrKey: "k", cursor: "c", limit: 10)
        XCTAssertEqual(r.path, "/blob-buckets/k/blobs?cursor=c&limit=10")
    }

    func test_blobBuckets_getMetadata_path() async throws {
        let r = CallRecorder()
        let api = BlobBucketsAPI(makeRequest: r.make)
        r.response = [
            "blobId": "b1", "bucketId": "k", "numBytes": 12, "tags": [String](),
        ]
        _ = try await api.getMetadata(bucketIdOrKey: "k", blobId: "b1")
        XCTAssertEqual(r.path, "/blob-buckets/k/blobs/b1/metadata")
    }

    func test_blobBuckets_delete_DELETE() async throws {
        let r = CallRecorder()
        let api = BlobBucketsAPI(makeRequest: r.make)
        r.response = ["deleted": true]
        _ = try await api.delete(bucketIdOrKey: "k", blobId: "b1")
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(r.path, "/blob-buckets/k/blobs/b1")
    }

    func test_blobBuckets_signedUrl_POSTwithExpires() async throws {
        let r = CallRecorder()
        let api = BlobBucketsAPI(makeRequest: r.make)
        r.response = [
            "url": "https://example.com/signed", "token": "tok",
            "expiresAt": 1735689600, "expiresInSeconds": 60,
        ]
        _ = try await api.getSignedUrl(bucketIdOrKey: "k", blobId: "b1", expiresInSeconds: 60)
        XCTAssertEqual(r.path, "/blob-buckets/k/blobs/b1/signed-url")
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["expiresInSeconds"] as? Int, 60)
    }

    // MARK: - UsersAPI new methods

    func test_users_getProfiles_POSTsIdsArray() async throws {
        let r = CallRecorder()
        let api = UsersAPI(makeRequest: r.make)
        r.response = ["profiles": [["userId": "u1", "email": "u1@example.com"]]]
        let profiles = try await api.getProfiles(userIds: ["u1", "u2"])
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/users/profiles")
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.userId, "u1")
    }

    func test_users_getProfiles_emptyArrayThrows() async {
        let r = CallRecorder()
        let api = UsersAPI(makeRequest: r.make)
        do {
            _ = try await api.getProfiles(userIds: [])
            XCTFail("expected throw on empty array")
        } catch {
            // expected
        }
    }

    func test_users_lookup_buildsQS() async throws {
        let r = CallRecorder()
        let api = UsersAPI(makeRequest: r.make)
        r.response = ["exists": false]
        _ = try await api.lookup(email: "alice@example.com")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/users/lookup?email=alice@example.com")
    }

    // MARK: - DocumentsAPI new methods

    func test_documents_revokeGroupPermission_DELETE() async throws {
        let r = CallRecorder()
        // documentManager isn't needed for the HTTP-only path; pass nil.
        // BlobManager has to be wired but we won't exercise it.
        let api = DocumentsAPI(
            makeRequest: r.make,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        r.response = ["success": true]
        _ = try await api.revokeGroupPermission(documentId: "d1", groupType: "team", groupId: "g1")
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(r.path, "/documents/d1/group-permissions/team/g1")
    }

    func test_documents_requestAccess_POSTsParams() async throws {
        let r = CallRecorder()
        let api = DocumentsAPI(
            makeRequest: r.make,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        r.response = [
            "success": true, "message": "ok",
            "request": Self.accessRequestJSON(),
        ]
        _ = try await api.requestAccess(
            documentId: "d1",
            options: RequestAccessOptions(permission: .readWrite, message: "please")
        )
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/documents/d1/access-requests")
    }

    func test_documents_approveAccessRequest_path() async throws {
        let r = CallRecorder()
        let api = DocumentsAPI(
            makeRequest: r.make,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
        r.response = [
            "success": true, "message": "ok",
            "request": Self.accessRequestJSON(),
        ]
        _ = try await api.approveAccessRequest(documentId: "d1", requestId: "r1")
        XCTAssertEqual(r.path, "/documents/d1/access-requests/r1/approve")

        _ = try await api.denyAccessRequest(documentId: "d1", requestId: "r1")
        XCTAssertEqual(r.path, "/documents/d1/access-requests/r1/deny")
    }

    // MARK: - DatabasesAPI new methods

    func test_databases_getCelContext_GET() async throws {
        let r = CallRecorder()
        let api = DatabasesAPI(makeRequest: r.make)
        r.response = ["databaseId": "db1", "celContext": ["tenantId": "t1"]]
        _ = try await api.getCelContext(databaseId: "db1")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/databases/db1/metadata")
    }

    func test_databases_updateCelContext_PATCH() async throws {
        let r = CallRecorder()
        let api = DatabasesAPI(makeRequest: r.make)
        r.response = [
            "databaseId": "db1", "title": "DB", "createdBy": "u1",
            "createdAt": "2024-01-01T00:00:00Z", "modifiedAt": "2024-01-01T00:00:00Z",
        ]
        _ = try await api.updateCelContext(databaseId: "db1", celContext: ["tenantId": "t1"])
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.path, "/databases/db1/metadata")
        XCTAssertEqual((r.body as? [String: Any])?["tenantId"] as? String, "t1")
    }

    func test_databases_addManager_PUTsPermission() async throws {
        let r = CallRecorder()
        let api = DatabasesAPI(makeRequest: r.make)
        r.response = [
            "databaseId": "db1", "userId": "u1", "permission": "manager",
            "grantedAt": "2024-01-01T00:00:00Z", "grantedBy": "owner",
        ]
        _ = try await api.addManager(databaseId: "db1", params: AddManagerParams(userId: "u1"))
        XCTAssertEqual(r.method, "PUT")
        XCTAssertEqual(r.path, "/databases/db1/permissions")
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["userId"] as? String, "u1")
        XCTAssertEqual(body?["permission"] as? String, "manager")
    }

    func test_databases_removeManager_DELETE() async throws {
        let r = CallRecorder()
        let api = DatabasesAPI(makeRequest: r.make)
        r.response = ["success": true]
        _ = try await api.removeManager(databaseId: "db1", userId: "u1")
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(r.path, "/databases/db1/permissions/u1")
    }

    func test_databases_listGroupPermissions_includeSystem_buildsQS() async throws {
        let r = CallRecorder()
        let api = DatabasesAPI(makeRequest: r.make)
        r.response = [[String: Any]]()
        _ = try await api.listGroupPermissions(databaseId: "db1", includeSystem: true)
        XCTAssertEqual(r.path, "/databases/db1/group-permissions?includeSystem=true")

        _ = try await api.listGroupPermissions(databaseId: "db1")
        XCTAssertEqual(r.path, "/databases/db1/group-permissions")
    }

    func test_databases_executeBatch_path() async throws {
        let r = CallRecorder()
        let api = DatabasesAPI(makeRequest: r.make)
        r.response = ["imported": 1, "failed": 0]
        _ = try await api.executeBatch(
            databaseId: "db1", operationName: "save",
            batch: [DatabaseBatchOperation(params: .object(["id": .string("1")]))]
        )
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/databases/db1/operations/save/batch")
        let body = r.body as? [String: Any]
        XCTAssertNotNil(body?["batch"])
    }

    func test_databases_importRows_batchesAndSumsResults() async throws {
        let r = CallRecorder()
        let api = DatabasesAPI(makeRequest: r.make)
        r.response = ["imported": 1, "failed": 0]
        let rows: [[String: JSONValue]] = [
            ["id": .string("1")], ["id": .string("2")], ["id": .string("3")],
            ["id": .string("4")], ["id": .string("5")],
        ]
        let result = try await api.importRows(
            databaseId: "db1", operationName: "save",
            rows: rows, batchSize: 2
        )
        // 5 rows / batchSize 2 → 3 batches; stub returns imported:1 each
        // call, so total is 3.
        XCTAssertEqual(result.imported, 3)
    }

    // MARK: - WorkflowsAPI options threading

    func test_workflows_start_forceRerunSerializes() async throws {
        let r = CallRecorder()
        let logger = createLogger(level: .error, scope: "test")
        let api = WorkflowsAPI(
            makeRequest: r.make,
            getConnectionId: { "conn-1" },
            logger: logger
        )
        _ = try await api.start(
            workflowKey: "wf",
            input: ["x": 1],
            options: StartWorkflowOptions(forceRerun: true)
        )
        let body = r.body as? [String: Any]
        XCTAssertEqual(body?["forceRerun"] as? Bool, true)
    }

    func test_workflows_terminate_contextDocId_appendsQS() async throws {
        let r = CallRecorder()
        let logger = createLogger(level: .error, scope: "test")
        let api = WorkflowsAPI(
            makeRequest: r.make,
            getConnectionId: { "conn-1" },
            logger: logger
        )
        _ = try await api.terminate(workflowKey: "wf", runKey: "rk", contextDocId: "doc-1")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/workflows/wf/instances/rk/terminate?contextDocId=doc-1")
    }

    func test_workflows_listStepRuns_path() async throws {
        let r = CallRecorder()
        let logger = createLogger(level: .error, scope: "test")
        let api = WorkflowsAPI(
            makeRequest: r.make,
            getConnectionId: { "conn-1" },
            logger: logger
        )
        _ = try await api.listStepRuns(runId: "run-1")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/workflows/runs/run-1/steps")
    }

    func test_workflows_listRuns_forwardAndContextDocId() async throws {
        let r = CallRecorder()
        let logger = createLogger(level: .error, scope: "test")
        let api = WorkflowsAPI(
            makeRequest: r.make,
            getConnectionId: { "conn-1" },
            logger: logger
        )
        _ = try await api.listRuns(options: ListWorkflowRunsOptions(
            forward: false,
            contextDocId: "doc-1"
        ))
        XCTAssertEqual(r.path, "/workflows/runs?forward=false&contextDocId=doc-1")
    }
}
