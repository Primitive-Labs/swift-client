import XCTest
@testable import JsBaoClient
import YSwift

/// Catching a client up over the sealed chain (#3437, behaviors 14, 15 and 16,
/// edge E4).
///
/// A client that was away while the room rotated is behind by whole epochs. It
/// does NOT need the document back: the overlays sealed between the epoch it
/// holds and the one the room is on are exactly the changes it missed, each a
/// bounded rotation-sized artifact, and applying them in order converges its
/// merged view on the server's `records` table with no base crossing the wire.
///
/// Three halves, deliberately separate:
///
/// - `Format2FastForward.plan` decides whether the chain can be TRUSTED, from
///   the handshake alone and before anything is downloaded. A gap or a pruned
///   archive means the sum of the overlays is not the document, and the honest
///   answer is to reload from a base rather than converge on a state that never
///   existed.
/// - `Format2ArtifactReader` reads one archive, with the same one-grant-refresh
///   rule a chunk is read by: the signature lives about an hour and a chain of
///   archives can outlast it, so an expiry is a step and not a failure — ONCE
///   (edge E10 of #3436, edge E4 here).
/// - `Format2Coordinator.runCatchUp` runs the plan: strictly sequential,
///   folding each decoded overlay WHOLE in one store transaction under the
///   operation lock, noting it into the conflict ledger on the way, and moving
///   the epoch mark only once the last archive has landed.
final class Format2FastForwardHermeticTests: XCTestCase {

    // MARK: - Behavior 14 — the planner

    private func entry(
        _ epoch: Int,
        sealedAt: Int = 0,
        flagged: Bool = false,
        granted: Bool = true
    ) -> SealedEpochChainEntry {
        SealedEpochChainEntry(
            epoch: epoch, sealedAt: sealedAt, baseDiscontinuity: flagged,
            downloadPath: granted ? "/grants/epoch-\(epoch)" : nil
        )
    }

    func testADocumentThatFollowsNoEpochAdoptsTheOneItIsToldAbout() {
        XCTAssertEqual(
            Format2FastForward.plan(current: 0, target: 7, sealed: []),
            .none(reason: .adopt),
            "a client with no overlay holds nothing to be behind WITH"
        )
    }

    func testAnAlreadyCurrentOrNonsenseTargetIsNoWork() {
        XCTAssertEqual(
            Format2FastForward.plan(current: 4, target: 4, sealed: []),
            .none(reason: .current)
        )
        XCTAssertEqual(
            Format2FastForward.plan(current: 4, target: 3, sealed: []),
            .none(reason: .current)
        )
        XCTAssertEqual(
            Format2FastForward.plan(current: 4, target: 0, sealed: []),
            .none(reason: .current)
        )
    }

    func testTheChainRunsFromTheHeldEpochToTheOneBeforeTheTarget() {
        let plan = Format2FastForward.plan(
            current: 3, target: 6,
            sealed: [entry(2), entry(3), entry(4), entry(5), entry(6)]
        )
        XCTAssertEqual(
            plan,
            .apply(
                from: 3, to: 6,
                steps: [
                    FastForwardStep(epoch: 3, downloadPath: "/grants/epoch-3"),
                    FastForwardStep(epoch: 4, downloadPath: "/grants/epoch-4"),
                    FastForwardStep(epoch: 5, downloadPath: "/grants/epoch-5"),
                ]
            ),
            "the HELD epoch's own archive is a step: writes landed in it after "
                + "this client went away, and its archive is the only place they "
                + "exist now. The target epoch is open and is reached by syncing."
        )
    }

    func testAMissingLinkIsAGapAndAPrunedArchiveIsUnavailable() {
        XCTAssertEqual(
            Format2FastForward.plan(
                current: 2, target: 5, sealed: [entry(2), entry(4)]
            ),
            .reload(reason: .gap, epoch: 3),
            "a chain that skips an epoch cannot say what happened in it"
        )
        XCTAssertEqual(
            Format2FastForward.plan(
                current: 2, target: 5,
                sealed: [entry(2), entry(3, granted: false), entry(4)]
            ),
            .reload(reason: .unavailable, epoch: 3)
        )
    }

    func testAFlaggedEpochConvergesAndItsOwnArchiveIsStillAStep() {
        let plan = Format2FastForward.plan(
            current: 2, target: 6,
            sealed: [
                entry(2), entry(3), entry(4, flagged: true), entry(5),
            ]
        )
        XCTAssertEqual(
            plan,
            .converge(
                from: 2, discontinuities: [4],
                steps: [
                    FastForwardStep(epoch: 2, downloadPath: "/grants/epoch-2"),
                    FastForwardStep(epoch: 3, downloadPath: "/grants/epoch-3"),
                    FastForwardStep(epoch: 4, downloadPath: "/grants/epoch-4"),
                ]
            ),
            "the flagged epoch was sealed and archived through the ordinary "
                + "path, so its own writes exist nowhere else and it IS "
                + "applicable; what is unknown starts at E+1"
        )
    }

    func testTheChainParityWithJsBao() throws {
        let cases: [[String: Any]] = [
            ["current": 0, "target": 4, "sealed": []],
            ["current": 4, "target": 4, "sealed": []],
            ["current": 5, "target": 4, "sealed": []],
            [
                "current": 3, "target": 6,
                "sealed": [
                    Self.link(3), Self.link(4), Self.link(5), Self.link(6),
                ],
            ],
            ["current": 2, "target": 5, "sealed": [Self.link(2), Self.link(4)]],
            [
                "current": 2, "target": 5,
                "sealed": [Self.link(2), Self.link(3, granted: false), Self.link(4)],
            ],
            [
                "current": 2, "target": 6,
                "sealed": [
                    Self.link(2), Self.link(3), Self.link(4, flagged: true),
                    Self.link(5),
                ],
            ],
            [
                "current": 1, "target": 5,
                "sealed": [
                    Self.link(1, flagged: true), Self.link(2),
                    Self.link(3, flagged: true), Self.link(4),
                ],
            ],
        ]

        let answer = try Format2Harness.run([
            "command": "plan-fast-forward", "cases": cases,
        ])
        let expected = try XCTUnwrap(answer["plans"] as? [[String: Any]])
        XCTAssertEqual(expected.count, cases.count)

        for (index, each) in cases.enumerated() {
            let sealed = (each["sealed"] as? [[String: Any]] ?? []).map { link in
                SealedEpochChainEntry(
                    epoch: link["epoch"] as? Int ?? 0,
                    baseDiscontinuity: link["baseDiscontinuity"] as? Bool ?? false,
                    downloadPath: link["download"] == nil
                        ? nil : "/grants/epoch-\(link["epoch"] as? Int ?? 0)"
                )
            }
            let mine = Format2FastForward.plan(
                current: each["current"] as? Int ?? 0,
                target: each["target"] as? Int ?? 0,
                sealed: sealed
            )
            let theirs = expected[index]
            XCTAssertEqual(
                mine.kind, theirs["kind"] as? String,
                "case \(index): js-bao planned \(theirs["kind"] ?? "?")"
            )
            if let reason = theirs["reason"] as? String {
                XCTAssertTrue(
                    mine.reasonName == reason,
                    "case \(index): reason \(mine.reasonName ?? "nil") ≠ \(reason)"
                )
            }
            if let steps = theirs["steps"] as? [[String: Any]] {
                XCTAssertEqual(
                    mine.steps.map(\.epoch), steps.compactMap { $0["epoch"] as? Int },
                    "case \(index): the steps are the chain, epoch for epoch"
                )
            }
            if let discontinuities = theirs["discontinuities"] as? [Int] {
                XCTAssertEqual(
                    mine.discontinuities, discontinuities, "case \(index)"
                )
            }
            if let epoch = theirs["epoch"] as? Int, theirs["kind"] as? String == "reload" {
                XCTAssertEqual(mine.refusedAt, epoch, "case \(index)")
            }
        }
    }

    private static func link(
        _ epoch: Int, flagged: Bool = false, granted: Bool = true
    ) -> [String: Any] {
        var out: [String: Any] = ["epoch": epoch]
        if flagged { out["baseDiscontinuity"] = true }
        if granted { out["download"] = ["path": "/grants/epoch-\(epoch)"] }
        return out
    }

    // MARK: - Behavior 15 — the artifact reader

    private func reader(
        grantPath: String = "/grants/epoch-3",
        answers: @escaping (URL, Int) -> Format2ArtifactReader.Answer,
        refresh: @escaping () throws -> String? = { nil }
    ) -> (Format2ArtifactReader, LockedBox<[URL]>) {
        let reads = LockedBox<[URL]>([])
        let source = Format2ArtifactReader(
            apiUrl: "https://example.test",
            documentId: "doc-1",
            grantPath: grantPath,
            logger: Logger(level: .none),
            read: { url in
                let index = reads.withValue { list -> Int in
                    list.append(url)
                    return list.count - 1
                }
                return answers(url, index)
            },
            refreshGrant: refresh
        )
        return (source, reads)
    }

    func testASealedArchiveIsReadAtItsOwnDownloadPath() throws {
        let (source, reads) = reader(
            answers: { _, _ in
                Format2ArtifactReader.Answer(status: 200, body: Data([1, 2, 3]))
            }
        )
        let body = try source.read(what: "the sealed overlay of epoch 3").body
        XCTAssertEqual(body, Data([1, 2, 3]))
        XCTAssertEqual(
            reads.value.map(\.absoluteString),
            ["https://example.test/grants/epoch-3"],
            "the chain entry's own signed path, resolved against the api origin"
        )
    }

    func testARefusedSignatureIsRefreshedOnceAndTheReadRepeated() throws {
        let (source, reads) = reader(
            answers: { _, index in
                index == 0
                    ? Format2ArtifactReader.Answer(status: 401, body: Data())
                    : Format2ArtifactReader.Answer(status: 200, body: Data([9]))
            },
            refresh: { "/grants/epoch-3-fresh" }
        )
        XCTAssertEqual(try source.read(what: "the archive").body, Data([9]))
        XCTAssertEqual(reads.value.count, 2)
        XCTAssertEqual(
            reads.value.last?.absoluteString,
            "https://example.test/grants/epoch-3-fresh",
            "the fresh grant is adopted, so the retry reads the new path"
        )
        XCTAssertEqual(source.grantPath, "/grants/epoch-3-fresh")
    }

    func testASecondRefusalIsReportedWithTheFirstStatusAndReadsNoMore() throws {
        let (source, reads) = reader(
            answers: { _, index in
                Format2ArtifactReader.Answer(
                    status: index == 0 ? 401 : 403, body: Data()
                )
            },
            refresh: { "/grants/epoch-3-fresh" }
        )
        do {
            _ = try source.read(what: "the archive of epoch 3")
            XCTFail("a second refusal with a grant just minted is not an expiry")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
            XCTAssertEqual(
                error.details?["status"], .number(401),
                "the FIRST status is the one that says what happened"
            )
        }
        XCTAssertEqual(reads.value.count, 2, "once, not a spin")
    }

    func testAStatusAFreshSignatureCannotFixIsNotRetried() throws {
        let refreshed = LockedBox(0)
        let (source, reads) = reader(
            answers: { _, _ in
                Format2ArtifactReader.Answer(status: 404, body: Data())
            },
            refresh: {
                refreshed.withValue { $0 += 1 }
                return "/grants/other"
            }
        )
        XCTAssertThrowsError(try source.read(what: "the archive"))
        XCTAssertEqual(reads.value.count, 1)
        XCTAssertEqual(
            refreshed.value, 0,
            "retention has taken the object; a new signature cannot bring it back"
        )
    }

    // MARK: - Behavior 16 and edge E4 — applying the chain

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "body": FieldDescriptor(type: .string),
        ]
    )

    private struct Fixture {
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let documentId: String
        let replaced: LockedBox<[(String, YDocument)]>
    }

    private func makeFixture(heldEpoch: Int) async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "/f2-ff-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let documentId = "ff-\(UUID().uuidString.prefix(8))"
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let replaced = LockedBox<[(String, YDocument)]>([])
        coordinator.replaceDocument = { id, document in
            replaced.withValue { $0.append((id, document)) }
        }
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: YDocument()
        )
        binding.registerModel(Self.schema)
        try binding.store.setEpoch(heldEpoch)
        return Fixture(
            coordinator: coordinator, binding: binding,
            documentId: documentId, replaced: replaced
        )
    }

    /// One sealed epoch's archive: an overlay holding exactly these entries.
    private func archive(_ entries: [(String, JSONValue)]) -> Data {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(entries, model: "Note")
        return Data(overlay.encodeStateAsUpdate())
    }

    func testTheChainIsFoldedOldestFirstAndTheMarkMovesOnlyAtTheEnd() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        let archives: [Int: Data] = [
            3: archive([("r1/title", .string("from 3")), ("r1/body", .string("kept"))]),
            4: archive([("r1/title", .string("from 4"))]),
        ]
        let order = LockedBox<[Int]>([])

        let outcome = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: 5,
            sealed: [
                SealedEpochChainEntry(
                    epoch: 3, sealedAt: 1_000, downloadPath: "/g/3"
                ),
                SealedEpochChainEntry(
                    epoch: 4, sealedAt: 2_000, downloadPath: "/g/4"
                ),
            ],
            fetch: { step in
                order.withValue { $0.append(step.epoch) }
                return archives[step.epoch] ?? Data()
            },
            now: 1_700_000_000_000
        )

        XCTAssertEqual(outcome, .caughtUp(applied: [3, 4], epoch: 5))
        XCTAssertEqual(order.value, [3, 4], "strictly sequential, oldest first")
        let row = try XCTUnwrap(
            fixture.binding.store.read(model: "Note", recordId: "r1")
        )
        XCTAssertEqual(
            row["title"], .string("from 4"),
            "a later overlay's value wins; applying them out of order would let "
                + "a stale one through"
        )
        XCTAssertEqual(row["body"], .string("kept"))
        XCTAssertEqual(
            try fixture.binding.store.epoch(), 5,
            "the mark moves onto the room's epoch, jumping the applied chain"
        )
        XCTAssertNotNil(
            try fixture.binding.store.lastSyncAt(),
            "a landed chain earns the offline window's mark (behavior 3)"
        )
        XCTAssertEqual(
            fixture.replaced.value.count, 1,
            "reaching the room's epoch is a move onto a fresh overlay"
        )
    }

    func testTheChainIsNotedIntoTheConflictLedgerAsItLands() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        let archives: [Int: Data] = [
            3: archive([("r1/title", .string("from 3"))]),
            4: archive([("r2/_deleted", .bool(true))]),
        ]

        _ = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: 5,
            sealed: [
                SealedEpochChainEntry(epoch: 3, sealedAt: 1_000, downloadPath: "/g/3"),
                SealedEpochChainEntry(epoch: 4, sealedAt: 2_000, downloadPath: "/g/4"),
            ],
            fetch: { archives[$0.epoch] ?? Data() },
            now: 5_000
        )

        let ledger = try XCTUnwrap(
            fixture.coordinator.conflictLedger(fixture.documentId),
            "the chain is the evidence a returning client's writes are judged "
                + "against, so it is kept for the replay"
        )
        XCTAssertTrue(ledger.covers(from: 3, to: 5))
        XCTAssertEqual(
            ledger.conflictFor(
                model: "Note", recordId: "r1", field: "title", afterEpoch: 2
            )?.epoch,
            3
        )
        XCTAssertEqual(
            ledger.deletedAfter(model: "Note", recordId: "r2", afterEpoch: 2)?.epoch,
            4
        )
        XCTAssertEqual(
            ledger.window(epoch: 4, currentEpoch: 5).start, 1_000,
            "an epoch's window opens at the PREVIOUS epoch's seal"
        )
        XCTAssertEqual(ledger.window(epoch: 4, currentEpoch: 5).end, 2_000)
    }

    func testAFailureIsRetriedOnceAndThenStopsTheDocumentNamingTheEpoch() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        let archives: [Int: Data] = [
            3: archive([("r1/title", .string("from 3"))]),
        ]
        let attempts = LockedBox<[Int]>([])

        let outcome = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: 5,
            sealed: [
                SealedEpochChainEntry(epoch: 3, sealedAt: 1_000, downloadPath: "/g/3"),
                SealedEpochChainEntry(epoch: 4, sealedAt: 2_000, downloadPath: "/g/4"),
            ],
            fetch: { step in
                attempts.withValue { $0.append(step.epoch) }
                guard let body = archives[step.epoch] else {
                    throw JsBaoError(code: .unavailable, message: "no archive")
                }
                return body
            },
            now: 5_000
        )

        XCTAssertEqual(
            outcome, .reload(reason: .failed, epoch: 4),
            "which epoch stopped the chain is what a retry starts from and what "
                + "an operator reads"
        )
        XCTAssertEqual(
            attempts.value, [3, 4, 4],
            "once more, and only once: a reader that kept spinning on a refusal "
                + "would be indistinguishable from one that had hung (edge E4)"
        )
        XCTAssertEqual(
            try fixture.binding.store.epoch(), 3,
            "the mark is untouched, so the next handshake retries from the same "
                + "held epoch"
        )
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "r1")?["title"],
            .string("from 3"),
            "the steps before the failure stay folded — harmless, because "
                + "applying an overlay is idempotent at the record level"
        )
        XCTAssertTrue(
            fixture.binding.reloadRequired,
            "a chain that cannot be read leaves the document held, reading from "
                + "the view it has"
        )
        XCTAssertEqual(fixture.replaced.value.count, 0, "nothing was moved")
    }

    func testARefusedChainDownloadsNothingAndMovesNothing() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        let fetched = LockedBox(0)

        let outcome = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: 6,
            sealed: [
                SealedEpochChainEntry(epoch: 3, sealedAt: 1, downloadPath: "/g/3"),
                // 4 is missing: a gap.
                SealedEpochChainEntry(epoch: 5, sealedAt: 2, downloadPath: "/g/5"),
            ],
            fetch: { _ in
                fetched.withValue { $0 += 1 }
                return Data()
            },
            now: 5_000
        )

        XCTAssertEqual(outcome, .reload(reason: .gap, epoch: 4))
        XCTAssertEqual(
            fetched.value, 0,
            "nothing is downloaded until the chain is known to be complete"
        )
        XCTAssertEqual(try fixture.binding.store.epoch(), 3)
    }

    func testAFlaggedChainIsHandedBackForTheRebuildRatherThanRun() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        let fetched = LockedBox(0)

        let outcome = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: 6,
            sealed: [
                SealedEpochChainEntry(epoch: 3, sealedAt: 1, downloadPath: "/g/3"),
                SealedEpochChainEntry(
                    epoch: 4, sealedAt: 2, baseDiscontinuity: true,
                    downloadPath: "/g/4"
                ),
                SealedEpochChainEntry(epoch: 5, sealedAt: 3, downloadPath: "/g/5"),
            ],
            fetch: { _ in
                fetched.withValue { $0 += 1 }
                return Data()
            },
            now: 5_000
        )

        XCTAssertEqual(
            outcome, .converge(from: 3, discontinuities: [4]),
            "converging needs a BASE between the chain and the move, which this "
                + "runner cannot fetch — so nothing is downloaded and nothing is "
                + "moved, exactly as for a refusal"
        )
        XCTAssertEqual(fetched.value, 0)
        XCTAssertEqual(try fixture.binding.store.epoch(), 3)
    }

    func testAFoldOfASealedOverlayIsOneTransactionUnderTheOperationLock() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        let overlay = OverlayDocument()
        overlay.applyRawEntries(
            [
                ("r1/title", .string("a")),
                ("r2/title", .string("b")),
                ("r3/_deleted", .bool(true)),
            ],
            model: "Note"
        )

        let folded = try fixture.binding.foldSealedOverlay(overlay, epoch: 3)
        XCTAssertEqual(folded, ["Note"])
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "r1")?["title"],
            .string("a")
        )
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "r2")?["title"],
            .string("b")
        )
        XCTAssertNil(
            try fixture.binding.store.read(model: "Note", recordId: "r3"),
            "a tombstone in a sealed overlay removes the row, as it does anywhere"
        )
    }
}
