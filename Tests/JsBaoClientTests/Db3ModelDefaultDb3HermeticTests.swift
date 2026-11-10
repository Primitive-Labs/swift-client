import XCTest
@testable import JsBaoClient

/// #5160 behaviours 2 and 3: `client.setModelDefaultDb3(model, db3Id)`, the
/// Swift form of js-bao's `BaseModel.setModelDefaultDb3`, and the declarations
/// the client answers for one db3: the models its copy holds, the models
/// bound to it, and, on the default db3, every model bound nowhere.
final class Db3ModelDefaultDb3HermeticTests: XCTestCase {

    private static let x = "01JD5160SCOPEDDECLARE0000X"
    private static let y = "01JD5160SCOPEDDECLARE0000Y"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string, indexed: true)]
    )
    private static let task = PrimitiveSchema(
        name: "Task", fields: ["id": FieldDescriptor(type: .id), "slug": FieldDescriptor(type: .string, unique: true)]
    )
    private static let label = PrimitiveSchema(
        name: "Label", fields: ["id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string)]
    )

    /// A client signed in as `user-a` over its own SQLite store, with no server.
    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/db3-model-default-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "db3-model-default-5160",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([Self.note, Self.task])
        return client
    }

    private func code(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
        }
    }

    // MARK: - Behaviour 2

    func testABindingToADb3NeverBoundHereIsRecordedReadBackAndCleared() async throws {
        let client = try await client()
        XCTAssertNil(client.recordLogBinding(Self.x), "nothing about the db3 is known here")

        client.setModelDefaultDb3("Note", Self.x)
        XCTAssertEqual(client.getDocumentModelMapping(modelName: "Note"), Self.x)
        XCTAssertNil(client.getDocumentModelMapping(modelName: "Task"))
        client.clearDocumentModelMapping(modelName: "Note")
        XCTAssertNil(client.getDocumentModelMapping(modelName: "Note"))

        // The other doors keep their checks.
        XCTAssertEqual(code { try client.addDocumentModelMapping(modelName: "Note", documentId: Self.x) }, "NOT_FOUND")
        XCTAssertEqual(code { try client.setDefaultDocumentId(Self.x) }, "NOT_FOUND")
        client.documentManager.noteDocumentFormat(Self.y, RecordLogTransport.documentFormat)
        _ = try await client.bindRecordLogDocument(Self.y)
        XCTAssertEqual(code { try client.setDefaultDb3(Self.y) }, "DB3_NOT_RESIDENT", "a bound db3 whose rows have not loaded")
        XCTAssertNil(client.defaultDocumentId)
    }

    // MARK: - Behaviour 3 and E1

    func testTheScopedDeclarationsAreTheHeldTheBoundAndOnTheDefaultTheUnboundModels() async throws {
        let client = try await client()
        let note = JsBaoClient.recordLogDeclaration(Self.note)
        let task = JsBaoClient.recordLogDeclaration(Self.task)

        XCTAssertEqual(client.recordLogDeclarations(for: Self.x, held: []), [:], "an empty, unbound copy declares nothing")
        XCTAssertEqual(client.recordLogDeclarations(for: Self.x, held: ["Note"]), ["Note": note], "a held model")
        XCTAssertEqual(
            client.recordLogDeclarations(for: Self.x, held: ["Gone", "Note"]), ["Note": note],
            "a held model this client has no schema for is left out"
        )

        client.setModelDefaultDb3("Task", Self.x)
        XCTAssertEqual(client.recordLogDeclarations(for: Self.x, held: []), ["Task": task], "a model bound to the db3")
        XCTAssertEqual(client.recordLogDeclarations(for: Self.y, held: []), [:], "bound elsewhere")

        // Y made the default db3: every model bound nowhere, not the one bound to X.
        client.documentManager.noteDocumentFormat(Self.y, RecordLogTransport.documentFormat)
        let binding = try await client.bindRecordLogDocument(Self.y)
        try binding.markCaughtUpAtCreate()
        try client.setDefaultDb3(Self.y)
        XCTAssertEqual(client.recordLogDeclarations(for: Self.y, held: []), ["Note": note])
        XCTAssertEqual(client.recordLogDeclarations(for: Self.x, held: []), ["Task": task], "X is not the default")

        // A model registered at runtime is bound nowhere: the default takes it, X does not.
        client.registerModels([Self.label])
        let label = JsBaoClient.recordLogDeclaration(Self.label)
        XCTAssertEqual(client.recordLogDeclarations(for: Self.y, held: []), ["Label": label, "Note": note])
        XCTAssertEqual(client.recordLogDeclarations(for: Self.x, held: []), ["Task": task])

        // An unbinding is followed at the next answer.
        client.clearDocumentModelMapping(modelName: "Task")
        XCTAssertEqual(client.recordLogDeclarations(for: Self.x, held: []), [:])
        XCTAssertEqual(client.recordLogDeclarations(for: Self.y, held: []), ["Label": label, "Note": note, "Task": task])
        client.clearDefaultDocumentId()
        XCTAssertEqual(client.recordLogDeclarations(for: Self.y, held: ["Task"]), ["Task": task])
    }
}
