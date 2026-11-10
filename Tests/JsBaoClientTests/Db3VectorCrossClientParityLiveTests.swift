import XCTest
@testable import JsBaoClient

/// #5230 behavior 29 — a Swift device and the JS client (`ModelFreeJSChild`,
/// with vec1 from `primitive-vec1-node`) share one db3's ANN model each way
/// and answer `$near` alike, live:
///
/// - a model the JS device trained installs on the Swift device, and one the
///   Swift device trained installs on a JS device (`fetchModel`'s bytes,
///   generation and revision equal on both, read from each client's `GET`);
/// - for 20 query vectors, exact and ann, filtered and not, k 10, both
///   answer the same ids in the same order with `_distance` equal to 1e-6;
/// - a cursor a Swift `$near` page minted pages the JS client, and the JS
///   client's pages Swift.
final class Db3VectorCrossClientParityLiveTests: XCTestCase {

    private typealias V = Db3VectorLive

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!
    private var children: [ModelFreeJSChild] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-vector-parity-5230")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        for child in children { child.stop() }
        children = []
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func child(_ id: String) async throws -> ModelFreeJSChild {
        let child = try ModelFreeJSChild(app: live.app, documentId: id)
        children.append(child)
        try await child.ready(timeout: 90)
        return child
    }

    private func jsMode(_ child: ModelFreeJSChild, _ name: String) async throws -> String? {
        try await child.send(["op": "local"]).arrayValue?.first { $0["name"]?.stringValue == name }?["mode"]?.stringValue
    }

    private func near(_ field: String, _ vector: [Float], filter: DocumentFilter? = nil) -> DocumentFilter {
        var near: [String: JSONValue] = ["field": .string(field), "vector": .array(vector.map { .number(Double($0)) }), "k": 10]
        if let filter { near["filter"] = .object(filter) }
        return ["$near": .object(near)]
    }

    /// A JS query's rows: `data` (or `rows`), each `id` and `_distance`.
    private func rows(_ value: JSONValue) -> [JSONValue] { value["data"]?.arrayValue ?? value["rows"]?.arrayValue ?? [] }

    func testBothClientsShareTheModelEachWayAndAnswerNearAlike() async throws {
        let id = try await V.seeded(live, other: true)
        let index = try await V.register(live, id)
        let generation = try XCTUnwrap(index["generation"] as? Int)
        try await V.register(live, id, [
            "model": V.model, "field": "other", "kind": "vector", "on": "device", "vector": ["distance": "l2", "index": "exact"],
        ])
        let otherName = "idx_vec_\(V.model)_other"

        // The JS device trains the first model.
        let js = try await child(id)
        try await eventually(timeout: 180, description: "the JS device on its own model") { try await self.jsMode(js, V.name) == "ann" }
        let swift = try await V.device(live, id, name: "swift")
        try await eventually(timeout: 120, description: "the Swift device on the JS device's model") { await V.mode(swift.client, id) == .ann }
        XCTAssertEqual(swift.client.vec1Trainer.runs, 0)
        XCTAssertFalse(swift.traffic.model().contains { $0.method == .put })
        let swiftModel = try await swift.client.db3.indexes.fetchModel(id, name: V.name)
        let jsModel = try await js.send(["op": "fetchModel", "name": .string(V.name)])
        XCTAssertEqual(jsModel["bytes"]?.stringValue, swiftModel.bytes.base64EncodedString())
        XCTAssertEqual(RecordLogVectorIndex.integer(jsModel["generation"]), swiftModel.generation)
        XCTAssertEqual(RecordLogVectorIndex.integer(jsModel["revision"]), swiftModel.revision)
        XCTAssertEqual(swiftModel.generation, generation)

        // 20 query vectors, ann (embedding) and exact (other), filtered and not: the same ids, order and distances.
        let queries = Db3VectorTestSupport.clusteredVectors(20, V.dims, clusters: 24, seed: 2929)
        for (offset, query) in queries.enumerated() {
            for field in ["embedding", "other"] {
                for filter in [nil, ["n": ["$gte": .number(Double(offset * 40))]]] as [DocumentFilter?] {
                    let filterValue = near(field, query, filter: filter)
                    let swiftRows = try swift.client.db3.records(id).query(V.model, filterValue).data
                    let jsRows = rows(try await js.send(["op": "query", "model": .string(V.model), "filter": .object(filterValue)]))
                    let label = "\(field) #\(offset)\(filter == nil ? "" : " filtered")"
                    XCTAssertEqual(swiftRows.compactMap { $0.raw["id"]?.stringValue }, jsRows.compactMap { $0["id"]?.stringValue }, label)
                    for (s, j) in zip(swiftRows, jsRows) {
                        let (a, b) = (s.raw["_distance"]?.numberValue ?? -1, j["_distance"]?.numberValue ?? -2)
                        XCTAssertEqual(a, b, accuracy: 1e-6 * max(1, abs(b)), label)
                    }
                }
            }
        }

        // Cursors page each other: Swift's first page, then the JS client's next; and the reverse.
        let filterValue = near("embedding", queries[3])
        let swiftFirst = try swift.client.db3.records(id).query(V.model, filterValue, options: QueryOptions(limit: 4))
        let jsNext = try await js.send([
            "op": "query", "model": .string(V.model), "filter": .object(filterValue),
            // The JS client's model-free records page with the cursor as `uniqueStartKey`.
            "options": ["limit": 4, "uniqueStartKey": .string(try XCTUnwrap(swiftFirst.nextCursor))],
        ])
        let swiftNext = try swift.client.db3.records(id).query(V.model, filterValue, options: QueryOptions(limit: 4, cursor: swiftFirst.nextCursor))
        XCTAssertEqual(rows(jsNext).compactMap { $0["id"]?.stringValue }, swiftNext.data.compactMap { $0.raw["id"]?.stringValue })
        let jsFirst = try await js.send(["op": "query", "model": .string(V.model), "filter": .object(filterValue), "options": ["limit": 4]])
        let jsCursor = try XCTUnwrap(jsFirst["nextCursor"]?.stringValue)
        let fromJs = try swift.client.db3.records(id).query(V.model, filterValue, options: QueryOptions(limit: 4, cursor: jsCursor))
        XCTAssertEqual(fromJs.data.compactMap { $0.raw["id"]?.stringValue }, swiftNext.data.compactMap { $0.raw["id"]?.stringValue })

        // The other way: the Swift device trains revision 2's model, and a fresh JS device installs it.
        js.stop()
        // The device that deletes the model reads its list again at once, whether or not the room's notice reaches it.
        _ = try await swift.client.db3.indexes.deleteModel(id, name: V.name)
        try await eventually(timeout: 120, description: "the Swift device on its own revision 2 model") {
            let revision = (try await V.listed(self.live, id)?["annModel"] as? [String: Any])?["revision"] as? Int
            let mode = await V.mode(swift.client, id)
            return revision == 2 && mode == .ann
        }
        XCTAssertEqual(swift.client.vec1Trainer.runs, 1)
        let fresh = try await child(id)
        try await eventually(timeout: 180, description: "a JS device on the Swift device's model") { try await self.jsMode(fresh, V.name) == "ann" }
        let swiftTrained = try await swift.client.db3.indexes.fetchModel(id, name: V.name)
        let jsFetched = try await fresh.send(["op": "fetchModel", "name": .string(V.name)])
        XCTAssertEqual(jsFetched["bytes"]?.stringValue, swiftTrained.bytes.base64EncodedString())
        XCTAssertEqual(RecordLogVectorIndex.integer(jsFetched["revision"]), 2)
        for (offset, query) in queries.prefix(5).enumerated() {
            let filterValue = near("embedding", query)
            let swiftRows = try swift.client.db3.records(id).query(V.model, filterValue).data
            let jsRows = rows(try await fresh.send(["op": "query", "model": .string(V.model), "filter": .object(filterValue)]))
            XCTAssertEqual(swiftRows.compactMap { $0.raw["id"]?.stringValue }, jsRows.compactMap { $0["id"]?.stringValue }, "#\(offset)")
        }
        let jsOther = try await jsMode(fresh, otherName)
        XCTAssertEqual(jsOther, "exact")
        swift.subscription.dispose()
    }
}
