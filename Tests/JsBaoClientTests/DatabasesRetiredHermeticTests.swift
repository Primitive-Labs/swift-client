import Foundation
import XCTest
@testable import JsBaoClient

/// The Swift client has no direct database surface (#3189, server-functions
/// phase 6).
///
/// `client.databases` — database lifecycle, the `DoDb` records handle,
/// permissions, group permissions, operation CRUD and change subscriptions —
/// is gone. Every `databases/*` route answers only an app admin or owner, so
/// an app reaches its records through a server function it invokes with
/// `client.functions`. `client.databaseTypeConfigs` stays for admin tooling,
/// without the retired `metadataAccess` key.
///
/// A member that is gone cannot be called to show it is gone, so the removals
/// are read off the comment-stripped sources (`ClientSourceText`), the
/// `PhaseFiveRetiredDoorsHermeticTests` shape. What survives is exercised.
final class DatabasesRetiredHermeticTests: XCTestCase {

    private static let retiredFiles = [
        "API/DatabasesAPI.swift",
        "API/DoDb.swift",
        "Types/DatabasesTypes.swift",
        "Types/DoDbTypes.swift",
        "Types/DatabaseOpsTypes.swift",
        "Internal/DatabaseSubscriptionRegistry.swift",
    ]

    func testTheDatabaseSourcesAreGone() {
        let sources = ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient")
        for file in Self.retiredFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sources.appendingPathComponent(file).path),
                "\(file) retired with client.databases"
            )
        }
    }

    func testTheClientHasNoDatabasesMember() throws {
        let client = try ClientSourceText.code("JsBaoClient.swift")
        XCTAssertFalse(client.contains("let databases:"), "client.databases retired")
        XCTAssertTrue(client.contains("let databaseTypeConfigs:"), "client.databaseTypeConfigs stays")
        // No inbound `db.*` routing and no reconnect re-subscribe.
        for frame in ["\"db.change\"", "\"db.subscribed\"", "\"db.unsubscribed\"", "resubscribeAll"] {
            XCTAssertFalse(client.contains(frame), "\(frame) left with database subscriptions")
        }
    }

    func testNoSourceDeclaresARetiredDatabaseType() throws {
        let sources = try ClientSourceText.allClientSources().map(ClientSourceText.stripComments)
        for declaration in [
            "class DatabasesAPI",
            "struct DoDb",
            "class DatabaseSubscriptionRegistry",
            "struct DatabaseInfo",
            "struct CreateDatabaseParams",
            "struct UpdateDatabaseParams",
            "struct DatabaseChangeEvent",
            "struct DatabaseSubscribeOptions",
            "struct DatabaseOperationInfo",
            "struct ModelFieldInfo",
            "struct ModelFieldsEnvelope",
            "\"db.subscribe\"",
        ] {
            XCTAssertFalse(
                sources.contains { $0.contains(declaration) },
                "\(declaration) belonged only to client.databases"
            )
        }
    }

    func testTypeConfigsCarryNoMetadataAccess() throws {
        let code = try ClientSourceText.code("Types/DatabaseTypeConfigsTypes.swift")
        XCTAssertFalse(code.contains("metadataAccess"), "metadataAccess retired (#3189)")
    }

    func testTypeConfigInfoStillDecodesAndIgnoresAStrayRetiredKey() throws {
        // A server older than phase 6 may still send the key; it is ignored.
        let json = #"""
        {"appId":"app1","databaseType":"userDB","ruleSetId":null,"triggers":null,
         "metadataAccess":"true","metadataManifest":null,
         "createdAt":"2026-10-08T00:00:00Z","modifiedAt":"2026-10-08T00:00:00Z","createdBy":"u1"}
        """#
        let info = try JSONDecoder().decode(DatabaseTypeConfigInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.databaseType, "userDB")
        let labels = Mirror(reflecting: info).children.compactMap(\.label)
        XCTAssertFalse(labels.contains { $0.lowercased().contains("metadataaccess") })
    }

    func testCreateTypeConfigParamsNeverSendTheRetiredKey() throws {
        let body = try JSONEncoder().encode(CreateDatabaseTypeConfigParams(databaseType: "userDB"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["databaseType"] as? String, "userDB")
        XCTAssertNil(object["metadataAccess"])
    }
}
