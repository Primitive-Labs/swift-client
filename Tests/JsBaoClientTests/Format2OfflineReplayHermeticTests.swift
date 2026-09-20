import XCTest
@testable import JsBaoClient

/// Judging what a client wrote while it was away (#3437, behavior 19, edge E9).
///
/// A returning client replays its unacknowledged writes onto the epoch it lands
/// on. Doing that unconditionally silently overwrites whatever anyone else
/// wrote in between, including writes made days after the offline one. Doing it
/// with per-field timestamps would mean stamping every field of every record,
/// in the overlay, in `records` and in every snapshot chunk, for a case that is
/// rare by construction.
///
/// Neither is necessary, because the client holds both halves of the evidence
/// by the time it replays: the sealed overlays it applied while catching up are
/// precisely the touched records and fields of the epochs it missed, and an
/// epoch's WINDOW runs from the previous epoch's seal to its own. So each op's
/// own `ts` is placed against the window of the epoch that touched the same
/// field.
///
/// Two rules are not recency-gated — a patch is never replayed onto a record
/// deleted meanwhile, and an op whose chain retention has pruned cannot be
/// checked at all — and nothing is EVER dropped on a clock this client has no
/// reason to trust (edge E9).
final class Format2OfflineReplayHermeticTests: XCTestCase {

    // MARK: - Fixtures

    private static func op(
        seq: Int,
        recordId: String = "r1",
        op kind: PendingOp.Kind = .patch,
        fields: [String] = ["a"],
        baseEpoch: Int = 3,
        ts: Int = 0,
        mutation: OverlayMutation? = nil
    ) -> PendingOp {
        PendingOp(
            seq: seq, model: "Note", recordId: recordId, op: kind,
            fields: fields, baseEpoch: baseEpoch, ts: ts,
            mutation: mutation
                ?? OverlayMutation(
                    id: recordId,
                    kind: OverlayMutation.Kind(rawValue: kind.rawValue) ?? .patch,
                    fields: Dictionary(
                        uniqueKeysWithValues: fields.map { ($0, JSONValue.string("mine")) }
                    )
                ),
            priorOverlay: nil
        )
    }

    /// A ledger whose epochs 3 and 4 are noted, sealed at 1,000 and 2,000.
    private func ledger(
        touches: [(epoch: Int, entry: OverlayRecordEntry)] = [],
        noted: [Int] = [3, 4],
        sealTimes: [(epoch: Int, sealedAt: Int?)] = [
            (epoch: 2, sealedAt: 500), (epoch: 3, sealedAt: 1_000),
            (epoch: 4, sealedAt: 2_000),
        ]
    ) -> OfflineConflictLedger {
        let ledger = OfflineConflictLedger()
        ledger.noteSealTimes(sealTimes)
        for epoch in noted {
            ledger.noteEpoch(epoch)
        }
        for touch in touches {
            ledger.noteEntry(epoch: touch.epoch, model: "Note", entry: touch.entry)
        }
        return ledger
    }

    // MARK: - Behavior 19 — the rules

    func testAnUncontestedWriteReplaysWithNoNotice() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [Self.op(seq: 1, ts: 1_500)],
            ledger: ledger(),
            currentEpoch: 5,
            now: 3_000
        )
        XCTAssertEqual(plan.ops.map(\.seq), [1])
        XCTAssertTrue(plan.notices.isEmpty)
        XCTAssertFalse(plan.rebuildRequired)
    }

    func testAFieldWrittenOnlineAfterTheOfflineWriteDropsIt() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [Self.op(seq: 1, ts: 600)],
            ledger: ledger(
                touches: [
                    (
                        epoch: 4,
                        entry: OverlayRecordEntry(id: "r1", fields: ["a": .string("theirs")])
                    )
                ]
            ),
            currentEpoch: 5,
            now: 3_000
        )
        XCTAssertTrue(plan.ops.isEmpty, "a patch with nothing left to say is gone")
        XCTAssertEqual(plan.notices.count, 1)
        XCTAssertEqual(plan.notices[0].outcome, .dropped)
        XCTAssertEqual(plan.notices[0].reason, .outdated)
        XCTAssertEqual(plan.notices[0].field, "a")
        XCTAssertEqual(
            plan.notices[0].epoch, 4,
            "the notice names the epoch whose write it raced"
        )
    }

    func testAWriteInsideTheRacingEpochsWindowIsKeptAndSurfaced() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [Self.op(seq: 1, ts: 1_500)],
            ledger: ledger(
                touches: [
                    (
                        epoch: 4,
                        entry: OverlayRecordEntry(id: "r1", fields: ["a": .string("theirs")])
                    )
                ]
            ),
            currentEpoch: 5,
            now: 3_000
        )
        XCTAssertEqual(plan.ops.map(\.seq), [1], "inside the window the offline write wins")
        XCTAssertEqual(plan.notices.map(\.reason), [.inWindow])
        XCTAssertEqual(plan.notices.map(\.outcome), [.keptAmbiguous])
    }

    func testOnlyTheLosingFieldIsNarrowedAndTheDurableRowIsToldSo() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [Self.op(seq: 1, fields: ["a", "b"], ts: 600)],
            ledger: ledger(
                touches: [
                    (
                        epoch: 4,
                        entry: OverlayRecordEntry(id: "r1", fields: ["a": .string("theirs")])
                    )
                ]
            ),
            currentEpoch: 5,
            now: 3_000
        )
        XCTAssertEqual(plan.ops.count, 1)
        XCTAssertEqual(plan.ops[0].fields, ["b"])
        XCTAssertEqual(
            plan.ops[0].mutation?.fields.keys.sorted(), ["b"],
            "the mutation is narrowed too, or the restore path would put the "
                + "whole write back after a crash"
        )
        XCTAssertEqual(
            plan.narrowed.map(\.seq), [1],
            "a partly surviving op has to be rewritten in `_pending_ops`"
        )
    }

    func testAPatchOntoARecordDeletedMeanwhileIsDroppedWhateverTheClockSays() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [Self.op(seq: 1, ts: 9_999_999)],
            ledger: ledger(
                touches: [
                    (epoch: 4, entry: OverlayRecordEntry(id: "r1", deleted: true))
                ]
            ),
            currentEpoch: 5,
            now: 10_000_000
        )
        XCTAssertTrue(plan.ops.isEmpty)
        XCTAssertEqual(plan.notices.map(\.reason), [.recordDeleted])
        XCTAssertNil(
            plan.notices[0].field,
            "the outcome is the whole record's, so the notice names no field"
        )
        XCTAssertFalse(
            plan.rebuildRequired,
            "an edit lost is recoverable; a resurrected record is not"
        )
    }

    func testADroppedDeleteSuppressesItsTombstoneAndAsksForARebuild() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [Self.op(seq: 1, op: .delete, fields: [], ts: 600)],
            ledger: ledger(
                touches: [
                    (
                        epoch: 4,
                        entry: OverlayRecordEntry(id: "r1", fields: ["a": .string("theirs")])
                    )
                ]
            ),
            currentEpoch: 5,
            now: 3_000
        )
        XCTAssertTrue(plan.ops.isEmpty)
        XCTAssertEqual(
            plan.suppressedDeletes.map(\.recordId), ["r1"],
            "the tombstone must not ride along on the carried overlay either"
        )
        XCTAssertTrue(
            plan.rebuildRequired,
            "the local row went when the delete was written, so what this client "
                + "holds for the record is only what the later epochs happened "
                + "to write — it needs a base to be right again"
        )
        XCTAssertEqual(plan.notices.map(\.reason), [.outdated])
    }

    func testACreateSurvivesWholeWhenTheRecordLevelRaceWentItsWay() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [
                Self.op(seq: 1, op: .create, fields: ["a", "b"], ts: 2_500)
            ],
            ledger: ledger(
                touches: [
                    (
                        epoch: 4,
                        entry: OverlayRecordEntry(id: "r1", fields: ["a": .string("theirs")])
                    )
                ]
            ),
            currentEpoch: 5,
            now: 3_000
        )
        XCTAssertEqual(plan.ops.count, 1)
        XCTAssertEqual(
            plan.ops[0].fields.sorted(), ["a", "b"],
            "`_replace` discards the base row, so the create travels whole"
        )
        XCTAssertTrue(plan.narrowed.isEmpty)
    }

    func testAnOpWhoseChainIsNotCoveredIsKeptAsUnverifiable() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [Self.op(seq: 1, baseEpoch: 2, ts: 600)],
            ledger: ledger(noted: [3, 4]),
            currentEpoch: 5,
            now: 3_000
        )
        XCTAssertEqual(plan.ops.map(\.seq), [1])
        XCTAssertEqual(plan.notices.map(\.reason), [.unverifiable])
        XCTAssertEqual(plan.notices.map(\.outcome), [.keptAmbiguous])
        XCTAssertEqual(
            plan.notices[0].epoch, 0,
            "there was no chain to name an epoch from"
        )
    }

    // MARK: - Edge E9 — an untrusted clock never drops

    func testWithNoMeasuredOffsetNothingIsDroppedOnRecency() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [
                Self.op(seq: 1, ts: 600),
                Self.op(seq: 2, recordId: "r2", op: .delete, fields: [], ts: 600),
            ],
            ledger: ledger(
                touches: [
                    (
                        epoch: 4,
                        entry: OverlayRecordEntry(id: "r1", fields: ["a": .string("theirs")])
                    ),
                    (
                        epoch: 4,
                        entry: OverlayRecordEntry(id: "r2", fields: ["a": .string("theirs")])
                    ),
                ]
            ),
            currentEpoch: 5,
            now: 3_000,
            clockOffsetKnown: false
        )
        XCTAssertEqual(plan.ops.map(\.seq), [1, 2])
        XCTAssertEqual(
            Set(plan.notices.map(\.reason)), [.inWindow],
            "a clock with no measured offset says nothing comparable, so "
                + "\"clearly older\" degrades to the ambiguous case"
        )
        XCTAssertFalse(plan.rebuildRequired)
    }

    // MARK: - The bulk-load presence rule, asked FIRST

    func testPresenceDecidesForAnOpBelowTheIngestAndIsAskedFirst() {
        let noChain = OfflineConflictLedger()
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [
                Self.op(seq: 1, recordId: "kept", baseEpoch: 3),
                Self.op(seq: 2, recordId: "gone", baseEpoch: 3),
                Self.op(seq: 3, recordId: "new", op: .create, baseEpoch: 3),
                Self.op(seq: 4, recordId: "above", baseEpoch: 5),
            ],
            ledger: noChain,
            currentEpoch: 6,
            now: 3_000,
            ingest: OfflineReplayIngest(
                through: 4,
                scope: .ranges,
                records: [
                    Format2OfflineReplay.recordKey("Note", "kept"): .present,
                    Format2OfflineReplay.recordKey("Note", "gone"): .absent,
                    Format2OfflineReplay.recordKey("Note", "new"): .absent,
                ]
            )
        )

        XCTAssertEqual(
            plan.ops.map(\.seq), [1, 3, 4],
            "the patch onto a record the ingest removed is gone; an offline "
                + "create at a new id is kept; an op written ABOVE the ingest "
                + "follows the ordinary rules"
        )
        let byRecord = Dictionary(
            uniqueKeysWithValues: plan.notices.map { ($0.recordId, $0) }
        )
        XCTAssertEqual(byRecord["kept"]?.reason, .bulkIngest)
        XCTAssertEqual(byRecord["kept"]?.outcome, .keptAmbiguous)
        XCTAssertEqual(byRecord["gone"]?.reason, .bulkIngest)
        XCTAssertEqual(byRecord["gone"]?.outcome, .dropped)
        XCTAssertEqual(byRecord["new"]?.outcome, .keptAmbiguous)
        XCTAssertEqual(
            byRecord["above"]?.reason, .unverifiable,
            "above the ingest there is no chain either, so it is unverifiable"
        )
        XCTAssertFalse(
            plan.rebuildRequired,
            "the convergence has already replaced the whole range, so the "
                + "merged view is correct"
        )
    }

    func testUnderScopeAllAMissIsMissingInformationAndNeverALicenceToDrop() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [Self.op(seq: 1, recordId: "unknown", baseEpoch: 3)],
            ledger: OfflineConflictLedger(),
            currentEpoch: 6,
            now: 3_000,
            ingest: OfflineReplayIngest(through: 4, scope: .all, records: [:])
        )
        XCTAssertEqual(plan.ops.map(\.seq), [1])
        XCTAssertEqual(plan.notices.map(\.outcome), [.keptAmbiguous])
        XCTAssertEqual(plan.notices.map(\.reason), [.bulkIngest])
    }

    func testTheRecordKeyIsNulJoinedSoNeitherHalfCanCollide() {
        XCTAssertEqual(
            Format2OfflineReplay.recordKey("Note", "r1"), "Note\u{0}r1"
        )
        XCTAssertNotEqual(
            Format2OfflineReplay.recordKey("a b", "c"),
            Format2OfflineReplay.recordKey("a", "b c"),
            "a model name or a record id may contain a space, and two records "
                + "whose joined keys collided would be judged as one"
        )
    }

    // MARK: - Ordering

    func testOpsComeBackInTheirOriginalLocalOrder() {
        let plan = Format2OfflineReplay.resolveOfflineReplay(
            ops: [
                Self.op(seq: 3, fields: ["c"]),
                Self.op(seq: 1, fields: ["a"]),
                Self.op(seq: 2, fields: ["b"]),
            ],
            ledger: ledger(),
            currentEpoch: 5,
            now: 3_000
        )
        XCTAssertEqual(
            plan.ops.map(\.seq), [1, 2, 3],
            "a later op of the same record must not overtake an earlier one"
        )
    }

    // MARK: - Parity with js-bao

    func testTheResolutionAgreesWithJsBao() throws {
        // Each case: the ops, what each epoch's sealed overlay touched, the
        // seal times, and the clock. Built so the verdicts genuinely differ —
        // dropped, narrowed, kept-ambiguous, unverifiable and a dropped delete
        // all appear.
        let cases: [[String: Any]] = [
            [
                "ops": [Self.wireOp(seq: 1, fields: ["a"], ts: 1_500)],
                "epochs": [
                    ["epoch": 3, "entries": [Self.wireEntry(id: "r1", fields: ["a"])]]
                ],
                "sealTimes": [
                    ["epoch": 2, "sealedAt": 500], ["epoch": 3, "sealedAt": 1_000],
                    ["epoch": 4, "sealedAt": 2_000],
                ],
                "noted": [3, 4], "currentEpoch": 5, "now": 3_000,
            ],
            [
                "ops": [Self.wireOp(seq: 1, fields: ["a"], ts: 600)],
                "epochs": [
                    ["epoch": 4, "entries": [Self.wireEntry(id: "r1", fields: ["a"])]]
                ],
                "sealTimes": [
                    ["epoch": 3, "sealedAt": 1_000], ["epoch": 4, "sealedAt": 2_000],
                ],
                "noted": [3, 4], "currentEpoch": 5, "now": 3_000,
            ],
            [
                "ops": [Self.wireOp(seq: 1, fields: ["a", "b"], ts: 600)],
                "epochs": [
                    ["epoch": 4, "entries": [Self.wireEntry(id: "r1", fields: ["a"])]]
                ],
                "sealTimes": [
                    ["epoch": 3, "sealedAt": 1_000], ["epoch": 4, "sealedAt": 2_000],
                ],
                "noted": [3, 4], "currentEpoch": 5, "now": 3_000,
            ],
            [
                "ops": [Self.wireOp(seq: 1, kind: "delete", fields: [], ts: 600)],
                "epochs": [
                    ["epoch": 4, "entries": [Self.wireEntry(id: "r1", fields: ["a"])]]
                ],
                "sealTimes": [
                    ["epoch": 3, "sealedAt": 1_000], ["epoch": 4, "sealedAt": 2_000],
                ],
                "noted": [3, 4], "currentEpoch": 5, "now": 3_000,
            ],
            [
                "ops": [Self.wireOp(seq: 1, fields: ["a"], ts: 9_000)],
                "epochs": [
                    [
                        "epoch": 4,
                        "entries": [Self.wireEntry(id: "r1", deleted: true)],
                    ]
                ],
                "sealTimes": [
                    ["epoch": 3, "sealedAt": 1_000], ["epoch": 4, "sealedAt": 2_000],
                ],
                "noted": [3, 4], "currentEpoch": 5, "now": 10_000,
            ],
            [
                "ops": [Self.wireOp(seq: 1, fields: ["a"], baseEpoch: 2, ts: 600)],
                "epochs": [], "sealTimes": [], "noted": [3, 4],
                "currentEpoch": 5, "now": 3_000,
            ],
            [
                "ops": [Self.wireOp(seq: 1, kind: "create", fields: ["a"], ts: 600)],
                "epochs": [
                    ["epoch": 4, "entries": [Self.wireEntry(id: "r1", fields: ["a"])]]
                ],
                "sealTimes": [
                    ["epoch": 3, "sealedAt": 1_000], ["epoch": 4, "sealedAt": 2_000],
                ],
                "noted": [3, 4], "currentEpoch": 5, "now": 3_000,
            ],
            [
                "ops": [Self.wireOp(seq: 1, fields: ["a"], ts: 600)],
                "epochs": [
                    ["epoch": 4, "entries": [Self.wireEntry(id: "r1", fields: ["a"])]]
                ],
                "sealTimes": [
                    ["epoch": 3, "sealedAt": 1_000], ["epoch": 4, "sealedAt": 2_000],
                ],
                "noted": [3, 4], "currentEpoch": 5, "now": 3_000,
                "clockOffsetKnown": false,
            ],
        ]

        let answer = try Format2Harness.run([
            "command": "resolve-offline-replay", "cases": cases,
        ])
        let plans = try XCTUnwrap(answer["plans"] as? [[String: Any]])
        XCTAssertEqual(plans.count, cases.count)

        for (index, each) in cases.enumerated() {
            let ledger = OfflineConflictLedger()
            ledger.noteSealTimes(
                (each["sealTimes"] as? [[String: Any]] ?? []).map {
                    (epoch: $0["epoch"] as? Int ?? 0, sealedAt: $0["sealedAt"] as? Int)
                }
            )
            for epoch in each["noted"] as? [Int] ?? [] { ledger.noteEpoch(epoch) }
            for group in each["epochs"] as? [[String: Any]] ?? [] {
                let epoch = group["epoch"] as? Int ?? 0
                for raw in group["entries"] as? [[String: Any]] ?? [] {
                    ledger.noteEntry(
                        epoch: epoch, model: "Note", entry: Self.entry(from: raw)
                    )
                }
            }
            let mine = Format2OfflineReplay.resolveOfflineReplay(
                ops: (each["ops"] as? [[String: Any]] ?? []).map(Self.pendingOp(from:)),
                ledger: ledger,
                currentEpoch: each["currentEpoch"] as? Int ?? 0,
                now: each["now"] as? Int ?? 0,
                clockOffsetKnown: each["clockOffsetKnown"] as? Bool ?? true
            )
            let theirs = plans[index]

            XCTAssertEqual(
                mine.ops.map(\.seq),
                (theirs["ops"] as? [[String: Any]] ?? []).compactMap { $0["seq"] as? Int },
                "case \(index): the surviving ops"
            )
            XCTAssertEqual(
                mine.ops.map { $0.fields.sorted() },
                (theirs["ops"] as? [[String: Any]] ?? []).map {
                    ($0["fields"] as? [String] ?? []).sorted()
                },
                "case \(index): the surviving FIELDS"
            )
            XCTAssertEqual(
                mine.narrowed.map(\.seq),
                (theirs["narrowed"] as? [[String: Any]] ?? []).compactMap {
                    $0["seq"] as? Int
                },
                "case \(index): what the durable row has to be rewritten to"
            )
            XCTAssertEqual(
                mine.rebuildRequired, theirs["rebuildRequired"] as? Bool,
                "case \(index): rebuildRequired"
            )
            XCTAssertEqual(
                mine.suppressedDeletes.map(\.recordId),
                (theirs["suppressedDeletes"] as? [[String: Any]] ?? []).compactMap {
                    $0["recordId"] as? String
                },
                "case \(index): suppressed deletes"
            )
            let theirNotices = theirs["notices"] as? [[String: Any]] ?? []
            XCTAssertEqual(
                mine.notices.count, theirNotices.count, "case \(index): notice count"
            )
            for (position, notice) in mine.notices.enumerated()
            where position < theirNotices.count {
                let their = theirNotices[position]
                XCTAssertEqual(
                    notice.outcome.rawValue, their["outcome"] as? String,
                    "case \(index) notice \(position): outcome"
                )
                XCTAssertEqual(
                    notice.reason.rawValue, their["reason"] as? String,
                    "case \(index) notice \(position): reason"
                )
                XCTAssertEqual(
                    notice.field, their["field"] as? String,
                    "case \(index) notice \(position): field"
                )
                XCTAssertEqual(
                    notice.epoch, their["epoch"] as? Int,
                    "case \(index) notice \(position): epoch"
                )
            }
        }
    }

    // MARK: - Wire helpers for the parity case

    private static func wireOp(
        seq: Int,
        kind: String = "patch",
        fields: [String],
        baseEpoch: Int = 3,
        ts: Int
    ) -> [String: Any] {
        [
            "seq": seq, "model": "Note", "recordId": "r1", "op": kind,
            "fields": fields, "baseEpoch": baseEpoch, "ts": ts,
            "mutation": [
                "id": "r1", "kind": kind,
                "fields": Dictionary(
                    uniqueKeysWithValues: fields.map { ($0, "mine") }
                ),
                "stringSetDeltas": [String: [String: Bool]](),
            ],
        ]
    }

    private static func wireEntry(
        id: String,
        fields: [String] = [],
        deleted: Bool = false,
        replace: Bool = false
    ) -> [String: Any] {
        [
            "id": id,
            "fields": Dictionary(uniqueKeysWithValues: fields.map { ($0, "theirs") }),
            "stringSets": [String: [String: Bool]](),
            "deleted": deleted, "replace": replace,
        ]
    }

    private static func entry(from raw: [String: Any]) -> OverlayRecordEntry {
        OverlayRecordEntry(
            id: raw["id"] as? String ?? "",
            fields: Dictionary(
                uniqueKeysWithValues: (raw["fields"] as? [String: Any] ?? [:]).map {
                    ($0.key, JSONValue.string($0.value as? String ?? ""))
                }
            ),
            stringSets: [:],
            replace: raw["replace"] as? Bool ?? false,
            deleted: raw["deleted"] as? Bool ?? false
        )
    }

    private static func pendingOp(from raw: [String: Any]) -> PendingOp {
        let fields = raw["fields"] as? [String] ?? []
        let kind = PendingOp.Kind(rawValue: raw["op"] as? String ?? "patch") ?? .patch
        return PendingOp(
            seq: raw["seq"] as? Int ?? 0,
            model: raw["model"] as? String ?? "Note",
            recordId: raw["recordId"] as? String ?? "r1",
            op: kind,
            fields: fields,
            baseEpoch: raw["baseEpoch"] as? Int ?? 3,
            ts: raw["ts"] as? Int ?? 0,
            mutation: OverlayMutation(
                id: raw["recordId"] as? String ?? "r1",
                kind: OverlayMutation.Kind(rawValue: kind.rawValue) ?? .patch,
                fields: Dictionary(
                    uniqueKeysWithValues: fields.map { ($0, JSONValue.string("mine")) }
                )
            ),
            priorOverlay: nil
        )
    }
}
