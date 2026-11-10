import XCTest
@testable import JsBaoClient

/// #5356 — `client.db3.schema(_:)` and `client.db3.validateAccess(_:userId:)`
/// are the db3 successors of the deprecated `client.documents.schema(_:)` and
/// `client.documents.validateAccess(documentId:userId:)`: each asks the db3
/// twin of its counterpart's route and answers what the counterpart answers,
/// refusals included, with no server.
@available(*, deprecated)
final class Db3SchemaAccessEntryHermeticTests: XCTestCase {

    private static let db3Id = "01JD5356DB3SCHEMAACCESSXXX"
    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        await world.tearDown()
        try await super.tearDown()
    }

    /// `client.db3` and `client.documents` over one scripted transport, on a
    /// client with networking stopped.
    private func apis(_ transport: RecordingTransport) async throws -> (JsBaoClient, Db3API, DocumentsAPI) {
        let client = try await world.client(directory: world.directory())
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let documents = DocumentsAPI(
            transport: transport, blobManager: BlobManager(logger: createLogger(level: .error, scope: "test"), transport: transport),
            documentManager: client.documentManager, client: client
        )
        return (client, db3, documents)
    }

    private static let schemaAnswer = """
    {"schema": {"models": {"Note": {"fields": {"title": {"type": "string"}},
     "observed": {"fields": {"title": {"kinds": ["string"]}}}}}},
     "modelNames": ["Note"], "modelCount": 1, "tableModels": ["Note"]}
    """

    private static let accessAnswer = """
    {"success": true, "hasAccess": true, "permission": "read-write", "accessSource": "app", "appRole": "member"}
    """

    func testSchemaAsksTheDb3RouteAndAnswersWhatDocumentsSchemaAnswers() async throws {
        let transport = RecordingTransport(json: Self.schemaAnswer)
        let (_, db3, documents) = try await apis(transport)
        let viaDb3 = try await db3.schema(Self.db3Id)
        let call = try XCTUnwrap(transport.lastCall(to: "/db3/\(Self.db3Id)/schema"))
        XCTAssertEqual(call.method, .get)
        XCTAssertNil(call.body)
        let viaDocuments = try await documents.schema(Self.db3Id)
        XCTAssertEqual(viaDb3, viaDocuments)
        XCTAssertEqual(viaDb3.modelNames, ["Note"])
        XCTAssertNotNil(viaDb3.schema.models["Note"]?["observed"])
    }

    func testValidateAccessAsksTheDb3RouteWithTheSameBodies() async throws {
        let transport = RecordingTransport(json: Self.accessAnswer)
        let (_, db3, documents) = try await apis(transport)
        let path = "/db3/\(Self.db3Id)/validate-access"

        let mine = try await db3.validateAccess(Self.db3Id)
        let bodyless = try XCTUnwrap(transport.lastCall(to: path))
        XCTAssertEqual(bodyless.method, .post)
        XCTAssertNil(bodyless.body, "naming nobody sends no body")

        let theirs = try await db3.validateAccess(Self.db3Id, userId: "user-7")
        let named = try XCTUnwrap(transport.lastCall(to: path))
        XCTAssertEqual(named.method, .post)
        XCTAssertEqual(named.jsonBody, .object(["userId": .string("user-7")]))
        XCTAssertEqual(transport.calls.filter { $0.path == path }.count, 2, "one request per call")

        let fromDocuments = try await documents.validateAccess(documentId: Self.db3Id, userId: "user-7")
        for result in [mine, theirs] {
            XCTAssertEqual(result.success, fromDocuments.success)
            XCTAssertEqual(result.hasAccess, fromDocuments.hasAccess)
            XCTAssertEqual(result.permission, fromDocuments.permission)
            XCTAssertEqual(result.accessSource, fromDocuments.accessSource)
            XCTAssertEqual(result.appRole, fromDocuments.appRole)
        }
        XCTAssertEqual(theirs.permission, .readWrite)
        XCTAssertEqual(theirs.accessSource, "app")
    }

    func testAServerRefusalIsThrownAsTheCounterpartThrowsIt() async throws {
        let transport = RecordingTransport(status: 403, json: """
        {"error": "Access denied", "code": "DOC_ACCESS_DENIED"}
        """)
        let (_, db3, documents) = try await apis(transport)
        let refusals: [(String, () async throws -> Void)] = [
            ("db3.schema", { _ = try await db3.schema(Self.db3Id) }),
            ("documents.schema", { _ = try await documents.schema(Self.db3Id) }),
            ("db3.validateAccess", { _ = try await db3.validateAccess(Self.db3Id, userId: "user-7") }),
            ("documents.validateAccess", { _ = try await documents.validateAccess(documentId: Self.db3Id, userId: "user-7") }),
        ]
        for (name, call) in refusals {
            do {
                try await call()
                XCTFail("\(name) throws the server's refusal")
            } catch let error as HttpError {
                XCTAssertEqual(error.status, 403, name)
                XCTAssertEqual(error.serverCode, "DOC_ACCESS_DENIED", name)
            }
        }
    }

    func testALocalOnlyDb3IsRefusedBeforeAnyRequestByBothForms() async throws {
        let transport = RecordingTransport(status: 200, json: "{}")
        let (client, db3, documents) = try await apis(transport)
        let id = try await world.createLocalOnly(client, transport: transport).id
        let calls: [(String, () async throws -> Void)] = [
            ("db3.schema", { _ = try await db3.schema(id) }),
            ("documents.schema", { _ = try await documents.schema(id) }),
            ("db3.validateAccess", { _ = try await db3.validateAccess(id) }),
            ("documents.validateAccess", { _ = try await documents.validateAccess(documentId: id) }),
        ]
        for (name, call) in calls {
            let error = await db3LocalOnlyThrown(call)
            XCTAssertEqual(error?.code, .db3LocalOnly, name)
            XCTAssertEqual(error?.details?["db3Id"], .string(id), name)
        }
        XCTAssertEqual(transport.calls.map(\.path).filter { $0.hasSuffix("/schema") || $0.hasSuffix("/validate-access") }, [])
    }

    func testAPendingCreateOfflineThrowsPendingCreateFromBothForms() async throws {
        let transport = RecordingTransport(status: 200, json: Self.accessAnswer)
        let (client, db3, documents) = try await apis(transport)
        let id = try await db3.create(title: "Offline").id
        XCTAssertTrue(client.isPendingCreate(id))
        let calls: [(String, () async throws -> Void)] = [
            ("db3.schema", { _ = try await db3.schema(id) }),
            ("db3.validateAccess", { _ = try await db3.validateAccess(id) }),
            ("documents.validateAccess", { _ = try await documents.validateAccess(documentId: id) }),
        ]
        for (name, call) in calls {
            let error = await db3LocalOnlyThrown(call)
            XCTAssertEqual(error?.code, .pendingCreate, name)
        }
        XCTAssertEqual(transport.calls.map(\.path).filter { $0.hasSuffix("/schema") || $0.hasSuffix("/validate-access") }, [])
    }
}
