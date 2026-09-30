import XCTest
@testable import JsBaoClient
import YSwift

/// Adopting and restoring a previous instance's unacknowledged writes
/// (#3437, behaviors 4, 5 and 6).
///
/// Swift mints its client id per `JsBaoClient` instance and never persists it,
/// and `pendingOps()` filters by that id. So after a relaunch every
/// unacknowledged write of the previous instance is INVISIBLE to the new one:
/// never carried, never replayed, never acknowledged (finding 3437-R02).
/// Adoption is therefore a prerequisite of criterion 12's replay half, not a
/// nicety — and the `from_client_id`/`from_seq` columns have been in the DDL
/// since #3431 waiting for it.
///
/// The classification is #3431's rule, and the Swift answers are held to
/// js-bao's over identical inputs: a verdict that drifts drops a write the app
/// was told was saved, and the next catch-up then claims its sequence and has
/// it pruned — a write existing on no machine at all.
final class Format2AdoptionHermeticTests: XCTestCase {

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
            "body": FieldDescriptor(type: .string),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private func newDirectory() -> String {
        let directory = NSTemporaryDirectory() + "/f2-adopt-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory
    }

    private func makeProvider(at path: String) async throws -> SQLiteStorageProvider {
        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeStore(
        host: any Format2SqlHost, documentId: String = "d", clientId: String
    ) throws -> Format2RecordStore {
        let store = Format2RecordStore(
            host: host, documentId: documentId, clientId: clientId
        )
        try store.initialize()
        return store
    }

    /// Write a pending op as `clientId` would have — the previous instance's
    /// row, left behind by a session that is gone.
    private func seedForeignOp(
        _ host: any Format2SqlHost,
        documentId: String = "d",
        clientId: String,
        seq: Int,
        model: String = "Note",
        recordId: String,
        op: PendingOp.Kind = .patch,
        fields: [String],
        mutation: OverlayMutation,
        priorOverlay: [String: JSONValue]? = nil,
        baseEpoch: Int = 1,
        ts: Int = 0
    ) throws {
        let store = try makeStore(host: host, documentId: documentId, clientId: clientId)
        try store.commitLocalWrite(
            model: model,
            mutation: mutation,
            pending: PendingOpInput(
                model: model, recordId: recordId, op: op, fields: fields,
                baseEpoch: baseEpoch, ts: ts, seq: seq, priorOverlay: priorOverlay
            )
        )
    }

    // MARK: - Behavior 4 — adoption

    func testAdoptionReKeysEveryForeignRowWithFreshContiguousSequences()
        async throws
    {
        let provider = try await makeProvider(at: newDirectory() + "/store.sqlite")

        // Two previous instances, interleaved sequences. Adoption orders by
        // `(client_id, seq)`, so the answer is deterministic.
        try seedForeignOp(
            provider, clientId: "gone-b", seq: 2, recordId: "r3",
            fields: ["title"],
            mutation: OverlayMutation(id: "r3", kind: .patch, fields: ["title": .string("b2")])
        )
        try seedForeignOp(
            provider, clientId: "gone-a", seq: 5, recordId: "r1",
            fields: ["title"],
            mutation: OverlayMutation(id: "r1", kind: .patch, fields: ["title": .string("a5")])
        )
        try seedForeignOp(
            provider, clientId: "gone-a", seq: 7, recordId: "r2",
            fields: ["body"],
            mutation: OverlayMutation(id: "r2", kind: .patch, fields: ["body": .string("a7")])
        )

        // The old client's own acked mark: adoption leaves it alone.
        let gone = try makeStore(host: provider, clientId: "gone-a")
        try gone.prunePendingOps(maxContiguousSeq: 4)
        XCTAssertEqual(try gone.ackedSeq(), 4)

        let mine = try makeStore(host: provider, clientId: "me")
        XCTAssertEqual(try mine.pendingOps().count, 0, "precondition: invisible before adoption")

        let adopted = try mine.adoptOrphanedPendingOps()

        XCTAssertEqual(adopted.map(\.seq), [1, 2, 3], "fresh, contiguous, above nextSeq()")
        XCTAssertEqual(
            adopted.map(\.fromClientId), ["gone-a", "gone-a", "gone-b"],
            "ascending by (client_id, seq)"
        )
        XCTAssertEqual(adopted.map(\.fromSeq), [5, 7, 2])
        XCTAssertEqual(adopted.map(\.recordId), ["r1", "r2", "r3"])

        // Now they are this client's, and they carry what they were written
        // with — the mutation is what makes a restore possible at all.
        let ours = try mine.pendingOps()
        XCTAssertEqual(ours.map(\.seq), [1, 2, 3])
        XCTAssertEqual(
            ours.compactMap { $0.mutation?.fields["title"] ?? $0.mutation?.fields["body"] },
            [.string("a5"), .string("a7"), .string("b2")]
        )

        // The old client's mark is untouched: it is a fact about a session
        // that is gone, not about this one.
        XCTAssertEqual(try gone.ackedSeq(), 4)
        XCTAssertEqual(try gone.pendingOps().count, 0, "its rows are ours now")

        // Idempotent: a second pass finds nothing foreign.
        XCTAssertEqual(try mine.adoptOrphanedPendingOps().count, 0)
        XCTAssertEqual(try mine.pendingOps().count, 3)
    }

    func testAdoptionStartsAboveThisClientsOwnSequences() async throws {
        let provider = try await makeProvider(at: newDirectory() + "/store.sqlite")
        let mine = try makeStore(host: provider, clientId: "me")
        try mine.commitLocalWrite(
            model: "Note",
            mutation: OverlayMutation(id: "own", kind: .create, fields: ["title": .string("m")]),
            pending: PendingOpInput(
                model: "Note", recordId: "own", op: .create, fields: ["title"],
                baseEpoch: 1, ts: 0
            )
        )
        try seedForeignOp(
            provider, clientId: "gone", seq: 1, recordId: "r1", fields: ["title"],
            mutation: OverlayMutation(id: "r1", kind: .patch, fields: ["title": .string("g")])
        )

        let adopted = try mine.adoptOrphanedPendingOps()
        XCTAssertEqual(adopted.map(\.seq), [2], "above this client's own highest")
        XCTAssertEqual(try mine.pendingOps().map(\.seq), [1, 2])
    }

    func testAClientWithNoForeignRowsAdoptsNothing() async throws {
        let provider = try await makeProvider(at: newDirectory() + "/store.sqlite")
        let mine = try makeStore(host: provider, clientId: "me")
        XCTAssertEqual(try mine.adoptOrphanedPendingOps().count, 0)
        XCTAssertEqual(try mine.pendingOps().count, 0)
    }

    // MARK: - Behavior 5 — the classification

    /// One chain per case, classified in sequence order with each verdict
    /// folded into the projection — so the parity covers 3431-R10's
    /// carry-forward as well as the per-op rule.
    func testTheClassificationAgreesWithJsBao() throws {
        let cases: [[String: Any]] = [
            // 1. Prior-overlay rule: the overlay still holds what the op
            //    recorded as prior, so the write never landed and is owed.
            [
                "overlay": ["Note": [["r1/title", "v1"]]],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["title"],
                    "mutation": ["id": "r1", "kind": "patch", "fields": ["title": "v2"]],
                    "priorOverlay": ["r1/title": "v1"],
                ]],
            ],
            // 2. Prior-overlay rule: the overlay holds the op's own value.
            [
                "overlay": ["Note": [["r1/title", "v2"]]],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["title"],
                    "mutation": ["id": "r1", "kind": "patch", "fields": ["title": "v2"]],
                    "priorOverlay": ["r1/title": "v1"],
                ]],
            ],
            // 3. Prior-overlay rule: a stranger's value sits on the key.
            [
                "overlay": ["Note": [["r1/title", "peer"]]],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["title"],
                    "mutation": ["id": "r1", "kind": "patch", "fields": ["title": "v2"]],
                    "priorOverlay": ["r1/title": "v1"],
                ]],
            ],
            // 4. Absent key is OWED, not lost: an overlay that was never
            //    persisted at all is the ordinary crash case.
            [
                "overlay": ["Note": []],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["title"],
                    "mutation": ["id": "r1", "kind": "patch", "fields": ["title": "v2"]],
                    "priorOverlay": ["r1/title": "v1"],
                ]],
            ],
            // 5. Partly superseded: one field owed, one a stranger's.
            [
                "overlay": ["Note": [["r1/title", "peer"], ["r1/body", "b1"]]],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["title", "body"],
                    "mutation": [
                        "id": "r1", "kind": "patch",
                        "fields": ["title": "v2", "body": "b2"],
                    ],
                    "priorOverlay": ["r1/title": "v1", "r1/body": "b1"],
                ]],
            ],
            // 6. A chain of two edits to one field (3431-R10): the second
            //    records the first's value as its prior, and weighing it
            //    against the RAW overlay would read its own predecessor as a
            //    stranger and drop the newest edit of all.
            [
                "overlay": ["Note": [["r1/title", "v1"]]],
                "ops": [
                    [
                        "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                        "fields": ["title"],
                        "mutation": ["id": "r1", "kind": "patch", "fields": ["title": "v2"]],
                        "priorOverlay": ["r1/title": "v1"],
                    ],
                    [
                        "seq": 2, "model": "Note", "recordId": "r1", "op": "patch",
                        "fields": ["title"],
                        "mutation": ["id": "r1", "kind": "patch", "fields": ["title": "v3"]],
                        "priorOverlay": ["r1/title": "v2"],
                    ],
                ],
            ],
            // 7. A delete whose tombstone key still reads what it read before.
            [
                "overlay": ["Note": [["r1/_deleted", false]]],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "delete",
                    "fields": [],
                    "mutation": ["id": "r1", "kind": "delete"],
                    "priorOverlay": ["r1/_deleted": false],
                ]],
            ],
            // 8. A delete already carried.
            [
                "overlay": ["Note": [["r1/_deleted", true]]],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "delete",
                    "fields": [],
                    "mutation": ["id": "r1", "kind": "delete"],
                    "priorOverlay": ["r1/_deleted": false],
                ]],
            ],
            // 9. Merged-row rule, for an op that recorded no prior values:
            //    the row still holds the op's value, so the op survived.
            [
                "overlay": ["Note": [["r1/title", "older"]]],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["title"],
                    "mutation": ["id": "r1", "kind": "patch", "fields": ["title": "v2"]],
                    "mergedRow": ["id": "r1", "title": "v2"],
                ]],
            ],
            // 10. Merged-row rule: a later write owns the key.
            [
                "overlay": ["Note": [["r1/title", "peer"]]],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["title"],
                    "mutation": ["id": "r1", "kind": "patch", "fields": ["title": "v2"]],
                    "mergedRow": ["id": "r1", "title": "peer"],
                ]],
            ],
            // 11. Merged-row rule: a patch whose record is gone lost whole.
            [
                "overlay": ["Note": []],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["title"],
                    "mutation": ["id": "r1", "kind": "patch", "fields": ["title": "v2"]],
                ]],
            ],
            // 12. Merged-row rule: a delete stands while the row is gone.
            [
                "overlay": ["Note": []],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "delete",
                    "fields": [],
                    "mutation": ["id": "r1", "kind": "delete"],
                ]],
            ],
            // 13. A stringset add the merged row still credits.
            [
                "overlay": ["Note": []],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["tags"],
                    "mutation": [
                        "id": "r1", "kind": "patch",
                        "stringSetDeltas": ["tags": ["red": true]],
                    ],
                    "mergedRow": ["id": "r1", "tags": ["red"]],
                ]],
            ],
            // 14. A stringset removal a later add undid.
            [
                "overlay": ["Note": []],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["tags"],
                    "mutation": [
                        "id": "r1", "kind": "patch",
                        "stringSetDeltas": ["tags": ["red": false]],
                    ],
                    "mergedRow": ["id": "r1", "tags": ["red"]],
                ]],
            ],
            // 15. A create with no fields — markers only, so key presence
            //     alone decides.
            [
                "overlay": ["Note": []],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "create",
                    "fields": [],
                    "mutation": ["id": "r1", "kind": "create"],
                    "mergedRow": ["id": "r1"],
                ]],
            ],
            // 16. An op with NO recorded mutation: nothing to weigh.
            [
                "overlay": ["Note": []],
                "ops": [[
                    "seq": 1, "model": "Note", "recordId": "r1", "op": "patch",
                    "fields": ["title"],
                ]],
            ],
        ]

        let response = try Format2Harness.run([
            "command": "classify-adopted", "cases": cases,
        ])
        let theirs = try XCTUnwrap(response["verdicts"] as? [[[String: Any]]])
        XCTAssertEqual(theirs.count, cases.count)

        for (index, each) in cases.enumerated() {
            let overlay = OverlayDocument()
            for (model, entries) in (each["overlay"] as? [String: [[Any]]]) ?? [:] {
                var raw: [(String, JSONValue)] = []
                for entry in entries {
                    guard let key = entry.first as? String else { continue }
                    raw.append((key, Self.jsonValue(entry.count > 1 ? entry[1] : nil)))
                }
                overlay.applyRawEntries(raw, model: model)
            }
            var projection = RestoreProjection()
            let ops = (each["ops"] as? [[String: Any]]) ?? []
            for (step, raw) in ops.enumerated() {
                let op = Self.pendingOp(raw)
                let verdict = Format2PendingRestore.classifyAdoptedOp(
                    overlay: overlay,
                    op: op,
                    mergedRow: Self.mergedRow(raw["mergedRow"]),
                    projection: projection
                )
                Format2PendingRestore.projectRestoredKeys(
                    overlay: overlay, op: op, verdict: verdict, projection: &projection
                )
                let label = "case \(index + 1) step \(step + 1)"
                let expected = theirs[index][step]
                XCTAssertEqual(
                    Self.describe(verdict), expected["kind"] as? String, label
                )
                if case .fragment(let mutation, let keep) = verdict {
                    let restore = try XCTUnwrap(expected["restore"] as? [String: Any], label)
                    XCTAssertEqual(
                        mutation.fields,
                        (restore["fields"] as? [String: Any])
                            .map { $0.mapValues(Self.jsonValue) } ?? [:],
                        label
                    )
                    XCTAssertEqual(
                        Set(keep), Set((expected["keep"] as? [String]) ?? []), label
                    )
                }
            }
        }
    }

    private static func describe(_ verdict: PendingRestoreVerdict) -> String {
        switch verdict {
        case .restore: return "restore"
        case .carried: return "carried"
        case .superseded: return "superseded"
        case .fragment: return "fragment"
        }
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

    private static func mergedRow(_ raw: Any?) -> [String: JSONValue]? {
        guard let object = raw as? [String: Any] else { return nil }
        return object.mapValues(jsonValue)
    }

    private static func pendingOp(_ raw: [String: Any]) -> PendingOp {
        var mutation: OverlayMutation?
        if let encoded = raw["mutation"] as? [String: Any],
           let id = encoded["id"] as? String,
           let kind = (encoded["kind"] as? String).flatMap(OverlayMutation.Kind.init(rawValue:))
        {
            mutation = OverlayMutation(
                id: id,
                kind: kind,
                fields: ((encoded["fields"] as? [String: Any]) ?? [:]).mapValues(jsonValue),
                stringSetDeltas: ((encoded["stringSetDeltas"] as? [String: [String: Bool]])
                    ?? [:])
            )
        }
        return PendingOp(
            seq: raw["seq"] as? Int ?? 0,
            model: raw["model"] as? String ?? "Note",
            recordId: raw["recordId"] as? String ?? "",
            op: (raw["op"] as? String).flatMap(PendingOp.Kind.init(rawValue:)) ?? .patch,
            fields: raw["fields"] as? [String] ?? [],
            baseEpoch: raw["baseEpoch"] as? Int ?? 1,
            ts: raw["ts"] as? Int ?? 0,
            mutation: mutation,
            priorOverlay: (raw["priorOverlay"] as? [String: Any])?.mapValues(jsonValue)
        )
    }

    // MARK: - Behavior 6 — the bind restores

    func testTheBindAdoptsClassifiesAndRestoresInSequenceOrder() async throws {
        let path = newDirectory() + "/store.sqlite"
        let provider = try await makeProvider(at: path)
        let documentId = "d"

        // A previous instance's two edits to one field, neither of whose Yjs
        // updates reached disk. The overlay holds v1.
        try seedForeignOp(
            provider, documentId: documentId, clientId: "gone", seq: 1, recordId: "r1",
            fields: ["title"],
            mutation: OverlayMutation(id: "r1", kind: .patch, fields: ["title": .string("v2")]),
            priorOverlay: ["r1/title": .string("v1")]
        )
        try seedForeignOp(
            provider, documentId: documentId, clientId: "gone", seq: 2, recordId: "r1",
            fields: ["title"],
            mutation: OverlayMutation(id: "r1", kind: .patch, fields: ["title": .string("v3")]),
            priorOverlay: ["r1/title": .string("v2")]
        )

        // The relaunched instance's overlay, as local persistence restored it.
        let doc = YDocument()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        binding.overlay.applyRawEntries([("r1/title", .string("v1"))], model: "Note")

        let outcome = try binding.adoptAndRestore()

        XCTAssertEqual(outcome.adopted, [1, 2], "both ops re-keyed to this client")
        XCTAssertEqual(
            outcome.restored, [1, 2],
            "both are still owed — the projection carries the first verdict "
            + "forward, so the second is weighed against v2 and not against v1"
        )
        XCTAssertEqual(
            binding.overlay.value(model: "Note", key: "r1/title"), .string("v3"),
            "the newest edit is what the overlay ends up holding"
        )
        // And the merged view agrees, because the restore refolds.
        XCTAssertEqual(
            try binding.store.read(model: "Note", recordId: "r1")?["title"],
            .string("v3")
        )
        XCTAssertEqual(try binding.store.pendingOps().map(\.seq), [1, 2])
    }

    func testCarriedAndSupersededOpsAreNotReapplied() async throws {
        let provider = try await makeProvider(at: newDirectory() + "/store.sqlite")

        // Carried: the overlay already holds this write.
        try seedForeignOp(
            provider, clientId: "gone", seq: 1, recordId: "r1", fields: ["title"],
            mutation: OverlayMutation(id: "r1", kind: .patch, fields: ["title": .string("v2")]),
            priorOverlay: ["r1/title": .string("v1")]
        )
        // Superseded: a stranger's value sits on the key.
        try seedForeignOp(
            provider, clientId: "gone", seq: 2, recordId: "r2", fields: ["title"],
            mutation: OverlayMutation(id: "r2", kind: .patch, fields: ["title": .string("mine")]),
            priorOverlay: ["r2/title": .string("old")]
        )

        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let binding = try coordinator.bind(documentId: "d", models: ["Note"])
        binding.overlay.applyRawEntries(
            [("r1/title", .string("v2")), ("r2/title", .string("peer"))], model: "Note"
        )

        let outcome = try binding.adoptAndRestore()
        XCTAssertEqual(outcome.adopted, [1, 2])
        XCTAssertEqual(outcome.restored, [], "neither is owed")
        XCTAssertEqual(
            binding.overlay.value(model: "Note", key: "r2/title"), .string("peer"),
            "the value that won stands"
        )
    }

    func testAnOpWithNoMutationIsLeftPendingRatherThanDropped() async throws {
        let provider = try await makeProvider(at: newDirectory() + "/store.sqlite")
        let store = try makeStore(host: provider, clientId: "gone")
        // A row from a build that recorded no mutation, written straight into
        // the log — `commitLocalWrite` always records one now.
        try provider.withConnection { connection in
            try connection.execute(
                """
                INSERT INTO _pending_ops
                  (doc_id, client_id, seq, model, record_id, op, fields, base_epoch, ts)
                VALUES ('d', 'gone', 1, 'Note', 'r1', 'patch', '["title"]', 1, 0)
                """,
                []
            )
        }
        _ = store

        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let binding = try coordinator.bind(documentId: "d", models: ["Note"])
        let outcome = try binding.adoptAndRestore()

        XCTAssertEqual(outcome.adopted, [1])
        XCTAssertEqual(outcome.restored, [])
        XCTAssertEqual(
            outcome.unreproducible, [1],
            "left pending rather than dropped: the ack path is what settles it"
        )
        XCTAssertEqual(try binding.store.pendingOps().map(\.seq), [1])
    }

    /// Finding 3437-SO-03: a restart between an epoch move and the completion
    /// of its deferred replay must not put the owed writes back on the
    /// overlay, where the flush would publish them with recency never asked.
    func testADeferredReplayNoteHoldsTheOwedWritesOffTheOverlay() async throws {
        let provider = try await makeProvider(at: newDirectory() + "/store.sqlite")
        try seedForeignOp(
            provider, clientId: "gone", seq: 1, recordId: "r1", fields: ["title"],
            mutation: OverlayMutation(id: "r1", kind: .patch, fields: ["title": .string("owed")]),
            priorOverlay: ["r1/title": .string("v1")]
        )
        try seedForeignOp(
            provider, clientId: "gone", seq: 2, recordId: "r2", fields: ["title"],
            mutation: OverlayMutation(id: "r2", kind: .patch, fields: ["title": .string("later")]),
            priorOverlay: ["r2/title": .string("v1")]
        )

        let note = try makeStore(host: provider, clientId: "scratch")
        try note.noteDeferredReplay(
            throughSeq: 1, fromEpoch: 3, toEpoch: 4, kind: .ordinary
        )

        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let binding = try coordinator.bind(documentId: "d", models: ["Note"])
        binding.overlay.applyRawEntries(
            [("r1/title", .string("v1")), ("r2/title", .string("v1"))], model: "Note"
        )

        let outcome = try binding.adoptAndRestore()
        XCTAssertEqual(outcome.adopted, [1, 2])
        XCTAssertEqual(outcome.deferred, [1], "at or below the note's through_seq")
        XCTAssertEqual(outcome.restored, [2], "above it, restored as usual")
        XCTAssertEqual(
            binding.overlay.value(model: "Note", key: "r1/title"), .string("v1"),
            "the deferred write is NOT on the overlay"
        )
        XCTAssertEqual(
            binding.overlay.value(model: "Note", key: "r2/title"), .string("later")
        )
        // The note itself survives the bind: the judgement is still owed.
        XCTAssertNotNil(try binding.store.deferredReplay())
    }

    /// Edge E16: a note whose `through_seq` the server has already
    /// acknowledged is cleared without a judgement — there is nothing left to
    /// judge, and holding a write back for it would hold nothing at all.
    func testADeferredReplayNoteAlreadyAcknowledgedIsClearedWithoutAJudgement()
        async throws
    {
        let provider = try await makeProvider(at: newDirectory() + "/store.sqlite")
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let binding = try coordinator.bind(documentId: "d", models: ["Note"])
        try binding.store.commitLocalWrite(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("x")]),
            pending: PendingOpInput(
                model: "Note", recordId: "r1", op: .create, fields: ["title"],
                baseEpoch: 1, ts: 0
            )
        )
        try binding.store.prunePendingOps(maxContiguousSeq: 1)
        try binding.store.noteDeferredReplay(
            throughSeq: 1, fromEpoch: 3, toEpoch: 4, kind: .ordinary
        )

        let outcome = try binding.adoptAndRestore()
        XCTAssertEqual(outcome.deferred, [], "nothing to hold back")
        XCTAssertNil(
            try binding.store.deferredReplay(),
            "the note is cleared: the server acknowledged everything it covered"
        )
    }

    /// Edge E10: an adopted op whose model this device does not hold is left
    /// to the key-presence rule, and no merged row is asked for.
    ///
    /// A capped load left the model out (behavior 34), so the rows the store
    /// holds for it are whatever a later overlay happened to touch — not the
    /// model. Reading one and treating it as the record's state before the
    /// write would classify the op against a fact that is not one; the store
    /// refuses such a read by name, and this path does not make it.
    func testAnAdoptedOpOfAnUnheldModelIsClassifiedWithoutReadingARow()
        async throws
    {
        let provider = try await makeProvider(at: newDirectory() + "/store.sqlite")
        try seedForeignOp(
            provider, clientId: "gone", seq: 1, model: "Task", recordId: "t1",
            fields: ["label"],
            mutation: OverlayMutation(
                id: "t1", kind: .patch, fields: ["label": .string("offline")]
            )
        )
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let binding = try coordinator.bind(documentId: "d", models: ["Note", "Task"])
        // This device holds `Note` and not `Task`.
        try binding.store.setHydrationScope(["Note"])
        XCTAssertThrowsError(
            try binding.store.read(model: "Task", recordId: "t1"),
            "the precondition: the store refuses a read of a model it does not hold"
        )

        let outcome = try binding.adoptAndRestore()
        XCTAssertEqual(outcome.adopted, [1])
        XCTAssertEqual(
            outcome.restored, [1],
            "the overlay carries no key for it, so the key-presence rule says "
                + "the write is still owed — decided without a row"
        )
        XCTAssertEqual(
            binding.overlay.value(model: "Task", key: "t1/label"), .string("offline")
        )
    }
}
