import XCTest
import YSwift
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

/// The record-log value rules on the Swift client (#4624 behaviour 6): what a
/// field value may be and what a name may be, in the sentences of js-bao's
/// `record-log/values.ts`, applied by `assertRecordLogEntry` to every entry in
/// the order reserved name, then rule, then value the wire cannot carry, then
/// size — the room's own order — each refusal reported once.
final class RecordLogValueRulesHermeticTests: XCTestCase {

    private static let notIdentifier = "is not an identifier (a letter, then letters, digits or _)"
    private static let valueRule = "a field value is a string, a number, a boolean, null or an array of strings"

    func testValueKindJudgesEveryValue() {
        XCTAssertEqual(RecordLogValues.valueKind("a"), .kind(.string))
        XCTAssertEqual(RecordLogValues.valueKind(1.5), .kind(.number))
        XCTAssertEqual(RecordLogValues.valueKind(true), .kind(.boolean))
        XCTAssertEqual(RecordLogValues.valueKind(nil), .kind(.null))
        XCTAssertEqual(RecordLogValues.valueKind(["a", "b"]), .kind(.stringset))
        XCTAssertEqual(RecordLogValues.valueKind([]), .kind(.stringset))
        XCTAssertEqual(RecordLogValues.valueKind(["$add": ["a"], "$remove": [], "$clear": true]), .kind(.setOp))
        XCTAssertEqual(RecordLogValues.valueKind(["a", 1]), .invalid("an array whose member 1 is a number"))
        XCTAssertEqual(RecordLogValues.valueKind(["a", nil]), .invalid("an array whose member 1 is null"))
        XCTAssertEqual(RecordLogValues.valueKind([["a"]]), .invalid("an array whose member 0 is an array"))
        XCTAssertEqual(RecordLogValues.valueKind([["x": 1]]), .invalid("an array whose member 0 is an object"))
        XCTAssertEqual(RecordLogValues.valueKind([true]), .invalid("an array whose member 0 is a boolean"))
        XCTAssertEqual(RecordLogValues.valueKind(.object([:])), .invalid("an object"))
        XCTAssertEqual(RecordLogValues.valueKind(["x": 1]), .invalid("an object"))
        XCTAssertEqual(RecordLogValues.valueKind(["$add": ["a"], "x": 1]), .invalid("an object"))
        XCTAssertEqual(RecordLogValues.valueKind(["$add": "a"]), .invalid("a string-set change whose $add is not an array"))
        XCTAssertEqual(RecordLogValues.valueKind(["$remove": ["a", 2]]),
                       .invalid("a string-set change whose $remove member 1 is a number"))
        XCTAssertEqual(RecordLogValues.valueKind(["$clear": "yes"]), .invalid("a string-set change whose $clear is not true or false"))
    }

    func testTheSentencesAreValuesTs() throws {
        XCTAssertEqual(RecordLogValues.describeValueKind(.null), "null")
        XCTAssertEqual(RecordLogValues.describeValueKind(.stringset), "an array of strings")
        XCTAssertEqual(RecordLogValues.describeValueKind(.setOp), "a string-set change")
        XCTAssertEqual(RecordLogValues.describeValueKind(.string), "a string")
        XCTAssertEqual(RecordLogValues.describeValueKind(.number), "a number")
        XCTAssertEqual(RecordLogValues.describeValueKind(.boolean), "a boolean")
        XCTAssertEqual(RecordLogValues.identifierProblem(.field, "a b"), "field \"a b\" \(Self.notIdentifier)")
        XCTAssertEqual(RecordLogValues.identifierProblem(.model, "_x"), "model \"_x\" \(Self.notIdentifier)",
                       "a name starts with a letter")
        XCTAssertEqual(RecordLogValues.identifierProblem(.field, "é"), "field \"é\" \(Self.notIdentifier)")
        XCTAssertEqual(RecordLogValues.identifierProblem(.field, "q\"x"), "field \"q\\\"x\" \(Self.notIdentifier)",
                       "the name as JSON writes it")
        XCTAssertNil(RecordLogValues.identifierProblem(.field, "a1_"))
        XCTAssertNil(RecordLogValues.identifierProblem(.model, "Note"))
        XCTAssertEqual(RecordLogValues.valueProblem(model: "Note", id: "n1", field: "o", description: "an object"),
                       "Note id=n1: field \"o\" holds an object; \(Self.valueRule)")
        guard ClientSourceText.isMonorepoCheckout else { return }
        let values = try ClientSourceText.repoFile("packages/js-bao/src/record-log/values.ts")
        XCTAssertTrue(values.contains("is not an identifier (a letter, then letters, digits or _)`"))
        XCTAssertTrue(values.contains("`a field value is a string, a number, a boolean, null or an array of strings`"))
        XCTAssertTrue(values.contains("/^[A-Za-z][A-Za-z0-9_]*$/"))
        for fragment in ["an array whose member ${i} is ", "a string-set change whose ${key} is not an array",
                         "a string-set change whose ${key} member ${i} is ", "a string-set change whose $clear is not true or false",
                         "\"an array of strings\"", "\"a string-set change\""] {
            XCTAssertTrue(values.contains(fragment), fragment)
        }
    }

    private func refusal(_ mutations: [RecordLogMutation], _ what: String,
                         file: StaticString = #filePath, line: UInt = #line) -> (JsBaoError?, [DocumentWriteRefusedEvent]) {
        var events: [DocumentWriteRefusedEvent] = []
        var thrown: JsBaoError?
        XCTAssertThrowsError(try assertRecordLogEntry(documentId: "doc-1", mutations: mutations) { events.append($0) }, what,
                             file: file, line: line) { thrown = $0 as? JsBaoError }
        XCTAssertEqual(events.count, 1, what, file: file, line: line)
        XCTAssertEqual(events.first?.error.message, thrown?.message, what, file: file, line: line)
        XCTAssertEqual(events.first?.writes?.map(\.recordId), mutations.map(\.id), what, file: file, line: line)
        return (thrown, events)
    }

    func testAnEntryBreakingTheRulesIsRefusedInTheRoomsWords() {
        let fine = RecordLogMutation(model: "Note", id: "n2", kind: .create, fields: ["title": "fine"])
        for (value, description) in [
            (JSONValue.object(["a": 1]), "an object"),
            (["a", "b"], "an array of strings"),
            ([], "an array of strings"),
            (["a", 1], "an array whose member 1 is a number"),
            (["$add": ["a"]], "a string-set change"),
        ] {
            let (error, _) = refusal([RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["o": value]), fine], description)
            XCTAssertEqual(error?.code, .documentEntryInvalid, description)
            XCTAssertEqual(error?.message, "Cannot save Note n1: Note id=n1: field \"o\" holds \(description); \(Self.valueRule).")
            XCTAssertEqual(error?.details?["scope"], "local")
        }
        let (model, _) = refusal([RecordLogMutation(model: "a b", id: "n1", kind: .create, fields: ["title": "x"])], "model")
        XCTAssertEqual(model?.code, .documentEntryInvalid)
        XCTAssertEqual(model?.message, "Cannot save a b n1: model \"a b\" \(Self.notIdentifier).")
        let (field, _) = refusal([RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["a b": "x"])], "field")
        XCTAssertEqual(field?.message, "Cannot save Note n1: field \"a b\" \(Self.notIdentifier). Rename the field.")
        let (setField, _) = refusal(
            [RecordLogMutation(model: "Note", id: "n1", kind: .patch, stringSetDeltas: ["a-b": ["x": true]])], "set field"
        )
        XCTAssertEqual(setField?.message, "Cannot save Note n1: field \"a-b\" \(Self.notIdentifier). Rename the field.")
        // A string set travels as deltas, an `id` value and every scalar pass.
        XCTAssertNoThrow(try assertRecordLogEntry(documentId: "doc-1", mutations: [
            RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["id": "n1", "s": "a", "n": 1, "b": false, "z": nil],
                              stringSetDeltas: ["tags": ["a": true], "empty": [:]]),
        ]))
    }

    func testTheChecksRunReservedThenRuleThenValueThenSize() {
        let (reserved, _) = refusal([RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["type": ["x": 1]])], "reserved")
        XCTAssertTrue(reserved?.message.hasPrefix("Cannot save Note n1: Field 'type' is reserved") ?? false, reserved?.message ?? "")
        let (rule, _) = refusal(
            [RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["o": ["deep": .number(.nan)]])], "rule"
        )
        XCTAssertEqual(rule?.message, "Cannot save Note n1: Note id=n1: field \"o\" holds an object; \(Self.valueRule).")
        let (value, _) = refusal([RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["n": .number(.infinity)])], "value")
        XCTAssertTrue(value?.message.hasPrefix("Cannot save Note n1: Note.n1.n is inf") ?? false, value?.message ?? "")
        let big = String(repeating: "x", count: 1024 * 1024)
        let (size, _) = refusal([RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["body": .string(big)])], "size")
        XCTAssertEqual(size?.code, .documentEntryTooLarge)
        let (first, _) = refusal([
            RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["n": .number(.infinity)]),
            RecordLogMutation(model: "Note", id: "n2", kind: .patch, fields: ["o": ["x": 1]]),
        ], "the first mutation's problem")
        XCTAssertTrue(first?.message.hasPrefix("Cannot save Note n1:") ?? false, first?.message ?? "")
    }
}

/// A model-free write's input, judged before anything is planned (#4624
/// behaviour 7), and the value a model-free write carries in a field
/// (`DocumentRecordValue`, edges 040 and 041): its literal forms, and members
/// that are distinct by their UTF-8 bytes, as the room and js-bao keep them.
final class RecordLogRecordInputHermeticTests: XCTestCase {

    private static let notIdentifier = "is not an identifier (a letter, then letters, digits or _)"

    private func refusal(model: String = "Note", id: String = "n1", kind: RecordLogRecordWriteKind = .put,
                         data: [String: DocumentRecordValue], _ what: String,
                         file: StaticString = #filePath, line: UInt = #line) -> (JsBaoError?, [DocumentWriteRefusedEvent]) {
        var events: [DocumentWriteRefusedEvent] = []
        var thrown: JsBaoError?
        XCTAssertThrowsError(
            try assertRecordLogRecordInput(documentId: "doc-1", model: model, id: id, kind: kind, data: data) { events.append($0) },
            what, file: file, line: line
        ) { thrown = $0 as? JsBaoError }
        XCTAssertEqual(thrown?.code, .documentEntryInvalid, what, file: file, line: line)
        XCTAssertEqual(thrown?.details?["scope"], "local", what, file: file, line: line)
        XCTAssertEqual(events.count, 1, what, file: file, line: line)
        XCTAssertEqual(events.first?.error.message, thrown?.message, what, file: file, line: line)
        return (thrown, events)
    }

    func testANameTheRoomWouldRefuseIsRefusedBeforePlanning() {
        let (model, modelEvents) = refusal(model: "a b", data: ["title": "x"], "model")
        XCTAssertEqual(model?.message, "Cannot save a b n1: model \"a b\" \(Self.notIdentifier).")
        XCTAssertEqual(modelEvents.first?.writes, [
            RecordLogRefusedWrite(model: "a b", recordId: "n1", kind: .create, fields: nil, stringSetDeltas: nil, seq: 0),
        ])
        XCTAssertEqual(modelEvents.first?.model, "a b")
        XCTAssertEqual(modelEvents.first?.recordId, "n1")
        let (type, _) = refusal(kind: .patch, data: ["type": "x"], "type")
        XCTAssertEqual(type?.message,
                       "Cannot save Note n1: Field 'type' is reserved (maps to internal _type column in queries). Rename the field.")
        let (underscore, _) = refusal(data: ["_x": 1], "_x")
        XCTAssertEqual(underscore?.message,
                       "Cannot save Note n1: Field '_x' is reserved (fields starting with '_' are internal). Rename the field.")
        let (spaced, spacedEvents) = refusal(kind: .patch, data: ["a b": "x"], "a b")
        XCTAssertEqual(spaced?.message, "Cannot save Note n1: field \"a b\" \(Self.notIdentifier). Rename the field.")
        XCTAssertEqual(spacedEvents.first?.writes?.first?.kind, .patch)
    }

    func testTheIdKeyIsNotJudgedAndAnEmptyIdIsRefused() {
        XCTAssertNoThrow(try assertRecordLogRecordInput(
            documentId: "doc-1", model: "Note", id: "n1", kind: .put, data: ["id": "a b", "title": "a", "toString": 1]
        ))
        for kind in [RecordLogRecordWriteKind.put, .patch, .delete] {
            let (empty, events) = refusal(id: "", kind: kind, data: [:], "empty id \(kind)")
            XCTAssertEqual(empty?.message, "Cannot save Note: a record id is a non-empty string.")
            XCTAssertEqual(events.first?.writes?.first?.kind, kind == .put ? .create : kind == .patch ? .patch : .delete)
        }
    }

    func testLiteralsBuildTheValues() {
        let data: [String: DocumentRecordValue] = ["title": "a", "n": 1, "f": 1.5, "ok": true, "tags": ["x"], "z": nil]
        XCTAssertEqual(data["title"], .string("a"))
        XCTAssertEqual(data["n"], .number(1))
        XCTAssertEqual(data["f"], .number(1.5))
        XCTAssertEqual(data["ok"], .bool(true))
        XCTAssertEqual(data["tags"], .stringSet(["x"]))
        XCTAssertEqual(data["z"], .null)
        XCTAssertEqual(DocumentRecordValue.setChange(add: ["a"]), .setChange(add: ["a"], remove: [], clear: false))
    }

    func testMembersAreDistinctByTheirBytes() {
        XCTAssertNotEqual(DocumentRecordValue.stringSet(["\u{E9}"]), .stringSet(["e\u{301}"]))
        XCTAssertNotEqual(DocumentRecordValue.string("\u{E9}"), .string("e\u{301}"))
        XCTAssertEqual(DocumentRecordValue.stringSet(["a", "a"]), .stringSet(["a"]))
        XCTAssertEqual(DocumentRecordValue.stringSet(["b", "a"]), .stringSet(["a", "b"]))
        XCTAssertEqual(DocumentRecordValue.stringSet(["\u{E9}", "e\u{301}"]).members, ["e\u{301}", "\u{E9}"],
                       "two members, in byte order")
        XCTAssertNotEqual(DocumentRecordValue.setChange(remove: ["\u{E9}"]), .setChange(remove: ["e\u{301}"]))
        XCTAssertEqual(DocumentRecordValue.stringSet(["\u{E9}", "e\u{301}"]).json, .array([.string("e\u{301}"), .string("\u{E9}")]))
    }

    func testARowReadBackHoldsBothSpellings() async throws {
        let directory = NSTemporaryDirectory() + "/record-log-record-input-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let store = RecordLogStore(host: provider, documentId: "doc-1", clientId: "client-a")
        try store.initialize()
        let writer = try store.mintWriter()
        _ = try store.applyCatchUpPage(writer: writer, rows: [
            RecordLogCatchUpRow(model: "Memo", id: "m1", row: ["id": "m1", "tags": [.string("e\u{301}"), .string("\u{E9}")]]),
        ], lsn: 0)
        let tags = try XCTUnwrap(try store.read(model: "Memo", id: "m1")?["tags"]?.arrayValue)
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(tags.compactMap(\.stringValue).map { Array($0.utf8) }, [Array("e\u{301}".utf8), Array("\u{E9}".utf8)])
    }
}

/// The declared path's planner says what js-bao's says (#4624 behaviour 9): a
/// touched set field with no net change travels as an empty change, an array
/// of strings in any field is a string set by its shape, and the merge of two
/// saves sends a field one way only.
final class RecordLogPlannerParityHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    func testATouchedSetFieldWithNoNetChangeTravelsAsAnEmptyChange() {
        let touched = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: ["id": "n1", "tags": []],
            dataToSave: ["id": "n1", "tags": []], touchedFields: ["tags"],
            stringSetChanges: ["tags": (additions: [], removals: [])], stringSetFieldNames: ["tags", "labels"]
        ))
        XCTAssertEqual(touched.stringSetDeltas, ["tags": [:]], "an explicitly empty set reaches the room")
        XCTAssertNil(touched.fields)
        let created = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: nil,
            dataToSave: ["id": "n1", "tags": [], "labels": ["a"]], touchedFields: [], stringSetFieldNames: ["tags", "labels"]
        ))
        XCTAssertEqual(created.stringSetDeltas, ["labels": ["a": true]], "a never-touched empty set stays out")
        let touchedCreate = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: nil, dataToSave: ["id": "n1", "tags": []], touchedFields: ["tags"],
            stringSetChanges: ["tags": (additions: [], removals: [])], stringSetFieldNames: ["tags"]
        ))
        XCTAssertEqual(touchedCreate.stringSetDeltas, ["tags": [:]])
    }

    func testAnArrayOfStringsInAnUndeclaredFieldIsAStringSet() {
        let created = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: nil,
            dataToSave: ["id": "n1", "labels": ["b", "a"], "title": "t"], touchedFields: []
        ))
        XCTAssertEqual(created.fields, ["title": "t"])
        XCTAssertEqual(created.stringSetDeltas, ["labels": ["a": true, "b": true]])
        let replaced = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: ["id": "n1", "labels": ["a", "c"]],
            dataToSave: ["id": "n1", "labels": ["a", "b"]], touchedFields: ["labels"]
        ))
        XCTAssertEqual(replaced.stringSetDeltas, ["labels": ["c": false, "a": true, "b": true]], "a patch replaces the members")
        XCTAssertNil(replaced.fields)
        let emptied = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: ["id": "n1", "labels": ["a", "b"], "s": "x"],
            dataToSave: ["id": "n1", "labels": nil, "s": nil, "gone": nil], touchedFields: ["labels", "s", "gone"]
        ))
        XCTAssertEqual(emptied.stringSetDeltas, ["labels": ["a": false, "b": false]], "null on a held array removes every member")
        XCTAssertEqual(emptied.fields, ["s": nil, "gone": nil], "null on a scalar or a missing field travels as null")
        let numbers = planRecordLogSave(RecordLogSaveInput(
            model: "Note", recordId: "n1", existing: nil, dataToSave: ["id": "n1", "nums": [1, 2]], touchedFields: []
        ))
        XCTAssertEqual(numbers.fields, ["nums": [1, 2]], "any other array stays in fields, where the rules refuse it")
        XCTAssertNil(numbers.stringSetDeltas)
    }

    func testTheMergeSendsAFieldOneWayAndKeepsANamedSetField() {
        let create = RecordLogMutation(model: "Note", id: "n1", kind: .create, stringSetDeltas: ["tags": ["a": true]])
        let removeIt = RecordLogMutation(model: "Note", id: "n1", kind: .patch, stringSetDeltas: ["tags": ["a": false]])
        XCTAssertEqual(mergeRecordLogMutations(create, removeIt).stringSetDeltas, ["tags": [:]],
                       "the later save named the set: it travels, empty")
        let patch = RecordLogMutation(model: "Note", id: "n1", kind: .patch, stringSetDeltas: ["tags": ["a": true]])
        XCTAssertEqual(mergeRecordLogMutations(patch, removeIt).stringSetDeltas, ["tags": ["a": false]])
        let asValue = RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["tags": nil])
        let merged = mergeRecordLogMutations(patch, asValue)
        XCTAssertNil(merged.stringSetDeltas, "an earlier delta for a field the later save sends as a value is dropped")
        XCTAssertEqual(merged.fields, ["tags": nil])
        let earlierValue = RecordLogMutation(model: "Note", id: "n1", kind: .patch, fields: ["labels": "x", "title": "t"])
        let laterSet = RecordLogMutation(model: "Note", id: "n1", kind: .patch, stringSetDeltas: ["labels": ["b": true]])
        let both = mergeRecordLogMutations(earlierValue, laterSet)
        XCTAssertEqual(both.fields, ["title": "t"], "a field the later save sends as a set change leaves fields")
        XCTAssertEqual(both.stringSetDeltas, ["labels": ["b": true]])
    }

    func testClearingADeclaredSetSendsRemovalsOfEachMember() async throws {
        let directory = NSTemporaryDirectory() + "/record-log-planner-parity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: "rl-parity", clientId: "client-1", logger: Logger(level: .none)
        )
        let schema = PrimitiveSchema(name: "Note", fields: ["id": FieldDescriptor(type: .id), "tags": FieldDescriptor(type: .stringset)])
        let model = MultiDocModel(schema: schema).connect(docId: "rl-parity", doc: YDocument())
        try model.bindRecordLog(binding)
        let record = try model.create(id: "n1", values: ["tags": .stringset(["a", "b"])])
        record["tags"] = nil
        let pending = try binding.store.pendingOf(binding.writer)
        XCTAssertEqual(pending.last?.m.stringSetDeltas, ["tags": ["a": false, "b": false]])
        XCTAssertNil(pending.last?.m.fields)
        // Saving the set unchanged sends it as an empty change.
        try model.update(id: "n1", values: ["tags": .stringset([])])
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).last?.m.stringSetDeltas, ["tags": [:]])
    }
}

/// The mutation a model-free write commits (#4624 behaviour 8, edges 034,
/// 035, 036, 042), planned against the record's view row as js-bao's
/// `planRecordLogRecordWrite` plans it.
final class RecordLogRecordWritePlanHermeticTests: XCTestCase {

    private func plan(_ kind: RecordLogRecordWriteKind, existing: RecordLogRow? = nil,
                      _ data: [String: DocumentRecordValue]) -> RecordLogMutation {
        planRecordLogRecordWrite(RecordLogRecordWriteInput(model: "Memo", id: "m1", kind: kind, existing: existing, data: data))
    }

    func testAPutIsACreateCarryingEveryField() {
        let m = plan(.put, existing: ["id": "m1", "tags": ["z"], "old": "x"], [
            "id": "ignored", "title": "a", "n": 1.5, "ok": true, "z": nil, "tags": ["b", "a"],
            "more": .setChange(add: ["x"], remove: ["y"], clear: true),
        ])
        XCTAssertEqual(m.kind, .create, "a create entry, whether or not the view holds the id")
        XCTAssertEqual(m.id, "m1")
        XCTAssertEqual(m.fields, ["title": "a", "n": 1.5, "ok": true, "z": nil])
        XCTAssertEqual(m.stringSetDeltas, ["tags": ["a": true, "b": true], "more": ["x": true]],
                       "a string set as additions; a set change's add only")
    }

    func testAPatchChangesTheNamedFieldsEvenOfARecordTheViewLacks() {
        let missing = plan(.patch, ["title": "a", "tags": ["x"]])
        XCTAssertEqual(missing.kind, .patch)
        XCTAssertEqual(missing.fields, ["title": "a"])
        XCTAssertEqual(missing.stringSetDeltas, ["tags": ["x": true]])
        let held: RecordLogRow = ["id": "m1", "tags": ["a", "b", "c"], "labels": ["p", "q"], "s": "x"]
        let replaced = plan(.patch, existing: held, ["tags": ["b", "d"], "labels": nil, "s": nil, "gone": nil, "id": "other"])
        XCTAssertEqual(replaced.stringSetDeltas, [
            "tags": ["a": false, "c": false, "b": true, "d": true],
            "labels": ["p": false, "q": false],
        ], "a string set replaces the held members; null on a held array removes every member")
        XCTAssertEqual(replaced.fields, ["s": nil, "gone": nil], "null on a scalar or a field the view lacks travels in fields")
        XCTAssertEqual(replaced.id, "m1", "the id key is ignored")
    }

    func testASetChangeClearsThenRemovesThenAdds() {
        let held: RecordLogRow = ["id": "m1", "tags": ["a", "b"]]
        XCTAssertEqual(plan(.patch, existing: held, ["tags": .setChange(add: ["a"], remove: ["x"], clear: true)]).stringSetDeltas,
                       ["tags": ["a": true, "b": false, "x": false]])
        XCTAssertEqual(plan(.patch, existing: held, ["tags": .setChange(add: ["d"], remove: ["a"])]).stringSetDeltas,
                       ["tags": ["a": false, "d": true]])
        XCTAssertEqual(plan(.patch, existing: held, ["tags": .setChange()]).stringSetDeltas, ["tags": [:]],
                       "a change of nothing travels as an empty change")
        XCTAssertEqual(plan(.patch, ["fresh": .setChange()]).stringSetDeltas, ["fresh": [:]])
        XCTAssertEqual(plan(.patch, ["fresh": []]).stringSetDeltas, ["fresh": [:]], "an empty set on a new field travels empty")
        XCTAssertEqual(plan(.put, existing: held, ["tags": .setChange(remove: ["a"], clear: true)]).stringSetDeltas, ["tags": [:]],
                       "a put takes a change's additions only")
    }

    func testMembersAreBytes() {
        XCTAssertEqual(plan(.put, ["tags": ["a", "a"]]).stringSetDeltas, ["tags": ["a": true]])
        let removal = plan(.patch, existing: ["id": "m1", "tags": [.string("\u{E9}")]], ["tags": .setChange(remove: ["e\u{301}"])])
        let delta = removal.stringSetDeltas?["tags"]
        XCTAssertEqual(delta?.count, 1)
        XCTAssertEqual(delta?.keys.first.map { Array($0.utf8) }, Array("e\u{301}".utf8),
                       "the removal names the member as given; the room, comparing bytes, removes nothing")
        let kept = plan(.patch, existing: ["id": "m1", "tags": [.string("\u{E9}"), "b"]], ["tags": [.init(stringLiteral: "\u{E9}")]])
        XCTAssertEqual(kept.stringSetDeltas?["tags"]?.filter { !$0.value }.keys.sorted(), ["b"],
                       "a held member the new set names by the same bytes is not removed")
    }

    func testAFieldNamedLikeAnObjectMemberIsAnOrdinaryField() {
        let m = plan(.patch, existing: ["id": "m1", "toString": ["a"]], ["toString": ["b"], "constructor": "x"])
        XCTAssertEqual(m.stringSetDeltas, ["toString": ["a": false, "b": true]])
        XCTAssertEqual(m.fields, ["constructor": "x"])
    }

    func testThePlannedEntryPassesOrFailsTheRulesAsTheRoomWould() {
        XCTAssertNoThrow(try assertRecordLogEntry(documentId: "doc-1", mutations: [plan(.put, ["s": "a", "tags": ["x"], "z": nil])]))
        for value in [DocumentRecordValue.number(.nan), .number(.infinity), .number(9_007_199_254_740_994)] {
            XCTAssertThrowsError(try assertRecordLogEntry(documentId: "doc-1", mutations: [plan(.put, ["n": value])])) { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .documentEntryInvalid)
            }
        }
    }
}

/// Members are their bytes on every path (#4624 behaviour 8, D4624-002). A
/// string-set change travels as an object keyed by member, and Swift's `String`
/// equality merges the two spellings of "é" (U+00E9, U+0065 U+0301) into one
/// key, so a model-free write whose changes name both is split into
/// consecutive mutations of the record, each naming at most one spelling of a
/// member: removals first, then additions, each in byte order. They travel as
/// one entry (`m` plus `also`), which the room applies in order or refuses
/// whole, so the record ends as one write would leave it (C4624-001).
final class RecordLogRecordWriteRoundsHermeticTests: XCTestCase {

    private let pre = "\u{E9}"
    private let decomposed = "e\u{301}"

    private func plan(_ kind: RecordLogRecordWriteKind, existing: RecordLogRow? = nil,
                      _ data: [String: DocumentRecordValue]) -> [RecordLogMutation] {
        planRecordLogRecordWrites(RecordLogRecordWriteInput(model: "Memo", id: "m1", kind: kind, existing: existing, data: data))
    }

    /// Each mutation's `tags` change as (member bytes, present), in a stable order.
    private func tags(_ mutations: [RecordLogMutation]) -> [[[UInt8]: Bool]] {
        mutations.map { m in
            Dictionary(uniqueKeysWithValues: (m.stringSetDeltas?["tags"] ?? [:]).map { (Array($0.key.utf8), $0.value) })
        }
    }

    func testAPutOfBothSpellingsAddsTwoMembers() {
        let mutations = plan(.put, ["s": "x", "tags": [.init(stringLiteral: pre), .init(stringLiteral: decomposed), "a"]])
        XCTAssertEqual(mutations.map(\.kind), [.create, .patch])
        XCTAssertEqual(mutations[0].fields, ["s": "x"], "the fields travel with the first entry")
        XCTAssertNil(mutations[1].fields)
        XCTAssertEqual(tags(mutations), [
            [Array(decomposed.utf8): true, Array("a".utf8): true],
            [Array(pre.utf8): true],
        ])
        XCTAssertEqual(plan(.put, ["tags": ["a", "a"]]).count, 1)
    }

    func testAReplaceOrAClearOfASetHoldingBothSpellingsRemovesBoth() {
        let held: RecordLogRow = ["id": "m1", "tags": [.string(decomposed), "j", .string(pre)]]
        XCTAssertEqual(tags(plan(.patch, existing: held, ["tags": ["j", "r"]])), [
            [Array(decomposed.utf8): false, Array("r".utf8): true, Array("j".utf8): true],
            [Array(pre.utf8): false],
        ])
        XCTAssertEqual(tags(plan(.patch, existing: held, ["tags": nil])), [
            [Array(decomposed.utf8): false, Array("j".utf8): false],
            [Array(pre.utf8): false],
        ])
        XCTAssertEqual(tags(plan(.patch, existing: held, ["tags": .setChange(clear: true)])), [
            [Array(decomposed.utf8): false, Array("j".utf8): false],
            [Array(pre.utf8): false],
        ])
        XCTAssertEqual(plan(.patch, existing: held, ["tags": nil]).map(\.kind), [.patch, .patch])
    }

    func testAReplaceOfOneSpellingByTheOtherRemovesThenAdds() {
        let held: RecordLogRow = ["id": "m1", "tags": [.string(pre)]]
        XCTAssertEqual(tags(plan(.patch, existing: held, ["tags": [.init(stringLiteral: decomposed)]])), [
            [Array(pre.utf8): false],
            [Array(decomposed.utf8): true],
        ])
        XCTAssertEqual(tags(plan(.patch, existing: held, ["tags": .setChange(remove: [decomposed])])), [
            [Array(decomposed.utf8): false],
        ], "naming the other spelling removes nothing the record holds")
    }

    func testAWriteWithNoTwoSpellingsIsOneEntryAsPlannedBefore() {
        let held: RecordLogRow = ["id": "m1", "tags": ["a", "b"]]
        let data: [String: DocumentRecordValue] = ["s": "x", "tags": ["b", "c"], "more": .setChange(add: ["q"])]
        XCTAssertEqual(plan(.patch, existing: held, data), [
            planRecordLogRecordWrite(RecordLogRecordWriteInput(model: "Memo", id: "m1", kind: .patch, existing: held, data: data)),
        ])
    }

    private func makeBinding(_ directories: inout [String]) async throws -> RecordLogDocumentBinding {
        let directory = NSTemporaryDirectory() + "/record-log-rounds-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return try RecordLogDocumentBinding(
            host: provider, documentId: "rl-rounds", clientId: "client-1", logger: Logger(level: .none)
        )
    }

    func testTheHandleCommitsOneEntryAndTheCopyHoldsBothSpellings() async throws {
        var directories: [String] = []
        defer { for directory in directories { try? FileManager.default.removeItem(atPath: directory) } }
        let binding = try await makeBinding(&directories)
        let records = DocumentRecords(documentId: "rl-rounds") { binding }
        let row = try records.put("Memo", ["id": "m1", "tags": [.init(stringLiteral: pre), .init(stringLiteral: decomposed)]])
        XCTAssertEqual(row["tags"]?.arrayValue?.compactMap(\.stringValue).map { Array($0.utf8) },
                       [Array(decomposed.utf8), Array(pre.utf8)])
        let pending = try binding.store.pendingOf(binding.writer)
        XCTAssertEqual(pending.count, 1, "one entry")
        XCTAssertEqual(pending.first?.mutations.map(\.kind), [.create, .patch], "`m` then `also`")
        let replaced = try records.patch("Memo", id: "m1", ["tags": ["j"]])
        XCTAssertEqual(replaced?["tags"], ["j"], "a replace removes both spellings")
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).count, 2)
    }

    /// The room refusing the write's one entry (a scalar lock on another
    /// field of it) hands back all of it: the copy shows the record as before,
    /// with no entry of the write left to send (C4624-001).
    func testARefusalOfTheEntryHandsBackTheWholeWrite() async throws {
        var directories: [String] = []
        defer { for directory in directories { try? FileManager.default.removeItem(atPath: directory) } }
        let binding = try await makeBinding(&directories)
        let before: RecordLogRow = ["id": "m1", "locked": 1, "tags": ["old"]]
        _ = try binding.store.applyCatchUpPage(
            writer: binding.writer, rows: [RecordLogCatchUpRow(model: "Memo", id: "m1", row: before)]
        )
        let records = DocumentRecords(documentId: "rl-rounds") { binding }
        let guessed = try records.patch(
            "Memo", id: "m1", ["locked": ["x"], "tags": [.init(stringLiteral: decomposed), .init(stringLiteral: pre)]]
        )
        XCTAssertEqual(guessed?["tags"]?.arrayValue?.count, 2)
        let pending = try binding.store.pendingOf(binding.writer)
        XCTAssertEqual(pending.map(\.mutations.count), [2], "one entry naming both spellings")

        let seq = try XCTUnwrap(pending.first?.seq)
        _ = try binding.store.refused(writer: binding.writer, refusal: RecordLogRefusal(
            seq: seq, code: "DOCUMENT_ENTRY_INVALID", scope: .entry, from: seq,
            records: [RecordLogRefusedRecord(model: "Memo", id: "m1", from: seq)],
            message: "field \"locked\" of Memo is a number since log 1 and cannot become a string set"
        ))
        XCTAssertEqual(try binding.store.pendingOf(binding.writer).count, 0, "nothing of the write is left to send")
        XCTAssertEqual(try records.get("Memo", id: "m1")?.raw, before, "the copy shows the record as before")
    }
}
