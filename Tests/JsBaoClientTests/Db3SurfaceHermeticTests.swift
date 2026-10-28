import XCTest
@testable import JsBaoClient

/// #4701 behaviour 11 — the Swift `client.db3` vocabulary is the JS client's,
/// read from the JS source by repository path: the six `client.db3` codes of
/// `src/client/errors.ts` and js-bao's `DB3_NOT_RESIDENT`, the seven `db3:*`
/// event keys of `src/client/internal/db3Lifecycle.ts`, and the `Db3Phase` and
/// permission names of `src/client/api/db3Api.ts`. Every new payload type is
/// in `allJsBaoEventPayloadTypes` once, under its own key.
final class Db3SurfaceHermeticTests: XCTestCase {

    private func jsSource(_ path: String) throws -> String {
        guard ClientSourceText.isMonorepoCheckout else {
            throw XCTSkip("the JS client source is not present (published SwiftPM mirror)")
        }
        return try ClientSourceText.repoFile(path)
    }

    /// Every double-quoted string in `text`.
    private func quoted(_ text: String) -> [String] {
        var out: [String] = []
        var current: String?
        for ch in text {
            if ch == "\"" {
                if let value = current { out.append(value); current = nil } else { current = "" }
            } else if current != nil {
                current?.append(ch)
            }
        }
        return out
    }

    func testTheCodesAreTheJsClientsStringsVerbatim() throws {
        let errors = try jsSource("src/client/errors.ts")
        let union = try ClientSourceText.slice(errors, from: "export type JsBaoErrorCode", to: ";\n")
        let jsCodes = quoted(union).filter { $0.hasPrefix("DB3_") || $0 == "NOT_A_DB3" }
        XCTAssertEqual(
            Set(jsCodes), ["DB3_READY_TIMEOUT", "DB3_ACCESS_REFUSED", "DB3_PENDING_WRITES", "DB3_HELD", "DB3_DISPOSED", "NOT_A_DB3", "DB3_SYNC_OFF", "DB3_CLIENT_OUTDATED", "DB3_DECLARATION_REFUSED_TYPED", "DB3_MODEL_NOT_DECLARED"],
            "the JS union parse: \(jsCodes)"
        )
        let scope = try jsSource("packages/js-bao/src/models/db3QueryScope.ts")
        let notResident = try ClientSourceText.slice(scope, from: "class Db3NotResidentError", to: "constructor")
        XCTAssertTrue(notResident.contains("\"DB3_NOT_RESIDENT\""))
        let swift: [JsBaoErrorCode] = [
            .db3ReadyTimeout, .db3AccessRefused, .db3PendingWrites, .db3Held, .db3Disposed, .notADb3, .db3NotResident,
            .db3SyncOff, .db3ClientOutdated, .db3DeclarationRefusedTyped, .db3ModelNotDeclared,
        ]
        XCTAssertEqual(Set(swift.map(\.rawValue)), Set(jsCodes + ["DB3_NOT_RESIDENT"]))
    }

    func testTheEventKeysAreTheJsClientsAndEachHasOnePayloadType() throws {
        let lifecycle = try jsSource("src/client/internal/db3Lifecycle.ts")
        let events = try ClientSourceText.slice(lifecycle, from: "export interface Db3LifecycleEvents {", to: "\n}")
        // Each line's key is its first quoted string (a payload type may index
        // `Db3SubscriptionEvents["ready"]`).
        let jsKeys = events.split(separator: "\n").compactMap { quoted(String($0)).first }
        XCTAssertEqual(jsKeys.count, 7, "\(jsKeys)")
        let db3Types: [any JsBaoEventPayload.Type] = [
            Db3StateEvent.self, Db3ReadyEvent.self, Db3RowsEvent.self, Db3WriteRefusedEvent.self,
            Db3EvictedEvent.self, Db3GoneEvent.self, Db3ErrorEvent.self,
        ]
        XCTAssertEqual(db3Types.map { $0.eventKey.rawValue }, jsKeys)
        let listed = allJsBaoEventPayloadTypes.map { String(describing: $0) }
        for type in db3Types {
            XCTAssertEqual(listed.filter { $0 == String(describing: type) }.count, 1, "\(type) in allJsBaoEventPayloadTypes")
        }
        XCTAssertFalse(db3Types.contains { $0.isReplayable }, "a db3 event is about one db3: it keeps no latest value")
    }

    func testThePhaseAndPermissionNamesAreTheJsClients() throws {
        let api = try jsSource("src/client/api/db3Api.ts")
        let phases = try ClientSourceText.slice(api, from: "export type Db3Phase =", to: ";")
        XCTAssertEqual(
            [Db3Phase.idle, .opening, .loading, .catchingUp, .live, .reconnecting, .gone].map(\.rawValue), quoted(phases)
        )
        let permission = try ClientSourceText.slice(api, from: "permission: \"reader\"", to: ";")
        XCTAssertEqual(
            [Db3Permission.reader, .readWrite, .owner, .admin, .refused].map(\.rawValue),
            ["reader"] + quoted(permission)
        )
        XCTAssertEqual(Db3RowsEvent.Origin.allCases.map(\.rawValue), ["local", "remote", "sibling"])
        XCTAssertEqual(Db3EvictedEvent.Reason.allCases.map(\.rawValue), ["explicit", "retention"])
        XCTAssertEqual(Db3GoneEvent(id: "d").code, "DB3_ACCESS_REFUSED")
        XCTAssertEqual(Db3GoneEvent(id: "d").reason, .permission)
        XCTAssertEqual(Db3SubscribeOptions().readyTimeout, 30)
        XCTAssertFalse(Db3EvictOptions().force)
    }

    /// #4806 (R3g, add-only): the gone reasons are the JS union's, `sync-off` included.
    func testTheGoneReasonsAreTheJsClients() throws {
        let api = try jsSource("src/client/api/db3Api.ts")
        let event = try ClientSourceText.slice(api, from: "export interface Db3GoneEvent", to: "}")
        let reasons = try ClientSourceText.slice(event, from: "reason:", to: ";")
        let swift: [Db3GoneEvent.Reason] = [.permission, .syncOff, .clientOutdated]
        XCTAssertEqual(Set(swift.map(\.rawValue)), Set(quoted(reasons)), "the JS union parse: \(quoted(reasons))")
        XCTAssertEqual(Db3GoneEvent(id: "d", reason: .syncOff).code, "DB3_SYNC_OFF")
        XCTAssertEqual(Db3GoneEvent(id: "d", reason: .syncOff).code, JsBaoErrorCode.db3SyncOff.rawValue)
        XCTAssertEqual(Db3GoneEvent(id: "d", reason: .clientOutdated).code, "DB3_CLIENT_OUTDATED")
    }

    /// #4806 (R3g, add-only): `client.db3`'s lifecycle calls.
    func testTheDb3NamespaceHasTheLifecycleCalls() {
        let api = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: RecordingTransport(status: 200))
        let _: (String, String?, Bool?, String?, [String]?, JSONValue?) async throws -> Db3Info = api.create(title:type:sync:custodian:tags:metadata:)
        let _: (String) async throws -> Db3Info = api.get(_:)
        let _: (String) async throws -> SuccessResult = api.delete(_:)
        let _: (PaginationOptions) async throws -> PaginatedResult<Db3Info> = api.listMine(options:)
        let _: (Db3GetOrCreateWithAliasOptions) async throws -> Db3GetOrCreateWithAliasResult = api.getOrCreateWithAlias(_:)
        let _: (String) async throws -> Db3SyncState = api.getSync(_:)
        let _: (String, Bool) async throws -> Db3SyncChange = api.setSync(_:sync:)
        let _: (String) async throws -> Db3TypeState = api.getType(_:)
        let _: (String, String) async throws -> Db3TypeChange = api.setType(_:type:)
        let _: (String) async throws -> Db3AppAccess = api.getAppAccess(_:)
        let _: (String, Db3AppAccessLevel?) async throws -> Db3AppAccessChange = api.setAppAccess(_:level:)
        let _: (String, String) async throws -> Db3Info = api.transfer(_:to:)
        let _: (String, Bool) async throws -> Db3OwnerRowChange = api.setOwnerRow(_:present:)
        XCTAssertEqual(DocumentAccessSource.app.rawValue, "app")
        // #4889 (R8b, add-only): the bulk load over the db3 mounts.
        let _: ([DocumentIngestRow], DocumentIngestBuildOptions) throws -> [DocumentIngestChunk] = api.ingests.buildChunks(rows:options:)
        let _: (String, DocumentIngestCreateOptions?) async throws -> DocumentIngestSession = api.ingests.create(db3Id:options:)
        let _: (String, String, DocumentIngestChunk) async throws -> DocumentIngestChunkUploadResult = api.ingests.uploadChunk(db3Id:sessionId:chunk:)
        let _: (String, String) async throws -> DocumentIngestSession = api.ingests.commit(db3Id:sessionId:)
        let _: (String, String) async throws -> DocumentIngestSession = api.ingests.abort(db3Id:sessionId:)
        let _: (String, String) async throws -> DocumentIngestSession = api.ingests.get(db3Id:sessionId:)
        let _: (String, Int?, String?) async throws -> DocumentIngestPage = api.ingests.list(db3Id:limit:cursor:)
    }

    /// #4943 (R3g, add-only): a db3's sharing, as `client.db3.permissions(_:)`.
    func testTheDb3NamespaceHasPermissions() {
        let api = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: RecordingTransport(status: 200))
        let _: (String) -> Db3PermissionsAPI = api.permissions(_:)
        let sharing = api.permissions("d")
        let _: () async throws -> [DocumentPermissionEntry] = sharing.list
        let _: (UpdatePermissionsData) async throws -> PermissionUpdateResult = sharing.set(_:)
        let _: (DocumentPermissionTarget) async throws -> Void = sharing.remove(_:)
        let _: () async throws -> [PendingInvitationEntry] = sharing.listPendingInvitations
        let _: (Bool) async throws -> [DocumentGroupPermissionEntry] = sharing.listGroups(includeSystem:)
        let _: (GrantGroupPermissionParams) async throws -> DocumentGroupPermissionEntry = sharing.grantGroup(_:)
        let _: (String) async throws -> SuccessResult = sharing.revokeGroup(_:)
        let _: () async throws -> LinkAccessResult = sharing.getLinkAccess
        let _: (DocumentLinkAccessLevel) async throws -> LinkAccessResult = sharing.setLinkAccess(_:)
        let _: () async throws -> LinkAccessResult = sharing.clearLinkAccess
        let _: (RequestAccessOptions) async throws -> DocumentAccessRequestResponse = sharing.requestAccess(_:)
        let _: () async throws -> [DocumentAccessRequest] = sharing.listAccessRequests
        let _: (String, ApproveAccessRequestOptions?) async throws -> AccessRequestResult = sharing.approveAccessRequest(_:options:)
        let _: (String, DenyAccessRequestOptions?) async throws -> AccessRequestResult = sharing.denyAccessRequest(_:options:)
    }

    /// #4943 (R3g, add-only): a db3's blobs, as `client.db3.blobs(_:)`, with
    /// the method set of `DocumentBlobContext`, which keeps its own.
    func testTheDb3NamespaceHasBlobs() {
        let api = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: RecordingTransport(status: 200))
        let _: (String) -> Db3BlobContext = api.blobs(_:)
        let blobs = api.blobs("d")
        let _: (Data, BlobUploadSourceOptions) async throws -> BlobUploadResult = blobs.upload(data:options:)
        let _: (Data, BlobUploadSourceOptions) async throws -> BlobUploadFileResult = blobs.uploadFile(data:options:)
        let _: (Int?, String?) async throws -> DocumentBlobListResult = blobs.list(limit:cursor:)
        let _: (String) async throws -> BlobInfo = blobs.get(blobId:)
        let _: (String, BlobDisposition?, String?) -> String = blobs.downloadUrl(blobId:disposition:attachmentFilename:)
        let _: (String) async throws -> BlobDeleteResult = blobs.delete(blobId:)
        let _: (String, Bool, BlobDisposition?) async throws -> Data = blobs.read(blobId:force:disposition:)
        let _: (String, String.Type, Bool, BlobDisposition?) async throws -> String = blobs.read(blobId:as:force:disposition:)
        let _: (String, [String].Type, Bool, BlobDisposition?) async throws -> [String] = blobs.read(blobId:as:force:disposition:)
        let _: ([String], Int) async -> Void = blobs.prefetch(blobIds:concurrency:)
        let _: () async -> [BlobUploadStatus] = blobs.uploadsAsync
        let _: (String) async -> Bool = blobs.pauseUploadAsync(blobId:)
        let _: (String) async -> Bool = blobs.resumeUploadAsync(blobId:)
        let _: () async -> Void = blobs.pauseAllAsync
        let _: () async -> Void = blobs.resumeAllAsync

        let documents = DocumentBlobContext(
            documentId: "d", transport: RecordingTransport(status: 200),
            blobManager: BlobManager(logger: createLogger(level: .error, scope: "test"))
        )
        let _: (Data, BlobUploadSourceOptions) async throws -> BlobUploadResult = documents.upload(data:options:)
        let _: (Data, BlobUploadSourceOptions) async throws -> BlobUploadFileResult = documents.uploadFile(data:options:)
        let _: (Int?, String?) async throws -> DocumentBlobListResult = documents.list(limit:cursor:)
        let _: (String) async throws -> BlobInfo = documents.get(blobId:)
        let _: (String, BlobDisposition?, String?) -> String = documents.downloadUrl(blobId:disposition:attachmentFilename:)
        let _: (String) async throws -> BlobDeleteResult = documents.delete(blobId:)
        let _: (String, Bool, BlobDisposition?) async throws -> Data = documents.read(blobId:force:disposition:)
        let _: ([String], Int) async -> Void = documents.prefetch(blobIds:concurrency:)
        let _: () async -> [BlobUploadStatus] = documents.uploadsAsync
        let _: (String) async -> Bool = documents.pauseUploadAsync(blobId:)
        let _: (String) async -> Bool = documents.resumeUploadAsync(blobId:)
        let _: () async -> Void = documents.pauseAllAsync
        let _: () async -> Void = documents.resumeAllAsync
    }

    func testTheClientHasADb3Namespace() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-surface-4701",
            token: makeTestJwt(userId: "db3-surface-user"), offline: true, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        let api: Db3API = client.db3
        let state = try await api.state("01JD4701SURFACEXXXXXXXXXXX")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.subscribed)
        await client.destroy()
    }
}
