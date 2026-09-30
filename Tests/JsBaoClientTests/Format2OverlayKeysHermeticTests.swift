import XCTest
@testable import JsBaoClient

/// The overlay key codec and the per-document table names (#3436, behavior 7,
/// edges E1 and E5).
///
/// A format-2 document's Y.Doc holds FLAT field-level keys, not a nested map
/// per record, and every consumer — the client write path, the observer, the
/// server projector, the snapshot builder — encodes and decodes them with one
/// grammar. Swift is the third implementation of that grammar, so the
/// interesting assertions here are the PARITY ones: the same input through
/// `js-bao`'s own `encodeOverlayMutation` / `parseOverlayKey` and through
/// Swift's, compared value for value.
final class Format2OverlayKeysHermeticTests: XCTestCase {

    // MARK: - Behavior 7 — round-trips

    func testSegmentsRoundTripThroughTheEscape() {
        // RFC 6901-flavoured: `~` → `~0`, `/` → `~1`, a LEADING `_` → `~2`.
        // Record ids are ULIDs and always safe; field and member names are
        // user data and are none of those things.
        for segment in [
            "title", "a/b", "a~b", "~0", "~1", "_replace", "_deleted",
            "_", "__x", "", "emoji 🎉", "tilde~slash/mix", "ünïcode",
        ] {
            XCTAssertEqual(
                OverlayKeys.decodeSegment(OverlayKeys.encodeSegment(segment)),
                segment,
                "segment did not round-trip: \(segment)"
            )
        }
    }

    func testFieldMemberAndMarkerKeysHaveTheirOwnShapes() {
        XCTAssertEqual(OverlayKeys.fieldKey(recordId: "r1", field: "title"), "r1/title")
        XCTAssertEqual(
            OverlayKeys.memberKey(recordId: "r1", field: "tags", member: "x"),
            "r1/tags/x"
        )
        XCTAssertEqual(
            OverlayKeys.markerKey(recordId: "r1", marker: OverlayKeys.markerReplace),
            "r1/_replace"
        )
        XCTAssertEqual(OverlayKeys.recordPrefix("r1"), "r1/")
    }

    // MARK: - Behavior 7 — parseOverlayKey's forms

    func testParseDistinguishesFieldMemberAndMarkerAndRefusesMalformed() throws {
        let field = try XCTUnwrap(OverlayKeys.parse("r1/title"))
        XCTAssertEqual(field.recordId, "r1")
        XCTAssertEqual(field.field, "title")
        XCTAssertNil(field.member)
        XCTAssertNil(field.marker)

        let member = try XCTUnwrap(OverlayKeys.parse("r1/tags/x"))
        XCTAssertEqual(member.field, "tags")
        XCTAssertEqual(member.member, "x")

        let marker = try XCTUnwrap(OverlayKeys.parse("r1/_deleted"))
        XCTAssertEqual(marker.marker, OverlayKeys.markerDeleted)
        XCTAssertNil(marker.field)

        // One segment is not a key, and neither is four.
        XCTAssertNil(OverlayKeys.parse("r1"))
        XCTAssertNil(OverlayKeys.parse("r1/a/b/c"))
    }

    /// E1 — a field genuinely NAMED `_replace` is a field, never the marker.
    func testAFieldNamedLikeAMarkerIsAFieldOnBothSides() throws {
        let key = OverlayKeys.fieldKey(recordId: "r1", field: "_replace")
        XCTAssertEqual(key, "r1/~2replace", "a leading underscore escapes to ~2")

        let parsed = try XCTUnwrap(OverlayKeys.parse(key))
        XCTAssertEqual(parsed.field, "_replace")
        XCTAssertNil(parsed.marker, "the escaped form must never read back as a marker")

        // And the marker itself, written unescaped, still reads as a marker.
        let asMarker = try XCTUnwrap(OverlayKeys.parse("r1/_replace"))
        XCTAssertEqual(asMarker.marker, OverlayKeys.markerReplace)
        XCTAssertNil(asMarker.field)
    }

    // MARK: - Behavior 7 — grouping

    func testGroupingRegathersFlatKeysIntoOneEntryPerRecord() throws {
        let grouped = OverlayKeys.group([
            ("r1/title", .string("hello")),
            ("r1/tags/a", .bool(true)),
            ("r1/tags/b", .bool(false)),
            ("r1/_replace", .bool(true)),
            ("r2/_deleted", .bool(true)),
            ("not-a-key", .string("ignored")),
        ])

        let r1 = try XCTUnwrap(grouped[ByteKey("r1")])
        XCTAssertEqual(r1.fields["title"], .string("hello"))
        XCTAssertEqual(r1.stringSets["tags"], ["a": true, "b": false])
        XCTAssertTrue(r1.replace)
        XCTAssertFalse(r1.deleted)

        let r2 = try XCTUnwrap(grouped[ByteKey("r2")])
        XCTAssertTrue(r2.deleted)

        XCTAssertEqual(grouped.count, 2, "a malformed key is skipped, not grouped")
    }

    /// Finding 3436-REV-09 — the grouping is keyed by the id's BYTES.
    ///
    /// Swift's `String` is equal under canonical equivalence, so two record
    /// ids the wire, SQLite and yrs all keep apart were ONE dictionary key
    /// here: one record's fields were merged into the other's, silently, with
    /// nothing downstream able to notice.
    func testTwoCanonicallyEquivalentRecordIdsStayTwoRecords() throws {
        let decomposed = "a\u{0301}"
        let precomposed = "\u{00E1}"
        XCTAssertEqual(decomposed, precomposed, "precondition: one Swift string")

        let grouped = OverlayKeys.group([
            ("\(decomposed)/title", .string("theirs")),
            ("\(precomposed)/title", .string("mine")),
        ])

        XCTAssertEqual(grouped.count, 2, "two keys on the wire are two records here")
        XCTAssertEqual(
            grouped[ByteKey(decomposed)]?.fields["title"], .string("theirs")
        )
        XCTAssertEqual(
            grouped[ByteKey(precomposed)]?.fields["title"], .string("mine")
        )
    }

    // MARK: - Behavior 7 — the create's marker order

    func testCreateEmitsReplaceThenClearsTheTombstoneBeforeAnyField() {
        let entries = OverlayKeys.encode(OverlayMutation(
            id: "r1",
            kind: .create,
            fields: ["title": .string("a")]
        ))

        XCTAssertEqual(entries.map(\.key).prefix(2), ["r1/_replace", "r1/_deleted"])
        XCTAssertEqual(entries[0].value, .bool(true))
        // A re-create must overwrite an earlier tombstone: under key-level
        // last-writer-wins a surviving `_deleted → true` would otherwise
        // outlive the re-created row.
        XCTAssertEqual(entries[1].value, .bool(false))
        XCTAssertEqual(entries[2].key, "r1/title")
    }

    func testDeleteEmitsOnlyTheTombstone() {
        let entries = OverlayKeys.encode(OverlayMutation(id: "r1", kind: .delete))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].key, "r1/_deleted")
        XCTAssertEqual(entries[0].value, .bool(true))
    }

    // MARK: - E5 — the table names

    func testTableNamesHexEncodeTheDocumentIdPerUtf16Unit() {
        // Per UTF-16 code unit, four hex digits each — which is what the JS
        // side produces, and what makes a database written by either client
        // readable on the other.
        XCTAssertEqual(
            Format2TableNames(documentId: "doc1").records,
            "records_f2_0064006f00630031"
        )
        XCTAssertEqual(
            Format2TableNames(documentId: "doc1").stringSetIndex,
            "stringset_index_f2_0064006f00630031"
        )
    }

    // MARK: - Parity with the TypeScript implementation

    func testEncodeMutationMatchesTheJavaScriptEncoderKeyForKey() throws {
        // Every shape that has ever been a source of drift in one mutation:
        // a marker-named field, a slash, a tilde, an explicit unset, a
        // stringset add AND a tombstone.
        let mutation = OverlayMutation(
            id: "r1",
            kind: .create,
            fields: [
                "title": .string("hello"),
                "_replace": .string("a field, not a marker"),
                "a/b": .number(1),
                "a~b": .bool(true),
                "cleared": .null,
            ],
            stringSetDeltas: ["tags": ["x": true, "y": false]]
        )

        let response = try Format2Harness.run([
            "command": "encode-mutation",
            "mutation": mutation.harnessJSON,
        ])
        let expected = try XCTUnwrap(response["entries"] as? [[Any]])

        let actual = OverlayKeys.encode(mutation)
        XCTAssertEqual(
            actual.count, expected.count,
            "Swift wrote \(actual.map(\.key)) where JS wrote \(expected.map { $0[0] })"
        )
        // Order matters for the first two: `_replace` then the tombstone
        // clear. The field keys' order follows the mutation's own field
        // order, so compare those as a SET.
        XCTAssertEqual(
            actual.prefix(2).map(\.key),
            expected.prefix(2).map { $0[0] as? String }
        )
        XCTAssertEqual(
            Set(actual.map(\.key)),
            Set(expected.compactMap { $0[0] as? String })
        )
        for entry in expected {
            let key = try XCTUnwrap(entry[0] as? String)
            let swiftValue = try XCTUnwrap(
                actual.first(where: { $0.key == key })?.value,
                "Swift wrote no entry for \(key)"
            )
            XCTAssertEqual(
                swiftValue, JSONValue(harness: entry[1]),
                "value differs for \(key)"
            )
        }
    }

    func testParseMatchesTheJavaScriptParserForEveryForm() throws {
        let keys = [
            "r1/title", "r1/tags/x", "r1/_replace", "r1/_deleted",
            "r1/~2replace", "r1/~2deleted", "r1/a~1b", "r1/a~0b",
            "r1", "r1/a/b/c", "", "/leading",
        ]
        let response = try Format2Harness.run(["command": "parse-key", "keys": keys])
        let parsedByJS = try XCTUnwrap(response["parsed"] as? [Any])

        for (index, key) in keys.enumerated() {
            let swift = OverlayKeys.parse(key)
            if parsedByJS[index] is NSNull {
                XCTAssertNil(swift, "JS refused \(key); Swift parsed it")
                continue
            }
            let js = try XCTUnwrap(parsedByJS[index] as? [String: Any], key)
            let swiftParsed = try XCTUnwrap(swift, "JS parsed \(key); Swift refused it")
            XCTAssertEqual(swiftParsed.recordId, js["recordId"] as? String, key)
            XCTAssertEqual(swiftParsed.field, js["field"] as? String, key)
            XCTAssertEqual(swiftParsed.member, js["member"] as? String, key)
            XCTAssertEqual(swiftParsed.marker, js["marker"] as? String, key)
        }
    }

    func testTableNamesMatchTheJavaScriptNamesIncludingANonAsciiDocumentId() throws {
        for documentId in ["doc1", "d", "dôc-ü", "文書", "01JABCDEF0123456789ABCDEFG"] {
            let response = try Format2Harness.run(["command": "ddl", "docId": documentId])
            let tables = try XCTUnwrap(response["tables"] as? [String: String])
            let swift = Format2TableNames(documentId: documentId)
            XCTAssertEqual(swift.records, tables["records"], documentId)
            XCTAssertEqual(swift.stringSetIndex, tables["stringSetIndex"], documentId)
        }
    }

    func testTheParityHarnessFailsRatherThanSkipsWhenNodeIsMissing() throws {
        // The guard itself: `Format2Harness.nodePath()` throws where
        // `CrossPlatformHarness.nodePath()` raises XCTSkip. A parity check
        // that silently skips is criterion 12 going unmeasured.
        XCTAssertNoThrow(try Format2Harness.nodePath())
    }
}
