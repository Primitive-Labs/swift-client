import XCTest
@testable import JsBaoClient

/// #5230 behavior 30 — a db3 that lives only on this device registers a
/// vector index on a field its registered model declares a vector, builds
/// its flat table, answers `$near`, and for `ann` trains and installs its own
/// model once it holds enough rows, sending nothing; the model survives a
/// restart; `drop` removes the tables and the model.
final class Db3LocalOnlyVectorIndexLiveTests: XCTestCase {

    private typealias V = Db3VectorLive

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-local-vector-5230")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func write(_ client: JsBaoClient, _ id: String, _ range: Range<Int>) throws {
        for i in range {
            _ = try client.codegen.save(V.note, id: V.id(i), values: [
                "title": .string("note \(i)"), "n": .number(Double(i)), "embedding": .vector(V.vectors[i]),
            ], in: id)
        }
    }

    private func refusal(_ body: () async throws -> Void) async -> JsBaoError? {
        do {
            try await body()
            XCTFail("expected a refusal")
            return nil
        } catch {
            return error as? JsBaoError
        }
    }

    func testALocalOnlyDb3RegistersAVectorIndexAndAnswersNear() async throws {
        let client = try await live.client("local", models: [V.note])
        let traffic = Db3ModelTraffic(client)
        let local = try await client.db3.create(title: "Local vectors", localOnly: true)
        let id = local.id
        let index = try await client.db3.indexes.register(id, Db3IndexRegistration(
            model: V.model, field: "embedding", kind: .vector, vector: Db3VectorIndexOptions(distance: .l2)
        ))
        XCTAssertEqual(index.name, V.name)
        XCTAssertEqual(index.kind, .vector)
        XCTAssertEqual(index.on, .device)
        XCTAssertEqual(index.vector, Db3VectorIndex(distance: .l2, index: .exact, dims: V.dims, element: .f32))
        XCTAssertNil(index.generation)
        XCTAssertNil(index.revision)
        XCTAssertNil(index.annModel)
        // The field's again answers it; a string field, vector options on a scalar index, and another placement are refused.
        let again = try await client.db3.indexes.register(id, Db3IndexRegistration(model: V.model, field: "embedding", kind: .vector, vector: nil))
        XCTAssertEqual(again.name, V.name)
        let string = await refusal {
            _ = try await client.db3.indexes.register(id, Db3IndexRegistration(model: V.model, field: "title", kind: .vector, vector: nil))
        }
        XCTAssertEqual(string?.code, .db3IndexInvalid)
        XCTAssertEqual(
            string?.message,
            "\(V.model).title is not a vector field: a vector index covers a field the model's declaration gives type \"vector\", dims and element"
        )
        let scalar = await refusal {
            _ = try await client.db3.indexes.register(id, Db3IndexRegistration(
                model: V.model, field: "n", fields: nil, unique: nil, name: nil, members: nil, kind: .scalar, vector: Db3VectorIndexOptions()
            ))
        }
        XCTAssertEqual(scalar?.code, .db3IndexInvalid)
        let server = await refusal {
            _ = try await client.db3.indexes.register(id, Db3IndexRegistration(model: V.model, field: "embedding", kind: .vector, vector: nil, on: .server))
        }
        XCTAssertEqual(server?.code, .db3LocalOnly)
        // Its flat table answers $near.
        try write(client, id, 0..<300)
        let near = try V.nearest(client, id, 12)
        XCTAssertEqual(near.first?["id"]?.stringValue, V.id(12))
        let reference = Db3VectorTestSupport.bruteForce(V.vectors.prefix(300).enumerated().map { (V.id($0.offset), $0.element) }, V.vectors[12], k: 10, distance: "l2")
        XCTAssertEqual(near.compactMap { $0["id"]?.stringValue }, reference.map(\.id))
        let listed = try await client.db3.indexes.list(id)
        XCTAssertEqual(listed.first { $0.name == V.name }?.vector?.distance, .l2)
        XCTAssertEqual(traffic.requests.filter { $0.path.contains(id) }.map(\.path), [], "nothing names the db3 to the server")
    }

    func testAnAnnIndexTrainsAndKeepsItsOwnModelSendingNothing() async throws {
        let file = live.file("local-ann")
        let client = try await live.client("local", models: [V.note], file: file)
        let traffic = Db3ModelTraffic(client)
        let local = try await client.db3.create(title: "Local model", localOnly: true)
        let id = local.id
        // Registered before the rows: exact until it holds enough, then its own model.
        _ = try await client.db3.indexes.register(id, Db3IndexRegistration(
            model: V.model, field: "embedding", kind: .vector, vector: Db3VectorIndexOptions(index: .ann())
        ))
        try write(client, id, 0..<V.rows)
        try await eventually(timeout: 120, description: "the local-only db3's own model") { await V.mode(client, id) == .ann }
        XCTAssertEqual(client.vec1Trainer.runs, 1)
        XCTAssertEqual(try V.nearest(client, id, 11).first?["id"]?.stringValue, V.id(11))
        XCTAssertEqual(traffic.requests.filter { $0.path.contains(id) }.map(\.path), [], "nothing names the db3 to the server")
        let refused = await refusal { _ = try await client.db3.indexes.fetchModel(id, name: V.name) }
        XCTAssertEqual(refused?.code, .db3LocalOnly)

        // A restart keeps the model and mode, training nothing.
        await client.destroy()
        let restarted = try await live.client("restarted", models: [V.note], file: file)
        _ = try restarted.db3.subscribe(id)
        try await eventually(timeout: 30, description: "the model kept across a restart") { await V.mode(restarted, id) == .ann }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(restarted.vec1Trainer.runs, 0)
        XCTAssertEqual(try V.nearest(restarted, id, 500).first?["id"]?.stringValue, V.id(500))

        // drop removes both tables, the triggers and the model.
        try await restarted.db3.indexes.drop(id, name: V.name)
        let store = try live.binding(restarted, id).store
        let objects = try store.readView { sql in
            try sql.rows(#"SELECT name FROM sqlite_master WHERE name LIKE 'idx\_record\_log\_vec\_%' ESCAPE '\' AND (type = 'trigger' OR sql LIKE 'CREATE VIRTUAL%')"#)
        }
        XCTAssertEqual(objects.count, 0)
        let after = try await restarted.db3.indexes.local(id)
        XCTAssertFalse(after.contains { $0.name == V.name })

        // Registered after the rows: trained at once.
        _ = try await restarted.db3.indexes.register(id, Db3IndexRegistration(
            model: V.model, field: "embedding", kind: .vector, vector: Db3VectorIndexOptions(index: .ann())
        ))
        try await eventually(timeout: 120, description: "a model trained for the index registered after the rows") { await V.mode(restarted, id) == .ann }
        XCTAssertEqual(restarted.vec1Trainer.runs, 1)
    }
}
