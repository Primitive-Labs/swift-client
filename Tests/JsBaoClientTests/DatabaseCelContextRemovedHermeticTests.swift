import XCTest
@testable import JsBaoClient

/// The database CEL context is gone from the Swift client — #3991.
///
/// `DatabaseInfo` and `CreateDatabaseParams` carry no `metadata`/`celContext`,
/// and `CelContextResult` with the four CEL-context methods is removed.
/// Per-database values are resource metadata categories: `initialMetadata` on
/// create, `md.self.<category>.<key>` in rules.
///
/// Server-free: the database payload is decoded from the bytes the server now
/// sends, and the shapes are read by reflection, so a stray stored property is
/// caught whether or not anything still reads it.
final class DatabaseCelContextRemovedHermeticTests: XCTestCase {

    /// A database exactly as the server answers it after #3991.
    private static let payload = """
    {"databaseId":"db-1","title":"Notes","databaseType":"notes",
     "permission":"owner","createdBy":"u-1",
     "createdAt":"2026-09-30T00:00:00.000Z","modifiedAt":"2026-09-30T00:00:00.000Z"}
    """

    private static func labels(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label)
    }

    func testDatabaseInfoDecodesThePayloadWithoutAContextDict() throws {
        let info = try JSONDecoder().decode(DatabaseInfo.self, from: Data(Self.payload.utf8))

        XCTAssertEqual(info.databaseId, "db-1")
        XCTAssertEqual(info.title, "Notes")
        XCTAssertEqual(info.databaseType, "notes")
        XCTAssertEqual(info.permission, "owner")
        let labels = Self.labels(of: info)
        for retired in ["metadata", "celContext", "metadataStorage", "celContextStorage"] {
            XCTAssertFalse(labels.contains(retired), "DatabaseInfo still stores \(retired)")
        }
    }

    func testCreateDatabaseParamsCarriesOnlyInitialMetadata() throws {
        let params = CreateDatabaseParams(
            title: "Notes",
            databaseType: "notes",
            initialMetadata: ["settings": ["teamId": .string("t-1")]]
        )
        XCTAssertEqual(Self.labels(of: params).sorted(), ["databaseType", "initialMetadata", "title"])

        let data = try JSONEncoder().encode(params)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["metadata"])
        XCTAssertNil(object["celContext"])
        let initial = try XCTUnwrap(object["initialMetadata"] as? [String: Any])
        let settings = try XCTUnwrap(initial["settings"] as? [String: Any])
        XCTAssertEqual(settings["teamId"] as? String, "t-1")
    }

    /// The four methods are gone from the source of the API and its types.
    func testNoCelContextMethodOrResultTypeRemains() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/JsBaoClient")
        let api = try String(
            contentsOf: sources.appendingPathComponent("API/DatabasesAPI.swift"),
            encoding: .utf8
        )
        let types = try String(
            contentsOf: sources.appendingPathComponent("Types/DatabasesTypes.swift"),
            encoding: .utf8
        )
        for method in ["getCelContext", "updateCelContext", "getMetadata", "updateMetadata"] {
            XCTAssertFalse(api.contains("func \(method)("), "DatabasesAPI still declares \(method)")
        }
        XCTAssertFalse(types.contains("CelContextResult"))
        XCTAssertFalse(api.contains("CelContextResult"))
    }
}
