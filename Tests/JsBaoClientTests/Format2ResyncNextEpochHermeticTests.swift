import XCTest
@testable import JsBaoClient
import YSwift

/// An `epoch.resync` naming the NEXT epoch is followed through a catch-up
/// (#4228, behavior 13).
///
/// The room answers `epoch.resync` naming the epoch it is on when it refuses a
/// frame it cannot integrate. A frame this client sent just before a seal can
/// be refused just after it, so the resync names the epoch the seal opened —
/// and it can reach the client before the seal does, or instead of it when the
/// seal's broadcast was lost. The coordinator used to stop the document there
/// with `FORMAT2_RELOAD_REQUIRED` (plan `epoch.resync`), which is how a Swift
/// writer lost every write during a concurrent import.
///
/// A resync carries no `baseDiscontinuity`, so the document does not move on
/// it directly: it re-handshakes, as it does when a seal leaves it more than
/// one epoch behind, and learns from `epoch.info` whether the sealed epoch was
/// a bulk-load boundary before it states any unacknowledged write again.
final class Format2ResyncNextEpochHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
        ]
    )

    private struct Fixture {
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let model: DynamicModel
        let documentId: String
        let replaced: LockedBox<[(String, YDocument)]>
    }

    /// A document joined at epoch 2, current and not held.
    private func makeFixture() async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "/f2-resync-next-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let documentId = "resync-next-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let replaced = LockedBox<[(String, YDocument)]>([])
        coordinator.replaceDocument = { id, document in
            replaced.withValue { $0.append((id, document)) }
        }
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: documentId, doc: doc)
        model.bindFormat2(binding)
        _ = try coordinator.handleEpochInfo(
            ["documentId": documentId, "epoch": 2, "sealedEpochs": []],
            now: Int(Date().timeIntervalSince1970 * 1000)
        )
        return Fixture(
            coordinator: coordinator, binding: binding, model: model,
            documentId: documentId, replaced: replaced
        )
    }

    private func resync(_ documentId: String, epoch: Int) -> [String: Any] {
        [
            "type": "epoch.resync", "documentId": documentId,
            "epoch": epoch, "reason": "update-not-integrated",
        ]
    }

    /// The `epoch.info` the re-handshake answers with: the room on `epoch`,
    /// with epoch `epoch - 1` sealed.
    private func handshake(
        _ documentId: String, epoch: Int, boundary: Bool, now: Int
    ) -> [String: Any] {
        [
            "type": "epoch.info", "documentId": documentId, "epoch": epoch,
            "serverTime": now,
            "sealedEpochs": [[
                "epoch": epoch - 1, "sealedAt": now - 60_000,
                "baseDiscontinuity": boundary,
                "download": ["path": "/g/\(epoch - 1)"],
            ]],
        ]
    }

    func testAResyncNamingTheNextEpochCatchesUpFirstAndKeepsWriting() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "acked", values: ["title": .string("old news")])
        try fixture.coordinator.handleUpdateAck(
            ["documentId": fixture.documentId, "maxContiguousSeq": 1]
        )
        _ = try fixture.model.create(id: "owed", values: ["title": .string("still owed")])
        let sealedOverlay = fixture.binding.overlay

        let decision = try fixture.coordinator.handleEpochSeal(
            resync(fixture.documentId, epoch: 3)
        )
        XCTAssertEqual(decision, .catchUp(from: 2, to: 3))
        XCTAssertFalse(fixture.binding.reloadRequired)
        // Nothing built on the overlay the room archived leaves meanwhile.
        XCTAssertNotNil(fixture.coordinator.hold.reason(fixture.documentId))

        // The re-handshake says epoch 2 was an ordinary seal.
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let plan = try fixture.coordinator.handleEpochInfo(
            handshake(fixture.documentId, epoch: 3, boundary: false, now: now), now: now
        )
        XCTAssertEqual(plan.plan, .catchUp)
        let archived = OverlayDocument()
        archived.applyRawEntries([("acked/title", .string("old news"))], model: "Note")
        let archive = Data(archived.encodeStateAsUpdate())
        let outcome = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: plan.reported, sealed: plan.sealed,
            fetch: { _ in archive }, now: now
        )
        XCTAssertEqual(outcome, .caughtUp(applied: [2], epoch: 3))
        XCTAssertEqual(try fixture.binding.store.epoch(), 3)
        XCTAssertFalse(fixture.binding.reloadRequired)
        XCTAssertFalse(fixture.binding.overlay === sealedOverlay)

        // The owed write survives the judgement and is stated on the new
        // epoch's overlay; the acknowledged one is not carried.
        let judged = try XCTUnwrap(
            fixture.coordinator.completeDeferredReplay(
                documentId: fixture.documentId, now: now
            )
        )
        XCTAssertEqual(judged.stated, [2])
        XCTAssertTrue(judged.dropped.isEmpty)
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "owed/title"),
            .string("still owed")
        )
        XCTAssertNil(fixture.binding.overlay.value(model: "Note", key: "acked/title"))

        // And it goes on writing, and the room's acknowledgement settles it.
        _ = try fixture.model.create(id: "after", values: ["title": .string("after the move")])
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "after/title"),
            .string("after the move")
        )
        let resend = try XCTUnwrap(
            fixture.coordinator.wholeStateResend(documentId: fixture.documentId)
        )
        XCTAssertEqual(resend.claim.stamps?.seqFrom, 2)
        XCTAssertEqual(resend.claim.stamps?.seq, 3)
        try fixture.coordinator.handleUpdateAck(
            ["documentId": fixture.documentId, "maxContiguousSeq": 3]
        )
        XCTAssertTrue(try fixture.binding.store.pendingOps().isEmpty)
        XCTAssertFalse(fixture.binding.reloadRequired)
    }

    func testALostSealAtABulkLoadIsFollowedAsABoundaryAndNothingCrossesItAsADelta()
        async throws
    {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "owed", values: ["title": .string("still owed")])

        // The seal of epoch 2 never arrived; the refusal's resync did.
        let decision = try fixture.coordinator.handleEpochSeal(
            resync(fixture.documentId, epoch: 3)
        )
        XCTAssertEqual(decision, .catchUp(from: 2, to: 3))
        XCTAssertEqual(try fixture.binding.store.epoch(), 2)

        // The re-handshake says epoch 2 was a bulk-load boundary.
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let plan = try fixture.coordinator.handleEpochInfo(
            handshake(fixture.documentId, epoch: 3, boundary: true, now: now), now: now
        )
        XCTAssertEqual(plan.plan, .catchUp)
        let outcome = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: plan.reported, sealed: plan.sealed,
            fetch: { _ in Data() }, now: now
        )
        XCTAssertEqual(outcome, .converge(from: 2, discontinuities: [2]))
        // Not moved, not stopped, and still held: the owed write waits for a
        // base past the boundary instead of going out as a delta on epoch 3.
        XCTAssertEqual(try fixture.binding.store.epoch(), 2)
        XCTAssertFalse(fixture.binding.reloadRequired)
        XCTAssertNotNil(fixture.coordinator.hold.reason(fixture.documentId))
        XCTAssertEqual(fixture.replaced.value.count, 0)
        XCTAssertEqual(try fixture.binding.store.pendingOps().map(\.recordId), ["owed"])
    }

    func testAResyncFurtherAheadIsACatchUpAndNotAStop() async throws {
        let fixture = try await makeFixture()
        let decision = try fixture.coordinator.handleEpochSeal(
            resync(fixture.documentId, epoch: 4)
        )
        XCTAssertEqual(decision, .catchUp(from: 2, to: 4))
        XCTAssertFalse(fixture.binding.reloadRequired)
    }

    func testAResyncBehindTheMarkIsAlreadyCurrent() async throws {
        let fixture = try await makeFixture()
        let decision = try fixture.coordinator.handleEpochSeal(
            resync(fixture.documentId, epoch: 1)
        )
        XCTAssertEqual(decision, .alreadyCurrent)
    }

    func testAResyncAtTheMarkIsOwedAWholeOverlay() async throws {
        let fixture = try await makeFixture()
        let decision = try fixture.coordinator.handleEpochSeal(
            resync(fixture.documentId, epoch: 2)
        )
        XCTAssertEqual(decision, .resyncOwed)
        XCTAssertFalse(fixture.binding.reloadRequired)
    }
}
