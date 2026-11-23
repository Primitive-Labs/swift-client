import XCTest
@testable import JsBaoClient

/// The Swift client's REST result types read permission levels as the app API
/// declares them (#6309, behaviors 13 and 14).
///
/// Each level a result type carries is an enum with the same members as the
/// JS client's union and the spec's `enum`, and a level this client does not
/// know decodes to `.unknown` with the string sent, rather than failing the
/// decode. `DocumentPermission.admin` and `Db3Permission.admin` are
/// deprecated, and a stored `"admin"` still decodes.
///
/// Server-free: these decode JSON fixtures.
final class PermissionLevelTypesHermeticTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Behavior 13: the level sets

    func testLevelEnumsDeclareTheSpecSets() {
        XCTAssertEqual(DocumentAccessLevel.allCases.map(\.rawValue), ["owner", "read-write", "reader"])
        XCTAssertEqual(DocumentGrantLevel.allCases.map(\.rawValue), ["read-write", "reader"])
        XCTAssertEqual(DatabaseAccessLevel.allCases.map(\.rawValue), ["owner", "manager"])
        XCTAssertEqual(CollectionAccessLevel.allCases.map(\.rawValue), ["reader", "read-write"])
    }

    func testEachKnownLevelDecodesAndAnUnknownOneIsKept() throws {
        for level in DocumentAccessLevel.allCases {
            XCTAssertEqual(try decode([DocumentAccessLevel].self, "[\"\(level.rawValue)\"]"), [level])
        }
        for level in DocumentGrantLevel.allCases {
            XCTAssertEqual(try decode([DocumentGrantLevel].self, "[\"\(level.rawValue)\"]"), [level])
        }
        for level in DatabaseAccessLevel.allCases {
            XCTAssertEqual(try decode([DatabaseAccessLevel].self, "[\"\(level.rawValue)\"]"), [level])
        }
        for level in CollectionAccessLevel.allCases {
            XCTAssertEqual(try decode([CollectionAccessLevel].self, "[\"\(level.rawValue)\"]"), [level])
        }
        XCTAssertEqual(try decode([DocumentAccessLevel].self, "[\"steward\"]"), [.unknown("steward")])
        XCTAssertEqual(try decode([DocumentGrantLevel].self, "[\"owner\"]"), [.unknown("owner")])
        XCTAssertEqual(try decode([DatabaseAccessLevel].self, "[\"viewer\"]"), [.unknown("viewer")])
        XCTAssertEqual(try decode([CollectionAccessLevel].self, "[\"editor\"]"), [.unknown("editor")])
        XCTAssertEqual(DocumentGrantLevel.unknown("later").rawValue, "later")
    }

    func testResultTypesDecodeTheirLevels() throws {
        let entry = try decode(DocumentGroupPermissionEntry.self, """
            {"documentId":"d","groupType":"team","groupId":"g","permission":"reader","grantedAt":"t","grantedBy":"u"}
            """)
        XCTAssertEqual(entry.permission, .reader)

        let pending = try decode(PendingInvitationEntry.self, """
            {"email":"a@b.c","permission":"read-write","invitationId":"i","createdAt":"t","expiresAt":"t"}
            """)
        XCTAssertEqual(pending.permission, .readWrite)

        let direct = try decode(DirectPermissionGrant.self, """
            {"status":"granted","userId":"u","permission":"reader"}
            """)
        XCTAssertEqual(direct.permission, .reader)

        let request = try decode(DocumentAccessRequest.self, """
            {"requestId":"r","documentId":"d","requesterId":"u","status":"approved",
             "requestedPermission":"reader","createdAt":"t","grantedPermission":"read-write"}
            """)
        XCTAssertEqual(request.requestedPermission, .reader)
        XCTAssertEqual(request.grantedPermission, .readWrite)

        let deferred = try decode(DeferredDocumentGrant.self, """
            {"deferredId":"x","type":"document","email":"a@b.c","documentId":"d","permission":"reader",
             "grantedBy":"u","createdAt":"t","expiresAt":"t"}
            """)
        XCTAssertEqual(deferred.permission, .reader)

        let groupDocument = try decode([GroupDocumentInfo].self, """
            [{"documentId":"d","createdBy":"u","createdAt":"t","lastModified":"t","permission":"owner"},
             {"documentId":"e","createdBy":"u","createdAt":"t","lastModified":"t","permission":null}]
            """)
        XCTAssertEqual(groupDocument.map(\.permission), [.owner, nil])

        let groupDatabase = try decode(GroupDatabaseInfo.self, """
            {"databaseId":"b","title":"T","databaseType":null,"createdBy":"u","createdAt":"t","modifiedAt":"t",
             "permission":"manager"}
            """)
        XCTAssertEqual(groupDatabase.permission, .manager)

        let member = try decode(CollectionMemberInfo.self, """
            {"userId":"u","permission":"read-write","role":"editor","addedAt":null,"addedBy":"o"}
            """)
        XCTAssertEqual(member.levelForTest, .readWrite)
    }

    /// The document, link-access and collection results that read a level
    /// through an enum of their own carry the spec's set, and a level this
    /// client does not know decodes through the result itself as `.unknown`.
    func testDocumentLinkAndCollectionResultsKeepAnUnknownLevel() throws {
        XCTAssertEqual(DocumentLinkAccessLevel.allCases.map(\.rawValue), ["reader", "read-write"])

        let info = try decode([DocumentInfo].self, """
            [{"documentId":"d","permission":"owner","linkAccess":"read-write"},
             {"documentId":"e","permission":"steward","linkAccess":"commenter"}]
            """)
        XCTAssertEqual(info.map(\.permission), [.owner, .unknown("steward")])
        XCTAssertEqual(info.map(\.linkAccess), [.readWrite, .unknown("commenter")])

        let entries = try decode([DocumentPermissionEntry].self, """
            [{"userId":"u","email":"a@b.c","permission":"read-write","grantedAt":"t"},
             {"userId":"v","email":"b@b.c","permission":"steward","grantedAt":"t"}]
            """)
        XCTAssertEqual(entries.map(\.permission), [.readWrite, .unknown("steward")])

        let access = try decode([DocumentAccessResult].self, """
            [{"success":true,"hasAccess":true,"permission":"reader"},
             {"success":true,"hasAccess":true,"permission":"steward"},
             {"success":true,"hasAccess":false}]
            """)
        XCTAssertEqual(access.map(\.permission), [.reader, .unknown("steward"), nil])

        let link = try decode([LinkAccessResult].self, """
            [{"documentId":"d","linkAccess":"reader"},{"documentId":"d","linkAccess":"commenter"},
             {"documentId":"d","linkAccess":null}]
            """)
        XCTAssertEqual(link.map(\.linkAccess), [.reader, .unknown("commenter"), nil])

        let collectionDocuments = try decode([CollectionDocumentInfo].self, """
            [{"documentId":"d","collectionId":"c","addedBy":"u","permission":"owner"},
             {"documentId":"e","collectionId":"c","addedBy":"u","permission":"steward"}]
            """)
        XCTAssertEqual(collectionDocuments.map(\.permission), [.owner, .unknown("steward")])

        let pending = try decode([PendingCollectionInvitationEntry].self, """
            [{"email":"a@b.c","permission":"reader","invitationId":"i","createdAt":"t","expiresAt":"t"},
             {"email":"a@b.c","permission":"commenter","invitationId":"i","createdAt":"t","expiresAt":"t"}]
            """)
        XCTAssertEqual(pending.map(\.levelForTest), ["reader", "commenter"])
    }

    /// `db3.get` and the db3 listings answer a `Db3Info` whose level is the
    /// document set: each known level decodes, an unknown one is kept as
    /// `.unknown` instead of failing the decode, and an absent one is `nil`.
    func testDb3InfoReadsTheDocumentLevelsAndKeepsAnUnknownOne() throws {
        let rows = try decode([Db3Info].self, """
            [{"id":"a","permission":"owner"},{"id":"b","permission":"read-write"},
             {"id":"c","permission":"reader"},{"id":"d","permission":"steward"},
             {"id":"e","permission":"admin"},{"id":"f"}]
            """)
        XCTAssertEqual(rows.map(\.permission), [.owner, .readWrite, .reader, .unknown("steward"), .unknown("admin"), nil])
        let level: DocumentAccessLevel? = rows[0].permission
        XCTAssertEqual(level, .owner)
    }

    func testASwitchOverEachLevelCompilesWithoutADefault() {
        func name(_ level: DocumentAccessLevel) -> String {
            switch level {
            case .owner: return "owner"
            case .readWrite: return "editor"
            case .reader: return "viewer"
            case .unknown(let raw): return raw
            }
        }
        func name(_ level: DocumentGrantLevel) -> String {
            switch level {
            case .readWrite: return "editor"
            case .reader: return "viewer"
            case .unknown(let raw): return raw
            }
        }
        func name(_ level: DatabaseAccessLevel) -> String {
            switch level {
            case .owner: return "owner"
            case .manager: return "manager"
            case .unknown(let raw): return raw
            }
        }
        func name(_ level: DocumentLinkAccessLevel) -> String {
            switch level {
            case .reader: return "viewer"
            case .readWrite: return "editor"
            case .unknown(let raw): return raw
            }
        }
        func name(_ level: CollectionAccessLevel) -> String {
            switch level {
            case .reader: return "viewer"
            case .readWrite: return "editor"
            case .unknown(let raw): return raw
            }
        }
        XCTAssertEqual(name(DocumentAccessLevel.readWrite), "editor")
        XCTAssertEqual(name(DocumentGrantLevel.unknown("x")), "x")
        XCTAssertEqual(name(DatabaseAccessLevel.manager), "manager")
        XCTAssertEqual(name(CollectionAccessLevel.reader), "viewer")
        XCTAssertEqual(name(DocumentLinkAccessLevel.readWrite), "editor")
    }

    // MARK: Behavior 14: admin is deprecated and still decodes

    func testAStoredAdminStillDecodes() throws {
        let decoded = try decode([DocumentPermission].self, "[\"admin\"]")
        XCTAssertEqual(decoded.map(\.rawValue), ["admin"])
        XCTAssertEqual(Db3Permission(rawValue: "admin")?.rawValue, "admin")
    }

    func testAdminCasesCarryTheDeprecation() throws {
        let types = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/JsBaoClient/Types")
        for (file, enumName) in [("Events.swift", "DocumentPermission"), ("Db3Events.swift", "Db3Permission")] {
            let source = try String(contentsOf: types.appendingPathComponent(file), encoding: .utf8)
            let body = source.components(separatedBy: "public enum \(enumName):")[1]
                .components(separatedBy: "\n}")[0]
            let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let admin = try XCTUnwrap(lines.firstIndex(of: "case admin"), "\(enumName) has no admin case")
            XCTAssertTrue(lines[admin - 1].hasPrefix("@available(*, deprecated"), "\(enumName).admin is not deprecated")
        }
    }
}

private extension CollectionMemberInfo {
    /// The deprecated `permission`, read by reflection so the test compiles without a deprecation warning.
    var levelForTest: CollectionAccessLevel {
        Mirror(reflecting: self).children.first { $0.label == "permission" }?.value as! CollectionAccessLevel
    }
}

private extension PendingCollectionInvitationEntry {
    /// The deprecated `permission`'s wire string, read by reflection so the test compiles without a deprecation warning.
    var levelForTest: String? {
        (Mirror(reflecting: self).children.first { $0.label == "permission" }?.value as? any RawRepresentable)?
            .rawValue as? String
    }
}
