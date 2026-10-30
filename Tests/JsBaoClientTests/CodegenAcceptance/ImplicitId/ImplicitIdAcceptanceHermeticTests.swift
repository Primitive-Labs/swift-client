import XCTest
@testable import JsBaoClient
import YSwift

/// The structs `swift-bao-codegen` emits for a db3 type file whose models
/// declare no `id` field (#5025 behaviour 23 and edge E13), compiled by this
/// target.
///
/// `ImplicitIdNote.swift` and `ImplicitIdEmpty.swift` beside this file are
/// what `Tests/SwiftBaoCodegenTests/Fixtures/implicit-id-5025.toml` emits
/// (`SynthesizedIdHermeticTests` compares them byte for byte): the type file
/// declares `notes` with no `id` and `empty` with no fields at all, and each
/// struct carries the `id` a declared `auto_assign` id gives.
final class ImplicitIdAcceptanceHermeticTests: XCTestCase {

    func testTheSchemaCarriesTheAutoAssignedId() {
        XCTAssertEqual(ImplicitIdNote.primitiveSchema.fields["id"]?.type, .id)
        XCTAssertEqual(ImplicitIdNote.primitiveSchema.fields["id"]?.autoAssign, true)
        XCTAssertEqual(Set(ImplicitIdEmpty.primitiveSchema.fields.keys), ["id"])
        XCTAssertEqual(ImplicitIdEmpty.primitiveSchema.fields["id"]?.autoAssign, true)
    }

    func testTheDesignatedInitTakesIdFirstAndTheAutoIdInitMints() {
        let pinned = ImplicitIdNote(id: "n1", title: "Pinned", done: true)
        XCTAssertEqual(pinned.id, "n1")
        XCTAssertTrue(pinned._explicitId)

        let minted = ImplicitIdNote(title: "Minted")
        XCTAssertEqual(minted.id.count, 26)
        XCTAssertFalse(minted._explicitId)
        XCTAssertNotEqual(ImplicitIdNote(title: "Other").id, minted.id)

        XCTAssertEqual(ImplicitIdEmpty().id.count, 26)
        XCTAssertEqual(ImplicitIdEmpty(id: "e1").id, "e1")
    }

    func testValuesOmitTheIdAndCodingKeysCarryIt() throws {
        let note = ImplicitIdNote(id: "n2", title: "T", done: false)
        XCTAssertEqual(Set(note.primitiveValues().keys), ["title", "done"])
        XCTAssertEqual(ImplicitIdEmpty(id: "e2").primitiveValues(), [:])
        XCTAssertEqual(ImplicitIdNote.CodingKeys.id.rawValue, "id")

        let decoded = try JSONDecoder().decode(ImplicitIdNote.self, from: try JSONEncoder().encode(note))
        XCTAssertEqual(decoded, note)
    }

    func testRecordAndRowInitsRoundTrip() throws {
        let fromRow = try XCTUnwrap(ImplicitIdNote(row: ["id": "n3", "title": "Row", "done": true]))
        XCTAssertEqual(fromRow, ImplicitIdNote(id: "n3", title: "Row", done: true))
        XCTAssertEqual(try XCTUnwrap(ImplicitIdEmpty(row: ["id": "e3"])).id, "e3")

        let doc = YDocument()
        SchemaSync.clearCache()
        let model = TypedModel<ImplicitIdNote>(doc: doc)
        let created = ImplicitIdNote(title: "Stored", done: true)
        _ = try model.create(created)
        let loaded = try XCTUnwrap(model.find(id: created.id))
        XCTAssertEqual(loaded, created)
    }
}
