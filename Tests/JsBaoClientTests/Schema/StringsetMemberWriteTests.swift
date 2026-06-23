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

    // MARK: - Full-set assignment is a diff, not a map replace (#1114)

    /// Merge updates from `src` into `dst` — simulates a remote
    /// client's updates arriving over the wire.
    private func merge(from src: YDocument, into dst: YDocument) {
        let bytes = src.transactSync { txn in
            Data(txn.transactionEncodeStateAsUpdate())
        }
        dst.transactSync { txn in
            _ = try? txn.transactionApplyUpdate(update: Array(bytes))
        }
    }

    /// Assigning a full set removes locally-known members that the new
    /// set omits and inserts the new ones — same observable result as
    /// the old replace path for purely local edits.
    func test_fullSetAssignment_diffsAgainstLocalMembers() throws {
        let model = makeModel()
        _ = try model.create(id: "r1", values: [
            "tags": .stringset(["alpha", "beta", "gamma"]),
        ])
        try model.update(id: "r1", values: [
            "tags": .stringset(["beta", "delta"]),
        ])
        XCTAssertEqual(
            readStringset(model: model, id: "r1", field: "tags"),
            ["beta", "delta"]
        )
    }

    /// The CRDT guarantee js-bao gets from per-member sync: a
    /// concurrent add of a member this client has never seen SURVIVES
    /// a full-set assignment, because the diff never touches the
    /// unknown key and the nested Y.Map instance is preserved. The
    /// old replace-the-map path orphaned the remote insert and lost it.
    func test_fullSetAssignment_preservesConcurrentRemoteAdd() throws {
        SchemaSync.clearCache()
        let docA = YDocument()
        let modelA = DynamicModel(doc: docA, schema: schema)
        _ = try modelA.create(id: "r1", values: [
            "tags": .stringset(["beta"]),
        ])

        // Replica B receives A's state, then adds "alpha" while
        // disconnected from A.
        SchemaSync.clearCache()
        let docB = YDocument()
        merge(from: docA, into: docB)
        let modelB = DynamicModel(doc: docB, schema: schema)
        try modelB.addStringsetMember(
            id: "r1", fieldName: "tags", member: "alpha"
        )

        // A — not knowing about "alpha" — assigns the full set
        // {beta, gamma} through the save/update path.
        try modelA.update(id: "r1", values: [
            "tags": .stringset(["beta", "gamma"]),
        ])

        // Reconnect: B's offline add merges into A. Union wins.
        merge(from: docB, into: docA)
        XCTAssertEqual(
            readStringset(model: modelA, id: "r1", field: "tags"),
            ["alpha", "beta", "gamma"],
            "concurrent unknown member must survive a full-set assignment"
        )
    }

    /// Both directions: two clients each add a different member while
    /// disconnected — one via per-member add, one via full-set
    /// assignment — and the reconnected docs converge on the union.
    func test_twoClientOfflineEdits_unionAfterReconnect() throws {
        SchemaSync.clearCache()
        let docA = YDocument()
        let modelA = DynamicModel(doc: docA, schema: schema)
        _ = try modelA.create(id: "r1", values: [
            "tags": .stringset(["base"]),
        ])

        SchemaSync.clearCache()
        let docB = YDocument()
        merge(from: docA, into: docB)
        let modelB = DynamicModel(doc: docB, schema: schema)

        // Offline edits on both sides.
        try modelA.update(id: "r1", values: [
            "tags": .stringset(["base", "from-a"]),
        ])
        try modelB.update(id: "r1", values: [
            "tags": .stringset(["base", "from-b"]),
        ])

        // Reconnect both ways.
        merge(from: docB, into: docA)
        merge(from: docA, into: docB)

        XCTAssertEqual(
            readStringset(model: modelA, id: "r1", field: "tags"),
            ["base", "from-a", "from-b"]
        )
        XCTAssertEqual(
            readStringset(model: modelB, id: "r1", field: "tags"),
            ["base", "from-a", "from-b"]
        )
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
