import XCTest
@testable import JsBaoClient

/// #5230 behavior 27 (the decode half) and edge case 46 — the public surface
/// of a vector index's shared model:
///
/// - `Db3Index` decodes a listing's `vector` (`index` `"exact"` or
///   `{ mode: "ann", … }`), `generation`, `revision` and `annModel` (its
///   `trainedAt` a `Date`), and a listing from a room before #5229 as before
///   (pin), every new field `nil`.
/// - `Db3LocalIndex`'s initializer keeps its source compatibility: `mode`
///   is defaulted.
/// - `JsBaoErrorCode` gains the six model codes, js-bao's strings.
/// - The operation map names the Swift callers of the three model routes.
final class Db3IndexModelApiHermeticTests: XCTestCase {

    private func decode(_ json: String) throws -> Db3Index {
        try JSONDecoder().decode(Db3Index.self, from: Data(json.utf8))
    }

    func testAListingDecodesAVectorIndexsOptionsGenerationRevisionAndModel() throws {
        let ann = try decode(#"""
            {"name":"idx_vec_note_embedding","model":"Note","fields":["embedding"],"unique":false,"origins":[{"kind":"named","unique":false}],
             "kind":"vector","on":"device","vector":{"distance":"l2","index":{"mode":"ann","nbucket":64,"codesize":8,"quantizer":"pq"},"dims":100,"element":"f16"},
             "generation":4,"revision":2,
             "annModel":{"revision":2,"trainedAt":"2026-11-05T01:02:03.456Z","rows":1200,"bytes":269000,"format":"pvm1"}}
            """#)
        XCTAssertEqual(ann.vector, Db3VectorIndex(distance: .l2, index: .ann(nbucket: 64, codesize: 8, quantizer: .pq), dims: 100, element: .f16))
        XCTAssertEqual(ann.generation, 4)
        XCTAssertEqual(ann.revision, 2)
        XCTAssertEqual(ann.annModel?.revision, 2)
        XCTAssertEqual(ann.annModel?.rows, 1200)
        XCTAssertEqual(ann.annModel?.bytes, 269_000)
        XCTAssertEqual(ann.annModel?.format, "pvm1")
        XCTAssertEqual(ann.annModel?.trainedAt.timeIntervalSince1970 ?? 0, 1_793_840_523.456, accuracy: 0.0005)
        let exact = try decode(#"""
            {"name":"v","model":"Note","fields":["e"],"unique":false,"origins":[],"kind":"vector","on":"device",
             "vector":{"distance":"cos","index":"exact","dims":3,"element":"f32"},"generation":1,"revision":1}
            """#)
        XCTAssertEqual(exact.vector?.index, .exact)
        XCTAssertNil(exact.annModel)
        // A quantizer this build has no case for reads as none given.
        let none = try decode(#"""
            {"name":"v","model":"Note","fields":["e"],"unique":false,"origins":[],"kind":"vector","on":"device",
             "vector":{"distance":"cos","index":{"mode":"ann","quantizer":"none"}}}
            """#)
        XCTAssertEqual(none.vector?.index, .ann(nbucket: nil, codesize: nil, quantizer: nil))
        XCTAssertNil(none.vector?.dims)
        XCTAssertNil(none.vector?.element)
    }

    /// Edge case 46's decode half, a pin: a room from before #5229 lists none of the new fields.
    func testAListingFromAnOlderRoomDecodesAsBefore() throws {
        let old = try decode(#"""
            {"name":"idx_records_note_title","model":"Note","fields":["title"],"unique":false,"origins":[{"kind":"declaration","unique":false}]}
            """#)
        XCTAssertEqual(old.kind, .scalar)
        XCTAssertEqual(old.on, .both)
        XCTAssertNil(old.vector)
        XCTAssertNil(old.generation)
        XCTAssertNil(old.revision)
        XCTAssertNil(old.annModel)
    }

    func testALocalIndexIsMadeAsBeforeItsModeDefaulted() {
        let index = Db3LocalIndex(name: "idx_text_note", model: "Note", fields: ["title"], kind: .text, on: .device, status: .built)
        XCTAssertNil(index.mode)
        let vector = Db3LocalIndex(name: "v", model: "Note", fields: ["e"], kind: .vector, on: .device, status: .built, mode: .ann)
        XCTAssertEqual(vector.mode, .ann)
        XCTAssertEqual(Db3LocalIndexMode.allCases.map(\.rawValue), ["exact", "ann"])
    }

    func testTheModelCodesAreJsBaosStrings() {
        XCTAssertEqual(JsBaoErrorCode.db3IndexModelExists.rawValue, "DB3_INDEX_MODEL_EXISTS")
        XCTAssertEqual(JsBaoErrorCode.db3IndexGenerationStale.rawValue, "DB3_INDEX_GENERATION_STALE")
        XCTAssertEqual(JsBaoErrorCode.db3IndexModelStale.rawValue, "DB3_INDEX_MODEL_STALE")
        XCTAssertEqual(JsBaoErrorCode.db3IndexModelNotFound.rawValue, "DB3_INDEX_MODEL_NOT_FOUND")
        XCTAssertEqual(JsBaoErrorCode.db3IndexModelTooLarge.rawValue, "DB3_INDEX_MODEL_TOO_LARGE")
        XCTAssertEqual(JsBaoErrorCode.db3IndexModelInvalid.rawValue, "DB3_INDEX_MODEL_INVALID")
        // A route's refusal resolves to its case.
        let refused = HttpError.fromBytes(status: 409, message: "refused", body: Data(#"{"code":"DB3_INDEX_MODEL_EXISTS","details":{"pending":true,"expiresAt":5}}"#.utf8))
        XCTAssertEqual(JsBaoErrorCode(rawValue: refused.serverCode ?? ""), .db3IndexModelExists)
        XCTAssertEqual(Db3IndexModelHttp.details(refused)["pending"], true)
        XCTAssertEqual(Db3IndexModelHttp.details(refused)["expiresAt"], 5)
    }

    /// An upload or a delete this device made applies here at once, as a registration does: its list is read again
    /// without waiting on the room's notice.
    func testAnUploadOrADeleteReadsTheCallersListAgain() async throws {
        let index = #"{"name":"v","model":"Note","fields":["e"],"unique":false,"origins":[],"kind":"vector","on":"device","generation":1,"revision":1}"#
        let transport = RecordingTransport { call in
            let body = call.method == .put ? #"{"ok":true,"index":\#(index)}"# : #"{"ok":true,"name":"v","generation":1,"revision":2}"#
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
        let applied = LockedBox<[String]>([])
        let api = Db3IndexesAPI(transport: transport, applyLocally: { id in applied.withValue { $0.append(id) } })
        _ = try await api.uploadModel("d1", name: "v", bytes: Data([1, 2]), upload: Db3IndexModelUpload(generation: 1, revision: 1, rows: 1000, trainedAt: Date()))
        XCTAssertEqual(applied.value, ["d1"])
        let deleted = try await api.deleteModel("d2", name: "v")
        XCTAssertEqual(deleted.revision, 2)
        XCTAssertEqual(applied.value, ["d1", "d2"])
    }

    func testTheOperationMapNamesTheSwiftCallersOfTheModelRoutes() throws {
        let map = ClientSourceText.packageRoot.deletingLastPathComponent().appendingPathComponent("docs/spec/operation-ids.json")
        let operations = try XCTUnwrap(JSONValue(jsonText: String(contentsOf: map, encoding: .utf8))?["operations"]?.arrayValue)
        let swift = { (id: String) in operations.first { $0["operationId"] == .string(id) }?["callers"]?["swift"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        let file = "swift-client/Sources/JsBaoClient/Internal/Db3IndexModelHttp.swift"
        XCTAssertTrue(swift("db3.indexes.model.get").contains("Db3IndexesAPI.fetchModel(_:name:) @ \(file)"))
        XCTAssertTrue(swift("db3.indexes.model.upload").contains("Db3IndexesAPI.uploadModel(_:name:bytes:upload:) @ \(file)"))
        XCTAssertTrue(swift("db3.indexes.model.delete").contains("Db3IndexesAPI.deleteModel(_:name:) @ \(file)"))
    }
}
