import XCTest
@testable import JsBaoClient
import YSwift

/// Following a seal onto a fresh overlay — the carry (#3437, behavior 8).
///
/// When the room seals epoch E it replaces its overlay with an empty one, so a
/// client's further DELTAS against the sealed overlay cannot be integrated
/// there. The obvious answer — resync the whole document — is the wrong one on
/// a large document: a state-complete sync of the sealed overlay would seed
/// E+1 with everything E held, the new epoch would re-cross the rotation
/// threshold at once, and the overlay would never actually be bounded.
///
/// What a client owes the new epoch is narrow: the writes the server has not
/// acknowledged. They are carried as OVERLAY entries taken from the sealed
/// document rather than rebuilt from the merged view, because the overlay is
/// the only place their exact shape survives — an explicit `null` unset, a
/// stringset member tombstone, and the difference between a patch and a
/// `_replace` create all vanish once a row has been materialized.
///
/// The record's LIFECYCLE is read off the overlay, never re-derived from the
/// local ops: the overlay is the CONVERGED state of that record in the epoch
/// being left, so its markers are the answer both ends already agree on.
/// Re-deriving it would carry a local patch across a peer's delete —
/// resurrecting, in the next epoch, a row the server has already dropped.
final class Format2EpochHandoffHermeticTests: XCTestCase {

    // MARK: - The overlay reader

    func testAnOverlayEntryIsReadWholeOutOfTheEpochBeingLeft() {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(
            [
                ("r1/title", .string("kept")),
                ("r1/note", .null),
                ("r1/tags/red", .bool(true)),
                ("r1/tags/blue", .bool(false)),
                ("r1/_replace", .bool(true)),
                ("r1/_deleted", .bool(false)),
                ("other/title", .string("not this record")),
            ],
            model: "Note"
        )

        let entry = overlay.recordEntry(model: "Note", recordId: "r1")
        XCTAssertEqual(entry.id, "r1")
        XCTAssertEqual(entry.fields["title"], .string("kept"))
        XCTAssertEqual(
            entry.fields["note"], .null,
            "an explicit unset is a null the overlay holds, not an absent key"
        )
        XCTAssertEqual(entry.stringSets["tags"], ["red": true, "blue": false])
        XCTAssertTrue(entry.replace)
        XCTAssertFalse(entry.deleted)

        let absent = overlay.recordEntry(model: "Note", recordId: "nobody")
        XCTAssertEqual(absent.id, "nobody")
        XCTAssertTrue(absent.fields.isEmpty)
        XCTAssertFalse(absent.replace)
        XCTAssertFalse(absent.deleted)
    }

    // MARK: - Behavior 8 — what travels

    func testOnlyTheFieldsTheOwedOpsTouchedTravel() {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(
            [
                ("r1/title", .string("mine")),
                ("r1/body", .string("a peer's")),
            ],
            model: "Note"
        )

        let carried = Format2EpochHandoff.carryUnackedOverlay(
            ops: [Self.op(seq: 1, recordId: "r1", fields: ["title"])],
            read: { model, recordId in
                overlay.recordEntry(model: model, recordId: recordId)
            }
        )

        XCTAssertEqual(carried.count, 1)
        XCTAssertEqual(carried[0].model, "Note")
        XCTAssertEqual(
            carried[0].entry.fields, ["title": .string("mine")],
            "the peer's concurrent write to another field must not be replayed"
        )
    }

    func testATombstoneTravelsAloneAndAReplaceTravelsWhole() {
        let deletedOverlay = OverlayDocument()
        deletedOverlay.applyRawEntries(
            [("r1/title", .string("moot")), ("r1/_deleted", .bool(true))],
            model: "Note"
        )
        let deleted = Format2EpochHandoff.carryUnackedOverlay(
            ops: [Self.op(seq: 1, recordId: "r1", fields: ["title"])],
            read: { deletedOverlay.recordEntry(model: $0, recordId: $1) }
        )
        XCTAssertTrue(deleted[0].entry.deleted)
        XCTAssertTrue(
            deleted[0].entry.fields.isEmpty,
            "whatever was written before the tombstone is moot and must not travel beside it"
        )

        let replaceOverlay = OverlayDocument()
        replaceOverlay.applyRawEntries(
            [
                ("r1/title", .string("mine")),
                ("r1/body", .string("a peer's")),
                ("r1/_replace", .bool(true)),
            ],
            model: "Note"
        )
        let replaced = Format2EpochHandoff.carryUnackedOverlay(
            ops: [Self.op(seq: 1, recordId: "r1", op: .create, fields: ["title"])],
            read: { replaceOverlay.recordEntry(model: $0, recordId: $1) }
        )
        XCTAssertTrue(replaced[0].entry.replace)
        XCTAssertEqual(
            replaced[0].entry.fields,
            ["title": .string("mine"), "body": .string("a peer's")],
            "`_replace` is only meaningful with the fields it replaces the base by, "
            + "including a peer's — which the re-create would otherwise discard"
        )
        XCTAssertFalse(replaced[0].entry.deleted)
    }

    func testASuppressedDeleteDoesNotCarryItsTombstone() {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(
            [("r1/title", .string("mine")), ("r1/_deleted", .bool(true))],
            model: "Note"
        )
        let carried = Format2EpochHandoff.carryUnackedOverlay(
            ops: [Self.op(seq: 1, recordId: "r1", fields: ["title"])],
            read: { overlay.recordEntry(model: $0, recordId: $1) },
            suppressDeletes: [(model: "Note", recordId: "r1")]
        )
        XCTAssertFalse(
            carried[0].entry.deleted,
            "this client's own delete lost to a write made online after it"
        )
        XCTAssertEqual(carried[0].entry.fields, ["title": .string("mine")])
    }

    func testTheCarriedEntriesKeepTheOpsLocalOrder() {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(
            [("a/title", .string("a")), ("b/title", .string("b"))], model: "Note"
        )
        let carried = Format2EpochHandoff.carryUnackedOverlay(
            ops: [
                Self.op(seq: 5, recordId: "b", fields: ["title"]),
                Self.op(seq: 2, recordId: "a", fields: ["title"]),
                Self.op(seq: 9, recordId: "b", fields: ["title"]),
            ],
            read: { overlay.recordEntry(model: $0, recordId: $1) }
        )
        XCTAssertEqual(
            carried.map(\.entry.id), ["a", "b"],
            "one entry per record, ordered by the first op that touched it"
        )
    }

    // MARK: - Behavior 8 — writing them onto the fresh epoch

    func testWriteCarriedOverlayWritesMarkersNullsAndTombstonesVerbatim() {
        let fresh = OverlayDocument()
        Format2EpochHandoff.writeCarriedOverlay(
            into: fresh,
            model: "Note",
            entry: OverlayRecordEntry(
                id: "r1",
                fields: ["title": .string("t"), "note": .null],
                stringSets: ["tags": ["red": true, "blue": false]],
                replace: true
            )
        )

        XCTAssertEqual(fresh.value(model: "Note", key: "r1/title"), .string("t"))
        XCTAssertEqual(
            fresh.value(model: "Note", key: "r1/note"), .null,
            "an explicit null travels as a null, not as an absent key"
        )
        XCTAssertEqual(fresh.value(model: "Note", key: "r1/tags/red"), .bool(true))
        XCTAssertEqual(
            fresh.value(model: "Note", key: "r1/tags/blue"), .bool(false),
            "a member tombstone travels as a tombstone"
        )
        XCTAssertEqual(fresh.value(model: "Note", key: "r1/_replace"), .bool(true))
        XCTAssertEqual(
            fresh.value(model: "Note", key: "r1/_deleted"), .bool(false),
            "`_replace` clears the tombstone, so the new epoch does not inherit "
            + "it under key-level LWW"
        )

        let tomb = OverlayDocument()
        Format2EpochHandoff.writeCarriedOverlay(
            into: tomb, model: "Note",
            entry: OverlayRecordEntry(
                id: "r2", fields: ["title": .string("moot")], deleted: true
            )
        )
        XCTAssertEqual(tomb.value(model: "Note", key: "r2/_deleted"), .bool(true))
        XCTAssertNil(
            tomb.value(model: "Note", key: "r2/title"),
            "a tombstone writes one key"
        )
    }

    // MARK: - Behavior 8 — taking back what a later write owns

    func testSuppressSupersededKeysLeavesALaterWritesKeysAlone() {
        let carried = [
            CarriedOverlay(
                model: "Note",
                entry: OverlayRecordEntry(
                    id: "r1",
                    fields: ["title": .string("captured"), "body": .string("captured")]
                )
            ),
        ]
        let kept = Format2EpochHandoff.suppressSupersededKeys(
            carried, later: [Self.op(seq: 9, recordId: "r1", fields: ["title"])]
        )
        XCTAssertEqual(
            kept[0].entry.fields, ["body": .string("captured")],
            "writing the captured title back over a newer one of this user's own "
            + "making would revert an edit the app already reported as saved"
        )
    }

    func testAnEntryALaterWriteOwnsEntirelyDoesNotTravel() {
        let carried = [
            CarriedOverlay(
                model: "Note",
                entry: OverlayRecordEntry(id: "r1", fields: ["title": .string("captured")])
            ),
        ]
        XCTAssertTrue(
            Format2EpochHandoff.suppressSupersededKeys(
                carried, later: [Self.op(seq: 9, recordId: "r1", fields: ["title"])]
            ).isEmpty
        )
    }

    func testALaterNonDeleteRevivesTheRecordAndDropsTheTombstone() {
        let carried = [
            CarriedOverlay(
                model: "Note",
                entry: OverlayRecordEntry(id: "r1", deleted: true)
            ),
        ]
        XCTAssertTrue(
            Format2EpochHandoff.suppressSupersededKeys(
                carried, later: [Self.op(seq: 9, recordId: "r1", fields: ["title"])]
            ).isEmpty,
            "a later write that is not itself a delete means the record lives now, "
            + "so the delete no longer describes anything"
        )
        XCTAssertEqual(
            Format2EpochHandoff.suppressSupersededKeys(
                carried,
                later: [Self.op(seq: 9, recordId: "r1", op: .delete, fields: [])]
            ).count,
            1,
            "a later DELETE does not revive it"
        )
    }

    func testAReplaceEntryTravelsEvenWithEveryFieldTakenBack() {
        let carried = [
            CarriedOverlay(
                model: "Note",
                entry: OverlayRecordEntry(
                    id: "r1", fields: ["title": .string("captured")], replace: true
                )
            ),
        ]
        let kept = Format2EpochHandoff.suppressSupersededKeys(
            carried, later: [Self.op(seq: 9, recordId: "r1", fields: ["title"])]
        )
        XCTAssertEqual(
            kept.count, 1,
            "`_replace` still has to reach the new epoch: it is what says the base "
            + "row was discarded"
        )
        XCTAssertTrue(kept[0].entry.fields.isEmpty)
    }

    // MARK: - Behavior 8 — parity

    func testTheCarryAgreesWithJsBao() throws {
        let cases: [[String: Any]] = [
            // 1. Only the touched field travels.
            [
                "overlay": ["Note": [["r1/title", "mine"], ["r1/body", "peer"]]],
                "ops": [Self.rawOp(seq: 1, recordId: "r1", fields: ["title"])],
            ],
            // 2. A tombstone travels alone.
            [
                "overlay": ["Note": [["r1/title", "moot"], ["r1/_deleted", true]]],
                "ops": [Self.rawOp(seq: 1, recordId: "r1", fields: ["title"])],
            ],
            // 3. A `_replace` travels whole, a peer's fields included.
            [
                "overlay": [
                    "Note": [
                        ["r1/title", "mine"], ["r1/body", "peer"],
                        ["r1/_replace", true],
                    ],
                ],
                "ops": [
                    Self.rawOp(seq: 1, recordId: "r1", op: "create", fields: ["title"]),
                ],
            ],
            // 4. An explicit null unset and a member tombstone.
            [
                "overlay": [
                    "Note": [
                        ["r1/note", NSNull()],
                        ["r1/tags/red", true],
                        ["r1/tags/blue", false],
                    ],
                ],
                "ops": [
                    Self.rawOp(seq: 1, recordId: "r1", fields: ["note", "tags"]),
                ],
            ],
            // 5. A suppressed delete.
            [
                "overlay": ["Note": [["r1/title", "mine"], ["r1/_deleted", true]]],
                "ops": [Self.rawOp(seq: 1, recordId: "r1", fields: ["title"])],
                "suppressDeletes": [["model": "Note", "recordId": "r1"]],
            ],
            // 6. Several records, ordered by the first op that touched each.
            [
                "overlay": ["Note": [["a/title", "a"], ["b/title", "b"]]],
                "ops": [
                    Self.rawOp(seq: 5, recordId: "b", fields: ["title"]),
                    Self.rawOp(seq: 2, recordId: "a", fields: ["title"]),
                ],
            ],
            // 7. A later write takes one field back.
            [
                "overlay": ["Note": [["r1/title", "mine"], ["r1/body", "mine"]]],
                "ops": [Self.rawOp(seq: 1, recordId: "r1", fields: ["title", "body"])],
                "later": [Self.rawOp(seq: 9, recordId: "r1", fields: ["title"])],
            ],
            // 8. A later write takes them all: nothing travels.
            [
                "overlay": ["Note": [["r1/title", "mine"]]],
                "ops": [Self.rawOp(seq: 1, recordId: "r1", fields: ["title"])],
                "later": [Self.rawOp(seq: 9, recordId: "r1", fields: ["title"])],
            ],
            // 9. A later non-delete revives the record.
            [
                "overlay": ["Note": [["r1/_deleted", true]]],
                "ops": [
                    Self.rawOp(seq: 1, recordId: "r1", op: "delete", fields: []),
                ],
                "later": [Self.rawOp(seq: 9, recordId: "r1", fields: ["title"])],
            ],
            // 10. A later delete does not revive it.
            [
                "overlay": ["Note": [["r1/_deleted", true]]],
                "ops": [
                    Self.rawOp(seq: 1, recordId: "r1", op: "delete", fields: []),
                ],
                "later": [
                    Self.rawOp(seq: 9, recordId: "r1", op: "delete", fields: []),
                ],
            ],
        ]

        let response = try Format2Harness.run(["command": "carry", "cases": cases])
        let theirs = try XCTUnwrap(response["results"] as? [[String: Any]])
        XCTAssertEqual(theirs.count, cases.count)

        for (index, each) in cases.enumerated() {
            let label = "case \(index + 1)"
            let overlay = OverlayDocument()
            for (model, entries) in (each["overlay"] as? [String: [[Any]]]) ?? [:] {
                var raw: [(String, JSONValue)] = []
                for entry in entries {
                    guard let key = entry.first as? String else { continue }
                    raw.append((key, Self.jsonValue(entry.count > 1 ? entry[1] : nil)))
                }
                overlay.applyRawEntries(raw, model: model)
            }

            var carried = Format2EpochHandoff.carryUnackedOverlay(
                ops: ((each["ops"] as? [[String: Any]]) ?? []).map(Self.pendingOp),
                read: { overlay.recordEntry(model: $0, recordId: $1) },
                suppressDeletes: ((each["suppressDeletes"] as? [[String: String]]) ?? [])
                    .compactMap { entry in
                        guard let model = entry["model"], let id = entry["recordId"]
                        else { return nil }
                        return (model: model, recordId: id)
                    }
            )
            if let later = each["later"] as? [[String: Any]] {
                carried = Format2EpochHandoff.suppressSupersededKeys(
                    carried, later: later.map(Self.pendingOp)
                )
            }

            // The entries themselves.
            let expectedCarried = try XCTUnwrap(theirs[index]["carried"] as? [[String: Any]], label)
            XCTAssertEqual(carried.count, expectedCarried.count, label)
            for (step, mine) in carried.enumerated() {
                let entry = try XCTUnwrap(
                    expectedCarried[step]["entry"] as? [String: Any], label
                )
                XCTAssertEqual(mine.model, expectedCarried[step]["model"] as? String, label)
                XCTAssertEqual(mine.entry.id, entry["id"] as? String, label)
                XCTAssertEqual(
                    mine.entry.fields,
                    ((entry["fields"] as? [String: Any]) ?? [:]).mapValues(Self.jsonValue),
                    "\(label) fields"
                )
                XCTAssertEqual(
                    mine.entry.stringSets,
                    ((entry["stringSets"] as? [String: [String: Bool]]) ?? [:]),
                    "\(label) stringSets"
                )
                XCTAssertEqual(mine.entry.replace, entry["replace"] as? Bool, label)
                XCTAssertEqual(mine.entry.deleted, entry["deleted"] as? Bool, label)
            }

            // And the KEYS they write onto the fresh epoch, which is the half a
            // port can get right in the entry and wrong on the wire.
            let fresh = OverlayDocument()
            for entry in carried {
                Format2EpochHandoff.writeCarriedOverlay(
                    into: fresh, model: entry.model, entry: entry.entry
                )
            }
            let written = (theirs[index]["written"] as? [String: [[Any]]]) ?? [:]
            for (model, expected) in written {
                let mine = fresh.entries(model: model)
                    .sorted { $0.0 < $1.0 }
                XCTAssertEqual(mine.count, expected.count, "\(label) written \(model)")
                for (step, pair) in expected.enumerated() {
                    guard step < mine.count else { break }
                    XCTAssertEqual(mine[step].0, pair.first as? String, "\(label) key")
                    XCTAssertEqual(
                        mine[step].1,
                        Self.jsonValue(pair.count > 1 ? pair[1] : nil),
                        "\(label) value at \(mine[step].0)"
                    )
                }
            }
        }
    }

    // MARK: - Fixtures

    private static func op(
        seq: Int,
        model: String = "Note",
        recordId: String,
        op: PendingOp.Kind = .patch,
        fields: [String]
    ) -> PendingOp {
        PendingOp(
            seq: seq, model: model, recordId: recordId, op: op, fields: fields,
            baseEpoch: 1, ts: 0, mutation: nil, priorOverlay: nil
        )
    }

    private static func rawOp(
        seq: Int,
        model: String = "Note",
        recordId: String,
        op: String = "patch",
        fields: [String]
    ) -> [String: Any] {
        [
            "seq": seq, "model": model, "recordId": recordId, "op": op,
            "fields": fields,
        ]
    }

    private static func pendingOp(_ raw: [String: Any]) -> PendingOp {
        PendingOp(
            seq: raw["seq"] as? Int ?? 0,
            model: raw["model"] as? String ?? "Note",
            recordId: raw["recordId"] as? String ?? "",
            op: (raw["op"] as? String).flatMap(PendingOp.Kind.init(rawValue:)) ?? .patch,
            fields: raw["fields"] as? [String] ?? [],
            baseEpoch: 1, ts: 0, mutation: nil, priorOverlay: nil
        )
    }

    private static func jsonValue(_ raw: Any?) -> JSONValue {
        switch raw {
        case let text as String: return .string(text)
        case let flag as Bool: return .bool(flag)
        case let number as Int: return .number(Double(number))
        case let number as Double: return .number(number)
        case let list as [Any]: return .array(list.map(jsonValue))
        case let object as [String: Any]: return .object(object.mapValues(jsonValue))
        default: return .null
        }
    }
}
