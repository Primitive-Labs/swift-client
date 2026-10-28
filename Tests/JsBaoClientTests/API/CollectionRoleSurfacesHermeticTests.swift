import XCTest
@testable import JsBaoClient

/// Collections on the role model from Swift (#4737, project
/// `role-based-groups-collections` phase 3): members as principals with
/// roles, groups as members, role changes, transfer, `resolveRole` and
/// `settings`. Each wire pin mirrors the JS client's route for the same call.
///
/// Server-free, like `RoleSurfacesHermeticTests`: a `RecordingTransport`
/// captures the request; decode pins use inline JSON. Pins of a deprecated
/// label or field live in test methods marked `@available(*, deprecated)`.
final class CollectionRoleSurfacesHermeticTests: XCTestCase {

    private static let collection = """
    {"collectionId":"c1","appId":"a1","name":"Shelf","collectionType":"default","documentCount":0,
     "custodian":"user:u1","settings":{"memberList":"managers"},"role":"owner",
     "createdAt":"2026-01-01T00:00:00Z","createdBy":"u1","modifiedAt":"2026-01-01T00:00:00Z"}
    """

    private func collections(_ json: String) -> (CollectionsAPI, RecordingTransport) {
        let transport = RecordingTransport(json: json)
        return (CollectionsAPI(transport: transport), transport)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    // MARK: - Behavior 17: members as principals

    func testListMembersAnswersUsersAndGroupsAsPrincipals() async throws {
        let (api, transport) = collections("""
        {"items":[
          {"principal":"u1","userId":"u1","role":"owner","permission":"read-write",
           "addedAt":"2026-01-01T00:00:00Z","addedBy":"u1"},
          {"principal":"group:g1","groupId":"g1","groupType":"group","role":"manager",
           "permission":"read-write","addedAt":"2026-01-01T00:00:00Z","addedBy":"u1"}
        ],"hasMore":false}
        """)
        let members = try await api.listMembers(collectionId: "c1")
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/collections/c1/members")
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0].principal, "u1")
        XCTAssertEqual(members[0].userId, "u1")
        XCTAssertNil(members[0].groupId)
        XCTAssertEqual(members[0].role, .owner)
        XCTAssertEqual(members[1].principal, "group:g1")
        XCTAssertEqual(members[1].groupId, "g1")
        XCTAssertNil(members[1].userId)
        XCTAssertEqual(members[1].role, .manager)
    }

    // MARK: - Behavior 18 and E5: adding a user with a role

    func testAddMemberSendsTheRoleAndNoPermission() async throws {
        let (api, transport) = collections("""
        {"status":"added","userId":"u2","principal":"u2","role":"viewer","permission":"reader",
         "addedAt":"2026-01-01T00:00:00Z","addedBy":"u1"}
        """)
        let added = try await api.addMember(collectionId: "c1", params: .user("u2", role: .viewer))
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/collections/c1/members")
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["userId": .string("u2"), "role": .string("viewer")]))
        guard case let .direct(direct) = added else { return XCTFail("expected a direct add") }
        XCTAssertEqual(direct.role, .viewer)
        XCTAssertEqual(direct.principal, "u2")

        let byEmail = AddCollectionMemberParams.email(
            "e@example.com", role: .editor, sendEmail: true,
            collectionUrl: "https://example.com/c1", note: "Welcome"
        )
        XCTAssertEqual(try encoded(byEmail), .object([
            "email": .string("e@example.com"), "role": .string("editor"), "sendEmail": .bool(true),
            "collectionUrl": .string("https://example.com/c1"), "note": .string("Welcome"),
        ]))
    }

    @available(*, deprecated)
    func testAddResultsDecodeTheRoleBesidePermission() throws {
        let direct = try decode(CollectionAddMemberResult.self, """
        {"status":"added","userId":"u2","principal":"u2","role":"editor","permission":"read-write",
         "addedAt":"2026-01-01T00:00:00Z","addedBy":"u1"}
        """)
        guard case let .direct(row) = direct else { return XCTFail("expected a direct add") }
        XCTAssertEqual(row.role, .editor)
        XCTAssertEqual(row.permission, .readWrite)

        let deferred = try decode(CollectionAddMemberResult.self, """
        {"status":"pending_signup","email":"e@example.com","role":"viewer","permission":"reader",
         "appInvitationCreated":true,"deferredId":"d1","expiresAt":"2026-02-01T00:00:00Z",
         "collectionId":"c1","invitationId":"i1","inviteToken":null}
        """)
        guard case let .deferred(pending) = deferred else { return XCTFail("expected a deferred add") }
        XCTAssertEqual(pending.role, .viewer)
        XCTAssertEqual(pending.permission, .reader)

        // E5: a body from before roles decodes with no role and no principal.
        let old = try decode(DirectCollectionAdd.self, """
        {"status":"added","userId":"u2","permission":"reader","addedAt":"2026-01-01T00:00:00Z","addedBy":"u1"}
        """)
        XCTAssertNil(old.role)
        XCTAssertNil(old.principal)
        XCTAssertEqual(old.permission, .reader)
    }

    @available(*, deprecated)
    func testPermissionFactoriesStillSendPermission() throws {
        XCTAssertEqual(
            try encoded(AddCollectionMemberParams.user("u2", permission: .readWrite)),
            .object(["userId": .string("u2"), "permission": .string("read-write")])
        )
    }

    // MARK: - Behavior 19: a group as a member

    func testAddGroupMemberPostsTheGroupAndRole() async throws {
        let (api, transport) = collections("""
        {"status":"added","principal":"group:g1","groupId":"g1","groupType":"group","role":"manager",
         "permission":"read-write","addedAt":"2026-01-01T00:00:00Z","addedBy":"u1"}
        """)
        let added = try await api.addGroupMember(collectionId: "c1", groupId: "g1", role: .manager)
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/collections/c1/members")
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["groupId": .string("g1"), "role": .string("manager")]))
        XCTAssertEqual(added.status, "added")
        XCTAssertEqual(added.principal, "group:g1")
        XCTAssertEqual(added.groupId, "g1")
        XCTAssertEqual(added.role, .manager)
    }

    // MARK: - Behavior 20 and E7: a principal's role and removal

    func testSetMemberRoleAndRemoveMemberAddressThePrincipal() async throws {
        let (api, transport) = collections("""
        {"principal":"group:g1","groupId":"g1","role":"viewer","permission":"reader"}
        """)
        let changed = try await api.setMemberRole(collectionId: "c1", principal: "group:g1", role: .viewer)
        XCTAssertEqual(transport.lastCall?.method, .patch)
        XCTAssertEqual(transport.lastCall?.path, "/collections/c1/members/group%3Ag1")
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["role": .string("viewer")]))
        XCTAssertEqual(changed.role, .viewer)

        _ = try await api.setMemberRole(collectionId: "c1", principal: "group:a b", role: .editor)
        XCTAssertEqual(transport.lastCall?.path, "/collections/c1/members/group%3Aa%20b")

        let (remover, removes) = collections(#"{"success":true}"#)
        _ = try await remover.removeMember(collectionId: "c1", principal: "group:g1")
        XCTAssertEqual(removes.lastCall?.method, .delete)
        XCTAssertEqual(removes.lastCall?.path, "/collections/c1/members/group%3Ag1")
        _ = try await remover.removeMember(collectionId: "c1", principal: "user id")
        XCTAssertEqual(removes.lastCall?.path, "/collections/c1/members/user%20id")
    }

    // MARK: - Behavior 21 and E6: transfer and resolveRole

    func testTransferPostsTheNewCustodian() async throws {
        let (api, transport) = collections(Self.collection)
        let moved = try await api.transfer(collectionId: "c1", to: "user:u2")
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/collections/c1/transfer")
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["to": .string("user:u2")]))
        XCTAssertEqual(moved.custodian, "user:u1")
    }

    func testResolveRoleAsksForTheCallerOrANamedUser() async throws {
        let (api, transport) = collections(#"{"role":"editor","source":"direct"}"#)
        let mine = try await api.resolveRole(collectionId: "c1")
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/collections/c1/role")
        XCTAssertEqual(mine, ResolvedCollectionRole(role: .editor, source: .direct))

        _ = try await api.resolveRole(collectionId: "c1", userId: "u 2")
        XCTAssertEqual(transport.lastCall?.path, "/collections/c1/role?userId=u%202")
    }

    func testResolvedRoleDecodesEachSource() throws {
        XCTAssertEqual(
            try decode(ResolvedCollectionRole.self, #"{"role":"viewer","source":{"groupId":"g1"}}"#),
            ResolvedCollectionRole(role: .viewer, source: .group(groupId: "g1"))
        )
        let none = try decode(ResolvedCollectionRole.self, #"{"role":null}"#)
        XCTAssertNil(none.role)
        XCTAssertNil(none.source)
        XCTAssertThrowsError(try decode(ResolvedCollectionRole.self, #"{"role":"viewer","source":"inherited"}"#))
        XCTAssertThrowsError(try decode(ResolvedCollectionRole.self, #"{"role":"viewer","source":{"userId":"u1"}}"#))
    }

    // MARK: - Behavior 22 and E4: custodian, settings and role on the collection

    func testCollectionInfoDecodesCustodySettingsAndRole() throws {
        let held = try decode(CollectionInfo.self, Self.collection)
        XCTAssertEqual(held.custodian, "user:u1")
        XCTAssertEqual(held.settings, ResourceSettings(memberList: .managers))
        XCTAssertEqual(held.role, .owner)

        let old = try decode(CollectionInfo.self, """
        {"collectionId":"c1","appId":"a1","name":"Shelf","collectionType":"default","documentCount":0,
         "createdAt":"2026-01-01T00:00:00Z","createdBy":"u1","modifiedAt":"2026-01-01T00:00:00Z"}
        """)
        XCTAssertNil(old.custodian)
        XCTAssertNil(old.settings)
        XCTAssertNil(old.role)
    }

    func testCreateAndUpdateSendSettingsAndNoCollectionType() async throws {
        let (api, transport) = collections(Self.collection)
        _ = try await api.create(params: CreateCollectionParams(
            name: "Shelf", settings: ResourceSettings(memberList: .managers)
        ))
        XCTAssertEqual(transport.lastCall?.path, "/collections")
        XCTAssertEqual(transport.lastCall?.jsonBody, .object([
            "name": .string("Shelf"), "settings": .object(["memberList": .string("managers")]),
        ]))
        _ = try await api.create(params: CreateCollectionParams(name: "Plain"))
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["name": .string("Plain")]))

        _ = try await api.update(
            collectionId: "c1", params: UpdateCollectionParams(settings: ResourceSettings(memberList: .members))
        )
        XCTAssertEqual(transport.lastCall?.method, .patch)
        XCTAssertEqual(
            transport.lastCall?.jsonBody,
            .object(["settings": .object(["memberList": .string("members")])])
        )
    }

    @available(*, deprecated)
    func testTypedCreateStillSendsCollectionType() throws {
        let params = CreateCollectionParams(name: "Typed", collectionType: "default")
        XCTAssertEqual(params.collectionType, "default")
        XCTAssertEqual(try encoded(params), .object([
            "name": .string("Typed"), "collectionType": .string("default"),
        ]))
    }

    // MARK: - Behavior 23: the compatibility surface, deprecated

    @available(*, deprecated)
    func testAccessStillDecodesWithRoles() async throws {
        let (api, transport) = collections("""
        {"groups":[{"collectionId":"c1","groupType":"group","groupId":"g1","permission":"reader",
                    "role":"viewer","grantedAt":"2026-01-01T00:00:00Z","grantedBy":"u1"}],
         "members":[{"userId":"u1","permission":"read-write","role":"owner",
                     "addedAt":"2026-01-01T00:00:00Z","addedBy":"u1"}]}
        """)
        let access = try await api.getAccess(collectionId: "c1")
        XCTAssertEqual(transport.lastCall?.path, "/collections/c1/access")
        XCTAssertEqual(access.groups.first?.role, .viewer)
        XCTAssertEqual(access.groups.first?.groupType, "group")
        XCTAssertEqual(access.members.first?.role, .owner)
        XCTAssertEqual(access.members.first?.permission, "read-write")

        let (remover, removes) = collections(#"{"success":true}"#)
        _ = try await remover.removeMember(collectionId: "c1", userId: "u2")
        XCTAssertEqual(removes.lastCall?.path, "/collections/c1/members/u2")
        _ = try await remover.revokeGroupPermission(collectionId: "c1", groupType: "group", groupId: "g1")
        XCTAssertEqual(removes.lastCall?.path, "/collections/c1/group-permissions/group/g1")
    }

    /// The labels, inits and fields the JS client deprecates are deprecated
    /// here too, naming the removal issue.
    func testCompatibilitySurfaceIsDeprecatedNamingTheRemovalIssue() throws {
        let declarations = RoleSurfacesHermeticTests.declarations
        let isDeprecated = RoleSurfacesHermeticTests.isDeprecatedFor4718
        let api = try ClientSourceText.code("API/CollectionsAPI.swift")
        for pattern in [
            #"public func getAccess\("#,
            #"public func grantGroupPermission\("#,
            #"public func revokeGroupPermission\("#,
            #"public func removeMember\(collectionId: String, userId:"#,
        ] {
            let found = declarations(api, pattern)
            XCTAssertEqual(found.count, 1, "\(pattern) not declared once")
            XCTAssertTrue(found.allSatisfy { isDeprecated($0.attributes) }, "\(pattern) is not deprecated naming #4718")
        }

        let types = try ClientSourceText.code("Types/CollectionsTypes.swift")
        let typePatterns: [(String, Int)] = [
            (#"public enum CollectionPermission\b"#, 1),
            (#"public struct GrantCollectionGroupPermissionParams\b"#, 1),
            (#"static func user\(\s*_ userId: String,\s*permission:"#, 1),
            (#"static func email\(\s*_ email: String,\s*permission:"#, 1),
            (#"public init\(\s*userId: String\? = nil,\s*email: String\? = nil,\s*permission:"#, 1),
            (#"public init\(\s*name: String,\s*description: String\? = nil,\s*collectionType:"#, 1),
        ]
        for (pattern, count) in typePatterns {
            let found = declarations(types, pattern)
            XCTAssertEqual(found.count, count, "\(pattern) declared \(found.count) times")
            for (decl, attributes) in found {
                XCTAssertTrue(isDeprecated(attributes), "\(decl) is not deprecated naming #4718")
            }
        }

        // The compatibility fields, each read inside the struct that declares it.
        let fields: [(String, [String])] = [
            ("CollectionInfo", ["collectionType", "permission"]),
            ("CreateCollectionParams", ["collectionType"]),
            ("CollectionGroupPermissionInfo", ["groupType", "permission"]),
            ("CollectionMemberInfo", ["permission", "addedBy"]),
            ("PendingCollectionInvitationEntry", ["permission"]),
            ("AddCollectionMemberParams", ["permission"]),
            ("DirectCollectionAdd", ["permission", "addedBy"]),
            ("DeferredCollectionAdd", ["permission"]),
            ("CollectionGroupMemberAdd", ["groupType", "permission", "addedBy"]),
            ("CollectionMemberEntry", ["groupType", "permission", "addedBy"]),
        ]
        for (type, names) in fields {
            let body = try ClientSourceText.slice(types, from: "public struct \(type):", to: "\n}\n")
            for name in names {
                let found = declarations(body, #"public (let|var) \#(name):"#)
                XCTAssertEqual(found.count, 1, "\(type).\(name) not declared once")
                XCTAssertTrue(found.allSatisfy { isDeprecated($0.attributes) }, "\(type).\(name) is not deprecated naming #4718")
            }
        }
        // Not compatibility: these stay undeprecated, as in the JS client.
        for (type, name) in [("PendingCollectionInvitationEntry", "addedBy"), ("CollectionDocumentInfo", "addedBy")] {
            let body = try ClientSourceText.slice(types, from: "public struct \(type):", to: "\n}\n")
            let found = declarations(body, #"public let \#(name):"#)
            XCTAssertEqual(found.count, 1, "\(type).\(name) not declared once")
            XCTAssertFalse(found.contains { $0.attributes.contains("deprecated") }, "\(type).\(name) is deprecated")
        }
    }
}
