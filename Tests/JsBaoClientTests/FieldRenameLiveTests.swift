import XCTest
@testable import JsBaoClient

/// #6023 behavior 32 — a Swift build generated from a type that renames a
/// field, live against the dev server.
///
/// `RenamedTask6023` (from `renamed-6023.toml`) declares `dueAt` with
/// `storedAs = "due"`; `PreRenameTask6023` (from `pre-rename-6023.toml`) is
/// the same model generated before the rename, still saying `due`. The
/// renamed build saves and reads `dueAt`, the room's row holds `due`, and
/// the pre-rename build reads and edits the same record under `due`.
@available(*, deprecated)
final class FieldRenameLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-field-rename-6023")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testARenamedBuildWritesTheStoredNameAndAPreRenameBuildReadsAndEditsIt() async throws {
        let renamed = try await live.client("renamed", models: [RenamedTask6023.primitiveSchema])
        let documentId = try await live.createDocument(renamed)
        try await live.open(renamed, documentId)
        JsBaoClient.configureDefault(renamed)
        _ = try RenamedTask6023(id: "t1", title: "Plan", dueAt: 5).save(in: documentId)
        try await live.settled(renamed, documentId)

        let row = try await XCTUnwrapAsync(try await live.roomRows(documentId, "renamed_tasks")["t1"])
        XCTAssertEqual((row["due"] as? NSNumber)?.doubleValue, 5, "the room's row holds the stored name: \(row)")
        XCTAssertNil(row["dueAt"], "the room's row has no current-name key: \(row)")
        XCTAssertEqual(try RenamedTask6023.find("t1")?.dueAt, 5)
        XCTAssertEqual(try RenamedTask6023.queryOne(["dueAt": .number(5)])?.id, "t1")

        let before = try await live.client("before", models: [PreRenameTask6023.primitiveSchema])
        try await live.open(before, documentId)
        JsBaoClient.configureDefault(before)
        try await eventually(timeout: 20, description: "the pre-rename build to read the record") {
            (try? PreRenameTask6023.find("t1"))?.due == 5
        }
        var edited = try XCTUnwrap(try PreRenameTask6023.find("t1"))
        edited.due = 8
        _ = try edited.save(in: documentId)
        try await live.settled(before, documentId)
        let editedRow = try await XCTUnwrapAsync(try await live.roomRows(documentId, "renamed_tasks")["t1"])
        XCTAssertEqual((editedRow["due"] as? NSNumber)?.doubleValue, 8, "\(editedRow)")

        JsBaoClient.configureDefault(renamed)
        try await eventually(timeout: 20, description: "the renamed build to read the pre-rename build's edit") {
            (try? RenamedTask6023.find("t1"))?.dueAt == 8
        }
    }
}

/// `XCTUnwrap` over an async expression.
private func XCTUnwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line
) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
