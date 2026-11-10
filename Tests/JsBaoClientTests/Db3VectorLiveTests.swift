import XCTest
@testable import JsBaoClient

/// #5225 behaviors 25 and 26 (live): vector fields through the Swift client
/// against the dev server.
///
/// - A model with a vector field of each element type saves `[Float]`; this
///   client and a second one read `[Float]` within the element's tolerance,
///   the room holds the base64 the JS codec writes for the same numbers, and
///   `nil` clears the field.
/// - On a typed db3 the device encodes a model-free `put` with the type's
///   encoding, and the room hands back a raw string that is not that
///   encoding's base64 `.db3VectorInvalid`.
/// - A vector index registers on a synced db3 the client declared its vector
///   fields to (with its first write) with its options, and is listed
///   `kind: .vector, on: .device`; the device builds its flat table (#5230).
final class Db3VectorLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
        "f32": FieldDescriptor(type: .vector, dims: 3, element: .f32),
        "f16": FieldDescriptor(type: .vector, dims: 3, element: .f16),
        "i8": FieldDescriptor(type: .vector, dims: 3, element: .i8),
    ])
    private static let values: [Float] = [0.25, -1.5, 3]

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-vector-5225")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// `read` holds `values` exactly for `f32` and `f16`, and within half a step for `i8`.
    private func assertClose(_ read: [Float]?, _ element: VectorElement, file: StaticString = #filePath, line: UInt = #line) {
        guard let read else { return XCTFail("no \(element) vector read", file: file, line: line) }
        XCTAssertEqual(read.count, Self.values.count, file: file, line: line)
        let step = Self.values.map(abs).max()! / 127
        for (got, want) in zip(read, Self.values) {
            XCTAssertLessThanOrEqual(abs(got - want), element == .i8 ? step / 2 + 1e-6 : 0, "\(element)", file: file, line: line)
        }
    }

    func testAVectorOfEachElementRoundTripsThroughTheRoomAndASecondClient() async throws {
        let x = try await live.client("x", models: [Self.note])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        _ = try await x.codegen.save(
            Self.note, id: "n1",
            values: ["title": .string("vectors"), "f32": .vector(Self.values), "f16": .vector(Self.values), "i8": .vector(Self.values)],
            in: documentId, confirm: true
        )
        let row = try XCTUnwrap(x.codegen.find(Self.note, id: "n1"))
        for element in VectorElement.allCases { assertClose(row[element.rawValue]?.floatArrayValue, element) }

        let rooms = try await live.roomRows(documentId, "Note")
        for element in VectorElement.allCases {
            XCTAssertEqual(
                rooms["n1"]?[element.rawValue] as? String,
                try VectorCodec.encode(Self.values, encoding: VectorEncoding(dims: 3, element: element)), "\(element)"
            )
        }

        let y = try await live.client("y", models: [Self.note])
        try await live.open(y, documentId)
        let seen = try XCTUnwrap(y.codegen.find(Self.note, id: "n1"))
        for element in VectorElement.allCases { assertClose(seen[element.rawValue]?.floatArrayValue, element) }
        let queried = try y.codegen.query(Self.note, filter: ["title": "vectors"])
        assertClose(queried.first?["f16"]?.floatArrayValue, .f16)

        _ = try await x.codegen.save(Self.note, id: "n1", values: [:], in: documentId, changedFields: ["f32"], confirm: true)
        let cleared = try await live.roomRows(documentId, "Note")
        XCTAssertTrue(cleared["n1"]?["f32"] == nil || cleared["n1"]?["f32"] is NSNull)
        try await eventually(timeout: 15, description: "the clear to reach y") {
            y.codegen.find(Self.note, id: "n1")?["f32"]?.floatArrayValue == nil
        }
    }

    func testATypedDb3EncodesAModelFreePutWithTheTypesEncoding() async throws {
        let type = "swift-vec-\(UUID().uuidString.prefix(6).lowercased())"
        let schema = "[models.Note.fields.title]\ntype = \"string\"\n\n[models.Note.fields.f32]\ntype = \"vector\"\ndims = 3\nelement = \"f32\"\n"
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3-types/\(type)", body: ["schema": schema], jwt: live.app.ownerJWT
        )
        let x = try await live.client("typed", models: [])
        let info = try await x.db3.create(title: "Typed vectors", type: type)
        let handle = try x.db3.subscribe(info.id)
        try await handle.ready()
        try await eventually(timeout: 15, description: "the type's encodings") {
            (try? self.live.binding(x, info.id).declaredType?.vectors["Note"]?["f32"]) == VectorEncoding(dims: 3, element: .f32)
        }
        let records = x.db3.records(info.id)
        let put = try await records.put("Note", ["title": "free", "f32": .vector(Self.values)], confirm: true)
        let id = try XCTUnwrap(put["id"]?.stringValue)
        assertClose(put["f32"]?.floatArrayValue, .f32)
        let rooms = try await live.roomRows(info.id, "Note")
        XCTAssertEqual(rooms[id]?["f32"] as? String, try VectorCodec.encode(Self.values, encoding: VectorEncoding(dims: 3, element: .f32)))
        do {
            _ = try await records.put("Note", ["title": "short", "f32": "AACAPw=="], confirm: true)
            XCTFail("a short vector was taken")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3VectorInvalid)
            XCTAssertTrue(error.message.contains("3 × f32, 16 base64 characters"), error.message)
        }
        handle.dispose()
    }

    func testAVectorIndexRegistersOnASyncedDb3AndTheDeviceBuildsItsFlatTable() async throws {
        let id = try await live.db3Written(0, model: "Note")
        let x = try await live.client("index", models: [Self.note])
        let handle = try x.db3.subscribe(id)
        try await handle.ready()
        // The client declares Note, its vector fields with their encodings, with its first write.
        _ = try await x.codegen.save(Self.note, id: "v1", values: ["f32": .vector(Self.values)], in: id, confirm: true)
        let before = try live.binding(x, id).store.indexTuples()
        let index = try await x.db3.indexes.register(id, Db3IndexRegistration(
            model: "Note", field: "f32", kind: .vector, vector: Db3VectorIndexOptions(distance: .cos, index: .exact)
        ))
        XCTAssertEqual(index.name, "idx_vec_note_f32")
        XCTAssertEqual(index.kind, .vector)
        XCTAssertEqual(index.on, .device)
        let listed = try await x.db3.indexes.list(id)
        XCTAssertEqual(listed.first { $0.name == "idx_vec_note_f32" }?.kind, .vector)
        // No view index; the device builds the vector index's own flat table (#5230).
        XCTAssertEqual(try live.binding(x, id).store.indexTuples(), before)
        let local = try await x.db3.indexes.local(id).first { $0.name == "idx_vec_note_f32" }
        XCTAssertEqual(local?.status, .built)
        XCTAssertEqual(local?.mode, .exact)
        handle.dispose()
    }
}
