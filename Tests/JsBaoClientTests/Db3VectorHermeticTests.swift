import XCTest
import YSwift
@testable import JsBaoClient

/// #5225 behaviors 24 and 25, edge case 40 and behavior 45 (the Swift halves)
/// — vector fields in the Swift client.
///
/// - 24: `PrimitiveFieldType.vector`, `FieldDescriptor(dims:element:)` and
///   `PrimitiveValue.vector([Float])`; `VectorCodec` writes and reads the
///   shared fixture's bytes (`Fixtures/Db3Vectors/codec.json`, the JS codec's
///   too) and refuses what js-bao's refuses; the runtime TOML loader takes a
///   vector field in a db3 type file and refuses a malformed one, and one in a
///   schema with no `[type]` table.
/// - 24 (codegen): the committed `Schema/CodegenVector/VectorNoteRecord.swift`
///   golden compiles here, and its `[Float]` fields write and read through a
///   bound db3.
/// - 25: a model save on a bound db3 encodes `[Float]` with the field's
///   encoding (the type's, when the room sent it) and a read answers
///   `[Float]`; a wrong length, a non-finite value and an `f16` overflow are
///   refused `.db3VectorInvalid` before anything commits; a stored value
///   that does not fit reads `nil` with one warn; the model-free API encodes a
///   known vector field and passes a string through; the device judges a
///   typed db3's vector values with the room's words; a type entry held from
///   before vectors makes the next open omit `db3TypeHash`; a format-1 save of
///   a vector model is refused `.invalidArgument`; `$near` on a device read
///   with no vector index for the field is refused `.queryIndexNotOnDevice`
///   (#5230: one under `$and` is the grammar's `.invalidArgument`); a vector
///   registration encodes its body, and a local-only db3 admits one (#5230).
final class Db3VectorHermeticTests: XCTestCase {

    private static let fixtureDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/Db3Vectors")
    }()

    private struct CodecFixture: Decodable {
        struct Case: Decodable {
            let name: String
            let element: String
            let dims: Int
            let values: [Double]
            let base64: String
            let bytesHex: String
            let decoded: [Double]
        }
        /// A decoded entry: a JSON number, or `"Infinity"`, `"-Infinity"` or `"NaN"`, which JSON cannot hold.
        struct Number: Decodable {
            let value: Double
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Double.self) {
                    value = number
                } else {
                    let text = try container.decode(String.self)
                    guard let number = ["Infinity": Double.infinity, "-Infinity": -Double.infinity, "NaN": Double.nan][text] else {
                        throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number: \(text)")
                    }
                    value = number
                }
            }
        }
        /// Canonical bytes no encoder writes that a decoder still reads.
        struct DecodeOnlyCase: Decodable {
            let name: String
            let element: String
            let dims: Int
            let base64: String
            let bytesHex: String
            let decoded: [Number]
        }
        struct DecodeOnly: Decodable {
            let cases: [DecodeOnlyCase]
        }
        let cases: [Case]
        let decodeOnly: DecodeOnly
    }

    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        Logger.lineForTest = nil
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    private func refusal(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> JsBaoError? {
        do {
            try body()
            XCTFail("expected a refusal", file: file, line: line)
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - 24: the codec

    func testTheCodecWritesAndReadsTheSharedFixturesBytes() throws {
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("codec.json"))
        let fixture = try JSONDecoder().decode(CodecFixture.self, from: data)
        XCTAssertGreaterThan(fixture.cases.count, 10)
        for c in fixture.cases {
            let encoding = VectorEncoding(dims: c.dims, element: try XCTUnwrap(VectorElement(rawValue: c.element)))
            let values = c.values.map { Float($0) }
            XCTAssertEqual(try VectorCodec.encode(values, encoding: encoding), c.base64, c.name)
            XCTAssertEqual(hex(try VectorCodec.bytes(c.base64)), c.bytesHex, c.name)
            XCTAssertEqual(try VectorCodec.decode(c.base64, encoding: encoding), c.decoded.map { Float($0) }, c.name)
            XCTAssertTrue(VectorCodec.isCanonical(c.base64, bytes: VectorCodec.byteLength(encoding)), c.name)
        }
        // A binary16 infinity or NaN reads as it does in js-bao and the functions SDK.
        XCTAssertFalse(fixture.decodeOnly.cases.isEmpty)
        for c in fixture.decodeOnly.cases {
            let encoding = VectorEncoding(dims: c.dims, element: try XCTUnwrap(VectorElement(rawValue: c.element)))
            XCTAssertEqual(hex(try VectorCodec.bytes(c.base64)), c.bytesHex, c.name)
            let decoded = try VectorCodec.decode(c.base64, encoding: encoding)
            XCTAssertEqual(decoded.count, c.decoded.count, c.name)
            for (read, expected) in zip(decoded, c.decoded.map(\.value)) {
                if expected.isNaN {
                    XCTAssertTrue(read.isNaN, "\(c.name): \(read)")
                } else {
                    XCTAssertEqual(read, Float(expected), c.name)
                }
            }
        }
        XCTAssertEqual(VectorElement.allCases.map(\.rawValue), ["f32", "f16", "i8"])
        XCTAssertEqual(VectorCodec.base64Length(VectorEncoding(dims: 768, element: .f32)), 4096)
        XCTAssertEqual(VectorCodec.base64Length(VectorEncoding(dims: 768, element: .i8)), 1032)
    }

    func testTheCodecRefusesWhatJsBaosRefuses() {
        let f32 = VectorEncoding(dims: 3, element: .f32)
        for (label, attempt) in [
            ("wrong length", { _ = try VectorCodec.encode([1, 2], encoding: f32) }),
            ("NaN", { _ = try VectorCodec.encode([1, .nan, 3], encoding: f32) }),
            ("infinity", { _ = try VectorCodec.encode([1, .infinity, 3], encoding: f32) }),
            ("f16 overflow", { _ = try VectorCodec.encode([65520], encoding: VectorEncoding(dims: 1, element: .f16)) }),
            ("short base64", { _ = try VectorCodec.decode("AACAPwAAAMA=", encoding: f32) }),
            ("url-safe base64", { _ = try VectorCodec.decode("AACAPwAAAMAAAAA_", encoding: f32) }),
            ("bytes of non-canonical text", { _ = try VectorCodec.bytes("QUJD=") }),
        ] as [(String, () throws -> Void)] {
            XCTAssertEqual(refusal(attempt)?.code, .db3VectorInvalid, label)
        }
        XCTAssertEqual(try? VectorCodec.decode(try VectorCodec.encode([65504], encoding: VectorEncoding(dims: 1, element: .f16)),
                                               encoding: VectorEncoding(dims: 1, element: .f16)), [65504])
        for (text, bytes) in [("QUJ", 3), ("QUJDRA", 4), ("QUJDREU==", 5), ("QU-D", 3), ("QU D", 3), ("QUJDRB==", 4), ("QUJDREV=", 5), ("QUJD=", 3)] {
            XCTAssertFalse(VectorCodec.isCanonical(text, bytes: bytes), "\(text) as \(bytes) bytes")
        }
        XCTAssertTrue(VectorCodec.isCanonical("QUJDRA==", bytes: 4))
    }

    // MARK: - 24: the schema vocabulary and the runtime loader

    func testTheSchemaCarriesAVectorFieldsEncoding() {
        XCTAssertEqual(PrimitiveFieldType.vector.rawValue, "vector")
        let field = FieldDescriptor(type: .vector, dims: 768, element: .f16)
        XCTAssertEqual(field.dims, 768)
        XCTAssertEqual(field.element, .f16)
        XCTAssertEqual(field.vectorEncoding, VectorEncoding(dims: 768, element: .f16))
        XCTAssertNil(FieldDescriptor(type: .string).vectorEncoding)
        XCTAssertEqual(PrimitiveValue.vector([1, 2]).fieldType, .vector)
        XCTAssertEqual(PrimitiveValue.vector([1, 2]).asVector, [1, 2])
    }

    private static let typeHeader = "[type]\nname = \"notes\"\n\n"

    private func typeFile(_ embedding: String) -> String {
        Self.typeHeader + "[models.notes.fields.id]\ntype = \"id\"\n\n[models.notes.fields.embedding]\n\(embedding)\n"
    }

    func testTheLoaderTakesAVectorFieldInATypeFileAndRefusesAMalformedOne() throws {
        let schemas = try TomlSchemaLoader.load(tomlString: typeFile("type = \"vector\"\ndims = 3\nelement = \"i8\"\nrequired = true"))
        let field = try XCTUnwrap(schemas.first?.fields["embedding"])
        XCTAssertEqual(field.type, .vector)
        XCTAssertEqual(field.vectorEncoding, VectorEncoding(dims: 3, element: .i8))
        XCTAssertTrue(field.required)
        // A flag set false is no option.
        XCTAssertNoThrow(try TomlSchemaLoader.load(tomlString: typeFile("type = \"vector\"\ndims = 3\nelement = \"f32\"\nindexed = false")))
        for body in [
            "type = \"vector\"\nelement = \"f32\"",
            "type = \"vector\"\ndims = 0\nelement = \"f32\"",
            "type = \"vector\"\ndims = 1.5\nelement = \"f32\"",
            "type = \"vector\"\ndims = 3",
            "type = \"vector\"\ndims = 3\nelement = \"bit\"",
            "type = \"string\"\ndims = 3",
            "type = \"number\"\nelement = \"f32\"",
            "type = \"vector\"\ndims = 3\nelement = \"f32\"\nindexed = true",
            "type = \"vector\"\ndims = 3\nelement = \"f32\"\nunique = true",
            "type = \"vector\"\ndims = 3\nelement = \"f32\"\ndefault = \"AAAA\"",
            "type = \"vector\"\ndims = 3\nelement = \"f32\"\ndefault = false",
            "type = \"vector\"\ndims = 3\nelement = \"f32\"\nauto_stamp = \"create\"",
            "type = \"vector\"\ndims = 3\nelement = \"f32\"\nmax_count = 2",
        ] {
            XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: typeFile(body)), body)
        }
        let constraint = typeFile("type = \"vector\"\ndims = 3\nelement = \"f32\"")
            + "\n[models.notes.fields.title]\ntype = \"string\"\n\n[[models.notes.unique_constraints]]\nname = \"pair\"\nfields = [\"title\", \"embedding\"]\n"
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: constraint)) { error in
            XCTAssertTrue("\(error)".contains("vector"), "\(error)")
        }
    }

    func testTheLoaderRefusesAVectorFieldOutsideADb3TypeUnlessAsked() throws {
        let modelsOnly = "[models.notes.fields.embedding]\ntype = \"vector\"\ndims = 3\nelement = \"f32\"\n"
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: modelsOnly)) { error in
            XCTAssertTrue("\(error)".contains("db3 type"), "\(error)")
        }
        let schemas = try TomlSchemaLoader.load(tomlString: modelsOnly, vectors: true)
        XCTAssertEqual(schemas.first?.fields["embedding"]?.vectorEncoding, VectorEncoding(dims: 3, element: .f32))
    }

    // MARK: - 25: a model save and read on a bound db3

    private static let db3Id = "db3-vector-5225"
    private static let note = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
            "embedding": FieldDescriptor(type: .vector, dims: 3, element: .f32),
            "half": FieldDescriptor(type: .vector, dims: 2, element: .f16),
        ]
    )

    /// Models with no vector field of their own, which include notes.
    private static let shelf = PrimitiveSchema(
        name: "Shelf",
        fields: ["id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string), "boxId": FieldDescriptor(type: .string)]
    )
    private static let box = PrimitiveSchema(
        name: "Box", fields: ["id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string)]
    )

    private func client(
        typed vectors: [String: [String: VectorEncoding]]? = nil, logLevel: LogLevel = .none
    ) async throws -> (JsBaoClient, RecordLogDocumentBinding, LockedBox<[Db3WriteRefusedEvent]>, EventSubscription) {
        let directory = NSTemporaryDirectory() + "/db3-vector-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "db3-vector-5225",
            token: makeTestJwt(userId: "user-a"), logLevel: logLevel,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([Self.note, VectorNoteRecord.primitiveSchema, Self.shelf, Self.box])
        try await client.bindStoredDb3(Self.db3Id)
        let binding = try XCTUnwrap(client.recordLogBinding(Self.db3Id))
        binding.createdLocally = true
        if let vectors {
            try binding.setState(type: .typed(
                name: "notes", hash: "h1", models: ["Note": ["title": "string", "embedding": "vector"]], vectors: vectors
            ))
        }
        let heard = LockedBox<[Db3WriteRefusedEvent]>([])
        let subscription = client.eventEmitter.subscribe(Db3WriteRefusedEvent.self) { event in heard.withValue { $0.append(event) } }
        return (client, binding, heard, subscription)
    }

    func testASaveEncodesFloatsWithTheFieldsEncodingAndAReadAnswersFloats() async throws {
        let (client, binding, _, subscription) = try await client()
        _ = try client.codegen.save(
            Self.note, id: "n1", values: ["title": .string("a"), "embedding": .vector([1, -2, 0.5]), "half": .vector([0.5, 2])], in: Self.db3Id
        )
        let stored = try XCTUnwrap(try binding.store.read(model: "Note", id: "n1"))
        XCTAssertEqual(stored["embedding"], .string("AACAPwAAAMAAAAA/"))
        XCTAssertEqual(stored["half"], .string(try VectorCodec.encode([0.5, 2], encoding: VectorEncoding(dims: 2, element: .f16))))
        let row = try XCTUnwrap(client.codegen.find(Self.note, id: "n1"))
        XCTAssertEqual(row["embedding"]?.floatArrayValue, [1, -2, 0.5])
        XCTAssertEqual(row["half"]?.floatArrayValue, [0.5, 2])
        let queried = try client.codegen.query(Self.note, filter: ["title": "a"])
        XCTAssertEqual(queried.first?["embedding"]?.floatArrayValue, [1, -2, 0.5])
        // nil clears it.
        _ = try client.codegen.save(Self.note, id: "n1", values: ["title": .string("a")], in: Self.db3Id, changedFields: ["embedding"])
        XCTAssertEqual(try binding.store.read(model: "Note", id: "n1")?["embedding"], .null)
        XCTAssertNil(client.codegen.find(Self.note, id: "n1")?["embedding"]?.floatArrayValue)
        withExtendedLifetime(subscription) {}
    }

    func testAnIncludedRecordsVectorReadsAsItsNumbersUnderAParentWithoutOne() async throws {
        let (client, _, _, subscription) = try await client()
        _ = try client.codegen.save(Self.box, id: "b1", values: ["label": .string("box")], in: Self.db3Id)
        _ = try client.codegen.save(Self.shelf, id: "s1", values: ["name": .string("a"), "boxId": .string("b1")], in: Self.db3Id)
        _ = try client.codegen.save(
            Self.note, id: "n1", values: ["title": .string("a"), "embedding": .vector([1, -2, 0.5]), "half": .vector([0.5, 2])], in: Self.db3Id
        )
        let notes = Include(
            type: .hasMany, target: client.codegen.includeTarget(for: Self.note), foreignKey: "title", localField: "name", resultKey: "notes"
        )
        let shelves = try client.codegen.query(Self.shelf, filter: ["name": "a"], include: [notes])
        let note = try XCTUnwrap(shelves.first?["_related"]?["notes"]?.arrayValue?.first)
        XCTAssertEqual(note["embedding"]?.floatArrayValue, [1, -2, 0.5])
        XCTAssertEqual(note["half"]?.floatArrayValue, [0.5, 2])

        // Nested: a box's shelves' notes.
        let boxes = try client.codegen.query(Self.box, filter: ["label": "box"], include: [Include(
            type: .hasMany, target: client.codegen.includeTarget(for: Self.shelf), foreignKey: "boxId", resultKey: "shelves", include: [notes]
        )])
        let shelf = try XCTUnwrap(boxes.first?["_related"]?["shelves"]?.arrayValue?.first)
        XCTAssertEqual(shelf["name"], "a")
        let nested = try XCTUnwrap(shelf["_related"]?["notes"]?.arrayValue?.first)
        XCTAssertEqual(nested["embedding"]?.floatArrayValue, [1, -2, 0.5])
        withExtendedLifetime(subscription) {}
    }

    func testTheGeneratedModelWritesAndReadsFloats() async throws {
        let (client, binding, _, subscription) = try await client()
        let record = VectorNoteRecord(id: "g1", title: "generated", embedding: [1, -2, 0.5], thumb: [1, -1])
        _ = try client.codegen.save(VectorNoteRecord.primitiveSchema, id: record.id, values: record.primitiveValues(), in: Self.db3Id)
        XCTAssertEqual(try binding.store.read(model: "vector_note", id: "g1")?["embedding"], .string("AACAPwAAAMAAAAA/"))
        let row = try XCTUnwrap(client.codegen.find(VectorNoteRecord.primitiveSchema, id: "g1"))
        let read = try XCTUnwrap(VectorNoteRecord(row: row))
        XCTAssertEqual(read.embedding, [1, -2, 0.5])
        XCTAssertEqual(read.thumb, [1, -1])
        XCTAssertEqual(read.title, "generated")
        withExtendedLifetime(subscription) {}
    }

    func testATypedDb3EncodesWithTheTypesEncoding() async throws {
        let (client, binding, _, subscription) = try await client(typed: ["Note": ["embedding": VectorEncoding(dims: 2, element: .i8)]])
        _ = try client.codegen.save(Self.note, id: "n1", values: ["embedding": .vector([1, -1])], in: Self.db3Id)
        XCTAssertEqual(
            try binding.store.read(model: "Note", id: "n1")?["embedding"],
            .string(try VectorCodec.encode([1, -1], encoding: VectorEncoding(dims: 2, element: .i8)))
        )
        XCTAssertEqual(client.codegen.find(Self.note, id: "n1")?["embedding"]?.floatArrayValue, [1, -1])
        withExtendedLifetime(subscription) {}
    }

    func testAValueThatDoesNotFitIsRefusedLocallyAndNothingCommits() async throws {
        let (client, binding, heard, subscription) = try await client()
        for (label, values) in [
            ("wrong length", ["embedding": PrimitiveValue.vector([1, 2])]),
            ("non-finite", ["embedding": PrimitiveValue.vector([1, .nan, 3])]),
            ("f16 overflow", ["half": PrimitiveValue.vector([1, 70_000])]),
        ] {
            let error = refusal { _ = try client.codegen.save(Self.note, id: "n-\(label)", values: values, in: Self.db3Id) }
            XCTAssertEqual(error?.code, .db3VectorInvalid, label)
            XCTAssertEqual(error?.details?["scope"], "local", label)
            XCTAssertTrue(error?.message.contains("Note") == true, label)
        }
        XCTAssertEqual(try binding.refreshMarks().pending, 0)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(heard.value.count, 3)
        XCTAssertEqual(heard.value.first?.error.code, .db3VectorInvalid)
        withExtendedLifetime(subscription) {}
    }

    func testAStoredValueThatDoesNotFitReadsNilWithOneWarn() async throws {
        let (client, binding, _, subscription) = try await client(logLevel: .warn)
        let lines = LockedBox<[String]>([])
        Logger.lineForTest = { level, _, message in
            if level == .warn, message.contains("does not fit") { lines.withValue { $0.append(message) } }
        }
        _ = try binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: "odd", kind: .create, fields: ["title": "odd", "embedding": "AACAPw==", "half": 7]),
        ])])
        let row = try XCTUnwrap(client.codegen.find(Self.note, id: "odd"))
        XCTAssertEqual(row["title"]?.stringValue, "odd")
        XCTAssertNil(row["embedding"]?.floatArrayValue)
        XCTAssertNil(client.codegen.find(Self.note, id: "odd")?["embedding"]?.floatArrayValue)
        XCTAssertNil(row["half"]?.floatArrayValue)
        XCTAssertEqual(lines.value.filter { $0.contains("embedding") }.count, 1)
        XCTAssertEqual(lines.value.filter { $0.contains("half") }.count, 1)
        withExtendedLifetime(subscription) {}
    }

    func testTheModelFreeApiEncodesAKnownVectorFieldAndPassesAStringThrough() async throws {
        let (client, binding, _, subscription) = try await client()
        let records = client.db3.records(Self.db3Id)
        let put = try records.put("Note", ["title": "free", "embedding": .vector([1, -2, 0.5])])
        XCTAssertEqual(put.raw["embedding"]?.floatArrayValue, [1, -2, 0.5])
        let id = try XCTUnwrap(put.raw["id"]?.stringValue)
        XCTAssertEqual(try binding.store.read(model: "Note", id: id)?["embedding"], .string("AACAPwAAAMAAAAA/"))
        XCTAssertEqual(try records.get("Note", id: id)?.raw["embedding"]?.floatArrayValue, [1, -2, 0.5])
        let loose = try records.put("Loose", ["raw": "AACAPwAAAMAAAAA/"])
        XCTAssertEqual(loose.raw["raw"]?.stringValue, "AACAPwAAAMAAAAA/")
        XCTAssertEqual(refusal { _ = try records.put("Note", ["embedding": .vector([1, 2])]) }?.code, .db3VectorInvalid)
        XCTAssertEqual(refusal { _ = try records.put("Loose", ["raw": .vector([1, 2])]) }?.code, .documentEntryInvalid)
        withExtendedLifetime(subscription) {}
    }

    // MARK: - 25: the room's rule, judged on the device

    private struct ParityFixture: Decodable {
        struct Case: Decodable {
            let label: String
            let mutations: [JSONValue]
            let expected: String?
        }
        let cases: [Case]
    }

    func testTheDevicesVectorRuleAnswersTheRoomsWords() throws {
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("room-parity.json"))
        let fixture = try JSONDecoder().decode(ParityFixture.self, from: data)
        let type = RecordLogDeclaredType(
            name: "notes", models: ["Note": ["title": "string", "embedding": "vector", "small": "vector"]],
            vectors: ["Note": ["embedding": VectorEncoding(dims: 3, element: .f32), "small": VectorEncoding(dims: 3, element: .i8)]]
        )
        var refused = 0
        for c in fixture.cases {
            let mutations = try c.mutations.map { try XCTUnwrap(RecordLogMutation(json: $0), c.label) }
            let problem = recordLogDeclaredTypeProblem(mutations, type)
            if let expected = c.expected {
                refused += 1
                XCTAssertEqual(problem?.code, .db3VectorInvalid, c.label)
                XCTAssertEqual(problem?.message, expected, c.label)
            } else {
                XCTAssertNil(problem, c.label)
            }
        }
        XCTAssertGreaterThan(refused, 5)
    }

    // MARK: - 45 (the Swift half): a type entry held from before vectors

    typealias H = RecordLogReceiptHarness

    func testAnEntryHeldWithoutVectorsOmitsTheHashOnceAndIsRewritten() async throws {
        let directory = NSTemporaryDirectory() + "/db3-vector-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(host: provider, documentId: H.documentId, clientId: "client-a", logger: Logger(level: .none))
        try binding.registerModel(H.schema)
        let connection = H.Connection(fetches: false)
        let synced = LockedBox(0)
        let session = RecordLogSession(
            documentId: H.documentId, binding: binding,
            host: RecordLogSessionHost(
                connection: { connection }, declarations: { [:] }, synced: { _ in synced.withValue { $0 += 1 } },
                syncFailed: { _, _ in }, waitsForTypeBeforeDeclaring: true
            ),
            timings: H.timings, logger: Logger(level: .none)
        )
        await session.attach()
        func feed(_ frame: [String: JSONValue]) async {
            var frame = frame
            frame["documentId"] = .string(H.documentId)
            await session.receive(frame)
        }
        func until(_ what: String, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(condition(), "timed out waiting for \(what)")
        }
        func reopen() async -> [String: JSONValue]? {
            await session.disconnected()
            let at = connection.frames.count
            await session.start()
            await until("an open") { connection.frames.dropFirst(at).contains { $0["type"]?.stringValue == "record.open" } }
            return connection.frames.dropFirst(at).first { $0["type"]?.stringValue == "record.open" }
        }
        func held() throws -> [String: JSONValue]? {
            let text = try provider.withConnection {
                try $0.query("SELECT value FROM record_log_meta WHERE key = ?", [.text("db3_type:\(H.documentId)")]).first?["value"].stringValue
            }
            return text.flatMap { JSONValue(jsonText: $0) }?.objectValue
        }
        let models: JSONValue = ["Note": ["title": "string", "embedding": "vector"]]
        let vectors: JSONValue = ["Note": ["embedding": ["dims": 3, "element": "f32"]]]
        var opened = H.opened(lsn: 0)
        opened["db3Type"] = ["name": "notes", "hash": "h1", "models": models, "vectors": vectors]
        await session.start()
        await feed(opened)
        await until("the open") { synced.value == 1 }
        XCTAssertEqual(binding.declaredType?.vectors, ["Note": ["embedding": VectorEncoding(dims: 3, element: .f32)]])
        XCTAssertEqual(try held()?["vectors"], vectors)
        let first = await reopen()
        XCTAssertEqual(first?["db3TypeHash"]?.stringValue, "h1")

        // The entry as a client from before vectors wrote it: no `vectors` key.
        try provider.withConnection { connection in
            try connection.execute(
                "UPDATE record_log_meta SET value = ? WHERE key = ?",
                [.text(#"{"typed":"yes","name":"notes","hash":"h1","models":{"Note":{"title":"string","embedding":"vector"}}}"#),
                 .text("db3_type:\(H.documentId)")]
            )
        }
        let omitted = await reopen()
        XCTAssertNotNil(omitted)
        XCTAssertNil(omitted?["db3TypeHash"])
        await feed(opened)
        await until("the second opened") { synced.value == 2 }
        XCTAssertEqual(try held()?["vectors"], vectors)
        let rewritten = await reopen()
        XCTAssertEqual(rewritten?["db3TypeHash"]?.stringValue, "h1")
    }

    // MARK: - 25: format 1, $near, the registration and the codes

    func testAVectorModelRefusesToSaveToAFormat1Document() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: Self.note)
        let before = doc.transactSync { txn in txn.transactionEncodeStateAsUpdate() }
        XCTAssertThrowsError(try model.create(id: "f1", values: ["title": .string("f1"), "embedding": .vector([1, 2, 3])])) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument, "\(error)")
            XCTAssertTrue("\(error)".contains("db3"), "\(error)")
        }
        XCTAssertEqual(doc.transactSync { txn in txn.transactionEncodeStateAsUpdate() }, before)
    }

    func testNearOnADeviceReadIsRefused() async throws {
        let (client, _, _, subscription) = try await client()
        _ = try client.codegen.save(Self.note, id: "n1", values: ["title": .string("a"), "embedding": .vector([1, 2, 3])], in: Self.db3Id)
        let near: JSONValue = ["field": "embedding", "vector": [1, 2, 3], "k": 2]
        // A db3 that holds no vector entry for the field (#5230: a device with one answers).
        let filter: DocumentFilter = ["$near": near]
        let error = refusal { _ = try client.codegen.query(Self.note, filter: filter) }
        XCTAssertEqual(error?.code, .queryIndexNotOnDevice)
        XCTAssertEqual(error?.details?["operator"], "$near")
        XCTAssertEqual(error?.details?["model"], "Note")
        XCTAssertEqual(error?.details?["field"], "embedding")
        XCTAssertEqual(refusal { _ = try client.codegen.count(Self.note, filter: filter) }?.code, .queryIndexNotOnDevice)
        XCTAssertEqual(refusal { _ = try client.db3.records(Self.db3Id).query("Note", filter) }?.code, .queryIndexNotOnDevice)
        // Under `$and` it is the grammar's refusal, as js-bao's (#5230).
        let nested: DocumentFilter = ["$and": [["title": "a"], ["$near": near]]]
        XCTAssertEqual(refusal { _ = try client.codegen.query(Self.note, filter: nested) }?.code, .invalidArgument)
        XCTAssertEqual(refusal { _ = try client.codegen.count(Self.note, filter: nested) }?.code, .invalidArgument)
        XCTAssertEqual(refusal { _ = try client.db3.records(Self.db3Id).query("Note", nested) }?.code, .invalidArgument)
        withExtendedLifetime(subscription) {}
    }

    func testNearInAnIncludeFilterIsRefusedBeforeAnyStatement() throws {
        final class Target: IncludeTarget {
            let modelName: String
            init(_ modelName: String) { self.modelName = modelName }
            func query(_ filter: DocumentFilter?, options: QueryOptions?) throws -> [[String: JSONValue]] {
                XCTFail("an include with $near reached a read")
                return []
            }
        }
        let near: JSONValue = ["field": "embedding", "vector": [1, 2, 3], "k": 2]
        let comments = Target("Comment")
        let notes = Target("Note")
        let nested = Include(
            type: .hasMany, target: comments, foreignKey: "postId",
            include: [Include(type: .refersTo, target: notes, sourceField: "noteId", filter: ["$and": [["$near": near]]])]
        )
        for (include, model) in [
            ([Include(type: .hasMany, target: notes, foreignKey: "postId", filter: ["$near": near])], "Note"),
            ([nested], "Note"),
        ] {
            XCTAssertThrowsError(try RecordLogViewReader.refuseNear("Post", ["title": "a"], include: include)) { error in
                let refusal = error as? JsBaoError
                XCTAssertEqual(refusal?.code, .queryIndexNotOnDevice, "\(error)")
                XCTAssertEqual(refusal?.details?["operator"], "$near")
                XCTAssertEqual(refusal?.details?["model"], .string(model))
                XCTAssertEqual(refusal?.details?["field"], "embedding")
            }
        }
        XCTAssertNoThrow(try RecordLogViewReader.refuseNear("Post", ["title": "a"], include: [Include(type: .hasMany, target: comments, foreignKey: "postId")]))
    }

    func testAVectorRegistrationEncodesItsBody() throws {
        let registration = Db3IndexRegistration(
            model: "Note", field: "embedding", kind: .vector,
            vector: Db3VectorIndexOptions(distance: .l2, index: .ann(nbucket: 64, codesize: 32, quantizer: .opq))
        )
        let body = try XCTUnwrap(JSONValue(jsonText: String(decoding: try JSONEncoder().encode(registration), as: UTF8.self)))
        XCTAssertEqual(body, [
            "model": "Note", "field": "embedding", "kind": "vector",
            "vector": ["distance": "l2", "index": ["mode": "ann", "nbucket": 64, "codesize": 32, "quantizer": "opq"]],
        ])
        let exact = Db3IndexRegistration(model: "Note", field: "embedding", kind: .vector, vector: Db3VectorIndexOptions(index: .exact))
        let exactBody = try XCTUnwrap(JSONValue(jsonText: String(decoding: try JSONEncoder().encode(exact), as: UTF8.self)))
        XCTAssertEqual(exactBody, ["model": "Note", "field": "embedding", "kind": "vector", "vector": ["index": "exact"]])
    }

    /// Behavior 23's local-only half, as #5230 changed it: a device builds a
    /// vector index, so a local-only db3 admits one with its options; its
    /// field's declaration is judged when it is registered.
    func testALocalOnlyDb3AdmitsAVectorRegistrationWithItsOptions() throws {
        let body = Db3IndexRegistration(
            model: "Note", field: "embedding", kind: .vector,
            vector: Db3VectorIndexOptions(distance: .l2, index: .ann(nbucket: 64))
        )
        let parsed = try RecordLogLocalOnly.parse(body)
        XCTAssertEqual(parsed.kind, .vector)
        XCTAssertEqual(parsed.fields, ["embedding"])
        XCTAssertEqual(parsed.vector, Db3VectorIndexOptions(distance: .l2, index: .ann(nbucket: 64)))
        let (_, index) = try RecordLogLocalOnly.register([Self.note], [], body)
        XCTAssertEqual(index.vector, Db3VectorIndex(distance: .l2, index: .ann(nbucket: 64), dims: 3, element: .f32))
    }

    func testTheCodesAreTheJsClientsStrings() {
        XCTAssertEqual(JsBaoErrorCode.db3VectorInvalid.rawValue, "DB3_VECTOR_INVALID")
        XCTAssertEqual(JsBaoErrorCode.queryIndexNotOnDevice.rawValue, "QUERY_INDEX_NOT_ON_DEVICE")
        XCTAssertEqual(JsBaoErrorCode.queryIndexNotOnServer.rawValue, "QUERY_INDEX_NOT_ON_SERVER")
        XCTAssertTrue(RecordLogHandBackCode.all.contains("DB3_VECTOR_INVALID"))
    }
}
