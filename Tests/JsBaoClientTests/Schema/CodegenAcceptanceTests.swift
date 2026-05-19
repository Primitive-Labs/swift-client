import XCTest
@testable import JsBaoClient
import YSwift

/// End-to-end acceptance test for the `swift-bao-codegen` build-tool
/// pipeline.
///
/// Two things are checked here:
///
///  1. **The generated source compiles against `JsBaoClient`.** The
///     fixture's golden output (`CodegenAcceptance/Generated/`) is
///     committed and gets compiled as a regular member of the test
///     target — so if `JsBaoClient`'s public API changes in a way that
///     breaks generated code, this target fails to build.
///
///  2. **The generated `TaskRecord` round-trips through `TypedModel`.**
///     This catches semantic drift: e.g. if the emitter started writing
///     `.string(date)` instead of `.date(date)`, the runtime value would
///     read back wrong on the way out.
///
/// To re-roll the golden file after intentionally changing the emitter:
/// ```
/// swift run swift-bao-codegen \
///   --input  Tests/JsBaoClientTests/Schema/CodegenAcceptance/fixture.toml \
///   --output Tests/JsBaoClientTests/Schema/CodegenAcceptance/Generated
/// ```
final class CodegenAcceptanceTests: XCTestCase {

    func testGeneratedSchemaMatchesHandConstructed() {
        // Field set + flags should match the TOML fixture.
        let s = TaskRecord.primitiveSchema
        XCTAssertEqual(s.name, "tasks")
        XCTAssertEqual(s.fields["title"]?.type, .string)
        XCTAssertEqual(s.fields["title"]?.required, true)
        XCTAssertEqual(s.fields["priority"]?.indexed, true)
        XCTAssertEqual(s.fields["tags"]?.type, .stringset)
        XCTAssertEqual(s.fields["createdAt"]?.type, .date)
        XCTAssertEqual(s.fields["id"]?.type, .id)
    }

    func testRoundTripThroughTypedModel() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<TaskRecord>(doc: doc)

        let original = TaskRecord(
            id: "t1",
            createdAt: "2026-04-27T00:00:00Z",
            priority: 3,
            tags: ["urgent", "backend"],
            title: "Ship it"
        )
        _ = try model.create(original)

        let loaded = try XCTUnwrap(model.find(id: "t1"))
        XCTAssertEqual(loaded.id, "t1")
        XCTAssertEqual(loaded.title, "Ship it")
        XCTAssertEqual(loaded.priority, 3)
        XCTAssertEqual(loaded.tags, ["urgent", "backend"])
        XCTAssertEqual(loaded.createdAt, "2026-04-27T00:00:00Z")
    }

    func testOptionalFieldsAreOmittedFromValues() {
        let task = TaskRecord(id: "t1", title: "minimal")
        let values = task.primitiveValues()
        XCTAssertEqual(values["title"], .string("minimal"))
        // Optional fields not set → not in the dict.
        XCTAssertNil(values["priority"])
        XCTAssertNil(values["tags"])
        XCTAssertNil(values["createdAt"])
        // `id` is intentionally NOT in primitiveValues() — DynamicModel
        // writes it separately on create.
        XCTAssertNil(values["id"])
    }
}
