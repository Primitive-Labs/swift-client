import XCTest
@testable import JsBaoClient

/// A large document that is also local-only is refused at create (#3759).
///
/// A large document's records live in a store the server's room opens, which a
/// local-only document never reaches — so the combination is not a document
/// that syncs late, it is one that can never work. The JS client has refused it
/// at create since #3654; Swift accepted it silently, wrote the local metadata
/// row, never committed it, and surfaced the failure at open, far from the call
/// that caused it.
///
/// What is asserted here is the refusal AND its boundary: the three doors a
/// create reaches Swift through all refuse with the same code before any local
/// state moves, and every neighbouring combination still creates exactly as it
/// did. Server-free: the client is built over a temporary `.sqlite` directory
/// with `autoNetwork: false` and an unreachable `wsUrl`, and the background
/// create commit is intercepted by `createRemoteDocument`.
final class Format2CreateLocalOnlyHermeticTests: XCTestCase {

    /// How long a create's background commit is given to put a body on the
    /// wire. The refusal cases assert NO body inside this window; behavior 5's
    /// positive controls assert a body arrives inside it, which is what makes
    /// the negative worth anything (edge E2).
    private static let commitWait: TimeInterval = 2.0

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    /// A fresh database file path. `.sqlite(directory:)` takes the FILE path
    /// its own callers pass; the enclosing directory is what gets cleaned up.
    private func newDatabasePath() -> String {
        let directory = NSTemporaryDirectory() + "/f2-localonly-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory + "/store.sqlite"
    }

    private func newDocId() -> String { ULID.generate() }

    private func sqliteClient(databasePath: String? = nil) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "format2-create-local-only-test-app",
            token: makeTestJwt(userId: "format2-local-only-user"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: databasePath ?? newDatabasePath()),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        return client
    }

    /// Record every body the background create commit would post, and answer
    /// it the way the server would, so a create that IS allowed completes.
    @discardableResult
    private func recordCommits(_ client: JsBaoClient) -> LockedBox<[[String: Any]]> {
        let bodies = LockedBox<[[String: Any]]>([])
        client.documentManager.createRemoteDocument = { body in
            bodies.withValue { $0.append(body) }
            return ["documentId": body["documentId"] as? String ?? ""]
        }
        return bodies
    }

    private func sleepThroughTheCommitWindow() async throws {
        try await Task.sleep(nanoseconds: UInt64(Self.commitWait * 1_000_000_000))
    }

    private func waitForACommitBody(
        _ bodies: LockedBox<[[String: Any]]>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(Self.commitWait)
        while Date() < deadline {
            if let body = bodies.value.first { return body }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(
            "no create commit body inside \(Self.commitWait)s — the refusal cases' "
            + "\"no body\" assertion is only worth something while this window is "
            + "long enough to see one",
            file: file, line: line
        )
        throw Unmet.noCommitBody
    }

    /// A premise this suite states and then finds untrue. Reported by the
    /// `XCTFail` beside the throw; the throw only stops the case reading on
    /// against state it has already said is wrong.
    private enum Unmet: Error {
        case noCommitBody
        case didNotThrow
    }

    /// Run `body`, require that it threw, and hand back the thrown error.
    private func expectThrow(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async throws -> Error {
        do {
            try await body()
        } catch {
            return error
        }
        XCTFail("\(description) did not throw", file: file, line: line)
        throw Unmet.didNotThrow
    }

    private func assertIsTheRefusal(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let jsBao = try XCTUnwrap(
            error as? JsBaoError,
            "expected a JsBaoError, got \(error)", file: file, line: line
        )
        XCTAssertEqual(
            jsBao.code, .localOnlyUnsupportedOption,
            "the JS client refuses this combination with LOCAL_ONLY_UNSUPPORTED_OPTION",
            file: file, line: line
        )
        XCTAssertEqual(
            jsBao.code.rawValue, "LOCAL_ONLY_UNSUPPORTED_OPTION",
            "the code travels by its JS string", file: file, line: line
        )
        XCTAssertNil(
            jsBao.details,
            "JS passes no details for this refusal; parity is a nil `details`",
            file: file, line: line
        )
        // The message's VOCABULARY, not the whole sentence: a JS rewording must
        // not fail a Swift test for a reason that has nothing to do with Swift
        // (3759-SO-03).
        for phrase in ["documentFormat: 2", "localOnly: true", "a large document"] {
            XCTAssertTrue(
                jsBao.message.contains(phrase),
                "the message does not say `\(phrase)`: \(jsBao.message)",
                file: file, line: line
            )
        }
    }

    // MARK: - Behavior 1 — the client door refuses

    func testTheClientDoorRefusesALocalOnlyLargeDocument() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }
        recordCommits(client)

        let error = try await expectThrow("createDocument with the combination") {
            _ = try await client.createDocument(options: CreateDocumentOptions(
                title: "x", localOnly: true, documentFormat: 2
            ))
        }
        try assertIsTheRefusal(error)
    }

    // MARK: - Behavior 2 / edge E2 — nothing local moved

    func testTheClientDoorRefusalMovesNoLocalState() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }
        let bodies = recordCommits(client)

        let events = LockedBox<[DocumentMetadataChangedEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentMetadataChangedEvent.self) {
            event in events.withValue { $0.append(event) }
        }
        defer { subscription.cancel() }

        let error = try await expectThrow("createDocument with the combination") {
            _ = try await client.createDocument(options: CreateDocumentOptions(
                title: "x", localOnly: true, documentFormat: 2
            ))
        }
        try assertIsTheRefusal(error)

        XCTAssertEqual(
            client.listPendingCreates(), [],
            "a refused create must leave no pending create behind"
        )
        // The commit is scheduled on a background task, so "no body" is only a
        // claim once the window a scheduled commit would have used has passed.
        try await sleepThroughTheCommitWindow()
        XCTAssertEqual(
            bodies.value.count, 0,
            "a refused create must never reach `createRemoteDocument`; bodies: \(bodies.value)"
        )
        XCTAssertEqual(
            events.value.count, 0,
            "a refused create must emit no metadata event; events: \(events.value.map(\.action))"
        )
    }

    // MARK: - Behavior 3 — the direct door refuses and persists nothing

    func testTheDirectDoorRefusesAndPersistsNothing() async throws {
        let databasePath = newDatabasePath()
        let client = await sqliteClient(databasePath: databasePath)
        recordCommits(client)
        let documentId = newDocId()

        let error = try await expectThrow("createLocalDocument with the combination") {
            _ = try await client.documentManager.createLocalDocument(
                documentId: documentId,
                title: "x",
                localOnly: true,
                documentFormat: 2
            )
        }
        try assertIsTheRefusal(error)

        XCTAssertNil(
            client.documentManager.getLocalMetadata(documentId),
            "a refused create must write no metadata row"
        )
        XCTAssertFalse(
            client.documentManager.isPendingCreate(documentId),
            "nor register a pending create"
        )
        XCTAssertFalse(
            client.isLocalOnly(documentId),
            "nor classify the document as local-only"
        )

        // And nothing was PERSISTED either: a second client over the same
        // database reads the store, not this instance's memory.
        await client.destroy()
        let reopened = await sqliteClient(databasePath: databasePath)
        defer { Task { await reopened.destroy() } }
        XCTAssertNil(
            reopened.documentManager.getLocalMetadata(documentId),
            "the refused create left a persisted row behind"
        )
    }

    // MARK: - Edge E3 — no half-registered classification survives the throw

    func testTheSameIdCreatesNormallyAfterARefusal() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }
        let bodies = recordCommits(client)
        let documentId = newDocId()

        _ = try await expectThrow("createLocalDocument with the combination") {
            _ = try await client.documentManager.createLocalDocument(
                documentId: documentId, title: "x", localOnly: true, documentFormat: 2
            )
        }

        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "x", localOnly: false, documentFormat: 2
        )
        XCTAssertEqual(
            client.documentManager.getLocalMetadata(documentId)?.documentFormat, 2,
            "the same id must create normally once the impossible combination is dropped"
        )
        XCTAssertTrue(client.documentManager.isPendingCreate(documentId))
        XCTAssertFalse(client.isLocalOnly(documentId))
        XCTAssertEqual(bodies.value.count, 0, "this door schedules no commit itself")
    }

    // MARK: - Behavior 4 — the sub-API doors

    func testTheDocumentsApiRefusesWithAWiredClient() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }
        recordCommits(client)

        let error = try await expectThrow("documents.create with the combination") {
            _ = try await client.documents.create(options: CreateDocumentOptions(
                title: "x", localOnly: true, documentFormat: 2
            ))
        }
        try assertIsTheRefusal(error)
        XCTAssertEqual(client.listPendingCreates(), [])
    }

    func testTheIsolatedDocumentsApiRefusesBeforeItAsksTheServer() async throws {
        let recorder = ApiParityTests.CallRecorder()
        let api = DocumentsAPI(
            transport: recorder,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )

        let error = try await expectThrow("an isolated DocumentsAPI.create") {
            _ = try await api.create(options: CreateDocumentOptions(
                title: "x", localOnly: true, documentFormat: 2
            ))
        }
        try assertIsTheRefusal(error)
        XCTAssertNil(
            recorder.path,
            "the isolated fallback must refuse before it builds a request; it sent "
            + "\(recorder.method ?? "-") \(recorder.path ?? "-")"
        )
    }

    // MARK: - Edge E4 — the isolated door refuses only the impossible pair

    func testTheIsolatedDocumentsApiStillPostsAnOrdinaryLocalOnlyCreate() async throws {
        let recorder = ApiParityTests.CallRecorder()
        recorder.response = ["metadata": ["documentId": "01ARZ3NDEKTSV4RRFFQ69G5FAV"]]
        let api = DocumentsAPI(
            transport: recorder,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )

        _ = try await api.create(options: CreateDocumentOptions(
            title: "x", localOnly: true, documentFormat: 1
        ))
        XCTAssertEqual(recorder.method, "POST")
        XCTAssertEqual(
            recorder.path, "/documents",
            "the fallback's guard refuses only `documentFormat: 2` with `localOnly: true`"
        )
    }

    // MARK: - Behavior 5 / edge E1 — the positive controls

    func testLocalOnlyAloneStillCreates() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }
        let bodies = recordCommits(client)

        let result = try await client.createDocument(
            options: CreateDocumentOptions(title: "x", localOnly: true)
        )
        let documentId = try XCTUnwrap(
            result.metadata?.objectValue?["documentId"]?.stringValue
        )
        let row = try XCTUnwrap(client.documentManager.getLocalMetadata(documentId))
        XCTAssertEqual(row.localOnly, true)
        XCTAssertEqual(row.pendingCreate, false)
        XCTAssertNil(row.documentFormat, "no format was asked for")
        XCTAssertTrue(client.isLocalOnly(documentId))

        try await sleepThroughTheCommitWindow()
        XCTAssertEqual(
            bodies.value.count, 0, "a local-only document is never committed to the server"
        )
    }

    func testLocalOnlyWithFormatOneStillCreates() async throws {
        let client = await sqliteClient()
        defer { Task { await client.destroy() } }
        let bodies = recordCommits(client)

        let result = try await client.createDocument(
            options: CreateDocumentOptions(title: "x", localOnly: true, documentFormat: 1)
        )
        let documentId = try XCTUnwrap(
            result.metadata?.objectValue?["documentId"]?.stringValue
        )
        let row = try XCTUnwrap(client.documentManager.getLocalMetadata(documentId))
        XCTAssertEqual(row.localOnly, true)
        XCTAssertEqual(row.pendingCreate, false)
        XCTAssertEqual(row.documentFormat, 1)
        XCTAssertTrue(client.isLocalOnly(documentId))

        try await sleepThroughTheCommitWindow()
        XCTAssertEqual(bodies.value.count, 0)
    }

    /// The third control, and the one that proves the commit window above is
    /// long enough to see a body when one is scheduled (edge E2). Both spellings
    /// of "not local-only" are driven: the explicit `false` and the struct's own
    /// default (edge E1).
    func testALargeDocumentThatIsNotLocalOnlyStillCreates() async throws {
        for explicit in [true, false] {
            let client = await sqliteClient()
            defer { Task { await client.destroy() } }
            let bodies = recordCommits(client)

            let options = explicit
                ? CreateDocumentOptions(title: "x", localOnly: false, documentFormat: 2)
                : CreateDocumentOptions(title: "x", documentFormat: 2)
            let result = try await client.createDocument(options: options)
            let documentId = try XCTUnwrap(
                result.metadata?.objectValue?["documentId"]?.stringValue
            )
            let row = try XCTUnwrap(client.documentManager.getLocalMetadata(documentId))
            XCTAssertEqual(
                row.documentFormat, 2,
                "localOnly \(explicit ? "explicitly false" : "left at its default")"
            )
            XCTAssertEqual(row.localOnly, false)
            XCTAssertFalse(client.isLocalOnly(documentId))

            let body = try await waitForACommitBody(bodies)
            XCTAssertEqual(
                body["documentFormat"] as? Int, 2,
                "the server decides the format from the create; body: \(body)"
            )
        }
    }

    // MARK: - Behavior 6 — one rule, called from both doors

    func testTheValidatorGuardsBothDoorsBeforeAnythingElse() throws {
        let manager = try source("Sources/JsBaoClient/Internal/DocumentManager.swift")
        let create = try body(of: "func createLocalDocument(", in: manager)
        let guardCall = try XCTUnwrap(
            create.range(of: "assertDocumentFormatAllowsLocalOnly("),
            "`createLocalDocument` does not call the shared validator"
        )
        let firstEntry = try XCTUnwrap(
            create.range(of: "LocalMetadataEntry("),
            "`createLocalDocument` no longer builds a LocalMetadataEntry — retarget this pin"
        )
        XCTAssertTrue(
            guardCall.lowerBound < firstEntry.lowerBound,
            "the refusal has to happen before any local state is built, taken or written"
        )

        let api = try source("Sources/JsBaoClient/API/DocumentsAPI.swift")
        let isolated = try body(of: "func create(options: CreateDocumentOptions", in: api)
        let isolatedGuard = try XCTUnwrap(
            isolated.range(of: "assertDocumentFormatAllowsLocalOnly("),
            "`DocumentsAPI.create`'s isolated fallback does not call the shared validator"
        )
        let request = try XCTUnwrap(
            isolated.range(of: "transport.request("),
            "`DocumentsAPI.create` no longer posts directly — retarget this pin"
        )
        XCTAssertTrue(
            isolatedGuard.lowerBound < request.lowerBound,
            "the fallback must refuse before it builds the request"
        )
    }

    // MARK: - Source reading

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // JsBaoClientTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-client
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    /// A declaration's OWN body, never a window of characters after a landmark:
    /// the parameter list is balanced first (it carries parentheses of its own,
    /// and a default value carries more), then the braces from the `{` that
    /// opens the body. Eight guards in this project have gone red for a line
    /// added somewhere else inside a fixed window; this one can only go red for
    /// a change to the method it names.
    private func body(of signature: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(
            text.range(of: signature), "`\(signature)` is not in this file"
        )
        var index = try XCTUnwrap(
            text[start.lowerBound...].firstIndex(of: "("),
            "`\(signature)` has no parameter list"
        )
        var depth = 0
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            index = text.index(after: index)
        }
        var open = try XCTUnwrap(
            text[index...].firstIndex(of: "{"), "`\(signature)` has no body"
        )
        let bodyStart = open
        depth = 0
        while open < text.endIndex {
            if text[open] == "{" { depth += 1 }
            if text[open] == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            open = text.index(after: open)
        }
        return text[bodyStart...open]
    }
}
