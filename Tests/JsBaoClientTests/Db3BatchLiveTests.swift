import XCTest
@testable import JsBaoClient

/// #5243 behavior 24 — `client.db3.batch` and `batchRead` against the dev
/// server: a batch's read sees the write before it, a batch read answers each
/// read at its index, a refused read with `atomic: false` decodes as
/// `.refused`, and both calls on a db3 created a moment ago wait for its
/// commit.
final class Db3BatchLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "n": FieldDescriptor(type: .number),
    ])

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-batch-5243")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testABatchsReadSeesTheWriteBeforeItAndABatchReadAnswersEachRead() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let info = try await createdOnServer(owner, title: "Batches")
        let a = RecordLogLiveApp.ulid()
        let written = try await owner.db3.batch(info.id, [
            .create(model: "Note", data: ["title": "a", "n": 1], id: a),
            .query(model: "Note", sort: ["n": 1]),
            .create(model: "Note", data: ["title": "b", "n": 2]),
            .count(model: "Note"),
        ])
        XCTAssertEqual(written.applied, 2)
        let reads = try XCTUnwrap(written.reads)
        XCTAssertEqual(reads.map(\.index), [1, 3])
        guard case .query(let items, let hasMore, _, _) = reads[0].answer else { return XCTFail("\(reads[0])") }
        XCTAssertEqual(items.map { $0["id"] }, [.string(a)])
        XCTAssertFalse(hasMore)
        XCTAssertEqual(reads[1].answer, .count(2))

        let answer = try await owner.db3.batchRead(info.id, [
            .count(model: "Note", filter: ["n": ["$gte": 2]]),
            .aggregate(model: "Note", options: ["operations": [["type": "sum", "field": "n"]]]),
            .query(model: "Note", filter: ["$near": ["field": "embedding", "vector": [1, 0, 0], "k": 1]]),
        ], atomic: false)
        XCTAssertEqual(answer.results.map(\.index), [0, 1, 2])
        XCTAssertEqual(answer.results[0].answer, .count(1))
        XCTAssertEqual(answer.results[1].answer, .aggregate([["group": [:], "sum_n": 3]]))
        guard case .refused(let code, let status, _) = answer.results[2].answer else { return XCTFail("\(answer.results[2])") }
        XCTAssertEqual(code, "QUERY_INDEX_NOT_ON_SERVER")
        XCTAssertEqual(status, 400)
        XCTAssertNotNil(answer.cost?.rowsRead)
    }

    func testBothWaitForAPendingCreate() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let held = heldDb3Commit(owner)
        let info = try await owner.db3.create(title: "Batched at once")
        let opened = LockedBox<Date?>(nil)
        let write = Task { () -> (Db3BatchResult, Date) in
            (try await owner.db3.batch(info.id, [.create(model: "Note", data: ["title": "early"])]), Date())
        }
        let read = Task { () -> (Db3BatchReadResponse, Date) in
            (try await owner.db3.batchRead(info.id, [.count(model: "Note")]), Date())
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        opened.value = Date()
        held.open()
        let (written, writtenAt) = try await write.value
        let (counted, countedAt) = try await read.value
        let openedAt = try XCTUnwrap(opened.value)
        XCTAssertEqual(written.applied, 1)
        XCTAssertEqual(counted.results.count, 1)
        XCTAssertGreaterThan(writtenAt, openedAt, "the batch answered after the commit was released")
        XCTAssertGreaterThan(countedAt, openedAt, "the batch read answered after the commit was released")
    }
}
