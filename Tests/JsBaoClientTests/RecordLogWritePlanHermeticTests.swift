import XCTest
@testable import JsBaoClient

/// Planning a format-3 save, merging two saves of one record, and the checks
/// an entry passes before anything commits — each refusal reported once as a
/// `DocumentWriteRefusedEvent` carrying the one write it refused.
final class RecordLogWritePlanHermeticTests: XCTestCase {

    func testANewRecordIsACreateCarryingTheWholeState() {
        let m = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: nil,
            dataToSave: ["id": "n1", "title": "t", "priority": 3, "done": false, "note": .null,
                         "tags": ["b", "a"], "_meta_doc_id": "doc", "type": "Note"],
            touchedFields: ["title"],
            stringSetFieldNames: ["tags"]
        ))
        XCTAssertEqual(m.kind, .create)
        XCTAssertEqual(m.fields, ["title": "t", "priority": 3, "done": false, "note": .null],
                       "every field the save resolved — a default included — and never the key or the store's columns")
        XCTAssertEqual(m.stringSetDeltas, ["tags": ["a": true, "b": true]])
    }

    func testAnExistingRecordIsAPatchOfTheTouchedFields() {
        let m = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: ["id": "n1", "title": "old", "note": "x"],
            dataToSave: ["id": "n1", "title": "new", "priority": 3],
            touchedFields: ["title", "note", "title"],
            stringSetChanges: ["tags": (additions: ["c"], removals: ["a"])],
            stringSetFieldNames: ["tags", "labels"]
        ))
        XCTAssertEqual(m.kind, .patch)
        XCTAssertEqual(m.fields, ["title": "new", "note": .null], "a touched field with no value is cleared with null")
        XCTAssertEqual(m.stringSetDeltas, ["tags": ["a": false, "c": true]], "members travel as deltas; an untouched set does not travel")

        let untouched = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: ["id": "n1"], dataToSave: ["id": "n1"], touchedFields: []
        ))
        XCTAssertNil(untouched.fields)
        XCTAssertNil(untouched.stringSetDeltas)
        XCTAssertEqual(planRecordLogDelete(model: "Note", recordId: "n1"), RecordLogMutation(model: "Note", id: "n1", kind: .delete))
    }

    func testALaterPatchMergesIntoAnEarlierCreateOrPatch() {
        let create = RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["title": "a", "x": 1],
                                       stringSetDeltas: ["tags": ["a": true, "b": true]])
        let patch = RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["title": "b"],
                                      stringSetDeltas: ["tags": ["a": false, "c": true]])
        let merged = mergeRecordLogMutations(create, patch)
        XCTAssertEqual(merged.kind, .create)
        XCTAssertEqual(merged.fields, ["title": "b", "x": 1])
        XCTAssertEqual(merged.stringSetDeltas, ["tags": ["b": true, "c": true]], "a create never carries a removal")

        let earlierPatch = RecordLogMutation(model: "Note", id: "n1", kind: .patch, stringSetDeltas: ["tags": ["a": true]])
        XCTAssertEqual(mergeRecordLogMutations(earlierPatch, patch).stringSetDeltas, ["tags": ["a": false, "c": true]])
        XCTAssertEqual(mergeRecordLogMutations(earlierPatch, patch).fields, ["title": "b"])

        let delete = RecordLogMutation(model: "Note", id: "n1", kind: .delete)
        XCTAssertEqual(mergeRecordLogMutations(create, delete), delete, "a later delete stands for both")
        XCTAssertEqual(mergeRecordLogMutations(delete, patch), patch)
    }

    func testAValueTheWireCannotCarryIsRefusedInvalidAndReportedOnceWithTheOneWrite() {
        for (value, what) in [(JSONValue.number(.nan), "NaN"), (.number(.infinity), "Infinity"),
                              (.number(9_007_199_254_740_994), "an integer outside ±2^53"),
                              (.object(["deep": .array([.number(-.infinity)])]), "a nested non-finite number")] {
            var events: [DocumentWriteRefusedEvent] = []
            let mutations = [
                RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["v": value]),
                RecordLogMutation(model: "Note", id: "n2", kind: .create, fields: ["title": "fine"]),
            ]
            XCTAssertThrowsError(try assertRecordLogEntry(documentId: "doc-1", mutations: mutations) { events.append($0) }, what) { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .documentEntryInvalid, what)
            }
            XCTAssertEqual(events.count, 1, what)
            XCTAssertEqual(events.first?.error.code, .documentEntryInvalid)
            XCTAssertEqual(events.first?.documentId, "doc-1")
            XCTAssertEqual(events.first?.model, "Note")
            XCTAssertEqual(events.first?.recordId, "n1")
            XCTAssertEqual(events.first?.writes?.map(\.recordId), ["n1", "n2"], "the one write, every mutation it carried")
            XCTAssertEqual(events.first?.writes?.first?.fields.map { RecordLogJSON.text(.object($0)) },
                           RecordLogJSON.text(.object(["v": value])), "the write with its values")
            XCTAssertEqual(events.first?.writes?.first?.seq, 0, "refused before it had a number")
            XCTAssertNil(events.first?.conflictingRecord)
        }
        XCTAssertNoThrow(try assertRecordLogEntry(documentId: "doc-1", mutations: [
            RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["v": .number(9_007_199_254_740_991), "w": 0.5]),
        ]))
    }

    func testAFieldTheRoomReservesIsRefusedInvalidAndReportedOnceWithTheOneWrite() {
        for (mutation, name) in [
            (RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["type": "x"]), "type"),
            (RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["_secret": 1]), "_secret"),
            (RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: nil, stringSetDeltas: ["_tags": ["a": true]]), "_tags"),
        ] {
            var events: [DocumentWriteRefusedEvent] = []
            let mutations = [mutation, RecordLogMutation(model: "Note", id: "n2", kind: .create, fields: ["title": "fine"])]
            XCTAssertThrowsError(try assertRecordLogEntry(documentId: "doc-1", mutations: mutations) { events.append($0) }, name) { error in
                let refused = error as? JsBaoError
                XCTAssertEqual(refused?.code, .documentEntryInvalid, name)
                XCTAssertTrue(refused?.message.hasPrefix("Cannot save Note n1: Field '\(name)' is reserved") == true, refused?.message ?? "")
                XCTAssertTrue(refused?.message.hasSuffix("Rename the field.") == true)
                XCTAssertEqual(refused?.details?["scope"], "local")
            }
            XCTAssertEqual(events.count, 1, name)
            XCTAssertEqual(events.first?.writes?.map(\.recordId), ["n1", "n2"], "the one write, every mutation it carried")
            XCTAssertEqual(events.first?.writes?.first?.seq, 0)
        }
        XCTAssertNoThrow(try assertRecordLogEntry(documentId: "doc-1", mutations: [
            RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["id": "n1", "kind": "a", "types": "b", "a_b": "c"]),
        ]))
    }

    /// #4505 — every name on the shared list (a name that breaks a generated
    /// model on either client) is refused like `type`, as a field and as a
    /// string-set delta key, with js-bao's sentence.
    func testEveryListedFieldNameIsRefusedInvalidWithTheSharedSentence() {
        XCTAssertFalse(ReservedFieldNames.reasons.isEmpty)
        for (name, reason) in ReservedFieldNames.reasons.sorted(by: { $0.key < $1.key }) {
            let sentence = "Field '\(name)' is reserved (\(reason))"
            XCTAssertEqual(recordLogReservedFieldProblem(name), sentence, name)
            for mutation in [
                RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["title": "a", name: "x"]),
                RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: nil, stringSetDeltas: [name: ["a": true]]),
            ] {
                var events: [DocumentWriteRefusedEvent] = []
                let mutations = [mutation, RecordLogMutation(model: "Note", id: "n2", kind: .create, fields: ["title": "fine"])]
                XCTAssertThrowsError(try assertRecordLogEntry(documentId: "doc-1", mutations: mutations) { events.append($0) }, name) { error in
                    let refused = error as? JsBaoError
                    XCTAssertEqual(refused?.code, .documentEntryInvalid, name)
                    XCTAssertEqual(refused?.message, "Cannot save Note n1: \(sentence). Rename the field.")
                    XCTAssertEqual(refused?.details?["scope"], "local")
                }
                XCTAssertEqual(events.count, 1, name)
                XCTAssertEqual(events.first?.writes?.map(\.recordId), ["n1", "n2"], "the one write, every mutation it carried")
            }
        }
        // `id`, every exempt name, and names that merely resemble a listed one.
        var accepted: [String: JSONValue] = ["id": "n1", "kind": "a", "types": "b", "a_b": "c", "Save": "d", "syncStatus": "e"]
        for name in ReservedFieldNames.exempt { accepted[name] = "x" }
        for name in accepted.keys {
            XCTAssertNil(recordLogReservedFieldProblem(name), name)
        }
        XCTAssertNoThrow(try assertRecordLogEntry(documentId: "doc-1", mutations: [
            RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: accepted),
        ]))
    }

    /// The sentence is js-bao's, reason for reason: the generated copy this
    /// target reads carries exactly the list `checkReservedFieldName` reads.
    func testTheListedReasonsAreJsBaosList() throws {
        guard ClientSourceText.isMonorepoCheckout else {
            throw XCTSkip("packages/js-bao is not published with the Swift package")
        }
        let json = try ClientSourceText.repoFile("packages/js-bao/src/utils/reservedFieldNames.json")
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let reserved = try XCTUnwrap(parsed?["reserved"] as? [String: [String: Any]])
        let exempt = try XCTUnwrap(parsed?["exempt"] as? [String: String])
        XCTAssertEqual(ReservedFieldNames.reasons, reserved.mapValues { $0["reason"] as? String ?? "" })
        XCTAssertEqual(ReservedFieldNames.exempt, Set(exempt.keys))
    }

    func testAnEntryOverOneMebibyteIsRefusedTooLargeAndReportedOnce() {
        var events: [DocumentWriteRefusedEvent] = []
        let big = String(repeating: "x", count: 1024 * 1024)
        XCTAssertThrowsError(try assertRecordLogEntry(documentId: "doc-1", mutations: [
            RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["body": .string(big)]),
        ]) { events.append($0) }) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .documentEntryTooLarge)
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.error.code, .documentEntryTooLarge)
        XCTAssertEqual(events.first?.writes?.count, 1)

        // Just under the limit, measured with the widest numbers the room could give it.
        let room = 1024 * 1024 - 200
        XCTAssertNoThrow(try assertRecordLogEntry(documentId: "doc-1", mutations: [
            RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["body": .string(String(repeating: "x", count: room))]),
        ]))
    }
}
