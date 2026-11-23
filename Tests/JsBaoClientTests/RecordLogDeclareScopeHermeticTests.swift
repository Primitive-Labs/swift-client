import XCTest
@testable import JsBaoClient

/// #5160: an untyped db3's session declares only the models the db3 uses,
/// through a host that scopes its declarations to one db3. Every open sends one
/// `record.declare` (`{}` when empty) naming the models the copy holds and the
/// entries in hand carry, plus what the host binds to the db3; a model first
/// written while open is declared in a frame queued just before its entry; an
/// earlier writer's drain declares what its entries write; a typed db3 takes
/// none. Real SQLite underneath; the room and the client's answer are scripted.
final class RecordLogDeclareScopeHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        Logger.lineForTest = nil
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static func schema(_ name: String) -> PrimitiveSchema {
        PrimitiveSchema(name: name, fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)])
    }

    private static func declaration(_ name: String) -> JSONValue {
        .object(["fields": .object(["title": .object(["type": .string(name)])])])
    }

    /// The client's side of the scoping, scripted: it answers a model when it
    /// knows the model and the copy holds it or it is bound to the db3.
    final class ScopingHost: @unchecked Sendable {
        private let lock = NSLock()
        private var _known: Set<String>
        private var _bound: Set<String> = []
        private var _asked: [[String]] = []

        init(known: Set<String>) { _known = known }

        var asked: [[String]] { lock.withLock { _asked } }
        func know(_ model: String) { lock.withLock { _ = _known.insert(model) } }
        func bind(_ model: String) { lock.withLock { _ = _bound.insert(model) } }

        func answer(_ documentId: String, _ held: [String]) -> [String: JSONValue] {
            lock.withLock {
                _asked.append(held)
                var out: [String: JSONValue] = [:]
                for model in _known where held.contains(model) || _bound.contains(model) {
                    out[model] = RecordLogDeclareScopeHermeticTests.declaration(model)
                }
                return out
            }
        }
    }

    final class RecordingConnection: RecordLogConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var _frames: [[String: JSONValue]] = []
        var frames: [[String: JSONValue]] { lock.withLock { _frames } }
        func send(_ frame: [String: JSONValue]) { lock.withLock { _frames.append(frame) } }
        func connected() -> Bool { true }
        func types(from at: Int = 0) -> [String] { frames.dropFirst(at).compactMap { $0["type"]?.stringValue } }
        func all(_ type: String) -> [[String: JSONValue]] { frames.filter { $0["type"]?.stringValue == type } }
    }

    private struct Fixture {
        let provider: SQLiteStorageProvider
        let binding: RecordLogDocumentBinding
        let session: RecordLogSession
        let connection: RecordingConnection
        let host: ScopingHost
        let synced: LockedBox<Int>

        /// The models each `record.declare` carried, in order, from frame `at`.
        func declares(from at: Int = 0) -> [[String]] {
            connection.frames.dropFirst(at).filter { $0["type"]?.stringValue == "record.declare" }
                .map { ($0["models"]?.objectValue ?? [:]).keys.sorted() }
        }

        /// Frame indexes of each `record.declare` and of the first `record.entries` carrying `seq`.
        func index(ofDeclareNaming model: String) -> Int? {
            connection.frames.firstIndex { $0["type"]?.stringValue == "record.declare" && $0["models"]?[model] != nil }
        }

        func index(ofEntries seq: Int) -> Int? {
            connection.frames.firstIndex {
                $0["type"]?.stringValue == "record.entries"
                    && ($0["entries"]?.arrayValue ?? []).contains { $0["seq"]?.wholeNumber == seq }
            }
        }

        func sentSeqs() -> [Int] {
            connection.all("record.entries").flatMap { ($0["entries"]?.arrayValue ?? []).compactMap { $0["seq"]?.wholeNumber } }
        }

        @discardableResult
        func write(_ model: String, _ id: String, also: [String] = []) throws -> RecordLogPendingEntry {
            let mutations = ([model] + also).enumerated().map { index, name in
                RecordLogMutation(model: name, id: index == 0 ? id : "\(id)-\(index)", kind: .create, fields: ["title": .string(id)])
            }
            let entry = try binding.commit([RecordLogWrite(mutations: mutations)])[0]
            try binding.store.flush()
            return entry
        }

        /// A write of `model` by this writer, refused and withdrawn: a void marker stays in line.
        func voided(_ model: String, _ id: String, binding: RecordLogDocumentBinding? = nil) throws -> Int {
            let binding = binding ?? self.binding
            let entry = try binding.commit([RecordLogWrite(mutations: [
                RecordLogMutation(model: model, id: id, kind: .delete),
            ])])[0]
            try binding.store.flush()
            _ = try binding.store.refused(writer: binding.writer, refusal: RecordLogRefusal(
                seq: entry.seq, code: "DOCUMENT_CONSTRAINT_VIOLATED", scope: .record, from: entry.seq,
                records: [RecordLogRefusedRecord(model: model, id: id, from: entry.seq)]
            ))
            return entry.seq
        }
    }

    private static let timings = RecordLogSessionTimings(
        tickMs: 1, resultGapMs: 5_000, drainWaitMs: 300, writerTakenRetryMs: 40, catchUpRetryMs: 40
    )
    private static let models = ["Note", "Task", "Label", "Draft", "Ghost"]

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-declare-scope-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func binding(_ provider: SQLiteStorageProvider, clientId: String = "client-1") throws -> RecordLogDocumentBinding {
        let binding = try RecordLogDocumentBinding(host: provider, documentId: "doc-1", clientId: clientId, logger: Logger(level: .none))
        for name in Self.models { try binding.registerModel(Self.schema(name)) }
        return binding
    }

    /// A session over `doc-1`; `scoping: false` gives the host with no
    /// `scopedDeclarations`, which declares every model as before.
    private func fixture(
        provider given: SQLiteStorageProvider? = nil, scoping: Bool = true, known: Set<String> = ["Note", "Task", "Label"],
        waitsForType: Bool = false, logger: Logger = Logger(level: .none)
    ) async throws -> Fixture {
        let provider: SQLiteStorageProvider
        if let given { provider = given } else { provider = try await makeProvider() }
        let binding = try binding(provider)
        let connection = RecordingConnection()
        let host = ScopingHost(known: known)
        let synced = LockedBox(0)
        let everything: [String: JSONValue] = Dictionary(uniqueKeysWithValues: known.map { ($0, Self.declaration($0)) })
        var sessionHost = RecordLogSessionHost(
            connection: { connection },
            declarations: { everything },
            synced: { _ in synced.withValue { $0 += 1 } },
            syncFailed: { _, _ in },
            waitsForTypeBeforeDeclaring: waitsForType
        )
        if scoping { sessionHost.scopedDeclarations = { documentId, held in host.answer(documentId, held) } }
        let session = RecordLogSession(documentId: "doc-1", binding: binding, host: sessionHost, timings: Self.timings, logger: logger)
        await session.attach()
        return Fixture(provider: provider, binding: binding, session: session, connection: connection, host: host, synced: synced)
    }

    private static func opened(lsn: Int = 0, catchUp: JSONValue? = nil, db3Type: JSONValue? = nil) -> [String: JSONValue] {
        var frame: [String: JSONValue] = [
            "type": "record.opened", "documentId": "doc-1", "lsn": .number(Double(lsn)), "lastSeq": 0,
            "epochs": .object(["current": 1, "next": 2, "floor": 0, "entries": 10_000, "high": 1]),
            "cursorFloor": 0, "constraints": [],
            "catchUp": catchUp ?? .object(["mode": "inline", "rows": [], "gone": [], "lsn": .number(Double(lsn)), "upTo": .number(Double(lsn))]),
        ]
        if let db3Type { frame["db3Type"] = db3Type }
        return frame
    }

    private static let typed: JSONValue = ["name": "notes", "hash": "h1", "models": ["Note": ["title": "string"]]]

    private func ack(_ fixture: Fixture, l: Int, seq: Int) -> [String: JSONValue] {
        ["type": "record.results", "documentId": "doc-1", "results": [
            .object(["l": .number(Double(l)), "e": 1, "w": .string(fixture.binding.writer), "seq": .number(Double(seq))]),
        ]]
    }

    private func until(
        _ what: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    /// Let queued frames and commits run out, so an absence is an absence.
    private func settle() async { try? await Task.sleep(nanoseconds: 40_000_000) }

    // MARK: - Behaviour 4: an empty, unbound copy declares `{}`, in the same place

    func testAnEmptyUnboundOpenSendsOneEmptyDeclareInTheSameFramesAsBefore() async throws {
        let scoped = try await fixture()
        await scoped.session.start()
        await scoped.session.receive(Self.opened())
        await until("open") { scoped.synced.value == 1 }
        await settle()
        XCTAssertEqual(scoped.declares(), [[]], "exactly one declare, naming no model")
        XCTAssertEqual(scoped.connection.all("record.declare").first?["models"], .object([:]))
        XCTAssertFalse(scoped.host.asked.isEmpty)
        XCTAssertTrue(scoped.host.asked.allSatisfy(\.isEmpty), "asked with nothing held: \(scoped.host.asked)")

        let unscoped = try await fixture(scoping: false)
        await unscoped.session.start()
        await unscoped.session.receive(Self.opened())
        await until("open") { unscoped.synced.value == 1 }
        await settle()
        XCTAssertEqual(scoped.connection.types(), unscoped.connection.types(), "the same frames in the same order")
        XCTAssertEqual(unscoped.declares(), [["Label", "Note", "Task"]], "a host that does not scope declares everything")
    }

    // MARK: - Behaviour 5 and E9: held and in-hand models; a void entry names none

    func testAnOpenDeclaresTheHeldAndInHandModelsAheadOfTheEntriesAndNotAVoidEntrysModel() async throws {
        let f = try await fixture()
        try f.write("Note", "n1", also: ["Label"])
        let void = try f.voided("Ghost", "g1")
        try f.write("Note", "n2")
        await f.session.start()
        await f.session.receive(Self.opened())
        await until("the entries") { f.sentSeqs().contains(3) }
        await settle()
        XCTAssertEqual(f.declares(), [["Label", "Note"]], "one declare, the held models only")
        XCTAssertFalse(f.host.asked.contains { $0.contains("Ghost") }, "a void entry's model is never asked for")
        XCTAssertEqual(f.host.asked.first, ["Label", "Note"], "asked with the sorted set")
        let declare = try XCTUnwrap(f.index(ofDeclareNaming: "Note"))
        XCTAssertLessThan(declare, try XCTUnwrap(f.index(ofEntries: 1)), "the declaration goes ahead of the entries")
        XCTAssertTrue(f.sentSeqs().contains(void), "the void marker itself is still sent")
    }

    // MARK: - Behaviour 6: a store the room has not typed waits, then declares

    func testAnUnknownStoreWaitsForTheOpenedThenDeclaresTheHeldModelsBeforeTheEntries() async throws {
        let f = try await fixture(waitsForType: true)
        try f.write("Task", "t1")
        await f.session.start()
        await settle()
        XCTAssertEqual(f.connection.types(), ["record.open"], "nothing ahead of the room's answer")
        await f.session.receive(Self.opened())
        await until("the entries") { f.sentSeqs().contains(1) }
        XCTAssertEqual(f.declares(), [["Task"]])
        XCTAssertLessThan(try XCTUnwrap(f.index(ofDeclareNaming: "Task")), try XCTUnwrap(f.index(ofEntries: 1)))
    }

    // MARK: - Behaviour 7: a first write declares, once

    func testAFirstWriteWhileOpenIsPrecededByOneDeclareNamingOnlyItsFreshModels() async throws {
        let f = try await fixture()
        await f.session.start()
        await f.session.receive(Self.opened())
        await until("open") { f.synced.value == 1 }
        await settle()
        let at = f.connection.frames.count

        try f.write("Task", "t1")
        await until("the first Task entry") { f.sentSeqs().contains(1) }
        XCTAssertEqual(f.declares(from: at), [["Task"]])
        XCTAssertLessThan(try XCTUnwrap(f.index(ofDeclareNaming: "Task")), try XCTUnwrap(f.index(ofEntries: 1)))

        await f.session.receive(ack(f, l: 1, seq: 1))
        try f.write("Task", "t2")
        await until("the second Task entry") { f.sentSeqs().contains(2) }
        XCTAssertEqual(f.declares(from: at), [["Task"]], "a second write of the model declares nothing")

        await f.session.receive(ack(f, l: 2, seq: 2))
        try f.write("Note", "n1", also: ["Label", "Task"])
        await until("the transaction") { f.sentSeqs().contains(3) }
        XCTAssertEqual(f.declares(from: at), [["Task"], ["Label", "Note"]], "every new model of a transaction in one frame")
        XCTAssertLessThan(try XCTUnwrap(f.index(ofDeclareNaming: "Label")), try XCTUnwrap(f.index(ofEntries: 3)))

        await f.session.receive(ack(f, l: 3, seq: 3))
        try f.write("Draft", "d1")
        await until("the Draft entry") { f.sentSeqs().contains(4) }
        await settle()
        XCTAssertEqual(f.declares(from: at), [["Task"], ["Label", "Note"]], "a model the host answers nothing for declares nothing")
    }

    // MARK: - Behaviour 8, E4 and E5: writes committed while the open runs

    func testAWriteCommittedWhileTheSentAheadOpenRunsIsDeclaredAtTheCatchUpsEnd() async throws {
        let f = try await fixture()
        await f.session.start()
        XCTAssertEqual(f.declares(), [[]], "sent ahead, empty")
        try f.write("Task", "t1")
        await settle()
        await f.session.receive(Self.opened())
        await until("the Task entry") { f.sentSeqs().contains(1) }
        XCTAssertEqual(f.declares(), [[], ["Task"]])
        XCTAssertLessThan(try XCTUnwrap(f.index(ofDeclareNaming: "Task")), try XCTUnwrap(f.index(ofEntries: 1)))
    }

    func testTheCatchUpsEndSendsNoDeclareWhenTheSetIsWhatWentAhead() async throws {
        let f = try await fixture()
        try f.write("Note", "n1")
        await f.session.start()
        try f.write("Note", "n2")
        await settle()
        await f.session.receive(Self.opened())
        await until("both entries") { f.sentSeqs().contains(1) }
        await f.session.receive(ack(f, l: 1, seq: 1))
        await until("the second entry") { f.sentSeqs().contains(2) }
        await settle()
        XCTAssertEqual(f.declares(), [["Note"]], "the recomputed set equals what went ahead")
    }

    func testFramesSentAheadRefusedGoAgainBehindTheScopedDeclarationOfHeldAndPendingModels() async throws {
        let f = try await fixture()
        try f.write("Note", "n1")
        await f.session.start()
        XCTAssertEqual(f.declares(), [["Note"]])
        await f.session.receive([
            "type": "error", "documentId": "doc-1", "code": "DOCUMENT_NOT_OPEN", "messageType": "record.entries", "message": "not open",
        ])
        try f.write("Task", "t1")
        await settle()
        let at = f.connection.frames.count
        await f.session.receive(Self.opened())
        await until("the entries again") { f.connection.frames.dropFirst(at).contains { $0["type"]?.stringValue == "record.entries" } }
        XCTAssertEqual(f.declares(from: at), [["Note", "Task"]], "the reopen path declares again, first")
        let again = try XCTUnwrap(f.connection.frames.dropFirst(at).firstIndex { $0["type"]?.stringValue == "record.entries" })
        let declare = try XCTUnwrap(f.connection.frames.dropFirst(at).firstIndex { $0["type"]?.stringValue == "record.declare" })
        XCTAssertLessThan(declare, again)
    }

    func testAnOpenAgainOnTheConnectionDeclaresHeldAndPendingModelsBeforeTheEntries() async throws {
        let f = try await fixture()
        try f.write("Note", "n1")
        await f.session.start()
        await f.session.receive(Self.opened())
        await until("open") { f.synced.value == 1 }
        // The room lost the subscription: the writer opens again on this connection.
        await f.session.receive([
            "type": "error", "documentId": "doc-1", "code": "DOCUMENT_NOT_OPEN", "messageType": "record.entries", "message": "not open",
        ])
        XCTAssertEqual(f.connection.all("record.open").count, 2)
        try f.write("Task", "t1")
        await settle()
        let at = f.connection.frames.count
        await f.session.receive(Self.opened())
        await until("the declaration") { !f.declares(from: at).isEmpty }
        // What was in flight goes again first; the Task entry waits behind its declaration.
        await f.session.receive(ack(f, l: 1, seq: 1))
        await until("the Task entry") { f.index(ofEntries: 2).map { $0 >= at } == true }
        XCTAssertEqual(f.declares(from: at), [["Note", "Task"]])
        XCTAssertLessThan(try XCTUnwrap(f.index(ofDeclareNaming: "Task")), try XCTUnwrap(f.index(ofEntries: 2)))
    }

    func testAGapDuringTheCatchUpResendsOnlyWhatWasInFlightAndTheNewModelsDeclarationLeavesFirst() async throws {
        let f = try await fixture()
        try f.write("Note", "n1")
        await f.session.start()
        XCTAssertEqual(f.sentSeqs(), [1], "sent ahead")
        await f.session.receive(Self.opened(lsn: 5, catchUp: .object(["mode": "paged", "count": 1, "cursor": 0, "upTo": 5])))
        try f.write("Task", "t1")
        await settle()
        await f.session.receive(["type": "record.gap", "documentId": "doc-1", "expected": 1])
        await f.session.receive([
            "type": "record.catchUpPage", "documentId": "doc-1", "rows": [], "gone": [], "lsn": 5,
        ])
        await until("open") { f.synced.value == 1 }
        await until("the resent entry") { f.sentSeqs().count >= 2 }
        await settle()
        let declare = try XCTUnwrap(f.index(ofDeclareNaming: "Task"))
        XCTAssertFalse(
            f.connection.frames.prefix(declare).contains {
                $0["type"]?.stringValue == "record.entries" && ($0["entries"]?.arrayValue ?? []).contains { $0["seq"]?.wholeNumber == 2 }
            },
            "the entry committed during the catch-up is not resent ahead of its declaration"
        )
        await f.session.receive(ack(f, l: 6, seq: 1))
        await until("the Task entry") { f.sentSeqs().contains(2) }
        XCTAssertLessThan(declare, try XCTUnwrap(f.index(ofEntries: 2)))
    }

    // MARK: - Behaviour 9 and E9: an earlier writer's drain

    func testAnEarlierWritersDrainDeclaresTheModelsItsEntriesWriteFirst() async throws {
        let provider = try await makeProvider()
        let earlier = try binding(provider, clientId: "earlier")
        _ = try earlier.commit([RecordLogWrite(mutations: [RecordLogMutation(model: "Task", id: "t1", kind: .create, fields: ["title": "t"])])])
        try earlier.store.flush()
        let f = try await fixture(provider: provider)
        _ = try f.voided("Label", "l1", binding: earlier)
        _ = try earlier.commit([RecordLogWrite(mutations: [RecordLogMutation(model: "Draft", id: "d1", kind: .create, fields: ["title": "d"])])])
        try earlier.store.flush()

        await f.session.start()
        XCTAssertEqual(f.connection.all("record.open").last?["writer"]?.stringValue, earlier.writer)
        await f.session.receive(Self.opened())
        await until("the drained entries") { f.sentSeqs().contains(3) }
        XCTAssertEqual(f.declares(), [["Task"]], "the models its entries write that the host declares; not a void entry's, nor an unanswered one")
        XCTAssertLessThan(try XCTUnwrap(f.index(ofDeclareNaming: "Task")), try XCTUnwrap(f.index(ofEntries: 1)))
        XCTAssertTrue(f.sentSeqs().contains(2), "the void marker is still sent")
    }

    func testADrainOfOnlyUnansweredModelsDeclaresNothingAndAHostThatDoesNotScopeKeepsTodaysFrames() async throws {
        for scoping in [true, false] {
            let provider = try await makeProvider()
            let earlier = try binding(provider, clientId: "earlier")
            _ = try earlier.commit([RecordLogWrite(mutations: [
                RecordLogMutation(model: scoping ? "Draft" : "Task", id: "x1", kind: .create, fields: ["title": "x"]),
            ])])
            try earlier.store.flush()
            let f = try await fixture(provider: provider, scoping: scoping)
            await f.session.start()
            await f.session.receive(Self.opened())
            await until("the drained entry") { f.sentSeqs().contains(1) }
            await settle()
            XCTAssertEqual(f.declares(), [], "no declare goes with the drain (scoping: \(scoping))")
        }
    }

    // MARK: - Behaviour 10 and E2: registration and binding while open

    func testAModelRegisteredWhileOpenIsDeclaredAtOnceOnlyWhenBound() async throws {
        let f = try await fixture()
        await f.session.start()
        await f.session.receive(Self.opened())
        await until("open") { f.synced.value == 1 }
        await settle()
        let at = f.connection.frames.count

        // Registered, known to the host, bound to nothing: not declared.
        try f.binding.registerModel(Self.schema("Later"))
        f.host.know("Later")
        await f.session.declare()
        await settle()
        XCTAssertEqual(f.declares(from: at), [])

        // Registered and bound to this db3: declared at once, alone.
        try f.binding.registerModel(Self.schema("Bound"))
        f.host.know("Bound")
        f.host.bind("Bound")
        await f.session.declare()
        await until("the declaration") { !f.declares(from: at).isEmpty }
        XCTAssertEqual(f.declares(from: at), [["Bound"]])
    }

    func testAModelBoundWhileOpenIsDeclaredAtItsFirstWriteAndAtTheNextOpen() async throws {
        let f = try await fixture()
        await f.session.start()
        await f.session.receive(Self.opened())
        await until("open") { f.synced.value == 1 }
        f.host.bind("Task")
        await settle()
        XCTAssertEqual(f.declares(), [[]], "a binding alone sends nothing while open")

        try f.write("Note", "n1")
        await until("the Note entry") { f.sentSeqs().contains(1) }
        XCTAssertEqual(f.declares(), [[], ["Note"]], "a write declares its own model, not the one bound since")

        await f.session.disconnected()
        let at = f.connection.frames.count
        await f.session.start()
        XCTAssertEqual(f.declares(from: at), [["Note", "Task"]], "the next open declares the bound model")
    }

    // MARK: - Behaviour 11: a typed db3 takes none

    func testATypedDb3TakesNoDeclarationAtOpenCommitRegistrationOrDrain() async throws {
        let provider = try await makeProvider()
        let f = try await fixture(provider: provider, waitsForType: true)
        f.host.bind("Task")
        try f.write("Note", "n1")
        await f.session.start()
        await f.session.receive(Self.opened(db3Type: Self.typed))
        await until("open") { f.synced.value == 1 }
        await until("the Note entry") { f.sentSeqs().contains(1) }
        await f.session.receive(ack(f, l: 1, seq: 1))
        try f.write("Task", "t1")
        await until("the Task entry") { f.sentSeqs().contains(2) }
        try f.binding.registerModel(Self.schema("Bound"))
        f.host.know("Bound")
        f.host.bind("Bound")
        await f.session.declare()

        // An earlier writer's entries drained into the typed db3.
        let earlier = try binding(provider, clientId: "earlier")
        _ = try earlier.commit([RecordLogWrite(mutations: [RecordLogMutation(model: "Task", id: "t9", kind: .create, fields: ["title": "t"])])])
        try earlier.store.flush()
        await f.session.disconnected()
        await f.session.start()
        XCTAssertEqual(f.connection.all("record.open").last?["writer"]?.stringValue, earlier.writer)
        await f.session.receive(Self.opened(lsn: 1, db3Type: ["name": "notes", "hash": "h1"]))
        await until("the drained entry") { f.connection.all("record.open").count == 3 }
        await f.session.receive(Self.opened(lsn: 1, db3Type: ["name": "notes", "hash": "h1"]))
        await until("open again") { f.synced.value == 2 }
        await settle()
        XCTAssertEqual(f.declares(), [], "no declaration anywhere")
    }

    // MARK: - Behaviour 13: one debug line per declare

    func testEachDeclareWritesOneDebugLineNamingTheDb3AndItsModels() async throws {
        let lines = LockedBox<[String]>([])
        Logger.lineForTest = { level, _, message in
            guard level == .debug, message.contains("declaring") else { return }
            lines.withValue { $0.append(message) }
        }
        let f = try await fixture(logger: Logger(level: .debug))
        await f.session.start()
        await f.session.receive(Self.opened())
        await until("open") { f.synced.value == 1 }
        try f.write("Note", "n1", also: ["Task"])
        await until("the entry") { f.sentSeqs().contains(1) }
        await settle()
        XCTAssertEqual(f.declares(), [[], ["Note", "Task"]])
        XCTAssertEqual(lines.value.count, 2, "one line per declare: \(lines.value)")
        XCTAssertTrue(lines.value[0].contains("doc-1") && lines.value[0].contains("no models"), lines.value[0])
        XCTAssertTrue(lines.value[1].contains("doc-1") && lines.value[1].contains("2 model(s): Note, Task"), lines.value[1])
    }
}
