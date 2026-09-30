import XCTest
@testable import JsBaoClient
import YSwift

/// The read-only window's gate (#3437, behaviors 2, 2a and 3).
///
/// Past the window the document keeps ANSWERING and stops ACCEPTING. The gate
/// sits at the shared commit boundary — `Format2WritePath.commitInsideOperation`
/// — rather than in `write`, because `addMember` and `removeMember` reach the
/// commit directly (finding 3437-SO-07): a gate in `write` alone would leave
/// stringset members writable past the window, recording writes outside the
/// period the server can replay them across. `write` refuses a second time,
/// early, before it takes the operation lock, so the common case never queues
/// behind a fold to be refused.
///
/// The throwing verbs throw. The public mutations that CANNOT throw —
/// `delete(id:)`, a `PrimitiveRecord` field setter, an explicit clear — refuse
/// without writing and report through `DocumentWriteRefusedEvent`, because
/// `DynamicModel.delete(id:)` is declared without `throws` and swallows the
/// delegate's error with `try?` (finding 3437-SO-08). Adding a throwing form
/// of those verbs would break every existing caller, so the event is the
/// compatible channel.
final class Format2OfflineWindowGateHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let dayMs = 24 * 60 * 60 * 1000

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "views": FieldDescriptor(type: .number),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private struct Fixture {
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let model: DynamicModel
        let doc: YDocument
        let documentId: String
        let refusals: LockedBox<[DocumentWriteRefusedEvent]>
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-gate-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeFixture(host: (any Format2SqlHost)? = nil) async throws -> Fixture {
        let sqlHost: any Format2SqlHost
        if let host { sqlHost = host } else { sqlHost = try await makeProvider() }
        let documentId = "gate-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        let coordinator = Format2Coordinator(
            host: sqlHost, clientId: "me", logger: Logger(level: .none)
        )
        let refusals = LockedBox<[DocumentWriteRefusedEvent]>([])
        coordinator.onWriteRefused = { event in
            refusals.withValue { $0.append(event) }
        }
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: documentId, doc: doc)
        model.bindFormat2(binding)
        return Fixture(
            coordinator: coordinator, binding: binding, model: model,
            doc: doc, documentId: documentId, refusals: refusals
        )
    }

    /// Put the document past its window: a mark `days` old against a 7-day
    /// window, which is what a client that has been away looks like.
    private func backDate(_ fixture: Fixture, days: Int = 30) throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try fixture.binding.store.noteSync(
            at: now - days * Self.dayMs, windowDays: 7
        )
    }

    private func expectWindowRefusal(
        _ label: String, _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("\(label) should have been refused past the offline window")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentOfflineWindowExpired, label)
            XCTAssertNotNil(error.details?["lastSyncAt"], label)
            XCTAssertNotNil(error.details?["windowDays"], label)
            XCTAssertNotNil(error.details?["overdueMs"], label)
        } catch {
            XCTFail("\(label) threw \(error) rather than the typed window refusal")
        }
    }

    // MARK: - Behavior 2 — the gate at the shared commit boundary

    func testTheCommitBoundaryRefusesPastTheWindowAndLeavesNothing() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)

        // `commitInsideOperation` is the boundary every door runs through, so
        // it is asserted directly rather than only through one caller.
        try fixture.binding.writePath.withOperation {
            expectWindowRefusal("the commit boundary") {
                _ = try fixture.binding.writePath.commitInsideOperation(
                    model: "Note",
                    mutation: OverlayMutation(
                        id: "r1", kind: .create, fields: ["title": .string("x")]
                    ),
                    fields: ["title"]
                )
            }
        }

        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "r1"))
        XCTAssertEqual(try fixture.binding.store.pendingOps().count, 0)
        XCTAssertEqual(
            fixture.binding.overlay.entries(model: "Note").count, 0,
            "a refused write publishes nothing, so the refusal cannot itself "
            + "become a write that replays later"
        )
    }

    func testWriteRefusesEarlyBeforeItTakesTheOperationLock() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)

        // Held from another thread, so a refusal that waited for the lock
        // would block rather than return. The early check is what makes the
        // common case cheap AND what makes this return at all.
        let holding = expectation(description: "the operation is held")
        let release = expectation(description: "the refusal came back")
        Thread.detachNewThread {
            try? fixture.binding.writePath.withOperation {
                holding.fulfill()
                XCTAssertEqual(XCTWaiter.wait(for: [release], timeout: 5), .completed)
            }
        }
        await fulfillment(of: [holding], timeout: 5)

        expectWindowRefusal("write") {
            _ = try fixture.binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(id: "r2", kind: .create),
                fields: []
            )
        }
        release.fulfill()
    }

    func testTheStopAndFoldBrokenChecksComeFirst() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)
        try backDate(fixture)

        // A document that is BOTH stopped and past its window reports the
        // stop: the gate runs after the stop check, so a reload-required
        // document does not start reporting a window problem instead.
        fixture.binding.requireReload(
            Format2Coordinator.reloadRequired(documentId: fixture.documentId, plan: "epoch.seal")
        )
        do {
            _ = try fixture.binding.writePath.write(
                model: "Note", mutation: OverlayMutation(id: "r1", kind: .create), fields: []
            )
            XCTFail("a stopped document should refuse")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .format2ReloadRequired)
        }
        fixture.binding.clearReload()

        // And a fold-broken one reports the broken fold, for the same reason.
        failing.failStatementsContaining = "INSERT INTO records_f2_"
        fixture.binding.overlay.apply(
            OverlayMutation(id: "remote", kind: .create, fields: ["title": .string("r")]),
            model: "Note"
        )
        fixture.binding.settleFolds()
        _ = try? fixture.binding.writePath.foldPendingUnderOperation()
        failing.failStatementsContaining = nil

        do {
            _ = try fixture.binding.writePath.write(
                model: "Note", mutation: OverlayMutation(id: "r1", kind: .create), fields: []
            )
            XCTFail("a fold-broken document should refuse")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .format2FoldBroken)
        }
    }

    /// The check reads an in-memory mirror, not SQL: it runs on the declared
    /// hot path, once per write, and the numbers it needs change only when a
    /// frame arrives.
    func testTheCheckReadsNoSqlAtAll() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)
        try backDate(fixture)

        // Every read of the epoch row now fails. A gate that asked SQL for the
        // mark would report that failure instead of the window.
        failing.failStatementsContaining = "FROM _epoch"
        expectWindowRefusal("a write with the epoch row unreadable") {
            _ = try fixture.binding.writePath.write(
                model: "Note", mutation: OverlayMutation(id: "r1", kind: .create), fields: []
            )
        }
        failing.failStatementsContaining = nil
    }

    // MARK: - Behavior 2 — the throwing doors

    func testEveryThrowingModelVerbRefusesAndLeavesNothing() async throws {
        let fixture = try await makeFixture()

        // Seeded INSIDE the window, so the refusals below are about the window
        // and not about a record that does not exist.
        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])
        try fixture.model.addStringsetMember(id: "n1", fieldName: "tags", member: "keep")
        let pendingBefore = try fixture.binding.store.pendingOps().count
        let rowBefore = try fixture.binding.store.read(model: "Note", recordId: "n1")
        let keysBefore = fixture.binding.overlay.entries(model: "Note").count

        try backDate(fixture)

        expectWindowRefusal("create") {
            _ = try fixture.model.create(id: "n2", values: ["title": .string("x")])
        }
        expectWindowRefusal("update") {
            try fixture.model.update(id: "n1", values: ["title": .string("x")])
        }
        expectWindowRefusal("save") {
            _ = try fixture.model.save(id: "n3", values: ["title": .string("x")])
        }
        expectWindowRefusal("addMember") {
            try fixture.model.addStringsetMember(id: "n1", fieldName: "tags", member: "new")
        }
        expectWindowRefusal("removeMember") {
            try fixture.model.removeStringsetMember(id: "n1", fieldName: "tags", member: "keep")
        }

        // Nothing moved: no merged row, no pending op, no overlay key.
        XCTAssertEqual(try fixture.binding.store.read(model: "Note", recordId: "n1"), rowBefore)
        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "n2"))
        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "n3"))
        XCTAssertEqual(try fixture.binding.store.pendingOps().count, pendingBefore)
        XCTAssertEqual(fixture.binding.overlay.entries(model: "Note").count, keysBefore)
        XCTAssertEqual(
            try fixture.binding.store.members(model: "Note", recordId: "n1", field: "tags"),
            ["keep"]
        )
        // #3758 — a throwing verb throws AND reports. One rule for both
        // clients: the event is every refused write's channel, so an app
        // handles the refusal once instead of at each call site. (Before
        // #3758 a throwing verb was silent here, which made the JS client's
        // event — where every verb throws — an event that could never fire.)
        XCTAssertEqual(
            fixture.refusals.value.count, 5,
            "one event per refused door, throwing or not"
        )
        XCTAssertEqual(
            fixture.refusals.value.map { $0.recordId },
            ["n2", "n1", "n3", "n1", "n1"]
        )
        for event in fixture.refusals.value {
            XCTAssertEqual(event.documentId, fixture.documentId)
            XCTAssertEqual(event.model, "Note")
            XCTAssertEqual(event.error.code, .documentOfflineWindowExpired)
            XCTAssertNotNil(event.error.details?["overdueMs"])
        }
    }

    // MARK: - #3758 — one contract: every refused write is reported

    /// Behavior 12 — the event has been delivered by the time the throw
    /// reaches the caller's `catch`.
    ///
    /// Which is what makes the two channels usable together: an app that
    /// catches at the call site and one that subscribes are never told in a
    /// surprising order.
    func testAThrowingVerbHasAlreadyReportedWhenItsErrorArrives() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)

        var seenAtCatch = 0
        do {
            _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
            XCTFail("create should have been refused past the offline window")
        } catch {
            seenAtCatch = fixture.refusals.value.count
        }
        XCTAssertEqual(
            seenAtCatch, 1,
            "the refusal was delivered before the error reached the caller"
        )
    }

    /// Behavior 13 and edge E1 — exactly one event per refused write, whichever
    /// gate refused it.
    ///
    /// `write()` refuses early or the commit refuses; never both. The early
    /// check runs inside an outer operation for the model verbs and outside one
    /// for `quietly`'s delete, and the count is the same either way.
    func testEachDoorReportsExactlyOnceAcrossBothEntryShapes() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("seed"), "views": .number(1),
        ])
        let record = try XCTUnwrap(fixture.model.find(id: "n1"))
        try backDate(fixture)

        // (a) A non-throwing door, whose early check runs OUTSIDE any
        // operation.
        fixture.model.delete(id: "n1")
        XCTAssertEqual(fixture.refusals.value.count, 1)
        XCTAssertFalse(
            fixture.binding.writePath.hasParkedRefusal,
            "nothing is left parked after a delivery"
        )

        // (b) A record field setter and a clear, same shape.
        record["title"] = .string("assigned")
        record["views"] = nil
        XCTAssertEqual(fixture.refusals.value.count, 3)
        XCTAssertFalse(fixture.binding.writePath.hasParkedRefusal)

        // (c) A throwing model verb, whose early check runs INSIDE the
        // operation `applyWriteFormat2` already holds.
        expectWindowRefusal("create") {
            _ = try fixture.model.create(id: "n2", values: ["title": .string("x")])
        }
        XCTAssertEqual(fixture.refusals.value.count, 4)
        XCTAssertFalse(fixture.binding.writePath.hasParkedRefusal)

        // (d) A member verb, which reaches the COMMIT gate under its own
        // operation rather than the early one.
        expectWindowRefusal("addMember") {
            try fixture.model.addStringsetMember(
                id: "n1", fieldName: "tags", member: "new"
            )
        }
        XCTAssertEqual(fixture.refusals.value.count, 5)
        XCTAssertFalse(fixture.binding.writePath.hasParkedRefusal)
    }

    /// Behavior 15 — a refusal at the commit boundary is delivered when the
    /// OUTERMOST operation exits, and not before.
    func testACommitBoundaryRefusalIsDeliveredWhenTheOperationExits() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)

        var insideCount = -1
        try fixture.binding.writePath.withOperation {
            expectWindowRefusal("the commit boundary") {
                _ = try fixture.binding.writePath.commitInsideOperation(
                    model: "Note",
                    mutation: OverlayMutation(
                        id: "r1", kind: .create, fields: ["title": .string("x")]
                    ),
                    fields: ["title"]
                )
            }
            // Recorded INSIDE the body, after the refusal: the callback has
            // not run, because running it here would run application code
            // under the document's operation lock.
            insideCount = fixture.refusals.value.count
            XCTAssertTrue(fixture.binding.writePath.hasParkedRefusal)
        }

        XCTAssertEqual(insideCount, 0, "not delivered while the lock is held")
        XCTAssertEqual(fixture.refusals.value.count, 1)
        XCTAssertEqual(fixture.refusals.value.first?.recordId, "r1")
        XCTAssertEqual(fixture.refusals.value.first?.model, "Note")
        XCTAssertFalse(fixture.binding.writePath.hasParkedRefusal)
    }

    /// Behavior 15a — the callback runs OUTSIDE the document's operation lock,
    /// and may read.
    ///
    /// `EventEmitter` delivers callback subscribers synchronously inside
    /// `emit`, so an `onWriteRefused` handler is application code on the
    /// refusing thread. Delivered at the gate it would hold the document's
    /// lock, and a handler reading a document whose folds are queued behind
    /// another operation could deadlock two concurrent refusals
    /// (3758-SO-01). The negative control below shows the assertion bites.
    func testTheCallbackRunsOutsideTheOperationLockAndMayRead() async throws {
        let provider = try await makeProvider()
        let fixture = try await makeFixture(host: provider)
        // A SECOND open document on the same coordinator, with a fold queued:
        // what a handler reading across documents meets.
        let otherId = "gate-other-\(UUID().uuidString.prefix(8))"
        let otherDoc = YDocument()
        let otherBinding = try fixture.coordinator.bind(
            documentId: otherId, models: ["Note"], document: otherDoc
        )
        let otherShared = MultiDocModel(schema: Self.schema)
        let otherModel = otherShared.connect(docId: otherId, doc: otherDoc)
        otherModel.bindFormat2(otherBinding)
        _ = try otherModel.create(id: "o1", values: ["title": .string("other")])
        otherBinding.overlay.apply(
            OverlayMutation(id: "o2", kind: .create, fields: ["title": .string("queued")]),
            model: "Note"
        )

        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])
        try backDate(fixture)

        let observed = LockedBox<[String: Bool]>([:])
        let readBack = LockedBox<[String: Bool]>([:])
        fixture.coordinator.onWriteRefused = { event in
            observed.withValue {
                $0[event.recordId] = fixture.binding.writePath.isInsideOperation
            }
            // Reading the REFUSING document and a second one, from inside the
            // handler. Under the lock either could block for ever.
            let here = fixture.model.find(id: "n1")
            let there = otherModel.find(id: "o1")
            readBack.withValue {
                $0[event.recordId] = here != nil && there != nil
            }
        }

        // (a) A nested model write, whose gate runs under `applyWriteFormat2`'s
        // own operation.
        let nested = expectation(description: "the nested write came back")
        Thread.detachNewThread {
            _ = try? fixture.model.create(id: "n2", values: ["title": .string("x")])
            nested.fulfill()
        }
        await fulfillment(of: [nested], timeout: 10)

        // (b) A member write, which takes the operation itself.
        let member = expectation(description: "the member write came back")
        Thread.detachNewThread {
            try? fixture.model.addStringsetMember(
                id: "n1", fieldName: "tags", member: "new"
            )
            member.fulfill()
        }
        await fulfillment(of: [member], timeout: 10)

        XCTAssertEqual(observed.value["n2"], false, "nested model write")
        XCTAssertEqual(observed.value["n1"], false, "member write")
        XCTAssertEqual(readBack.value["n2"], true, "reads answered from the handler")
        XCTAssertEqual(readBack.value["n1"], true, "reads answered from the handler")
    }

    /// The negative control for behavior 15a: at the moment the gate refuses,
    /// the calling thread IS inside the operation.
    ///
    /// So `isInsideOperation == false` at the callback is a fact about the
    /// parking, not a property the document has anyway — without it the
    /// assertion above would pass whatever the delivery did.
    func testTheGateItselfRunsInsideTheOperation() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)

        var insideAtTheGate: Bool?
        try fixture.binding.writePath.withOperation {
            do {
                try fixture.binding.writePath.assertWithinOfflineWindow(
                    model: "Note", recordId: "r1"
                )
                XCTFail("the gate should have refused")
            } catch {
                insideAtTheGate = fixture.binding.writePath.isInsideOperation
            }
        }
        XCTAssertEqual(
            insideAtTheGate, true,
            "delivering at the gate would run application code under the lock"
        )
        // And the event that was parked there is delivered on the way out.
        XCTAssertEqual(fixture.refusals.value.count, 1)
    }

    /// Every refusal parked inside one operation is delivered, in order.
    ///
    /// An operation body that catches a refusal and writes again refuses
    /// twice, and each refused write is owed its own report: parking one slot
    /// would report the last write and drop the first in silence
    /// (finding 3758-C01).
    func testEveryRefusalParkedInOneOperationIsDelivered() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)

        try fixture.binding.writePath.withOperation {
            try? fixture.binding.writePath.assertWithinOfflineWindow(
                model: "Note", recordId: "first"
            )
            XCTAssertTrue(
                fixture.refusals.value.isEmpty,
                "nothing is delivered while the operation is held"
            )
            try? fixture.binding.writePath.assertWithinOfflineWindow(
                model: "Note", recordId: "second"
            )
        }

        XCTAssertEqual(
            fixture.refusals.value.map(\.recordId), ["first", "second"],
            "both refused writes are reported, in the order they were refused"
        )
        XCTAssertFalse(fixture.binding.writePath.hasParkedRefusal)
    }

    /// Edge E10 — a parked refusal survives an operation body that then throws
    /// something else, the lock is given back, and a callback's own refused
    /// write parks a fresh event rather than re-delivering the first.
    func testAParkedRefusalOutlivesADifferentErrorAndFreesTheLock() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)

        struct Unrelated: Error {}
        do {
            try fixture.binding.writePath.withOperation {
                try? fixture.binding.writePath.assertWithinOfflineWindow(
                    model: "Note", recordId: "r1"
                )
                throw Unrelated()
            }
            XCTFail("the body's own error should propagate")
        } catch is Unrelated {
            // expected
        }

        XCTAssertEqual(
            fixture.refusals.value.count, 1,
            "a body that threw afterwards does not swallow the refusal"
        )
        XCTAssertEqual(fixture.refusals.value.first?.recordId, "r1")
        XCTAssertFalse(fixture.binding.writePath.hasParkedRefusal)

        // The lock was released: a later write proceeds, under a bounded wait.
        let proceeded = expectation(description: "a later write proceeded")
        Thread.detachNewThread {
            _ = try? fixture.binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(id: "r2", kind: .create),
                fields: []
            )
            proceeded.fulfill()
        }
        await fulfillment(of: [proceeded], timeout: 5)

        // A callback that itself writes — and is itself refused — parks a
        // fresh event rather than re-delivering the one being delivered.
        fixture.coordinator.onWriteRefused = { event in
            if event.recordId == "r3" {
                _ = try? fixture.model.create(id: "r4", values: ["title": .string("x")])
            }
        }
        let reentrant = expectation(description: "the re-entrant refusal came back")
        Thread.detachNewThread {
            _ = try? fixture.binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(id: "r3", kind: .create),
                fields: []
            )
            reentrant.fulfill()
        }
        await fulfillment(of: [reentrant], timeout: 10)
        XCTAssertFalse(
            fixture.binding.writePath.hasParkedRefusal,
            "the slot is cleared before delivery, so a nested refusal parks its own"
        )
    }

    /// Edge E7 — a stringset clear through a `PrimitiveRecord` reports with the
    /// record's id and leaves the member index untouched.
    func testAStringsetClearReportsAndLeavesTheMemberIndexAlone() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])
        try fixture.model.addStringsetMember(id: "n1", fieldName: "tags", member: "keep")
        let record = try XCTUnwrap(fixture.model.find(id: "n1"))
        try backDate(fixture)

        record["tags"] = nil

        XCTAssertEqual(
            try fixture.binding.store.members(model: "Note", recordId: "n1", field: "tags"),
            ["keep"]
        )
        XCTAssertEqual(fixture.refusals.value.count, 1)
        XCTAssertEqual(fixture.refusals.value.first?.recordId, "n1")
        XCTAssertEqual(fixture.refusals.value.first?.model, "Note")
    }

    /// Edge E8 — the channel's scope is the WINDOW, unchanged by #3758: a
    /// stopped document's throwing verb refuses without an event.
    func testAStoppedDocumentsThrowingVerbReportsNothing() async throws {
        let fixture = try await makeFixture()
        fixture.binding.requireReload(
            Format2Coordinator.reloadRequired(
                documentId: fixture.documentId, plan: "epoch.seal"
            )
        )

        do {
            _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
            XCTFail("a stopped document should refuse")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .format2ReloadRequired)
        }
        XCTAssertTrue(
            fixture.refusals.value.isEmpty,
            "a reload-required refusal is not a window refusal"
        )
        XCTAssertFalse(fixture.binding.writePath.hasParkedRefusal)
    }

    /// Behavior 14 — inside the window no door reports anything.
    func testNoDoorReportsInsideTheWindow() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("seed"), "views": .number(1),
        ])
        let record = try XCTUnwrap(fixture.model.find(id: "n1"))
        try fixture.model.update(id: "n1", values: ["title": .string("again")])
        _ = try fixture.model.save(id: "n2", values: ["title": .string("x")])
        try fixture.model.addStringsetMember(id: "n1", fieldName: "tags", member: "a")
        try fixture.model.removeStringsetMember(id: "n1", fieldName: "tags", member: "a")
        record["title"] = .string("assigned")
        record["views"] = nil
        fixture.model.delete(id: "n2")

        XCTAssertTrue(fixture.refusals.value.isEmpty)
        XCTAssertFalse(fixture.binding.writePath.hasParkedRefusal)
    }

    /// `Format2ModelDelegate.quietly` swallows; it no longer reports.
    ///
    /// The report lives at the gate now — the one place every door runs
    /// through — so a copy in `quietly` would be a second report for the
    /// non-throwing doors and a second place the rule could drift.
    func testQuietlyOnlySwallows() throws {
        let source = try Self.readSource("Sources/JsBaoClient/LargeDocuments/Format2ModelDelegate.swift")
        let body = try Self.functionBody(source, signature: "func quietly(")
        XCTAssertFalse(
            body.contains("reportWriteRefused"),
            "the report is the gate's; `quietly` only swallows"
        )
    }

    // MARK: - Source helpers

    private static func readSource(_ relative: String) throws -> String {
        // …/swift-client/Tests/JsBaoClientTests/<this file> — three up is the
        // package root the relative path is written against.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }

    /// A function's OWN body, balanced from its signature — never a fixed
    /// number of characters after a landmark, which slides off the fact it
    /// grades as the code around it grows.
    private static func functionBody(_ source: String, signature: String) throws -> String {
        guard let start = source.range(of: signature) else {
            throw NSError(domain: "no '\(signature)'", code: 1)
        }
        let rest = source[start.lowerBound...]
        guard let open = rest.firstIndex(of: "{") else {
            throw NSError(domain: "'\(signature)' has no body", code: 1)
        }
        var depth = 0
        var index = open
        while index < rest.endIndex {
            if rest[index] == "{" { depth += 1 }
            if rest[index] == "}" {
                depth -= 1
                if depth == 0 { return String(rest[open...index]) }
            }
            index = rest.index(after: index)
        }
        throw NSError(domain: "'\(signature)' is unbalanced", code: 1)
    }

    func testReadsKeepAnsweringPastTheWindow() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("readable"), "views": .number(2),
        ])
        try backDate(fixture)

        let found = try XCTUnwrap(fixture.model.find(id: "n1"))
        XCTAssertEqual(found["title"], .string("readable"))
        XCTAssertEqual(try fixture.model.count(), 1)
        XCTAssertEqual(
            try fixture.model.query(["title": .string("readable")]).count,
            1
        )
    }

    func testASyncRestoresWrites() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)
        expectWindowRefusal("create before the sync") {
            _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
        }

        try fixture.binding.store.noteSync(at: Int(Date().timeIntervalSince1970 * 1000))

        _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
        XCTAssertNotNil(try fixture.binding.store.read(model: "Note", recordId: "n1"))
    }

    // MARK: - Behavior 2a — the doors that cannot throw

    func testDeleteRefusesWithoutWritingAndReportsTheEvent() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])
        let pendingBefore = try fixture.binding.store.pendingOps().count
        try backDate(fixture)

        fixture.model.delete(id: "n1")

        // The record is still there — the delete wrote nothing at all.
        XCTAssertNotNil(try fixture.binding.store.read(model: "Note", recordId: "n1"))
        XCTAssertEqual(try fixture.binding.store.pendingOps().count, pendingBefore)

        let events = fixture.refusals.value
        XCTAssertEqual(events.count, 1, "exactly one refusal event")
        XCTAssertEqual(events.first?.documentId, fixture.documentId)
        XCTAssertEqual(events.first?.model, "Note")
        XCTAssertEqual(events.first?.recordId, "n1")
        XCTAssertEqual(events.first?.error.code, .documentOfflineWindowExpired)
        XCTAssertNotNil(events.first?.error.details?["overdueMs"])
    }

    func testARecordFieldSetterAndAnExplicitClearRefuseAndReportTheEvent()
        async throws
    {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("seed"), "views": .number(1),
        ])
        let record = try XCTUnwrap(fixture.model.find(id: "n1"))
        try backDate(fixture)

        record["title"] = .string("assigned")
        record["views"] = nil

        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "n1")?["title"],
            .string("seed"),
            "the assignment wrote nothing"
        )
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "n1")?["views"],
            .number(1),
            "the clear wrote nothing"
        )

        let events = fixture.refusals.value
        XCTAssertEqual(events.count, 2, "one per refused mutation")
        XCTAssertEqual(Set(events.map { $0.recordId }), ["n1"])
        for event in events {
            XCTAssertEqual(event.error.code, .documentOfflineWindowExpired)
            XCTAssertEqual(event.model, "Note")
        }
    }

    /// Every OTHER error on a non-throwing path keeps the handling #3436 left
    /// it: swallowed, with no refusal event — the event is about the window,
    /// not a second reporting channel for everything.
    func testAnotherErrorOnANonThrowingPathIsStillHandledAsBefore() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])

        fixture.binding.requireReload(
            Format2Coordinator.reloadRequired(documentId: fixture.documentId, plan: "epoch.seal")
        )
        fixture.model.delete(id: "n1")

        XCTAssertNotNil(
            try fixture.binding.store.read(model: "Note", recordId: "n1"),
            "a stopped document's delete writes nothing, as #3436 left it"
        )
        XCTAssertTrue(
            fixture.refusals.value.isEmpty,
            "a reload-required refusal is not a window refusal and raises no event"
        )
    }

    // MARK: - Behavior 3 — where the mark is earned

    func testAJoinEarnsTheMarkAndRestoresWrites() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)
        expectWindowRefusal("create before the join") {
            _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
        }

        let now = Int(Date().timeIntervalSince1970 * 1000)
        _ = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 0,
                "sealedEpochs": [], "offlineWindowDays": 7,
            ],
            now: now
        )

        XCTAssertEqual(try fixture.binding.store.lastSyncAt(), now)
        _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
    }

    func testAnUpdateAckEarnsTheMarkAndRestoresWrites() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])
        try backDate(fixture)
        expectWindowRefusal("create before the ack") {
            _ = try fixture.model.create(id: "n2", values: ["title": .string("x")])
        }

        // An `update.ack` is the server speaking about THIS client's writes:
        // proof of contact as good as a handshake's, and the JS client earns
        // the mark on it for that reason.
        let now = Int(Date().timeIntervalSince1970 * 1000)
        _ = try fixture.coordinator.handleUpdateAck(
            ["documentId": fixture.documentId, "maxContiguousSeq": 1], now: now
        )

        XCTAssertEqual(try fixture.binding.store.lastSyncAt(), now)
        _ = try fixture.model.create(id: "n2", values: ["title": .string("x")])
    }
}
