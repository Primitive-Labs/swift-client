import XCTest
@testable import JsBaoClient

/// #4797 behaviors 30, 31 and 33 — increments, the write guards and the wire
/// version in the Swift client: the twin of js-bao's
/// `record-log-client-increment-4797` suite.
///
/// - 30: the core port — an `increment` mutation and the guards round-trip,
///   the guess adds `numeric + delta`, the entry check refuses what the room
///   would, the transaction fold is the JS one, a guarded guess is held until
///   acknowledged, `whenSettled` answers the rows captured when the entry's
///   result applied, and `DB3_CONDITION_NOT_MET` / `DB3_RECORD_NOT_FOUND` hand
///   back under their own codes with `current`.
/// - 31: every `record.open` declares `wireVersion: 2`; `DB3_CLIENT_OUTDATED`
///   ends the open, nothing opens again, and the lifecycle reports the db3
///   gone with `reason: .clientOutdated`.
/// - 33: a save into a format-1 document logs the deprecation warning once per
///   model per document, and writes what it wrote before.
final class RecordLogIncrementHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private var directories: [String] = []

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Harness

    private func directory(_ tag: String) throws -> String {
        let directory = NSTemporaryDirectory() + "/record-log-increment-\(tag)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func harness() async throws -> H.Fixture {
        let provider = SQLiteStorageProvider(path: try directory("session") + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return try await H.Fixture(provider: provider, clientId: "client-a", fetches: false, timings: H.timings)
    }

    /// A harness whose session is open with the record `r1` confirmed holding `fields`.
    private func opened(_ fields: [String: JSONValue] = ["t": 0]) async throws -> H.Fixture {
        let h = try await harness()
        await h.session.start()
        var row = fields
        row["id"] = "r1"
        await h.feed(H.opened(lsn: 1, catchUp: .object([
            "mode": "inline", "rows": [.object(["model": "Note", "id": "r1", "row": .object(row)])], "gone": [], "lsn": 1, "upTo": 1,
        ])))
        await until("open") { h.synced.value == 1 }
        return h
    }

    private func until(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    private static func inc(_ id: String, _ fields: [String: JSONValue], condition: JSONValue? = nil) -> RecordLogMutation {
        RecordLogMutation(model: "Note", id: id, kind: .increment, fields: fields, condition: condition)
    }

    private static func patch(_ id: String, _ fields: [String: JSONValue], condition: JSONValue? = nil) -> RecordLogMutation {
        RecordLogMutation(model: "Note", id: id, kind: .patch, fields: fields, condition: condition)
    }

    /// The JsBaoError `body` throws.
    private func refusal(_ body: () throws -> Void) -> JsBaoError? {
        do {
            try body()
            return nil
        } catch {
            return error as? JsBaoError
        }
    }

    private func ack(_ l: Int, seq: Int, writer: String) -> JSONValue {
        .object(["l": .number(Double(l)), "e": 1, "w": .string(writer), "seq": .number(Double(seq))])
    }

    // MARK: - Behavior 30: the core port

    func testAMutationRoundTripsTheIncrementKindTheConditionAndIfNotExists() throws {
        let increment = Self.inc("r1", ["t": 2], condition: .object(["t": 1]))
        XCTAssertEqual(increment.json["kind"], "increment")
        XCTAssertEqual(increment.json["condition"], .object(["t": 1]))
        XCTAssertEqual(RecordLogMutation(json: increment.json), increment)
        let guarded = RecordLogMutation(model: "Note", id: "r2", kind: .create, fields: ["t": 1], ifNotExists: true)
        XCTAssertEqual(guarded.json["ifNotExists"], true)
        XCTAssertEqual(RecordLogMutation(json: guarded.json), guarded)
        // The existing initialiser still makes an unguarded mutation, written as before.
        let plain = RecordLogMutation(model: "Note", id: "r3", kind: .patch, fields: ["t": 1])
        XCTAssertNil(plain.condition)
        XCTAssertFalse(plain.ifNotExists)
        XCTAssertEqual(plain.json, .object(["model": "Note", "id": "r3", "kind": "patch", "fields": .object(["t": 1])]))
        XCTAssertEqual(RecordLogWriteKind.increment.rawValue, "increment")
        XCTAssertEqual(
            planRecordLogIncrement(model: "Note", recordId: "r1", fields: ["t": 2], condition: .object(["t": 1])),
            increment
        )
        XCTAssertEqual(planRecordLogDelete(model: "Note", recordId: "r1", condition: .object(["t": 1])).condition, .object(["t": 1]))
    }

    func testTheGuessAddsNumericPlusDeltaAndAnswersNilWithNoRow() {
        XCTAssertEqual(
            recordLogPlainRowAfter(["id": "r1", "t": 1, "title": "x"], Self.inc("r1", ["t": 2, "title": 1, "m": 3])),
            ["id": "r1", "t": 3, "title": 1, "m": 3]
        )
        XCTAssertNil(recordLogPlainRowAfter(nil, Self.inc("r1", ["t": 2])))
    }

    func testTheEntryCheckRefusesWhatTheRoomWould() {
        let refused: [([RecordLogMutation], String?, String)] = [
            ([Self.inc("r1", ["t": .number(.infinity)])], nil, "finite number"),
            ([Self.inc("r1", ["t": "1"])], nil, "finite number"),
            ([Self.inc("r1", [:])], nil, "names no field"),
            ([RecordLogMutation(model: "Note", id: "r1", kind: .increment, fields: ["t": 1], stringSetDeltas: ["tags": ["a": true]])], nil, "stringSetDeltas"),
            ([RecordLogMutation(model: "Note", id: "r1", kind: .increment, fields: ["t": 1], ifNotExists: true)], nil, "ifNotExists guards a create"),
            ([RecordLogMutation(model: "Note", id: "r1", kind: .patch, fields: ["t": 1], ifNotExists: true)], nil, "ifNotExists guards a create"),
            ([RecordLogMutation(model: "Note", id: "r1", kind: .create, fields: ["t": 1], ifNotExists: true)], "slug", "cannot ride an entry with upsertOn"),
            ([Self.patch("r1", ["t": 1], condition: "open")], nil, "condition must be an object"),
            ([Self.patch("r1", ["t": 1], condition: .object(["t": .object(["$nope": 1])]))], nil, "condition"),
            ([Self.patch("r1", ["t": 5]), Self.inc("r1", ["t": 1])], nil, "which m of the same entry assigns"),
        ]
        for (mutations, upsertOn, words) in refused {
            let reported = LockedBox(0)
            let error = refusal {
                try assertRecordLogEntry(documentId: "doc", mutations: mutations, upsertOn: upsertOn) { _ in reported.withValue { $0 += 1 } }
            }
            XCTAssertEqual(error?.code, .documentEntryInvalid, "\(mutations)")
            XCTAssertTrue(error?.message.contains(words) == true, "\(error?.message ?? "nothing") should name \(words)")
            XCTAssertEqual(reported.value, 1)
        }
        XCTAssertNil(refusal { try assertRecordLogEntry(documentId: "doc", mutations: [Self.inc("r1", ["t": 0.5, "m": -3])]) })
        XCTAssertNil(refusal { try assertRecordLogEntry(documentId: "doc", mutations: [Self.patch("r1", ["title": "t"]), Self.inc("r1", ["t": 1])]) })
        XCTAssertNil(refusal { try assertRecordLogEntry(documentId: "doc", mutations: [Self.patch("r1", ["t": 1], condition: .object(["t": .object(["$gte": 0])]))]) })
    }

    func testTheTransactionFoldIsTheJSOne() {
        // A delta of a field the held write assigns goes into it; a create takes every delta.
        XCTAssertEqual(
            foldRecordLogIncrement(RecordLogHeldWrites(mutation: Self.patch("r1", ["t": 10])), Self.inc("r1", ["t": 1])),
            RecordLogHeldWrites(mutation: Self.patch("r1", ["t": 11]))
        )
        XCTAssertEqual(
            foldRecordLogIncrement(
                RecordLogHeldWrites(mutation: RecordLogMutation(model: "Note", id: "r1", kind: .create, fields: ["title": "t"])),
                Self.inc("r1", ["t": 1])
            ),
            RecordLogHeldWrites(mutation: RecordLogMutation(model: "Note", id: "r1", kind: .create, fields: ["title": "t", "t": 1]))
        )
        // Other deltas accumulate in the record's increment, summed, conditions conjoined.
        var held = foldRecordLogIncrement(RecordLogHeldWrites(mutation: Self.patch("r1", ["title": "t"])), Self.inc("r1", ["t": 1], condition: .object(["t": 0])))
        held = foldRecordLogIncrement(held, Self.inc("r1", ["t": 2, "m": 1], condition: .object(["m": 0])))
        XCTAssertEqual(held, RecordLogHeldWrites(
            mutation: Self.patch("r1", ["title": "t"]),
            increment: Self.inc("r1", ["t": 3, "m": 1], condition: .object(["$and": [.object(["t": 0]), .object(["m": 0])]]))
        ))
        // A later patch takes a field over; a later delete drops the increment, keeping its condition.
        let incremented = foldRecordLogIncrement(RecordLogHeldWrites(), Self.inc("r1", ["t": 1, "m": 1]))
        XCTAssertEqual(incremented, RecordLogHeldWrites(increment: Self.inc("r1", ["t": 1, "m": 1])))
        XCTAssertEqual(
            foldRecordLogIncrement(incremented, Self.patch("r1", ["t": 10])),
            RecordLogHeldWrites(mutation: Self.patch("r1", ["t": 10]), increment: Self.inc("r1", ["m": 1]))
        )
        let delete = RecordLogMutation(model: "Note", id: "r1", kind: .delete)
        XCTAssertEqual(foldRecordLogIncrement(incremented, delete), RecordLogHeldWrites(mutation: delete))
        var guardedDelete = delete
        guardedDelete.condition = .object(["t": 0])
        XCTAssertEqual(
            foldRecordLogIncrement(RecordLogHeldWrites(increment: Self.inc("r1", ["t": 1], condition: .object(["t": 0]))), delete),
            RecordLogHeldWrites(mutation: guardedDelete)
        )
    }

    func testAGuardedGuessIsHeldUntilAcknowledgedAndAnIncrementShowsAtOnce() async throws {
        let h = try await opened(["t": 1])
        _ = try h.binding.commit([RecordLogWrite(mutations: [Self.inc("r1", ["t": 2])])])
        XCTAssertEqual(try h.read("r1")?["t"], 3)
        let guarded = try h.binding.commit([RecordLogWrite(mutations: [Self.patch("r1", ["title": "x"], condition: .object(["t": 3]))])])[0]
        XCTAssertNil(try h.read("r1")?["title"])
        await h.feed(["type": "record.results", "results": [ack(9, seq: guarded.seq, writer: h.binding.writer)]])
        await until("the acknowledged guess") { (try? h.read("r1")?["title"]) == "x" }
    }

    func testWhenSettledAnswersTheRowsCapturedWhenTheResultAppliedNotTheView() async throws {
        let h = try await opened()
        let writer = h.binding.writer
        let a = try h.binding.commit([RecordLogWrite(mutations: [Self.inc("r1", ["t": 1])])])[0].seq
        let b = try h.binding.commit([RecordLogWrite(mutations: [Self.inc("r1", ["t": 100])])])[0].seq
        await h.feed(["type": "record.results", "results": [ack(2, seq: a, writer: writer)]])
        let settledA = try await h.binding.whenSettled(a)
        XCTAssertEqual(settledA.rows, [RecordLogCurrentRecord(model: "Note", id: "r1", row: ["id": "r1", "t": 1])])
        XCTAssertEqual(try h.read("r1")?["t"], 101)
        await h.feed(["type": "record.results", "results": [ack(3, seq: b, writer: writer)]])
        let settledB = try await h.binding.whenSettled(b)
        XCTAssertEqual(settledB.rows.first?.row?["t"], 101)
    }

    func testWhenSettledKeepsTheRowThoughALaterDeleteIsPendingAndCapturesEachOfTwoResultsInOneFrame() async throws {
        let h = try await opened()
        let writer = h.binding.writer
        let a = try h.binding.commit([RecordLogWrite(mutations: [Self.inc("r1", ["t": 1])])])[0].seq
        _ = try h.binding.commit([RecordLogWrite(mutations: [RecordLogMutation(model: "Note", id: "r1", kind: .delete)])])
        XCTAssertNil(try h.read("r1"))
        await h.feed(["type": "record.results", "results": [ack(2, seq: a, writer: writer)]])
        let settled = try await h.binding.whenSettled(a)
        XCTAssertEqual(settled.rows.first?.row?["t"], 1)

        let g = try await opened()
        let w = g.binding.writer
        let x = try g.binding.commit([RecordLogWrite(mutations: [Self.inc("r1", ["t": 1])])])[0].seq
        let y = try g.binding.commit([RecordLogWrite(mutations: [Self.inc("r1", ["t": 100])])])[0].seq
        async let first = g.binding.whenSettled(x)
        async let second = g.binding.whenSettled(y)
        await g.feed(["type": "record.results", "results": [ack(2, seq: x, writer: w), ack(3, seq: y, writer: w)]])
        let (one, two) = try await (first, second)
        XCTAssertEqual(one.rows.first?.row?["t"], 1)
        XCTAssertEqual(two.rows.first?.row?["t"], 101)
    }

    func testTheGuardRefusalsHandBackUnderTheirOwnCodesWithCurrent() async throws {
        for (code, swiftCode, row) in [
            ("DB3_CONDITION_NOT_MET", JsBaoErrorCode.db3ConditionNotMet, JSONValue.object(["id": "r1", "t": 0])),
            ("DB3_RECORD_NOT_FOUND", JsBaoErrorCode.db3RecordNotFound, JSONValue.null),
        ] {
            let h = try await opened()
            let heard = LockedBox<[DocumentWriteRefusedEvent]>([])
            h.binding.setRefusalReporter { event in heard.withValue { $0.append(event) } }
            let seq = try h.binding.commit([RecordLogWrite(mutations: [Self.inc("r1", ["t": 1], condition: .object(["t": 5]))])])[0].seq
            async let acknowledged: Void = h.binding.whenAcknowledged(seq)
            async let settled = h.binding.whenSettled(seq)
            await h.feed([
                "type": "record.refused", "seq": .number(Double(seq)), "code": .string(code), "scope": "record",
                "from": .number(Double(seq)), "records": [.object(["model": "Note", "id": "r1", "from": .number(Double(seq))])],
                "current": .object(["model": "Note", "id": "r1", "row": row]),
            ])
            let current = RecordLogCurrentRecord(model: "Note", id: "r1", row: row.objectValue)
            do {
                try await acknowledged
                XCTFail("\(code): the acknowledgement should throw")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, swiftCode)
                XCTAssertEqual(error.details?["current"], current.json)
            }
            do {
                _ = try await settled
                XCTFail("\(code): the settlement should throw")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, swiftCode)
            }
            await until("the refusal event") { !heard.value.isEmpty }
            XCTAssertEqual(heard.value.first?.current, current)
            XCTAssertEqual(heard.value.first?.writes?.first?.kind, .increment)
            XCTAssertEqual(Db3WriteRefusedEvent(heard.value[0]).current, current)
        }
    }

    func testTheModelDelegateRefusesAMissingRecordAndAnUnsafeDeltaLocally() async throws {
        let h = try await opened(["t": 5])
        let delegate = try RecordLogModelDelegate(binding: h.binding, schema: H.schema)
        let reported = LockedBox<[DocumentWriteRefusedEvent]>([])
        h.binding.setRefusalReporter { event in reported.withValue { $0.append(event) } }
        XCTAssertEqual(refusal { _ = try delegate.increment(id: "missing", fields: ["t": 1], condition: nil) }?.code, .db3RecordNotFound)
        // A delta past ±2^53 is refused before the view is read, so no client
        // can send an increment whose sum would not be finite.
        let unsafe = refusal { _ = try delegate.increment(id: "r1", fields: ["t": 1e308], condition: nil) }
        XCTAssertEqual(unsafe?.code, .documentEntryInvalid)
        XCTAssertTrue(unsafe?.message.contains("outside ±2^53") == true)
        XCTAssertEqual(reported.value.map(\.error.code), [.db3RecordNotFound, .documentEntryInvalid])
        XCTAssertEqual(reported.value.first?.writes?.first?.kind, .increment)
        XCTAssertEqual(try h.binding.store.pendingOf(h.binding.writer), [])
        let done = try delegate.increment(id: "r1", fields: ["t": -2], condition: nil)
        XCTAssertEqual(done.values, ["t": 3])
        XCTAssertNotNil(done.seq)
        XCTAssertEqual(try h.read("r1")?["t"], 3)
    }

    // MARK: - Behavior 31: the wire version

    func testEveryOpenDeclaresWireVersionTwoTheBarrierIncluded() async throws {
        let h = try await harness()
        try h.save("r1", ["t": 1])
        try h.save("r2", ["t": 2])
        await h.session.start()
        XCTAssertEqual(h.of("record.open").first?["wireVersion"], 2)
        // The room judged numbers this store never minted: re-minted, and the old
        // id opened again once its owed answers do not come.
        var reopened = H.opened(lsn: 0)
        reopened["lastSeq"] = 7
        await h.feed(reopened)
        await until("the barrier re-open", timeout: 5) { h.of("record.open").count >= 2 }
        for frame in h.of("record.open") { XCTAssertEqual(frame["wireVersion"], 2, "\(frame)") }
        XCTAssertEqual(JsBaoErrorCode.db3ConditionNotMet.rawValue, "DB3_CONDITION_NOT_MET")
        XCTAssertEqual(JsBaoErrorCode.db3RecordNotFound.rawValue, "DB3_RECORD_NOT_FOUND")
        XCTAssertEqual(JsBaoErrorCode.db3ClientOutdated.rawValue, "DB3_CLIENT_OUTDATED")
    }

    func testClientOutdatedEndsTheOpenAndNothingOpensAgain() async throws {
        let h = try await harness()
        try h.save("r1", ["t": 1])
        await h.session.start()
        XCTAssertEqual(h.of("record.open").count, 1)
        await h.feed(["type": "error", "messageType": "record.open", "code": "DB3_CLIENT_OUTDATED", "wireVersion": 2, "declared": 1])
        await h.feed(["type": "error", "messageType": "record.declare", "code": "DOCUMENT_NOT_OPEN"])
        await h.feed(["type": "error", "messageType": "record.entries", "code": "DOCUMENT_NOT_OPEN"])
        XCTAssertEqual(h.failed.value, ["DB3_CLIENT_OUTDATED"])
        await h.session.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.of("record.open").count, 1)
        XCTAssertEqual(h.of("record.entries").count, 1)
    }

    func testARecordOpenedAtWireVersionTwoOrThreeOpens() async throws {
        for version in [2, 3] {
            let h = try await harness()
            await h.session.start()
            var frame = H.opened(lsn: 0)
            frame["wireVersion"] = .number(Double(version))
            await h.feed(frame)
            await until("open at \(version)") { h.synced.value == 1 }
        }
    }

    func testTheLifecycleReportsAnOutdatedDb3GoneWithNoRetry() async throws {
        let id = "01JD4797W1REVERS10NXXXXXXX"
        let emitted = LockedBox<[any JsBaoEventPayload]>([])
        let resyncs = LockedBox(0)
        let lifecycle = Db3Lifecycle(deps: Db3LifecycleDeps(
            emit: { payload in emitted.withValue { $0.append(payload) } },
            socketUp: { true },
            resolveFormat: { _ in 3 },
            resync: { _ in resyncs.withValue { $0 += 1 } },
            isBound: { _ in true },
            syncMarks: { _ in Db3SyncMarks(cursor: 2, permission: nil, lastCatchUpAt: 1_000, replacing: false, staged: false) },
            storedState: { _ in RecordLogStoredState(cursor: 2, rows: 1, writers: [], replacing: false, lastCatchUpAt: 1_000) }
        ))
        let handle = try lifecycle.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        lifecycle.syncFailed(id, "DB3_CLIENT_OUTDATED")
        do {
            try await handle.ready()
            XCTFail("ready should throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3ClientOutdated)
        }
        await until("gone") { handle.state.phase == .gone }
        XCTAssertEqual(handle.state.error?.code, "DB3_CLIENT_OUTDATED")
        let state = try await lifecycle.state(id)
        XCTAssertEqual(state.phase, .gone)
        XCTAssertEqual(state.error?.code, "DB3_CLIENT_OUTDATED")
        let gone = emitted.value.compactMap { $0 as? Db3GoneEvent }
        XCTAssertEqual(gone, [Db3GoneEvent(id: id, reason: .clientOutdated)])
        XCTAssertEqual(gone.first?.code, "DB3_CLIENT_OUTDATED")
        XCTAssertTrue(emitted.value.compactMap { $0 as? Db3ErrorEvent }.isEmpty)
        lifecycle.connectionChanged()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(resyncs.value, 0)
        XCTAssertEqual(emitted.value.compactMap { $0 as? Db3GoneEvent }.count, 1)
        // The original reason and initialiser are unchanged.
        XCTAssertEqual(Db3GoneEvent(id: id).reason, .permission)
        XCTAssertEqual(Db3GoneEvent(id: id).code, "DB3_ACCESS_REFUSED")
    }

    // MARK: - Behavior 33: the format-1 deprecation warning

    private func format1Client() async throws -> (JsBaoClient, String) {
        let path = try directory("format1") + "/store.sqlite"
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "format1-warning-test-app",
            token: makeTestJwt(userId: "user-a"),
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .warn,
            storageConfig: .sqlite(directory: path),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([Self.note, Self.tag])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        let created = try await client.createDocument(options: CreateDocumentOptions(title: "plain"))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        return (client, documentId)
    }

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )
    private static let tag = PrimitiveSchema(
        name: "Tag", fields: ["id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string)]
    )

    func testAFormat1SaveWarnsOncePerModelPerDocumentAndWritesAsBefore() async throws {
        let warnings = LockedBox<[String]>([])
        Logger.lineForTest = { level, _, message in
            if level == .warn, message.contains("is deprecated: records belong in a db3") { warnings.withValue { $0.append(message) } }
        }
        let (client, documentId) = try await format1Client()
        let notes = try XCTUnwrap(client.sharedModel("Note")?.member(docId: documentId))
        let record = try notes.save(id: "n1", values: ["title": .string("one")])
        XCTAssertEqual(record.id, "n1")
        XCTAssertEqual(notes.find(id: "n1")?["title"], .string("one"))
        _ = try notes.create(id: "n2", values: ["title": .string("two")])
        try notes.update(id: "n2", values: ["title": .string("again")])
        XCTAssertEqual(warnings.value, ["saving `Note` into format-1 document \(documentId) is deprecated: records belong in a db3"])
        // The guards are ignored on a format-1 document, as confirm is; the warning has fired already.
        _ = try await notes.save(id: "n3", values: ["title": .string("three")], options: Db3WriteOptions(condition: ["title": "nope"], confirm: true))
        XCTAssertEqual(notes.find(id: "n3")?["title"], .string("three"))
        XCTAssertEqual(warnings.value.count, 1)
        // Another model in the same document warns once of its own.
        let tags = try XCTUnwrap(client.sharedModel("Tag")?.member(docId: documentId))
        _ = try tags.create(id: "t1", values: ["name": .string("x")])
        _ = try tags.create(id: "t2", values: ["name": .string("y")])
        XCTAssertEqual(warnings.value.count, 2)
        // A format-1 document takes no increment, and nothing is written.
        do {
            _ = try await notes.increment(id: "n1", fields: ["title": 1])
            XCTFail("a format-1 document takes no increment")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
        XCTAssertEqual(notes.find(id: "n1")?["title"], .string("one"))
        // The same model in another document warns once there too.
        let other = try await client.createDocument(options: CreateDocumentOptions(title: "plain 2"))
        let otherId = try XCTUnwrap(other.metadata?["documentId"]?.stringValue)
        _ = try await client.openDocument(otherId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false))
        let notes2 = try XCTUnwrap(client.sharedModel("Note")?.member(docId: otherId))
        _ = try notes2.create(id: "m1", values: ["title": .string("elsewhere")])
        _ = try notes2.create(id: "m2", values: ["title": .string("elsewhere too")])
        XCTAssertEqual(warnings.value.count, 3)
        XCTAssertTrue(warnings.value.last?.contains(otherId) == true)
        await client.destroy()
    }
}
