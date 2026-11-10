import XCTest
@testable import JsBaoClient

/// #5363 behavior 15 (Swift) — `revokePendingInvitation` on documents, db3
/// permissions, groups and collections, on the wire.
///
/// Each sends `DELETE …/pending-invitations/{invitationId}` with its ids
/// percent-encoded and decodes `PendingInvitationRevokeResult`; a refusal is
/// thrown as the server answered it. The documents call refuses a db3 that
/// lives only on this device before any request; the db3 call waits for a
/// pending create and throws `.pendingCreate` offline.
final class PendingInvitationRevokeHermeticTests: XCTestCase {

    private static let answer = """
    {"success": true, "status": "pending_cancelled", "invitationId": "inv/1", "email": "a@x.test", "deferredCount": 2}
    """
    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        await world.tearDown()
        try await super.tearDown()
    }

    private func documents(_ transport: RecordingTransport, client: JsBaoClient? = nil) -> DocumentsAPI {
        DocumentsAPI(transport: transport, blobManager: BlobManager(logger: createLogger(level: .error, scope: "test")), client: client)
    }

    private func assertRevoked(_ result: PendingInvitationRevokeResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            result,
            PendingInvitationRevokeResult(success: true, status: "pending_cancelled", invitationId: "inv/1", email: "a@x.test", deferredCount: 2),
            file: file, line: line
        )
    }

    @available(*, deprecated)
    func testTheDocumentsCallDeletesOnTheDocumentsRoute() async throws {
        let transport = RecordingTransport(status: 200, json: Self.answer)
        assertRevoked(try await documents(transport).revokePendingInvitation(documentId: "D 1", invitationId: "inv/1"))
        XCTAssertEqual(transport.lastCall?.method, .delete)
        XCTAssertEqual(transport.lastCall?.path, "/documents/D%201/pending-invitations/inv%2F1")
        XCTAssertNil(transport.lastCall?.body)
    }

    func testTheDb3CallDeletesOnTheDb3Mount() async throws {
        let transport = RecordingTransport(status: 200, json: Self.answer)
        let sharing = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport).permissions("D 1")
        assertRevoked(try await sharing.revokePendingInvitation("inv/1"))
        XCTAssertEqual(transport.lastCall?.method, .delete)
        XCTAssertEqual(transport.lastCall?.path, "/db3/D%201/pending-invitations/inv%2F1")
    }

    func testTheGroupAndCollectionCallsDeleteOnTheirRoutes() async throws {
        let transport = RecordingTransport(status: 200, json: Self.answer)
        assertRevoked(try await GroupsAPI(transport: transport).revokePendingInvitation(groupId: "g 1", invitationId: "inv/1"))
        XCTAssertEqual(transport.lastCall?.method, .delete)
        XCTAssertEqual(transport.lastCall?.path, "/groups/g%201/pending-invitations/inv%2F1")
        assertRevoked(try await CollectionsAPI(transport: transport).revokePendingInvitation(collectionId: "c 1", invitationId: "inv/1"))
        XCTAssertEqual(transport.lastCall?.method, .delete)
        XCTAssertEqual(transport.lastCall?.path, "/collections/c%201/pending-invitations/inv%2F1")
    }

    func testARefusalIsThrownAsTheServerAnswered() async throws {
        let transport = RecordingTransport(status: 403, json: #"{"error": "Forbidden", "code": "ACCESS_DENIED"}"#)
        do {
            _ = try await GroupsAPI(transport: transport).revokePendingInvitation(groupId: "g1", invitationId: "i1")
            XCTFail("a 403 is thrown")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
    }

    @available(*, deprecated)
    func testTheDocumentsCallRefusesALocalOnlyDb3BeforeAnyRequest() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 200, json: Self.answer)
        let id = try await world.createLocalOnly(client, transport: transport).id
        let error = await db3LocalOnlyThrown {
            _ = try await documents(transport, client: client).revokePendingInvitation(documentId: id, invitationId: "i1")
        }
        XCTAssertEqual(error?.code, .db3LocalOnly)
        XCTAssertEqual(transport.calls.map(\.path).filter { $0.contains("/pending-invitations") }, [])
    }

    func testTheDb3CallWaitsForAPendingCreateAndThrowsPendingCreateOffline() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 200, json: Self.answer)
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let id = try await db3.create(title: "Offline").id
        XCTAssertTrue(client.isPendingCreate(id))
        let error = await db3LocalOnlyThrown {
            _ = try await db3.permissions(id).revokePendingInvitation("i1")
        }
        XCTAssertEqual(error?.code, .pendingCreate)
        XCTAssertEqual(transport.calls.map(\.path).filter { $0.contains("/pending-invitations") }, [])
    }
}
