import XCTest
@testable import JsBaoClient

/// How a large document with nothing local to start from should be opened
/// (#3436, behavior 25).
///
/// The planner is a decision, not an action: it says what the document needs,
/// and which of its answers THIS client can honour is deliberately narrow
/// (`join`, and a cold client's `snapshot` whose base covers the room's
/// epoch). Every case is compared with js-bao's own `planColdStart` for the
/// same input, because a Swift client that read the same handshake and reached
/// a different conclusion would either stop a document that is fine or open
/// one that is missing most of itself.
final class Format2ColdStartHermeticTests: XCTestCase {

    private func sealed(
        _ epoch: Int, granted: Bool = true, discontinuity: Bool = false
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "epoch": epoch,
            "sealedAt": 1_700_000_000_000 + epoch,
        ]
        if discontinuity { entry["baseDiscontinuity"] = true }
        if granted {
            entry["download"] = ["path": "/artifact/tok-\(epoch)", "expiresAt": 0]
        }
        return entry
    }

    /// Every case, named, in the shape the harness takes.
    private func cases() -> [(name: String, input: [String: Any])] {
        [
            (
                "a cold client on a document that never rotated",
                ["held": 0, "reported": 1, "sealed": []]
            ),
            (
                "a cold client on a room reporting no epoch at all",
                ["held": 0, "reported": 0, "sealed": []]
            ),
            (
                "a client already on the room's epoch",
                ["held": 5, "reported": 5, "sealed": [sealed(4)]]
            ),
            (
                "a client behind the room",
                ["held": 3, "reported": 5, "sealed": [sealed(3), sealed(4)]]
            ),
            (
                "a cold client whose base covers the room's epoch",
                [
                    "held": 0, "reported": 5,
                    "sealed": [sealed(3), sealed(4)], "snapshot": ["epoch": 5],
                ]
            ),
            (
                "a cold client whose base is one epoch behind, chain whole",
                [
                    "held": 0, "reported": 5,
                    "sealed": [sealed(3), sealed(4)], "snapshot": ["epoch": 4],
                ]
            ),
            (
                "a cold client whose base is behind and the chain has a hole",
                [
                    "held": 0, "reported": 5,
                    "sealed": [sealed(3)], "snapshot": ["epoch": 3],
                ]
            ),
            (
                "a cold client whose base is behind and a link lost its grant",
                [
                    "held": 0, "reported": 5,
                    "sealed": [sealed(3), sealed(4, granted: false)],
                    "snapshot": ["epoch": 3],
                ]
            ),
            (
                "no base at all, but the whole chain from epoch 1",
                [
                    "held": 0, "reported": 4,
                    "sealed": [sealed(1), sealed(2), sealed(3)],
                ]
            ),
            (
                "no base and a chain that does not start at 1",
                ["held": 0, "reported": 4, "sealed": [sealed(2), sealed(3)]]
            ),
            (
                "a bulk load between the base on offer and the room",
                [
                    "held": 0, "reported": 6,
                    "sealed": [
                        sealed(3), sealed(4, discontinuity: true), sealed(5),
                    ],
                    "snapshot": ["epoch": 3],
                ]
            ),
            (
                "a bulk load whose own epoch lost its grant",
                [
                    "held": 0, "reported": 6,
                    "sealed": [
                        sealed(3), sealed(4, granted: false, discontinuity: true),
                        sealed(5),
                    ],
                    "snapshot": ["epoch": 3],
                ]
            ),
            (
                "a base newer than the room reports",
                [
                    "held": 0, "reported": 3,
                    "sealed": [sealed(1), sealed(2)], "snapshot": ["epoch": 9],
                ]
            ),
        ]
    }

    // MARK: - Behavior 25 — parity

    func testEveryCasePlansTheWayTheTypeScriptPlannerPlansIt() throws {
        let cases = self.cases()
        let response = try Format2Harness.run([
            "command": "plan-cold-start",
            "cases": cases.map(\.input),
        ])
        let expected = try XCTUnwrap(response["plans"] as? [[String: Any]])
        XCTAssertEqual(expected.count, cases.count)

        for (index, each) in cases.enumerated() {
            let plan = Format2ColdStart.plan(
                held: each.input["held"] as? Int ?? 0,
                reported: each.input["reported"] as? Int ?? 0,
                sealed: Format2Coordinator.decodeSealedChain(each.input["sealed"]),
                snapshotEpoch: (each.input["snapshot"] as? [String: Any])?["epoch"] as? Int
            )
            XCTAssertEqual(
                plan.kind, expected[index]["kind"] as? String, "\(each.name): kind"
            )
            switch plan {
            case .snapshot(let base), .overlays(let base):
                XCTAssertEqual(base, expected[index]["base"] as? Int, "\(each.name): base")
            case .awaitBase(let discontinuities):
                XCTAssertEqual(
                    discontinuities, expected[index]["discontinuities"] as? [Int],
                    "\(each.name): discontinuities"
                )
            case .unavailable(let reason):
                XCTAssertEqual(
                    reason, expected[index]["reason"] as? String, "\(each.name): reason"
                )
            case .join, .catchUp:
                break
            }
        }
    }

    /// The case set has to reach every plan the JS planner can return, or a
    /// Swift planner that answered `join` to everything would pass the parity
    /// assertion for the cases it happened to cover.
    func testTheCaseSetReachesEveryPlanKind() throws {
        let kinds = Set(cases().map { each in
            Format2ColdStart.plan(
                held: each.input["held"] as? Int ?? 0,
                reported: each.input["reported"] as? Int ?? 0,
                sealed: Format2Coordinator.decodeSealedChain(each.input["sealed"]),
                snapshotEpoch: (each.input["snapshot"] as? [String: Any])?["epoch"] as? Int
            ).kind
        })
        XCTAssertEqual(
            kinds,
            ["join", "catch-up", "snapshot", "overlays", "await-base", "unavailable"]
        )
    }

    // MARK: - Reading the chain off the frame

    func testSealedEpochsAreReadOffTheFrameAndMalformedEntriesAreSkipped() {
        let entries = Format2Coordinator.decodeSealedChain([
            ["epoch": 3, "sealedAt": 10, "download": ["path": "/a", "expiresAt": 0]],
            ["epoch": 4, "baseDiscontinuity": true],
            ["sealedAt": 12],
            "not an entry",
        ] as [Any])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].epoch, 3)
        XCTAssertEqual(entries[0].downloadPath, "/a")
        XCTAssertFalse(entries[0].baseDiscontinuity)
        XCTAssertEqual(entries[1].epoch, 4)
        XCTAssertNil(entries[1].downloadPath)
        XCTAssertTrue(entries[1].baseDiscontinuity)
    }

    func testAnUnsortedChainIsPlannedTheSameAsASortedOne() {
        let ordered = Format2ColdStart.plan(
            held: 0, reported: 4,
            sealed: [
                SealedEpochChainEntry(epoch: 1, downloadPath: "/a"),
                SealedEpochChainEntry(epoch: 2, downloadPath: "/b"),
                SealedEpochChainEntry(epoch: 3, downloadPath: "/c"),
            ],
            snapshotEpoch: nil
        )
        let shuffled = Format2ColdStart.plan(
            held: 0, reported: 4,
            sealed: [
                SealedEpochChainEntry(epoch: 3, downloadPath: "/c"),
                SealedEpochChainEntry(epoch: 1, downloadPath: "/a"),
                SealedEpochChainEntry(epoch: 2, downloadPath: "/b"),
            ],
            snapshotEpoch: nil
        )
        XCTAssertEqual(ordered, .overlays(base: 1))
        XCTAssertEqual(shuffled, ordered)
    }
}
