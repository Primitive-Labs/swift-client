import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests the shared write path's `auto_stamp` application + the `save()`
/// dirty-check short-circuit (#1056 / #1057).
///
/// Mirrors js-bao `BaseModel.save`:
///   - `create`: stamped on insert only, and only when the caller didn't
///     supply the field and nothing is already persisted (preserves
///     createdAt across re-saves).
///   - `update` / `both`: stamped on every write unless the caller set the
///     field explicitly on that save.
///   - dirty-check: an update that changes nothing is skipped entirely
///     (no listener fires); but an `update`/`both` stamp makes the record
///     dirty, so those models always write.
final class AutoStampWriteTests: XCTestCase {

    private func makeSchema() -> PrimitiveSchema {
        PrimitiveSchema(
            name: "stamped",
            fields: [
                "id":        FieldDescriptor(type: .id),
                "title":     FieldDescriptor(type: .string),
                "createdAt": FieldDescriptor(type: .number, autoStamp: .create),
                "updatedAt": FieldDescriptor(type: .number, autoStamp: .update),
            ]
        )
    }

    private func model() -> DynamicModel {
        let doc = YDocument()
        SchemaSync.clearCache()
        return DynamicModel(doc: doc, schema: makeSchema())
    }

    // MARK: - create stamp

    func testCreateStampSetOnInsert() throws {
        let m = model()
        let before = Date().timeIntervalSince1970 * 1000
        _ = try m.save(id: "r1", values: ["title": .string("a")])
        let after = Date().timeIntervalSince1970 * 1000

        let snap = m.snapshot(recordId: "r1")
        let created = try XCTUnwrap(snap["createdAt"]?.asNumber,
                                    "createdAt should be auto-stamped on insert")
        XCTAssertGreaterThanOrEqual(created, before.rounded() - 1)
        XCTAssertLessThanOrEqual(created, after.rounded() + 1)
    }

    func testCreateStampPreservedAcrossUpdate() throws {
        let m = model()
        _ = try m.save(id: "r1", values: ["title": .string("a")])
        let firstCreated = try XCTUnwrap(m.snapshot(recordId: "r1")["createdAt"]?.asNumber)

        // An update must NOT re-stamp `create`.
        _ = try m.save(id: "r1", values: ["title": .string("b")])
        let secondCreated = try XCTUnwrap(m.snapshot(recordId: "r1")["createdAt"]?.asNumber)
        XCTAssertEqual(firstCreated, secondCreated,
                       "createdAt must be preserved on update")
    }

    func testCreateStampRespectsCallerValue() throws {
        let m = model()
        _ = try m.save(id: "r1", values: ["title": .string("a"),
                                          "createdAt": .number(42)])
        XCTAssertEqual(m.snapshot(recordId: "r1")["createdAt"]?.asNumber, 42,
                       "explicit caller value must win over the create stamp")
    }

    // MARK: - update stamp

    func testUpdateStampSetOnInsertAndUpdate() throws {
        let m = model()
        _ = try m.save(id: "r1", values: ["title": .string("a")])
        let first = try XCTUnwrap(m.snapshot(recordId: "r1")["updatedAt"]?.asNumber,
                                  "updatedAt should be stamped on insert too")

        // Update a field so the write always happens; `update` re-stamps.
        // Monotonic (>=) rather than strictly-greater so the test is robust
        // when both saves land in the same millisecond.
        _ = try m.save(id: "r1", values: ["title": .string("b")])
        let second = try XCTUnwrap(m.snapshot(recordId: "r1")["updatedAt"]?.asNumber)
        XCTAssertGreaterThanOrEqual(second, first,
                                    "updatedAt must be re-stamped on update")
    }

    func testUpdateStampRespectsCallerValue() throws {
        let m = model()
        _ = try m.save(id: "r1", values: ["title": .string("a"),
                                          "updatedAt": .number(99)])
        XCTAssertEqual(m.snapshot(recordId: "r1")["updatedAt"]?.asNumber, 99,
                       "explicit caller value must win over the update stamp")
    }

    // MARK: - dirty-check short-circuit (#1057)

    func testNoOpUpdateIsSkipped() throws {
        // A model with NO update/both stamp — a re-save of identical values
        // must be a no-op. A skipped write touches the Y.Doc not at all, so
        // neither the synchronous listener nor the async observer ever fires
        // (deterministic 0); a real change fires at least once.
        let doc = YDocument()
        SchemaSync.clearCache()
        let m = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "plain",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string),
            ]
        ))
        _ = try m.save(id: "r1", values: ["title": .string("a")])
        m.awaitObserverDrain()

        let fired = NSCountedSet()
        let unsub = m.subscribe { fired.add("x") }
        defer { unsub() }

        // Identical re-save → dirty-check skips it, no write, no fire.
        _ = try m.save(id: "r1", values: ["title": .string("a")])
        m.awaitObserverDrain()
        XCTAssertEqual(fired.count(for: "x"), 0,
                       "a no-op update must be skipped (no write, no listener fire)")

        // A real change DOES write and fire.
        _ = try m.save(id: "r1", values: ["title": .string("b")])
        m.awaitObserverDrain()
        XCTAssertGreaterThanOrEqual(fired.count(for: "x"), 1,
                                    "a changed update must write and fire")
    }

    func testNoOpUpdatePreservesPersistedState() throws {
        // The dirty-check skip must not corrupt the persisted record — a
        // no-op re-save leaves every field exactly as it was.
        let doc = YDocument()
        SchemaSync.clearCache()
        let m = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "plain2",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string),
                "n":     FieldDescriptor(type: .number),
            ]
        ))
        _ = try m.save(id: "r1", values: ["title": .string("a"), "n": .number(7)])
        let before = m.snapshot(recordId: "r1")
        _ = try m.save(id: "r1", values: ["title": .string("a"), "n": .number(7)])
        XCTAssertEqual(m.snapshot(recordId: "r1"), before,
                       "a skipped no-op update must leave the record unchanged")
    }
}
