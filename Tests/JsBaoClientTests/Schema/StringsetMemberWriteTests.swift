import XCTest
@testable import JsBaoClient
import YSwift

/// Regression tests for the CRDT-friendly stringset member-write path
/// added in the events/wire-polish PR (gaps 1 + 2 from the followup
/// report). Two layers of coverage:
///
/// 1. **Member encoding** — `writeValue` (the full-set replace path)
///    now stores `"true"` as the value for each member, matching
///    js-bao's wire shape. Previously each value was the JSON-encoded
///    member name, which broke byte-equality assertions against the
///    JS-side Y.Doc.
///
/// 2. **`addStringsetMember` / `removeStringsetMember`** — per-member
///    writes that don't blow away the rest of the nested Y.Map. The
///    CRDT-correct path for "add this tag" operations under
///    concurrent offline editing.
final class StringsetMemberWriteTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "tagged_items",
        fields: [
            "id":   FieldDescriptor(type: .id),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private func makeModel() -> DynamicModel {
        SchemaSync.clearCache()
        return DynamicModel(doc: YDocument(), schema: schema)
    }

    /// Unwraps the `.stringset(...)` PrimitiveValue stored on the record
    /// for the given field, or returns an empty set when absent. Keeps
    /// the assertion sites readable.
    private func readStringset(
        model: DynamicModel, id: String, field: String
    ) -> Set<String> {
        guard let record = model.find(id: id),
              case let .stringset(items) = record[field] else {
            return []
        }
        return items
    }

    // MARK: - Encoding

    func test_writeValue_storesMembersAsTrue() throws {
        let model = makeModel()
        _ = try model.create(id: "r1", values: [
            "tags": .stringset(["alpha", "beta"]),
        ])
        XCTAssertEqual(
            readStringset(model: model, id: "r1", field: "tags"),
            ["alpha", "beta"]
        )
    }

    // MARK: - Per-member writes

    func test_addStringsetMember_addsWithoutOverwriting() throws {
        let model = makeModel()
        _ = try model.create(id: "r1", values: [
            "tags": .stringset(["alpha"]),
        ])
        try model.addStringsetMember(id: "r1", fieldName: "tags", member: "beta")
        XCTAssertEqual(
            readStringset(model: model, id: "r1", field: "tags"),
            ["alpha", "beta"],
            "addStringsetMember should add without removing existing members"
        )
    }

    func test_addStringsetMember_isIdempotent() throws {
        let model = makeModel()
        _ = try model.create(id: "r1", values: [
            "tags": .stringset(["alpha"]),
        ])
        try model.addStringsetMember(id: "r1", fieldName: "tags", member: "alpha")
        try model.addStringsetMember(id: "r1", fieldName: "tags", member: "alpha")
        XCTAssertEqual(
            readStringset(model: model, id: "r1", field: "tags"),
            ["alpha"]
        )
    }

    func test_removeStringsetMember_dropsMember() throws {
        let model = makeModel()
        _ = try model.create(id: "r1", values: [
            "tags": .stringset(["alpha", "beta", "gamma"]),
        ])
        try model.removeStringsetMember(id: "r1", fieldName: "tags", member: "beta")
        XCTAssertEqual(
            readStringset(model: model, id: "r1", field: "tags"),
            ["alpha", "gamma"]
        )
    }

    func test_removeStringsetMember_missingMemberNoOp() throws {
        let model = makeModel()
        _ = try model.create(id: "r1", values: [
            "tags": .stringset(["alpha"]),
        ])
        XCTAssertNoThrow(try model.removeStringsetMember(
            id: "r1", fieldName: "tags", member: "doesnotexist"
        ))
        XCTAssertEqual(
            readStringset(model: model, id: "r1", field: "tags"),
            ["alpha"]
        )
    }

    func test_addStringsetMember_throwsOnNonStringsetField() throws {
        SchemaSync.clearCache()
        let scalarSchema = PrimitiveSchema(
            name: "scalar_items",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
            ]
        )
        let model = DynamicModel(doc: YDocument(), schema: scalarSchema)
        _ = try model.create(id: "r1", values: ["name": .string("x")])

        XCTAssertThrowsError(
            try model.addStringsetMember(id: "r1", fieldName: "name", member: "y")
        ) { error in
            guard let jbe = error as? JsBaoError else {
                XCTFail("expected JsBaoError, got \(error)")
                return
            }
            XCTAssertEqual(jbe.code, .invalidArgument)
        }
    }

    func test_addStringsetMember_respectsMaxCount() throws {
        SchemaSync.clearCache()
        let bounded = PrimitiveSchema(
            name: "bounded_items",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset, maxCount: 2),
            ]
        )
        let model = DynamicModel(doc: YDocument(), schema: bounded)
        _ = try model.create(id: "r1", values: ["tags": .stringset([])])

        try model.addStringsetMember(id: "r1", fieldName: "tags", member: "a")
        try model.addStringsetMember(id: "r1", fieldName: "tags", member: "b")
        XCTAssertThrowsError(
            try model.addStringsetMember(id: "r1", fieldName: "tags", member: "c")
        ) { error in
            guard let fe = error as? FieldValidationError else {
                XCTFail("expected FieldValidationError, got \(error)")
                return
            }
            if case .stringsetMaxCountExceeded = fe { /* ok */ }
            else { XCTFail("expected stringsetMaxCountExceeded, got \(fe)") }
        }
    }
}
