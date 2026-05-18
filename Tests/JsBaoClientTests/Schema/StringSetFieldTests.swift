import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests the end-to-end stringset data path: write a stringset value on
/// a record, read it back, confirm we see the same members. Also
/// confirms the wire shape is a nested Y.Map (not a Y.Array, not a JSON
/// string), matching js-bao's `StringSet` wire format.
final class StringSetFieldTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "articles_ss",
        fields: [
            "id":         FieldDescriptor(type: .id),
            "title":      FieldDescriptor(type: .string),
            "tags":       FieldDescriptor(type: .stringset, maxCount: 10),
            "categories": FieldDescriptor(type: .stringset, maxCount: 5),
        ]
    )

    // MARK: - Round-trip

    /// Set a stringset on create; reading the same record returns the
    /// same set. This is the load-bearing "stringset actually works"
    /// test — pre-fix, DynamicModel's read path returned nil for
    /// nested-map fields.
    func testStringSetRoundTripViaCreate() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        let record = try model.create(id: "a1", values: [
            "title": .string("hello"),
            "tags":  .stringset(["swift", "crdt", "yrs"]),
        ])
        XCTAssertEqual(record["tags"]?.asStringSet, ["swift", "crdt", "yrs"])

        // Independent read path — `find` returns a fresh PrimitiveRecord
        // that must also see the stringset.
        let fresh = model.find(id: "a1")
        XCTAssertEqual(fresh?["tags"]?.asStringSet, ["swift", "crdt", "yrs"])
    }

    /// Stringsets are stored as a NESTED Y.Map, not a JSON scalar. The
    /// inner map's keys ARE the set members; matches js-bao's
    /// `StringSet` on-disk shape.
    func testStringSetIsStoredAsNestedYMap() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "a1", values: [
            "tags": .stringset(["a", "b", "c"]),
        ])

        let keys: Set<String> = doc.transactSync { txn in
            guard let root = txn.transactionGetMap(name: "articles_ss"),
                  let rec  = root.getMap(tx: txn, key: "a1"),
                  let tags = rec.getMap(tx: txn, key: "tags") else { return [] }
            let collector = StringSetKeyCollector()
            tags.keys(tx: txn, delegate: collector)
            return Set(collector.keys)
        }
        XCTAssertEqual(keys, ["a", "b", "c"])
    }

    /// Subscript-set replaces the whole set — old members are purged.
    func testStringSetReplacementDropsOldMembers() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        let record = try model.create(id: "a1", values: [
            "tags": .stringset(["old1", "old2"]),
        ])

        record["tags"] = .stringset(["new"])
        XCTAssertEqual(record["tags"]?.asStringSet, ["new"])
    }

    /// An empty stringset is legal; reading it back returns an empty set.
    func testEmptyStringSet() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        let record = try model.create(id: "a1", values: [
            "tags": .stringset([]),
        ])
        XCTAssertEqual(record["tags"]?.asStringSet, [])
    }

    /// Multiple stringset fields on the same record are independent.
    func testMultipleStringSetFieldsAreIndependent() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "a1", values: [
            "tags":       .stringset(["red", "blue"]),
            "categories": .stringset(["tech"]),
        ])
        let r = model.find(id: "a1")
        XCTAssertEqual(r?["tags"]?.asStringSet, ["red", "blue"])
        XCTAssertEqual(r?["categories"]?.asStringSet, ["tech"])
    }

    /// Stringsets show up in `snapshot()` as `.stringset` values.
    func testSnapshotIncludesStringSets() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "a1", values: [
            "title": .string("hi"),
            "tags":  .stringset(["x", "y"]),
        ])
        let snap = model.find(id: "a1")?.snapshot()
        XCTAssertEqual(snap?["title"], .string("hi"))
        XCTAssertEqual(snap?["tags"], .stringset(["x", "y"]))
    }

    // MARK: - Infer-on-read of a stringset-shaped record

    /// A data map with no `_meta_*`, where a record has a nested Y.Map
    /// under some field, should be inferred as a stringset via the
    /// discovery fallback path.
    func testDiscoveryInfersStringSetFromNestedMap() throws {
        let doc = YDocument()
        SchemaSync.clearCache()

        doc.transactSync { txn in
            let items = txn.transactionGetOrInsertMap(name: "inferred_ss")
            let rec = items.getOrInsertMap(tx: txn, key: "r1")
            rec.insert(tx: txn, key: "title", value: "\"hi\"")
            let tags = rec.getOrInsertMap(tx: txn, key: "labels")
            tags.insert(tx: txn, key: "alpha",
                        value: PrimitiveValue.jsonEncodeString("alpha"))
        }

        let discovered = SchemaDiscovery.discoverSchema(
            doc: doc,
            modelNames: ["inferred_ss"]
        )
        XCTAssertEqual(discovered.models["inferred_ss"]?.fields["labels"]?.type,
                       .stringset)
        XCTAssertEqual(discovered.models["inferred_ss"]?.fields["title"]?.type,
                       .string)
    }

    // MARK: - Helpers

    private final class StringSetKeyCollector: YrsMapIteratorDelegate {
        var keys: [String] = []
        func call(value: String) { keys.append(value) }
    }
}
