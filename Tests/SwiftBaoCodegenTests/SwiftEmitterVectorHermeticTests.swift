import XCTest
@testable import swift_bao_codegen

/// #5225 behavior 24 (the codegen half) — a vector field in a generated model.
///
/// In a db3 type file (a schema with a `[type]` table) a `vector` field takes
/// `dims` (a positive integer) and `element` (`f32`, `f16` or `i8`), and
/// nothing a scalar index or a default would need; the emitter writes it as
/// `[Float]` (optional unless `required`), its descriptor
/// `FieldDescriptor(type: .vector, dims:, element:)`, its value
/// `.vector(...)`, and reads it from a row with `floatArrayValue` and from a
/// record with `asVector`. The parser refuses a vector field outside a type
/// file, a malformed one, `dims`/`element` on any other field, and a unique
/// constraint naming one. The committed `CodegenVector/VectorNoteRecord.swift`
/// golden, which the client's test target compiles and runs, is what the
/// emitter writes for `CodegenVector/vector-note.toml`.
final class SwiftEmitterVectorHermeticTests: XCTestCase {

    private static let packageRoot: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }()

    private static let directory = packageRoot.appendingPathComponent("Tests/JsBaoClientTests/Schema/CodegenVector")

    private func emitted() throws -> String {
        let toml = try String(contentsOf: Self.directory.appendingPathComponent("vector-note.toml"), encoding: .utf8)
        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record", strict: true)
        let emitter = SwiftEmitter(options: EmitOptions(
            sourcePath: "vector-note.toml",
            swiftNamesByModel: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) })
        ))
        let schema = try XCTUnwrap(schemas.first { $0.swiftName == "VectorNoteRecord" })
        return emitter.emit(schema: schema)
    }

    func testTheCommittedGoldenIsWhatTheEmitterWrites() throws {
        let golden = try String(contentsOf: Self.directory.appendingPathComponent("VectorNoteRecord.swift"), encoding: .utf8)
        XCTAssertEqual(try emitted(), golden)
    }

    func testAVectorFieldIsFloatsWithItsEncoding() throws {
        let source = try emitted()
        XCTAssertTrue(source.contains(#""embedding": FieldDescriptor(type: .vector, dims: 3, element: .f32),"#), source)
        XCTAssertTrue(source.contains(#"FieldDescriptor(type: .vector, required: true, dims: 2, element: .i8),"#), source)
        XCTAssertTrue(source.contains("public var embedding: [Float]? {"))
        XCTAssertTrue(source.contains("public var thumb: [Float] {"))
        XCTAssertTrue(source.contains(#""thumb": .vector(thumb),"#))
        XCTAssertTrue(source.contains(#"if let embedding { values["embedding"] = .vector(embedding) }"#))
        XCTAssertTrue(source.contains(#"row["embedding"]?.floatArrayValue"#))
        XCTAssertTrue(source.contains(#"let thumb = row["thumb"]?.floatArrayValue"#))
        XCTAssertTrue(source.contains("asVector"))
    }

    private static let header = "[type]\nname = \"notes\"\n\n[models.note.fields.id]\ntype = \"id\"\n\n"

    func testTheParserRefusesAVectorFieldItCannotEncode() {
        let refused = [
            "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\nelement = \"f32\"\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\nelement = \"f32\"\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 0\nelement = \"f32\"\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\nelement = \"bit\"\n",
            Self.header + "[models.note.fields.v]\ntype = \"string\"\ndims = 3\n",
            Self.header + "[models.note.fields.v]\ntype = \"number\"\nelement = \"f32\"\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\nelement = \"f32\"\nindexed = true\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\nelement = \"f32\"\nunique = true\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\nelement = \"f32\"\ndefault = \"AAAA\"\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\nelement = \"f32\"\ndefault = false\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\nelement = \"f32\"\nauto_stamp = \"create\"\n",
            Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\nelement = \"f32\"\n\n[models.note.fields.t]\ntype = \"string\"\n\n"
                + "[[models.note.unique_constraints]]\nname = \"pair\"\nfields = [\"t\", \"v\"]\n",
        ]
        for toml in refused {
            XCTAssertThrowsError(try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record", strict: true), toml)
        }
        XCTAssertNoThrow(try TomlParser.parse(
            tomlString: Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 768\nelement = \"f16\"\n",
            swiftNameSuffix: "Record", strict: true
        ))
        XCTAssertNoThrow(try TomlParser.parse(
            tomlString: Self.header + "[models.note.fields.v]\ntype = \"vector\"\ndims = 3\nelement = \"f16\"\nindexed = false\n",
            swiftNameSuffix: "Record", strict: true
        ))
    }
}
