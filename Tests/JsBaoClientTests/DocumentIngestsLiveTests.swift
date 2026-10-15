import XCTest
@testable import JsBaoClient

/// #4475 — bulk loads driven from the Swift client, against the dev server.
///
/// - Behavior 13 and E1: no options sends no body and the session takes the
///   defaults; `mode`, `models` and `reserveEpoch` are echoed; an option the
///   document's format does not take is the server's
///   `400 INGEST_OPTION_INVALID`.
/// - Behavior 14 and E2: a merge load built with `buildChunks` completes and
///   its rows read back, a `_deleted` row removing a record saved before it;
///   a refresh empties a model `models` names and removes the covered rows no
///   row named. The merge test's `// #region example` block is the documents
///   guide's Swift example (`primitive-docs/examples/documents/bulk-load.swift`):
///   the docs gate holds the two equal.
/// - Behavior 15: abort ends an uploading session and a second abort is
///   refused; `get` decodes a completed session's record-log fields.
/// - E8: a session id carrying `/` and `?` addresses that id and nothing else.
final class DocumentIngestsLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "n": FieldDescriptor(type: .number)]
    )
    private static let tag = PrimitiveSchema(
        name: "Tag",
        fields: ["id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-document-ingests-4475")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func driver(_ documentId: String) -> RecordLogLoadDriver {
        RecordLogLoadDriver(ctx: ctx, appId: live.app.appId, documentId: documentId, jwt: live.app.ownerJWT)
    }

    /// The server's refusal, as the `HttpError` it reached the caller as.
    private func refusal(
        _ body: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line
    ) async -> HttpError? {
        do {
            _ = try await body()
            XCTFail("the request was not refused", file: file, line: line)
        } catch let error as HttpError {
            return error
        } catch {
            XCTFail("refused with \(error)", file: file, line: line)
        }
        return nil
    }

    /// Poll a session until it is terminal.
    private func finished(_ client: JsBaoClient, _ documentId: String, _ sessionId: String) async throws -> DocumentIngestSession {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let view = try await client.documents.ingests.get(documentId: documentId, sessionId: sessionId)
            if ["complete", "failed", "aborted"].contains(view.state) { return view }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TestSetupError("session \(sessionId) did not finish")
    }

    /// `DocumentIngestsAPI` over a transport that records what it is handed
    /// and sends it to the dev server as it is.
    private func observedIngests() -> (DocumentIngestsAPI, RecordingTransport) {
        let appId = live.app.appId
        let jwt = live.app.ownerJWT
        let recorder = RecordingTransport(responder: { call in
            var request = URLRequest(url: URL(string: "\(TestConfig.httpUrl)/app/\(appId)/api\(call.path)")!)
            request.httpMethod = call.method.rawValue
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            if let body = call.body {
                request.httpBody = body
                request.setValue(call.options?.customHeaders["Content-Type"] ?? "application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            return TransportResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, headers: [:], body: data)
        })
        return (DocumentIngestsAPI(transport: recorder), recorder)
    }

    // MARK: - Behavior 13, E1

    func testNoOptionsSendsNoBodyAndTheOptionsGivenAreEchoed() async throws {
        let client = try await live.client("ingests", models: [Self.note, Self.tag])
        let (observed, recorder) = observedIngests()
        let plain = try await live.createDocument(client)
        let defaults = try await observed.create(documentId: plain)
        XCTAssertNil(recorder.calls.last?.body)
        XCTAssertEqual(defaults.state, "uploading")
        XCTAssertEqual(defaults.reserveEpoch, .open)
        XCTAssertEqual(defaults.mode, .merge)
        let other = try await live.createDocument(client)
        _ = try await observed.create(documentId: other, options: DocumentIngestCreateOptions())
        XCTAssertNil(recorder.calls.last?.body, "an options value with nothing set sends no body either")
        _ = try await client.documents.ingests.abort(documentId: other, sessionId: (try await client.documents.ingests.list(documentId: other)).items[0].sessionId)

        let documentId = try await live.createDocument(client)
        let session = try await observed.create(
            documentId: documentId,
            options: DocumentIngestCreateOptions(mode: .refresh, models: ["Note"], reserveEpoch: .commit)
        )
        XCTAssertEqual(recorder.calls.last?.jsonBody, ["mode": "refresh", "models": ["Note"], "reserveEpoch": "commit"])
        XCTAssertEqual(session.mode, .refresh)
        XCTAssertEqual(session.reserveEpoch, .commit)
        XCTAssertEqual(session.refusedRows, 0)
        XCTAssertNil(session.load)
        let read = try await client.documents.ingests.get(documentId: documentId, sessionId: session.sessionId)
        XCTAssertEqual(read.sessionId, session.sessionId)
        XCTAssertEqual(read.mode, .refresh)
        XCTAssertEqual(read.reserveEpoch, .commit)
    }

    func testAnOptionTheDocumentDoesNotTakeIsTheServersRefusal() async throws {
        let client = try await live.client("ingests", models: [Self.note])
        let classic = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/documents", body: ["title": "classic"], jwt: live.app.ownerJWT
        )
        let formatOne = try XCTUnwrap(classic["documentId"] as? String)
        for options in [DocumentIngestCreateOptions(reserveEpoch: .commit), DocumentIngestCreateOptions(mode: .refresh)] {
            let error = await refusal { try await client.documents.ingests.create(documentId: formatOne, options: options) }
            XCTAssertEqual(error?.status, 400)
            XCTAssertEqual(error?.serverCode, "INGEST_OPTION_INVALID")
        }
        let plain = await refusal { try await client.documents.ingests.create(documentId: formatOne) }
        XCTAssertEqual(plain?.serverCode, "DOCUMENT_NOT_LARGE")

        // E1: models without a refresh is sent as given, and refused.
        let documentId = try await live.createDocument(client)
        let models = await refusal {
            try await client.documents.ingests.create(documentId: documentId, options: DocumentIngestCreateOptions(models: ["Note"]))
        }
        XCTAssertEqual(models?.status, 400)
        XCTAssertEqual(models?.serverCode, "INGEST_OPTION_INVALID")
        let listed = try await client.documents.ingests.list(documentId: documentId)
        XCTAssertEqual(listed.items.count, 0)
    }

    // MARK: - Behavior 14, E2

    func testAMergeLoadBuiltWithBuildChunksCompletesAndItsRowsReadBack() async throws {
        let client = try await live.client("ingests", models: [Self.note, Self.tag])
        let documentId = try await live.createDocument(client)
        let room = driver(documentId)
        let saved = try await room.save("Note", "gone", ["title": "saved before the load"])
        XCTAssertEqual(saved, 200)
        let before = try await room.record("Note", "gone")
        XCTAssertNotNil(before)
        let rows: [DocumentIngestRow] =
            (0..<600).map { DocumentIngestRow(model: "Note", id: String(format: "note-%04d", $0), patch: ["title": .string("Note \($0)"), "n": .number(Double($0))]) }
            + (0..<20).map { DocumentIngestRow(model: "Tag", id: "tag-\($0)", patch: ["label": .string("Tag \($0)")]) }
            + [DocumentIngestRow(model: "Note", id: "gone", patch: ["_deleted": true])]

        // #region example
        // rows: [DocumentIngestRow(model: "Note", id: "note-1", patch: ["title": "First"]), …]
        let chunks = try client.documents.ingests.buildChunks(rows: rows)
        let session = try await client.documents.ingests.create(
          documentId: documentId,
          options: DocumentIngestCreateOptions(mode: .merge)
        )
        for chunk in chunks {
          _ = try await client.documents.ingests.uploadChunk(
            documentId: documentId, sessionId: session.sessionId, chunk: chunk
          )
        }
        _ = try await client.documents.ingests.commit(documentId: documentId, sessionId: session.sessionId)

        var loaded = try await client.documents.ingests.get(documentId: documentId, sessionId: session.sessionId)
        while !["complete", "failed", "aborted"].contains(loaded.state) {
          try await _Concurrency.Task.sleep(nanoseconds: 1_000_000_000)
          loaded = try await client.documents.ingests.get(documentId: documentId, sessionId: session.sessionId)
        }
        // loaded.state is now "complete", "failed" (loaded.failure says why) or "aborted".
        // loaded.refusedRows counts rows the document refused; refusedSample names the first few.
        // #endregion example

        XCTAssertEqual(chunks.map(\.model), ["Note", "Tag"])
        XCTAssertEqual(loaded.state, "complete", "\(String(describing: loaded.failure))")
        XCTAssertEqual(loaded.mode, .merge)
        XCTAssertEqual(loaded.refusedRows, 0)
        let notes = try await room.count("Note")
        XCTAssertEqual(notes, 600)
        let tags = try await room.count("Tag")
        XCTAssertEqual(tags, 20)
        let sampled = try await room.record("Note", "note-0377")
        XCTAssertEqual(sampled?["title"] as? String, "Note 377")
        XCTAssertEqual((sampled?["n"] as? NSNumber)?.intValue, 377)
        let gone = try await room.record("Note", "gone")
        XCTAssertNil(gone)
    }

    func testARefreshEmptiesTheModelItNamesAndRemovesTheCoveredRowsNoRowNamed() async throws {
        let client = try await live.client("ingests", models: [Self.note, Self.tag])
        let documentId = try await live.createDocument(client)
        let room = driver(documentId)
        var statuses: [Int] = []
        for id in ["a1", "a2", "a3"] { statuses.append(try await room.save("Note", id, ["title": "before"])) }
        for id in ["t1", "t2"] { statuses.append(try await room.save("Tag", id, ["label": "before"])) }
        statuses.append(try await room.save("Label", "l1", ["name": "not covered"]))
        XCTAssertEqual(statuses, [200, 200, 200, 200, 200, 200])
        let seeded = try await room.count("Note")
        XCTAssertEqual(seeded, 3)

        // Note is covered by its rows; Tag has none, so `models` names it.
        let chunks = try client.documents.ingests.buildChunks(rows: [
            DocumentIngestRow(model: "Note", id: "a4", patch: ["title": "loaded"]),
            DocumentIngestRow(model: "Note", id: "a1", patch: ["title": "refreshed"]),
        ])
        let session = try await client.documents.ingests.create(
            documentId: documentId, options: DocumentIngestCreateOptions(mode: .refresh, models: ["Tag"])
        )
        for chunk in chunks {
            _ = try await client.documents.ingests.uploadChunk(documentId: documentId, sessionId: session.sessionId, chunk: chunk)
        }
        _ = try await client.documents.ingests.commit(documentId: documentId, sessionId: session.sessionId)
        let done = try await finished(client, documentId, session.sessionId)
        XCTAssertEqual(done.state, "complete", "\(String(describing: done.failure))")
        XCTAssertEqual(done.mode, .refresh)

        let notes = try await room.count("Note")
        XCTAssertEqual(notes, 2)
        let a1 = try await room.record("Note", "a1")
        XCTAssertEqual(a1?["title"] as? String, "refreshed")
        let a4 = try await room.record("Note", "a4")
        XCTAssertNotNil(a4)
        let a2 = try await room.record("Note", "a2")
        XCTAssertNil(a2)
        let tags = try await room.count("Tag")
        XCTAssertEqual(tags, 0)
        let l1 = try await room.record("Label", "l1")
        XCTAssertEqual(l1?["name"] as? String, "not covered")
    }

    // MARK: - Behavior 15

    func testAbortEndsAnUploadingSessionAndGetDecodesACompletedOne() async throws {
        let client = try await live.client("ingests", models: [Self.note])
        let documentId = try await live.createDocument(client)
        let session = try await client.documents.ingests.create(documentId: documentId)
        let aborted = try await client.documents.ingests.abort(documentId: documentId, sessionId: session.sessionId)
        XCTAssertEqual(aborted.state, "aborted")
        let again = await refusal { try await client.documents.ingests.abort(documentId: documentId, sessionId: session.sessionId) }
        XCTAssertEqual(again?.serverCode, "INGEST_SESSION_NOT_ABORTABLE")

        // A completed load with one row the room refuses.
        let chunks = try client.documents.ingests.buildChunks(rows: [
            DocumentIngestRow(model: "Note", id: "kept", patch: ["title": "kept"]),
            DocumentIngestRow(model: "Note", id: "refused", patch: ["_deleted": true, "title": "beside it"]),
        ])
        let loaded = try await client.documents.ingests.create(documentId: documentId, options: DocumentIngestCreateOptions(reserveEpoch: .commit))
        for chunk in chunks {
            let stored = try await client.documents.ingests.uploadChunk(documentId: documentId, sessionId: loaded.sessionId, chunk: chunk)
            XCTAssertTrue(stored.ok)
            XCTAssertEqual(stored.bytes, chunk.bytes)
        }
        let committed = try await client.documents.ingests.commit(documentId: documentId, sessionId: loaded.sessionId)
        XCTAssertNotEqual(committed.state, "uploading")
        _ = try await finished(client, documentId, loaded.sessionId)
        let view = try await client.documents.ingests.get(documentId: documentId, sessionId: loaded.sessionId)
        XCTAssertEqual(view.state, "complete")
        XCTAssertEqual(view.mode, .merge)
        XCTAssertEqual(view.reserveEpoch, .commit)
        XCTAssertEqual(view.refusedRows, 1)
        XCTAssertEqual(view.refusedSample?.first?.id, "refused")
        XCTAssertEqual(view.refusedSample?.first?.model, "Note")
        XCTAssertNotNil(view.load)
        XCTAssertNotNil(view.timings?.objectValue, "timings stays readable as JSONValue")
        XCTAssertEqual(view.rows, 2)
        let page = try await client.documents.ingests.list(documentId: documentId, limit: 1)
        XCTAssertEqual(page.items.map(\.sessionId), [loaded.sessionId])
        XCTAssertTrue(page.hasMore)
    }

    // MARK: - E8

    func testASessionIdCarryingASlashAndAQuestionMarkAddressesOnlyItself() async throws {
        let client = try await live.client("ingests", models: [Self.note])
        let documentId = try await live.createDocument(client)
        let real = try await client.documents.ingests.create(documentId: documentId)
        let odd = "a/b?c"
        let read = await refusal { try await client.documents.ingests.get(documentId: documentId, sessionId: odd) }
        let ended = await refusal { try await client.documents.ingests.abort(documentId: documentId, sessionId: odd) }
        for error in [read, ended] {
            XCTAssertTrue(
                ["INGEST_SESSION_NOT_FOUND", "INGEST_SESSION_UNADDRESSABLE"].contains(error?.serverCode ?? ""),
                "\(String(describing: error))"
            )
        }
        let untouched = try await client.documents.ingests.get(documentId: documentId, sessionId: real.sessionId)
        XCTAssertEqual(untouched.state, "uploading")
    }
}
