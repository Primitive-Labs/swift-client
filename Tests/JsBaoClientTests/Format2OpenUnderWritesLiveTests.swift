import XCTest
@testable import JsBaoClient

/// A Swift client opens a large document it has never held while a server
/// function is writing into it, against a real room (#4191).
///
/// The application that reported it saw `openDocument` neither resolve nor
/// throw: the room answered within seconds, the state reached the device, and
/// the caller never resumed. The shape here is the report's: the document's
/// overlay is already past the room's inline limit, so the handshake's
/// `syncStep2` arrives as an `updateUrl`, and further writes are broadcast the
/// same way while the open is in flight.
final class Format2OpenUnderWritesLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var testApp: TestApp!
    private var directory: String!
    private var clients: [JsBaoClient] = []

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
            "views": FieldDescriptor(type: .number, indexed: true),
        ]
    )

    /// One invocation writes `input.count` records in one batch, each carrying
    /// a ~1 KB title, so a few invocations put the overlay well past the
    /// room's 100 KB inline limit. Ids are ULIDs (the bulk route mints none):
    /// the caller's 16-character prefix and a Crockford-encoded counter.
    private static let writerBundle = """
    export default async function (input, ctx) {
      const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
      const encode = (n) => {
        let out = "";
        for (let i = 0; i < 10; i++) { out = alphabet[n % 32] + out; n = Math.floor(n / 32); }
        return out;
      };
      const ops = [];
      for (let i = 0; i < input.count; i++) {
        const n = input.start + i;
        ops.push({
          action: "create",
          id: input.prefix + encode(n),
          data: { title: "row " + n + " " + "x".repeat(1000), views: n },
        });
      }
      await ctx.doc(input.documentId, { documentFormat: 2 }).model("Note").batch(ops);
      return { written: ops.length };
    }
    """

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-f2-open-writes")
        directory = NSTemporaryDirectory() + "f2-open-writes-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        try? FileManager.default.removeItem(atPath: directory)
        await ctx?.cleanup()
    }

    /// Writes into the document through the pushed function until stopped,
    /// recording when each successful write ran and the first failure, which
    /// ends the loop: a regression that passed with every write failing would
    /// be testing an idle document.
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private var _stopped = false
        private var _written = 0
        private var _windows: [(started: Date, ended: Date)] = []
        private var _failure: String?
        var stopped: Bool { lock.withLock { _stopped || _failure != nil } }
        var written: Int { lock.withLock { _written } }
        var failure: String? { lock.withLock { _failure } }
        func stop() { lock.withLock { _stopped = true } }
        func add(_ count: Int, started: Date, ended: Date) {
            lock.withLock {
                _written += count
                _windows.append((started, ended))
            }
        }
        func fail(_ reason: String) { lock.withLock { if _failure == nil { _failure = reason } } }
        /// Successful writes that were running at some point in `from...to`.
        func overlapping(from: Date, to: Date) -> Int {
            lock.withLock { _windows.filter { $0.started < to && $0.ended > from }.count }
        }
    }

    private func invokeWriter(
        _ functionKey: String, documentId: String, prefix: String, start: Int, count: Int
    ) async throws {
        let response = try await ctx.appRequest(
            method: "POST",
            appId: testApp.appId,
            path: "/functions/\(functionKey)",
            body: [
                "rootInput": [
                    "documentId": documentId, "prefix": prefix,
                    "start": start, "count": count,
                ],
                "timeoutMs": 25_000,
            ],
            jwt: testApp.ownerJWT
        )
        guard response["status"] as? String == "completed" else {
            throw JsBaoError(code: .unavailable, message: "the writer failed: \(response)")
        }
    }

    func testAnOpenThatStartsUnderServerWritesResolvesWithTheRowsReadable() async throws {
        let created = try await ctx.appRequest(
            method: "POST",
            appId: testApp.appId,
            path: "/documents",
            body: ["title": "written by a function", "documentFormat": 2],
            jwt: testApp.ownerJWT
        )
        let documentId = try XCTUnwrap(created["documentId"] as? String, "\(created)")

        let functionKey = "swift-f2-writer-\(Int(Date().timeIntervalSince1970))"
        try await ctx.pushFunction(
            appId: testApp.appId, functionKey: functionKey, bundle: Self.writerBundle
        )
        let prefix = String(ULID.generate().prefix(16))

        // Well past the room's inline limit before the open starts: ~2.4 MB of
        // records, each later write another ~300 KB.
        let batch = 300
        let seeds = 8
        var next = 0
        for _ in 0..<seeds {
            try await invokeWriter(
                functionKey, documentId: documentId, prefix: prefix, start: next, count: batch
            )
            next += batch
        }

        // And still writing while the open runs.
        let writer = Writer()
        let start = next
        let writing = Task { [ctx, testApp] in
            var position = start
            while !writer.stopped {
                let started = Date()
                let response: [String: Any]
                do {
                    response = try await ctx!.appRequest(
                        method: "POST",
                        appId: testApp!.appId,
                        path: "/functions/\(functionKey)",
                        body: [
                            "rootInput": [
                                "documentId": documentId, "prefix": prefix,
                                "start": position, "count": batch,
                            ],
                            "timeoutMs": 25_000,
                        ],
                        jwt: testApp!.ownerJWT
                    )
                } catch {
                    writer.fail("\(error)")
                    break
                }
                guard response["status"] as? String == "completed" else {
                    writer.fail("\(response)")
                    break
                }
                position += batch
                writer.add(batch, started: started, ended: Date())
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { writer.stop() }

        // A client that has never held the document, with default options.
        let reader = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            storageConfig: .sqlite(directory: directory + "/reader.sqlite"),
            autoNetwork: true,
            // `PL_F2_DEBUG=1` turns the client's own trace of the open on.
            logLevel: ProcessInfo.processInfo.environment["PL_F2_DEBUG"] == "1" ? .debug : .warn
        )
        reader.registerModels([Self.schema])
        clients.append(reader)
        _ = await reader.waitForStorageReady()
        try await reader.connect()
        try await waitForConnection(client: reader)

        // The open settles inside its availability wait, whatever is in flight.
        // Bounded here so a hang fails this test instead of the whole run.
        let budget = OpenDocumentOptions().availabilityWait + 15
        let openStarted = Date()
        // Unstructured on purpose: a task group waits for every child, so an
        // open that never settles would hold the test with it.
        let once = LockedBox(false)
        let outcome: String? = await withCheckedContinuation { continuation in
            let finish: @Sendable (String?) -> Void = { value in
                let first = once.withValue { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            Task {
                do {
                    _ = try await reader.openDocument(documentId)
                    finish("resolved")
                } catch {
                    finish("threw: \(error)")
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                finish(nil)
            }
        }
        let openEnded = Date()
        XCTAssertEqual(
            outcome, "resolved",
            "the open did not resolve within \(budget)s while the writes ran"
                + " (\(writer.written) records written meanwhile)"
        )

        // The condition under test held: at least one write succeeded while
        // the open was in flight. One still running when the open resolved is
        // given time to land before the writer stops.
        try await eventually(timeout: 60, description: "a write overlapping the open") {
            writer.failure != nil || writer.overlapping(from: openStarted, to: openEnded) > 0
        }
        writer.stop()
        _ = await writing.value
        XCTAssertNil(writer.failure, "a concurrent write failed")
        XCTAssertGreaterThan(
            writer.overlapping(from: openStarted, to: openEnded), 0,
            "no write ran while the open was in flight"
        )
        guard outcome == "resolved" else { return }

        // The rows are readable through the model the app uses, including the
        // ones written while the open ran.
        let model = try XCTUnwrap(reader.sharedModel("Note")?.member(docId: documentId))
        let expected = seeds * batch + writer.written
        try await eventually(timeout: 60, description: "every written row to be readable") {
            (try? model.count([:])) ?? 0 >= expected
        }
    }
}
