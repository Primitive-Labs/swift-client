import XCTest
@testable import JsBaoClient

/// The Swift surface of a large document, and the refusal that keeps one off
/// storage that cannot host it (#3436, behaviors 17 and 14).
///
/// Names mirror the JS client's, per the intent's Swift-surface decision: a
/// developer who has read `documents.create({ documentFormat: 2 })` should be
/// able to guess `CreateDocumentOptions(documentFormat: 2)`.
final class Format2SurfaceHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    // MARK: - Behavior 17 — the create option

    func testTheCreateOptionIsEncodedOnlyWhenItIsSet() throws {
        // Absent by default: an ordinary create's POST body must be exactly
        // what it was before this option existed.
        let ordinary = try Self.encode(CreateDocumentOptions(title: "plain"))
        XCTAssertNil(
            ordinary["documentFormat"],
            "an unset option must not appear in the commit POST body"
        )
        XCTAssertEqual(ordinary["title"] as? String, "plain")

        let large = try Self.encode(
            CreateDocumentOptions(title: "big", documentFormat: 2)
        )
        XCTAssertEqual(large["documentFormat"] as? Int, 2)
        XCTAssertEqual(large["title"] as? String, "big")
    }

    func testTheCreateOptionKeepsTheExistingInitializerWorking() {
        // Additive: every existing call site compiles unchanged, and the new
        // parameter defaults to absent.
        let options = CreateDocumentOptions(
            title: "t", tags: ["a"], localOnly: true, metadata: ["k": "v"]
        )
        XCTAssertNil(options.documentFormat)
        XCTAssertEqual(options.title, "t")
        XCTAssertEqual(options.tags, ["a"])
        XCTAssertTrue(options.localOnly)
    }

    func testTheLocalMetadataRowCarriesTheFormatAndOlderRowsStillDecode() throws {
        var entry = LocalMetadataEntry(documentId: "d")
        entry.documentFormat = 2
        let round = try JSONDecoder().decode(
            LocalMetadataEntry.self, from: try JSONEncoder().encode(entry)
        )
        XCTAssertEqual(round.documentFormat, 2)

        // A row written before the field existed decodes with it absent —
        // which is exactly "this client does not know the format yet", the
        // state the message-size rule reads.
        let legacy = try XCTUnwrap(#"{"documentId":"old"}"#.data(using: .utf8))
        let decoded = try JSONDecoder().decode(LocalMetadataEntry.self, from: legacy)
        XCTAssertNil(decoded.documentFormat)
        XCTAssertTrue(Format2Transport.needsRaisedMessageSize(
            storedDocumentFormat: decoded.documentFormat
        ))
    }

    func testDocumentInfoDecodesTheFormatAndDefaultsToNilWithoutIt() throws {
        let withFormat = try XCTUnwrap("""
        {"documentId":"d","title":"t","createdBy":"u","createdAt":"2026-01-01T00:00:00Z",
         "lastModified":"2026-01-01T00:00:00Z","permission":"owner","documentFormat":2}
        """.data(using: .utf8))
        XCTAssertEqual(
            try JSONDecoder().decode(DocumentInfo.self, from: withFormat).documentFormat, 2
        )

        // Every document the server has ever described omits it, so absent
        // must decode rather than throw.
        let without = try XCTUnwrap("""
        {"documentId":"d","title":"t","createdBy":"u","createdAt":"2026-01-01T00:00:00Z",
         "lastModified":"2026-01-01T00:00:00Z","permission":"owner"}
        """.data(using: .utf8))
        XCTAssertNil(
            try JSONDecoder().decode(DocumentInfo.self, from: without).documentFormat
        )
    }

    // MARK: - Behavior 14 — the storage refusal

    func testAMemoryProviderCannotHostALargeDocument() async throws {
        // `MemoryStorageProvider` deliberately does not conform to
        // `Format2SqlHost`: a provider that cannot host a large document is a
        // type-level fact, not a runtime capability probe.
        let memory = MemoryStorageProvider()
        try await memory.initialize(namespace: "test")
        XCTAssertNil(
            memory as? any Format2SqlHost,
            "an in-memory provider must not claim it can host a record store"
        )
    }

    func testTheRefusalNamesTheReasonTheJavaScriptClientNames() {
        let error = Format2Storage.unavailable(reason: .notPersistent)
        XCTAssertEqual(error.code, .format2StorageUnavailable)
        XCTAssertEqual(error.details?["reason"]?.stringValue, "not-persistent")

        let overQuota = Format2Storage.unavailable(reason: .overQuota)
        XCTAssertEqual(overQuota.details?["reason"]?.stringValue, "over-quota")
    }

    func testResolvingAHostRefusesAMemoryProviderAndAcceptsSqlite() async throws {
        let memory = MemoryStorageProvider()
        try await memory.initialize(namespace: "test")
        XCTAssertThrowsError(try Format2Storage.host(for: memory)) { error in
            let typed = error as? JsBaoError
            XCTAssertEqual(typed?.code, .format2StorageUnavailable)
            XCTAssertEqual(typed?.details?["reason"]?.stringValue, "not-persistent")
        }

        let directory = NSTemporaryDirectory() + "/f2-surface-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let sqlite = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await sqlite.initialize(namespace: "test")
        XCTAssertNoThrow(try Format2Storage.host(for: sqlite))
    }

    // MARK: - Helpers

    private static func encode(_ options: CreateDocumentOptions) throws -> [String: Any] {
        let data = try JSONEncoder().encode(options)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
