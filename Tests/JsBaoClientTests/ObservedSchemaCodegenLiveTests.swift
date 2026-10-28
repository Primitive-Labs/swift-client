import XCTest
@testable import JsBaoClient

/// `swift-bao-codegen` on a document's observed schema, live (#4624
/// behaviour 25): a format-3 document seeded over HTTP (a declared `Shelf`,
/// an undeclared `shelf`, an undeclared `Mix` of mixed, null-only and date
/// fields, and models whose names need an explicit Swift class name) exports
/// through `client.documents.schema` and the JS client's `recordLogSchemaToToml`
/// exactly the committed `observed-schema-4624.toml`; a client registering the
/// models generated from it reads every existing record through them, a value
/// that does not fit its type as missing; what the export omitted stays
/// readable through `documents.records`.
final class ObservedSchemaCodegenLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-observed-codegen")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        await live?.destroy()
        await ctx?.cleanup()
    }

    static let fixture = ClientSourceText.packageRoot
        .appendingPathComponent("Tests/SwiftBaoCodegenTests/Fixtures/observed-schema-4624.toml")

    /// The document, written as its owner over the app's routes; `Shelf` declared through the room's test route.
    private func seed() async throws -> String {
        let app = live.app
        let created = try await ctx.appRequest(
            method: "POST", appId: app.appId, path: "/documents",
            body: ["title": "observed-schema", "documentFormat": 3], jwt: app.ownerJWT
        )
        let documentId = try XCTUnwrap(created["documentId"] as? String)
        // Sent as text: the export lists declared fields in the declaration's
        // order, which a dictionary would not fix.
        let declaration = #"{"model":"Shelf","declaration":{"fields":{"id":{"type":"id","autoAssign":true},"#
            + #""title":{"type":"string","indexed":true},"code":{"type":"string"},"tags":{"type":"stringset","default":[]}},"#
            + #""uniqueConstraints":[{"name":"byTitleCode","fields":["title","code"]}]}}"#
        var request = URLRequest(url: try XCTUnwrap(URL(string: "\(TestConfig.httpUrl)/__test__/document/\(app.appId)/\(documentId)/declare")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ProcessInfo.processInfo.environment["TEST_ADMIN_TOKEN"] ?? "local-test-secret", forHTTPHeaderField: "X-Test-Auth")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        request.httpBody = Data(declaration.utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: body, as: UTF8.self))
        let save = { (model: String, id: String, data: [String: Any]) async throws in
            _ = try await self.ctx.appRequest(
                method: "POST", appId: app.appId, path: "/documents/\(documentId)/records/\(model)",
                body: ["id": id, "data": data], jwt: app.ownerJWT
            )
        }
        try await save("Shelf", "shelfA", ["title": "a", "code": "1", "tags": ["x"]])
        try await save("Shelf", "shelfB", ["title": "b", "code": "2"])
        try await save("shelf", "lowerA", ["label": "lower case"])
        try await save("Mix", "mixA", [
            "mixed": "a", "n": "5", "at": "2026-10-16T10:00:00Z", "nothing": NSNull(), "tags": ["p"], "title": "lower", "Title": "upper",
        ])
        try await save("Mix", "mixB", ["mixed": 3, "n": 1, "at": "2026-10-17T11:00:00Z", "nothing": NSNull()])
        try await save("Mix", "mixC", ["mixed": true, "n": 2, "at": "2026-10-18", "nothing": NSNull()])
        for model in ["any", "tasks", "tasks_record", "primitive_row"] {
            try await save(model, "\(model)1", ["label": model])
        }
        return documentId
    }

    /// `GET /documents/{id}/schema` as the room wrote it: the export keeps its key order.
    private func rawSchema(_ documentId: String) async throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(
            string: "\(TestConfig.httpUrl)/app/\(live.app.appId)/api/documents/\(documentId)/schema"
        )))
        request.setValue("Bearer \(live.app.ownerJWT)", forHTTPHeaderField: "Authorization")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return data
    }

    /// `recordLogSchemaToToml` of `answer`, run by the JS client's own module in a Node child.
    private func exportToml(_ answer: Data) throws -> String {
        let repoRoot = ClientSourceText.repoRoot
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("observed-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("answer.json")
        let errors = temp.appendingPathComponent("stderr.txt")
        try answer.write(to: input)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try CrossPlatformHarness.nodePath())
        process.arguments = ["--import", "tsx", repoRoot.appendingPathComponent("tests/client/helpers/record-log-schema-toml-child-4624.ts").path]
        process.currentDirectoryURL = repoRoot
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardError = try FileHandle(forWritingTo: errors)
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestSetupError("the TOML child exited \(process.terminationStatus): \((try? String(contentsOf: errors, encoding: .utf8)) ?? "")")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func testTheExportGeneratesModelsThatReadEveryRecord() async throws {
        let documentId = try await seed()
        let toml = try exportToml(try await rawSchema(documentId))
        let committed = try String(contentsOf: Self.fixture, encoding: .utf8)
        if toml != committed {
            try? toml.write(toFile: NSTemporaryDirectory() + "observed-schema-4624.actual.toml", atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(Array(toml.utf8), Array(committed.utf8), "the live export is the committed fixture, byte for byte")

        let reader = try await live.client("reader", models: [
            Shelf.primitiveSchema, Mix.primitiveSchema, AnyModel.primitiveSchema, TasksRecord.primitiveSchema,
            TasksRecordModel.primitiveSchema, PrimitiveRowModel.primitiveSchema,
        ])
        JsBaoClient.configureDefault(reader)
        try await live.open(reader, documentId)

        let shelves = try Shelf.findAll().sorted { $0.id < $1.id }
        XCTAssertEqual(shelves.map(\.id), ["shelfA", "shelfB"])
        XCTAssertEqual(shelves.map(\.title), ["a", "b"])
        XCTAssertEqual(shelves.map(\.code), ["1", "2"])
        XCTAssertEqual(shelves.map(\.tags), [["x"], []])
        XCTAssertEqual(try Shelf.query(["title": "a"]).map(\.id), ["shelfA"])

        let mixA = try XCTUnwrap(try Mix.find("mixA"))
        let mixB = try XCTUnwrap(try Mix.find("mixB"))
        let mixC = try XCTUnwrap(try Mix.find("mixC"))
        XCTAssertEqual([mixA.mixed, mixB.mixed, mixC.mixed], ["a", nil, nil], "a value that does not fit string is missing")
        XCTAssertEqual([mixA.n, mixB.n, mixC.n], ["5", nil, nil])
        XCTAssertEqual([mixA.at, mixB.at, mixC.at], ["2026-10-16T10:00:00Z", "2026-10-17T11:00:00Z", "2026-10-18"])
        XCTAssertEqual([mixA.nothing, mixB.nothing, mixC.nothing], [nil, nil, nil])
        XCTAssertEqual(mixA.tags, ["p"])
        XCTAssertEqual(mixA.Title, "upper")
        XCTAssertEqual(try Mix.query(nil, options: QueryOptions(limit: 10)).count, 3)
        XCTAssertEqual(try Mix.query(["n": "5"]).map(\.id), ["mixA"])

        XCTAssertEqual(try AnyModel.findAll().map(\.id), ["any1"])
        XCTAssertEqual(try TasksRecord.findAll().map(\.id), ["tasks1"])
        XCTAssertEqual(try TasksRecordModel.findAll().map(\.id), ["tasks_record1"])
        XCTAssertEqual(try PrimitiveRowModel.findAll().map(\.id), ["primitive_row1"])

        // What the export left out is read through the model-free records.
        let records = reader.documents.records(documentId)
        XCTAssertEqual(try records.get("shelf", id: "lowerA")?["label"], "lower case")
        XCTAssertEqual(try records.get("Mix", id: "mixA")?["title"], "lower")
    }
}
