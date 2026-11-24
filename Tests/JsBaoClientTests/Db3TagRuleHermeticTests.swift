import XCTest
@testable import JsBaoClient

/// #6371 behaviors 10 and 11, and the Swift halves of the edge cases — the
/// db3 tag rule and the db3 path-segment guard in the Swift client.
///
/// `Db3API.create` (both overloads, `localOnly` included) and
/// `getOrCreateWithAlias` throw `.invalidArgument` before any request for a
/// tag that breaks the db3 tag rule; the rule is the generated `Db3TagRule`,
/// checked here against the one vector file (`Fixtures/Db3TagRule`, inside
/// this target, so the test reads nothing outside `swift-client/`). Every
/// db3 path segment goes through `URLEncoding.pathSegment`: exactly `.` or
/// `..` throws `.invalidArgument` with no request recorded and no upload
/// queued; anything else is sent as before. Query values and the documents
/// blob paths are left alone.
final class Db3TagRuleHermeticTests: XCTestCase {

    private static let id = "01JD6371TAG000000000000AAA"

    private struct Vectors: Decodable {
        struct Row: Decodable {
            let tag: String
            let valid: Bool
        }
        let rows: [Row]
    }

    /// The vector file, read by a path inside this test target.
    private func vectors() throws -> [Vectors.Row] {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()
        let file = url.appendingPathComponent("Fixtures/Db3TagRule/vectors.json")
        XCTAssertTrue(file.standardizedFileURL.path.contains("/swift-client/Tests/"), file.path)
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file)).rows
    }

    private func transport(status: Int = 200, json: String = "{}") -> RecordingTransport {
        RecordingTransport(status: status, json: json)
    }

    private func api(_ transport: RecordingTransport) -> Db3API {
        Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport)
    }

    private func manager(_ transport: RecordingTransport) -> BlobManager {
        BlobManager(
            logger: createLogger(level: .error, scope: "test"), transport: transport,
            getApiUrl: { "https://api.test" }, getAppId: { "app1" }
        )
    }

    private func blobs(_ transport: RecordingTransport, _ db3Id: String = id) -> Db3BlobContext {
        Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport, blobManager: manager(transport)).blobs(db3Id)
    }

    /// The `JsBaoError` `body` throws, or `nil` when it throws none (or another kind).
    private func refusal(_ body: () async throws -> Void) async -> JsBaoError? {
        do {
            try await body()
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            return nil
        }
    }

    private func assertInvalidArgument(_ error: JsBaoError?, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(error?.code, .invalidArgument, "\(label): \(String(describing: error))", file: file, line: line)
    }

    // MARK: - Behavior 10: the tag rule

    func testTheMirrorGivesTheVectorFilesVerdictOnEveryRow() throws {
        let rows = try vectors()
        XCTAssertTrue(rows.contains { $0.tag == "__ROOT_TAG__" && !$0.valid })
        XCTAssertTrue(rows.contains { $0.tag == String(repeating: "x", count: 48) && $0.valid })
        XCTAssertTrue(rows.contains { $0.tag == String(repeating: "x", count: 49) && !$0.valid })
        for row in rows {
            XCTAssertEqual(Db3TagRule.violation(row.tag) == nil, row.valid, row.tag.debugDescription)
        }
    }

    func testEveryCreateRefusesARuleBreakingTagBeforeAnyRequest() async throws {
        for row in try vectors() where !row.valid {
            let wire = transport(status: 201)
            let db3 = api(wire)
            let label = row.tag.debugDescription
            assertInvalidArgument(await refusal { _ = try await db3.create(title: "t", tags: [row.tag]) }, "create \(label)")
            assertInvalidArgument(
                await refusal { _ = try await db3.create(title: "t", sync: false, custodian: "app", tags: ["ok", row.tag], allowUnknownType: false) },
                "direct create \(label)"
            )
            let localOnly = await refusal { _ = try await db3.create(title: "t", tags: [row.tag], localOnly: true) }
            assertInvalidArgument(localOnly, "localOnly \(label)")
            XCTAssertEqual(localOnly?.details?["tag"], .string(row.tag), "localOnly \(label)")
            let options = Db3GetOrCreateWithAliasOptions(alias: AliasRef(scope: .user, aliasKey: "home", userId: "u-1"), title: "t", tags: [row.tag])
            assertInvalidArgument(await refusal { _ = try await db3.getOrCreateWithAlias(options) }, "alias \(label)")
            XCTAssertTrue(wire.calls.isEmpty, "\(label): \(wire.calls.map(\.path))")
        }
    }

    func testTheTagIsReportedAheadOfALocalOnlyOptionRefusal() async {
        let db3 = api(transport())
        let error = await refusal { _ = try await db3.create(title: "t", custodian: "app", tags: ["a.b"], localOnly: true) }
        assertInvalidArgument(error, "localOnly with custodian")
        XCTAssertEqual(error?.details?["tag"], .string("a.b"))
    }

    func testEveryCreateSendsATagThatMeetsTheRule() async throws {
        let answer = """
        {"id": "\(Self.id)", "title": "t", "createdBy": "u-1", "createdAt": "c", "modifiedAt": "m", "custodian": "app",
         "sync": false, "type": null, "tags": []}
        """
        for row in try vectors() where row.valid {
            let wire = transport(status: 201, json: answer)
            let db3 = api(wire)
            _ = try await db3.create(title: "t", sync: false, custodian: "app", tags: [row.tag], allowUnknownType: false)
            XCTAssertEqual(wire.lastCall?.path, "/db3", row.tag)
            if case .object(let body)? = wire.lastCall?.jsonBody {
                XCTAssertEqual(body["tags"], .array([.string(row.tag)]), row.tag)
            } else {
                XCTFail("create sent no body for \(row.tag)")
            }
            // Without a client a localOnly create is refused for want of a user, never for the tag.
            let localOnly = await refusal { _ = try await db3.create(title: "t", tags: [row.tag], localOnly: true) }
            XCTAssertNil(localOnly?.details?["tag"], row.tag)
        }
    }

    // MARK: - Behavior 11: the path-segment guard

    func testADotOnlySegmentIsRefusedWithNoRequest() async throws {
        let wire = transport()
        let db3 = api(wire)
        for dots in [".", ".."] {
            assertInvalidArgument(await refusal { _ = try await db3.get(dots) }, "get \(dots)")
            assertInvalidArgument(await refusal { _ = try await db3.delete(dots) }, "delete \(dots)")
            assertInvalidArgument(await refusal { try await db3.permissions(Self.id).remove(.userId(dots)) }, "permission remove \(dots)")
            assertInvalidArgument(await refusal { try await db3.indexes.drop(Self.id, name: dots) }, "index drop \(dots)")
            assertInvalidArgument(await refusal { _ = try await db3.indexes.fetchModel(Self.id, name: dots) }, "fetchModel \(dots)")
            assertInvalidArgument(await refusal { _ = try await db3.aliases.resolve(AliasRef(scope: .user, aliasKey: dots)) }, "alias \(dots)")
        }
        XCTAssertTrue(wire.calls.isEmpty, "\(wire.calls.map(\.path))")
    }

    func testADotOnlyModelOnAWriteWhereIsRefusedWithNoRequest() async throws {
        let wire = transport()
        let db3 = api(wire)
        for dots in [".", ".."] {
            assertInvalidArgument(
                await refusal { _ = try await db3.deleteWhere(Self.id, model: dots, filter: [:]) },
                "deleteWhere \(dots)"
            )
            assertInvalidArgument(
                await refusal { _ = try await db3.patchWhere(Self.id, model: dots, filter: [:], data: ["a": .bool(true)]) },
                "patchWhere \(dots)"
            )
        }
        XCTAssertTrue(wire.calls.isEmpty, "\(wire.calls.map(\.path))")
    }

    /// The ids a pending-create wait was asked about. The wait throws
    /// `.pendingCreate`, as it does offline for a db3 whose create has not
    /// committed; online it would start that commit.
    private final class PendingWaits: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        var ids: [String] { lock.lock(); defer { lock.unlock() }; return asked }
        func wait(_ db3Id: String) throws {
            lock.lock()
            asked.append(db3Id)
            lock.unlock()
            throw JsBaoError(code: .pendingCreate, message: "pending", details: ["db3Id": .string(db3Id)])
        }
    }

    func testADotOnlySegmentOnAPendingDb3IsRefusedBeforeTheCreateWait() async throws {
        let wire = transport()
        let waits = PendingWaits()
        let awaitCreate: @Sendable (String) async throws -> Void = { try waits.wait($0) }
        let permissions = Db3PermissionsAPI(db3Id: Self.id, transport: wire, awaitCreate: awaitCreate)
        let indexes = Db3IndexesAPI(transport: wire, awaitCreate: awaitCreate)
        let ingests = Db3IngestsAPI(transport: wire, awaitCreate: awaitCreate)
        for dots in [".", ".."] {
            assertInvalidArgument(await refusal { try await permissions.remove(.userId(dots)) }, "permission remove \(dots)")
            assertInvalidArgument(await refusal { _ = try await permissions.revokePendingInvitation(dots) }, "invitation \(dots)")
            assertInvalidArgument(await refusal { _ = try await permissions.revokeGroup(dots) }, "group \(dots)")
            assertInvalidArgument(await refusal { _ = try await permissions.approveAccessRequest(dots) }, "approve \(dots)")
            assertInvalidArgument(await refusal { _ = try await permissions.denyAccessRequest(dots) }, "deny \(dots)")
            assertInvalidArgument(await refusal { try await indexes.drop(Self.id, name: dots) }, "index drop \(dots)")
            assertInvalidArgument(await refusal { _ = try await indexes.fetchModel(Self.id, name: dots) }, "fetchModel \(dots)")
            assertInvalidArgument(await refusal { _ = try await indexes.deleteModel(Self.id, name: dots) }, "deleteModel \(dots)")
            assertInvalidArgument(await refusal { _ = try await ingests.commit(db3Id: Self.id, sessionId: dots) }, "ingest commit \(dots)")
            assertInvalidArgument(await refusal { _ = try await ingests.abort(db3Id: Self.id, sessionId: dots) }, "ingest abort \(dots)")
            assertInvalidArgument(await refusal { _ = try await ingests.get(db3Id: Self.id, sessionId: dots) }, "ingest get \(dots)")
        }
        XCTAssertEqual(waits.ids, [], "no pending-create wait began")
        XCTAssertTrue(wire.calls.isEmpty, "\(wire.calls.map(\.path))")

        // A segment that passes still waits for the pending create first.
        let pending = await refusal { try await permissions.remove(.userId("a.b")) }
        XCTAssertEqual(pending?.code, .pendingCreate)
        XCTAssertEqual(waits.ids, [Self.id])
        XCTAssertTrue(wire.calls.isEmpty, "\(wire.calls.map(\.path))")
    }

    func testADotOnlyBlobIdOrDb3IdIsRefusedBeforeAnyQueueOrRequest() async throws {
        let wire = transport()
        let context = blobs(wire)
        assertInvalidArgument(await refusal { _ = try await context.delete(blobId: "..") }, "delete ..")
        assertInvalidArgument(await refusal { _ = try await context.read(blobId: "..") }, "read ..")
        assertInvalidArgument(await refusal { _ = try await context.get(blobId: "..") }, "get ..")
        assertInvalidArgument(await refusal { _ = try context.downloadUrl(blobId: "..") }, "downloadUrl ..")
        assertInvalidArgument(await refusal { _ = try context.downloadRequest(blobId: ".") }, "downloadRequest .")
        assertInvalidArgument(await refusal { _ = try await context.deleteBatch(blobIds: [".."]) }, "deleteBatch ..")

        let dotted = blobs(wire, "..")
        assertInvalidArgument(await refusal { _ = try await dotted.upload(data: Data("x".utf8)) }, "upload to ..")
        assertInvalidArgument(await refusal { _ = try await dotted.list() }, "list of ..")
        assertInvalidArgument(await refusal { _ = try await dotted.get(blobId: "B1") }, "get in ..")
        assertInvalidArgument(await refusal { _ = try dotted.downloadUrl(blobId: "B1") }, "downloadUrl in ..")
        let queued = await dotted.uploadsAsync()
        XCTAssertTrue(queued.isEmpty, "no upload queued")
        XCTAssertTrue(wire.calls.isEmpty, "\(wire.calls.map(\.path))")
    }

    func testPrefetchOfADotOnlyIdThrowsBeforeFetchingAnything() async throws {
        let wire = transport()
        let context = blobs(wire)
        assertInvalidArgument(await refusal { try await context.prefetch(blobIds: ["B1", ".."]) }, "prefetch B1, ..")
        assertInvalidArgument(await refusal { try await context.prefetch(blobIds: ["."]) }, "prefetch .")
        assertInvalidArgument(await refusal { try await self.blobs(wire, "..").prefetch(blobIds: ["B1"]) }, "prefetch in ..")
        XCTAssertTrue(wire.calls.isEmpty, "\(wire.calls.map(\.path))")
    }

    func testEveryOtherValueBuildsTheSamePathAsBefore() async throws {
        let wire = transport(json: #"{"blobId":"a.b","filename":"a.txt","success":true,"deleted":true}"#)
        let db3 = api(wire)
        _ = try? await db3.get("a.b")
        try? await db3.permissions(Self.id).remove(.userId("a.b"))
        try? await db3.indexes.drop(Self.id, name: "...")
        let context = blobs(wire)
        _ = try? await context.get(blobId: "a.b")
        _ = try? await context.delete(blobId: "...")
        _ = try? await context.get(blobId: "a b")
        XCTAssertEqual(wire.calls.map(\.path), [
            "/db3/a.b",
            "/db3/\(Self.id)/permissions/a.b",
            "/db3/\(Self.id)/indexes/...",
            "/db3/\(Self.id)/blobs/a.b",
            "/db3/\(Self.id)/blobs/...",
            "/db3/\(Self.id)/blobs/a%20b",
        ])
        XCTAssertEqual(try context.downloadUrl(blobId: "a.b"), "https://api.test/app/app1/api/db3/\(Self.id)/blobs/a.b/download")
    }

    func testQueryValuesAreLeftAlone() async throws {
        let wire = transport(json: #"{"success":true}"#)
        let db3 = api(wire)
        try? await db3.permissions(Self.id).remove(.email(".."))
        _ = try? await db3.aliases.resolve(AliasRef(scope: .user, aliasKey: "home", userId: "."))
        let paths = wire.calls.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasPrefix("/db3/\(Self.id)/permissions") && $0.contains("email=..") }, "\(paths)")
        XCTAssertTrue(paths.contains("/db3-aliases/user/home?userId=."), "\(paths)")
    }

    // MARK: - The documents blob calls (pin)

    @available(*, deprecated)
    func testTheDocumentsBlobPathsAreUnchanged() async throws {
        let wire = transport(json: #"{"blobId":"B1","filename":"a.txt","deleted":true,"items":[],"hasMore":false}"#)
        let documents = DocumentBlobContext(documentId: "D1", transport: wire, blobManager: manager(wire))
        _ = try? await documents.get(blobId: "blob_1")
        _ = try? await documents.delete(blobId: "blob_1")
        _ = try? await documents.list()
        XCTAssertEqual(wire.calls.map(\.path), ["/documents/D1/blobs/blob_1", "/documents/D1/blobs/blob_1", "/documents/D1/blobs"])
        XCTAssertEqual(documents.downloadUrl(blobId: "blob_1"), "https://api.test/app/app1/api/documents/D1/blobs/blob_1/download")
        let spaced = documents.downloadUrl(blobId: "a b")
        XCTAssertTrue(spaced.hasPrefix("https://api.test/app/app1/api/documents/D1/blobs/"), spaced)
        XCTAssertEqual(spaced, manager(wire).downloadUrl(documentId: "D1", blobId: "a b"))
    }
}
