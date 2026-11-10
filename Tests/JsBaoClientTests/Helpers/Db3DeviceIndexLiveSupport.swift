import XCTest
@testable import JsBaoClient

/// The live fixture of the device-index suites (#5223), js-bao's
/// `db3-device-text-index-5222.test.ts` rows: a `Note` with titles, bodies,
/// a rank and two string sets.
enum Db3DeviceIndexLiveFixture {
    static let note = PrimitiveSchema(name: "Note", fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "body": FieldDescriptor(type: .string),
        "rank": FieldDescriptor(type: .number), "tags": FieldDescriptor(type: .stringset), "labels": FieldDescriptor(type: .stringset),
    ])

    static let rows: [(title: String, body: String, tags: Set<String>, labels: Set<String>)] = [
        ("Red apple pie", "a sweet apple dessert", ["fruit", "sweet"], ["a"]),
        ("Green apple", "tart and crisp", ["fruit"], ["a", "b"]),
        ("Apple apple apple", "nothing else", ["fruit", "odd"], ["b"]),
        ("Pear tart", "pears and apples baked", ["fruit", "sweet"], []),
        ("Running notes", "notes about runners", ["sport"], ["c"]),
    ]

    /// A db3 of `live`'s, subscribed by a new client `name` (over `file` when given, logging at `logLevel` from
    /// before it subscribes when given), the rows written when `write`.
    static func subscribed(
        _ live: RecordLogLiveApp, _ name: String, documentId: String? = nil, file: String? = nil, write: Bool = true,
        logLevel: LogLevel? = nil
    ) async throws -> (client: JsBaoClient, id: String) {
        let id: String
        if let documentId { id = documentId } else { id = try await live.db3Written(0, model: "Note") }
        let client = try await live.client(name, models: [note], file: file)
        if let logLevel { client.setLogLevel(logLevel) }
        try await client.db3.subscribe(id).ready()
        if write {
            for row in rows {
                try await client.codegen.save(note, id: RecordLogLiveApp.ulid(), values: [
                    "title": .string(row.title), "body": .string(row.body), "rank": .number(Double(row.title.count)),
                    "tags": .stringset(row.tags), "labels": .stringset(row.labels),
                ], in: id, confirm: true)
            }
        }
        return (client, id)
    }

    /// The names of `type` objects of `client`'s store for `documentId` named like `pattern`.
    static func objects(_ live: RecordLogLiveApp, _ client: JsBaoClient, _ documentId: String, _ type: String, like pattern: String) throws -> [String] {
        try live.binding(client, documentId).store.readView { sql in
            try sql.rows(
                "SELECT name FROM sqlite_master WHERE type = ? AND name LIKE ? ESCAPE '\\' AND (type = 'trigger' OR sql LIKE 'CREATE%TABLE%') ORDER BY name",
                [.text(type), .text(pattern)]
            ).compactMap { $0["name"].stringValue }.filter { !$0.hasSuffix("_data") && !$0.hasSuffix("_idx") && !$0.hasSuffix("_config") && !$0.hasSuffix("_docsize") && !$0.hasSuffix("_content") }
        }
    }
}
