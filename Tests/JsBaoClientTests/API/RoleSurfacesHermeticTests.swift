import XCTest
@testable import JsBaoClient

/// The Swift client on the role model (#4737, project
/// `role-based-groups-collections` phase 3): groups addressed by `groupId`
/// alone, roles, custodian, `settings`, transfer, and document group grants
/// by id. Each wire pin mirrors the JS client's route for the same call.
///
/// Server-free: a `RecordingTransport` captures the request and answers a
/// canned body; decode pins use inline JSON. Pins of a deprecated label live
/// in test methods marked `@available(*, deprecated)`.
final class RoleSurfacesHermeticTests: XCTestCase {

    private static let group = """
    {"appId":"a1","groupType":"group","groupId":"g 1","name":"Team",
     "memberCount":1,"custodian":"user:u1","settings":{"memberList":"members"},
     "createdAt":"2026-01-01T00:00:00Z","createdBy":"u1","modifiedAt":"2026-01-01T00:00:00Z"}
    """

    private func groups(_ json: String) -> (GroupsAPI, RecordingTransport) {
        let transport = RecordingTransport(json: json)
        return (GroupsAPI(transport: transport), transport)
    }

    private func documents(_ transport: RecordingTransport) -> DocumentsAPI {
        DocumentsAPI(
            transport: transport,
            blobManager: BlobManager(
                logger: createLogger(level: .error, scope: "test"),
                uploadConcurrency: 1
            )
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Behavior 1: get / update / delete by id

    func testGetUpdateDeleteAddressTheGroupById() async throws {
        let (api, transport) = groups(Self.group)

        let fetched = try await api.get(groupId: "g 1")
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/groups/g%201")
        XCTAssertEqual(fetched.groupId, "g 1")

        _ = try await api.update(
            groupId: "g 1",
            params: UpdateGroupParams(settings: ResourceSettings(memberList: .managers))
        )
        XCTAssertEqual(transport.lastCall?.method, .patch)
        XCTAssertEqual(transport.lastCall?.path, "/groups/g%201")
        XCTAssertEqual(
            transport.lastCall?.jsonBody,
            .object(["settings": .object(["memberList": .string("managers")])])
        )

        _ = try await api.update(groupId: "g 1", params: UpdateGroupParams(name: "Renamed"))
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["name": .string("Renamed")]))

        let (deleter, deletes) = groups(#"{"success":true}"#)
        let deleted = try await deleter.delete(groupId: "g 1")
        XCTAssertEqual(deletes.lastCall?.method, .delete)
        XCTAssertEqual(deletes.lastCall?.path, "/groups/g%201")
        XCTAssertTrue(deleted.success)
    }

    // MARK: - Behavior 2: the group's lists by id

    func testListsAddressTheGroupById() async throws {
        let (api, transport) = groups("""
        {"items":[{"userId":"u1","role":"owner","addedAt":"2026-01-01T00:00:00Z","addedBy":"u1"},
                  {"userId":"u2","role":"member","addedBy":"u1"}],"hasMore":false}
        """)
        let members = try await api.listMembers(
            groupId: "g1", options: PaginationOptions(limit: 50, cursor: "a+b c"), include: .profiles
        )
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/groups/g1/members?limit=50&cursor=a%2Bb%20c&include=profiles")
        XCTAssertEqual(members.items.map(\.role), ["owner", "member"])

        _ = try await api.listMembers(groupId: "g1")
        XCTAssertEqual(transport.lastCall?.path, "/groups/g1/members")

        let (pendingAPI, pending) = groups(#"{"items":[]}"#)
        _ = try await pendingAPI.listPendingInvitations(groupId: "g1")
        XCTAssertEqual(pending.lastCall?.path, "/groups/g1/pending-invitations")

        let (listAPI, lists) = groups("[]")
        _ = try await listAPI.listDocuments(groupId: "g1")
        XCTAssertEqual(lists.lastCall?.path, "/groups/g1/documents")
        _ = try await listAPI.listDatabases(groupId: "g1")
        XCTAssertEqual(lists.lastCall?.path, "/groups/g1/databases")
    }

    // MARK: - Behavior 3 and E2: addMember with a role

    func testAddMemberSendsTheRoleOnlyWhenSet() async throws {
        let (api, transport) = groups("""
        {"status":"added","userId":"u2","role":"manager","addedAt":"2026-01-01T00:00:00Z","addedBy":"u1"}
        """)
        let added = try await api.addMember(groupId: "g1", params: .userId("u2", role: .manager))
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/groups/g1/members")
        XCTAssertEqual(
            transport.lastCall?.jsonBody,
            .object(["userId": .string("u2"), "role": .string("manager")])
        )
        guard case let .direct(direct) = added else { return XCTFail("expected a direct add") }
        XCTAssertEqual(direct.role, .manager)

        _ = try await api.addMember(groupId: "g1", params: .email("e@example.com"))
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["email": .string("e@example.com")]))
    }

    func testAddMemberParamsEncodeTheRoleBesideTheIdentifier() throws {
        let byId = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(AddGroupMemberParams.userId("u"))
        )
        XCTAssertEqual(byId, .object(["userId": .string("u")]))
        let byEmail = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(AddGroupMemberParams.email("e", role: .member))
        )
        XCTAssertEqual(byEmail, .object(["email": .string("e"), "role": .string("member")]))
    }

    func testDeferredAddDecodesItsRole() throws {
        let result = try decode(GroupAddMemberResult.self, """
        {"status":"pending_signup","email":"e@example.com","appInvitationCreated":true,
         "deferredId":"d1","expiresAt":"2026-02-01T00:00:00Z","groupType":"group","groupId":"g1",
         "role":"member","invitationId":"i1","inviteToken":null}
        """)
        guard case let .deferred(deferred) = result else { return XCTFail("expected a deferred add") }
        XCTAssertEqual(deferred.role, .member)
    }

    // MARK: - Behavior 4: remove by id

    func testRemoveMemberAddressesTheGroupById() async throws {
        let (api, transport) = groups(#"{"success":true}"#)
        _ = try await api.removeMember(groupId: "g1", userId: "user id#7")
        XCTAssertEqual(transport.lastCall?.method, .delete)
        XCTAssertEqual(transport.lastCall?.path, "/groups/g1/members/user%20id%237")

        _ = try await api.removeMemberByEmail(groupId: "g1", email: "a+b@x.com")
        XCTAssertEqual(transport.lastCall?.method, .delete)
        XCTAssertEqual(transport.lastCall?.path, "/groups/g1/members?email=a%2Bb%40x.com")
    }

    // MARK: - Behavior 5: transfer and setMemberRole

    func testTransferPostsTheNewCustodian() async throws {
        let (api, transport) = groups(Self.group)
        let moved = try await api.transfer(groupId: "g 1", to: "user:u2")
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/groups/g%201/transfer")
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["to": .string("user:u2")]))
        XCTAssertEqual(moved.custodian, "user:u1")
    }

    func testSetMemberRolePatchesTheRole() async throws {
        let (api, transport) = groups(#"{"userId":"u2","role":"manager","addedBy":"u1"}"#)
        let changed = try await api.setMemberRole(groupId: "g1", userId: "u 2", role: .manager)
        XCTAssertEqual(transport.lastCall?.method, .patch)
        XCTAssertEqual(transport.lastCall?.path, "/groups/g1/members/u%202")
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["role": .string("manager")]))
        XCTAssertEqual(changed, GroupMemberRole(userId: "u2", role: .manager, addedAt: nil, addedBy: "u1"))
    }

    // MARK: - Behavior 6: custodian and settings

    func testGroupInfoDecodesCustodianAndSettings() throws {
        let held = try decode(GroupInfo.self, Self.group)
        XCTAssertEqual(held.custodian, "user:u1")
        XCTAssertEqual(held.settings, ResourceSettings(memberList: .members))

        let managers = try decode(GroupInfo.self, Self.group
            .replacingOccurrences(of: #""custodian":"user:u1""#, with: #""custodian":null"#)
            .replacingOccurrences(of: #""memberList":"members""#, with: #""memberList":"managers""#))
        XCTAssertNil(managers.custodian)
        XCTAssertEqual(managers.settings?.memberList, .managers)

        let old = try decode(GroupInfo.self, """
        {"appId":"a1","groupType":"team","groupId":"g1","name":"Team","memberCount":1,
         "createdAt":"2026-01-01T00:00:00Z","createdBy":"u1","modifiedAt":"2026-01-01T00:00:00Z"}
        """)
        XCTAssertNil(old.custodian)
        XCTAssertNil(old.settings)
    }

    // MARK: - E1: a member row's role

    func testMemberRowRoleIsNilWhenAbsentOrNull() throws {
        let page = try decode(PaginatedResult<GroupMemberInfo>.self, """
        {"items":[{"userId":"u1","addedBy":"u0"},{"userId":"u2","role":null,"addedBy":"u0"},
                  {"userId":"u3","role":"manager","addedBy":"u0"}]}
        """)
        XCTAssertEqual(page.items.map(\.role), [nil, nil, "manager"])

        let memberships = try decode([GroupMembershipInfo].self, """
        [{"groupType":"group","groupId":"g1","name":"Team","role":"owner","addedBy":"u1"},
         {"groupType":"team","groupId":"g2","name":"Old","addedBy":"u1"}]
        """)
        XCTAssertEqual(memberships.map(\.role), ["owner", nil])
    }

    // MARK: - E3: ListGroupsOptions without a type

    func testListGroupsOptionsWithoutATypeSendNoType() async throws {
        let (api, transport) = groups(#"{"items":[]}"#)
        _ = try await api.list(options: ListGroupsOptions(limit: 25, cursor: "c", includeSystem: true))
        XCTAssertEqual(transport.lastCall?.path, "/groups?limit=25&cursor=c&includeSystem=true")
    }

    @available(*, deprecated)
    func testListGroupsOptionsWithATypeStillSendIt() async throws {
        let (api, transport) = groups(#"{"items":[]}"#)
        let options = ListGroupsOptions(type: "editors")
        XCTAssertEqual(options.type, "editors")
        _ = try await api.list(options: options)
        XCTAssertEqual(transport.lastCall?.path, "/groups?type=editors")
    }

    // MARK: - Behavior 7: the typed labels keep their routes, deprecated

    @available(*, deprecated)
    func testTypedLabelsStillReachTheTypedRoutes() async throws {
        let (api, transport) = groups(Self.group)
        _ = try await api.get(groupType: "team", groupId: "g1")
        XCTAssertEqual(transport.lastCall?.path, "/groups/team/g1")
        _ = try await api.update(groupType: "team", groupId: "g1", params: UpdateGroupParams(name: "n"))
        XCTAssertEqual(transport.lastCall?.path, "/groups/team/g1")
        _ = try await api.create(params: CreateGroupParams(groupType: "team", name: "n"))
        XCTAssertEqual(transport.lastCall?.path, "/groups")
    }

    /// Each `(groupType:` overload, `create`, `CreateGroupParams` and
    /// `ListGroupsOptions.type` is deprecated naming the removal issue.
    func testTypedGroupSurfacesAreDeprecatedNamingTheRemovalIssue() throws {
        let api = try ClientSourceText.code("API/GroupsAPI.swift")
        let typed = Self.declarations(in: api, matching: #"public func \w+\(groupType:"#)
        XCTAssertEqual(typed.count, 10, "expected the ten typed-label group methods")
        for (decl, attributes) in typed + Self.declarations(in: api, matching: #"public func create\("#) {
            XCTAssertTrue(Self.isDeprecatedFor4718(attributes), "\(decl) is not deprecated naming #4718")
        }
        let types = try ClientSourceText.code("Types/GroupsTypes.swift")
        for pattern in [#"public struct CreateGroupParams\b"#, #"public var type: String\?"#] {
            let found = Self.declarations(in: types, matching: pattern)
            XCTAssertEqual(found.count, 1, "\(pattern) not declared once")
            for (decl, attributes) in found {
                XCTAssertTrue(Self.isDeprecatedFor4718(attributes), "\(decl) is not deprecated naming #4718")
            }
        }
    }

    // MARK: - Behavior 8: document group grants by id

    func testDocumentGroupGrantNamesTheGroupById() async throws {
        let transport = RecordingTransport(json: """
        {"documentId":"d1","groupType":"group","groupId":"g1","permission":"reader",
         "grantedAt":"2026-01-01T00:00:00Z","grantedBy":"u1"}
        """)
        let api = documents(transport)
        _ = try await api.grantGroupPermission(
            documentId: "d1", params: GrantGroupPermissionParams(groupId: "g1", permission: "reader")
        )
        XCTAssertEqual(transport.lastCall?.path, "/documents/d1/group-permissions")
        XCTAssertEqual(
            transport.lastCall?.jsonBody,
            .object(["groupId": .string("g1"), "permission": .string("reader")])
        )

        let revokes = RecordingTransport(json: #"{"success":true}"#)
        _ = try await documents(revokes).revokeGroupPermission(documentId: "d1", groupId: "g 1")
        XCTAssertEqual(revokes.lastCall?.method, .delete)
        XCTAssertEqual(revokes.lastCall?.path, "/documents/d1/group-permissions/g%201")
    }

    @available(*, deprecated)
    func testTypedDocumentGroupGrantStillBuildsTheTypedRoute() async throws {
        let transport = RecordingTransport(json: #"{"success":true}"#)
        _ = try await documents(transport).revokeGroupPermission(
            documentId: "d1", groupType: "team", groupId: "g1"
        )
        XCTAssertEqual(transport.lastCall?.path, "/documents/d1/group-permissions/team/g1")

        let params = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(
            GrantGroupPermissionParams(groupType: "team", groupId: "g1", permission: "reader")
        ))
        XCTAssertEqual(params["groupType"], .string("team"))

        let code = try ClientSourceText.code("API/DocumentsAPI.swift")
        let typed = Self.declarations(in: code, matching: #"public func revokeGroupPermission\(\s*documentId: String,\s*groupType:"#)
        XCTAssertEqual(typed.count, 1)
        XCTAssertTrue(typed.allSatisfy { Self.isDeprecatedFor4718($0.attributes) })
        let types = try ClientSourceText.code("Types/DocumentTypes.swift")
        let oldInit = Self.declarations(in: types, matching: #"public init\(groupType: String, groupId: String, permission: String\)"#)
        XCTAssertEqual(oldInit.count, 1)
        XCTAssertTrue(oldInit.allSatisfy { Self.isDeprecatedFor4718($0.attributes) })
    }

    // MARK: - Behavior 29: the type-config namespaces are gone

    /// `client.groupTypeConfigs` and `client.collectionTypeConfigs` are
    /// removed with their routes, API classes and types;
    /// `databaseTypeConfigs` stays.
    func testTypeConfigNamespacesAreRemoved() throws {
        let client = try ClientSourceText.code("JsBaoClient.swift")
        XCTAssertFalse(client.contains("groupTypeConfigs"), "JsBaoClient still declares groupTypeConfigs")
        XCTAssertFalse(client.contains("collectionTypeConfigs"), "JsBaoClient still declares collectionTypeConfigs")
        XCTAssertTrue(
            client.contains("public let databaseTypeConfigs: DatabaseTypeConfigsAPI"),
            "databaseTypeConfigs is not declared"
        )
        let sources = ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient")
        for file in [
            "API/GroupTypeConfigsAPI.swift", "API/CollectionTypeConfigsAPI.swift",
            "Types/GroupTypeConfigsTypes.swift", "Types/CollectionTypeConfigsTypes.swift",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sources.appendingPathComponent(file).path),
                "\(file) is still in Sources"
            )
        }
        let spine = try ClientSourceText.packageFile("Tests/JsBaoClientTests/TransportSpineTests.swift")
        XCTAssertFalse(spine.contains("CollectionTypeConfigsAPI"), "TransportSpineTests still names CollectionTypeConfigsAPI")
        XCTAssertFalse(spine.contains("GroupTypeConfigsAPI"), "TransportSpineTests still names GroupTypeConfigsAPI")
    }

    // MARK: - Behavior 30: every marker names the removal issue

    /// Every deprecation attribute in the group, collection and document
    /// client files names #4718, the issue that removes the compatibility
    /// surface. The floor keeps the scan from passing on files that declare
    /// no deprecation at all.
    func testEveryDeprecationNamesTheRemovalIssue() throws {
        var markers: [String] = []
        for file in [
            "API/GroupsAPI.swift", "API/CollectionsAPI.swift", "API/DocumentsAPI.swift",
            "Types/GroupsTypes.swift", "Types/CollectionsTypes.swift", "Types/DocumentTypes.swift",
        ] {
            let lines = try ClientSourceText.code(file).components(separatedBy: "\n")
            for line in lines where line.contains("@available(*, deprecated") {
                markers.append(line.trimmingCharacters(in: .whitespaces))
                XCTAssertTrue(line.contains("#4718"), "\(file): \(line.trimmingCharacters(in: .whitespaces)) does not name #4718")
            }
        }
        XCTAssertGreaterThanOrEqual(markers.count, 40, "expected the group, collection and document deprecations")
    }

    // MARK: - Source scan helpers

    /// Every declaration matching `pattern`, with the attribute lines directly
    /// above it (comments already stripped, so a doc comment reads as a blank
    /// line and is passed over).
    static func declarations(in code: String, matching pattern: String) -> [(decl: String, attributes: String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let lines = code.components(separatedBy: "\n")
        var found: [(String, String)] = []
        var offset = 0
        var lineStarts: [Int] = []
        for line in lines {
            lineStarts.append(offset)
            offset += (line as NSString).length + 1
        }
        let ns = code as NSString
        for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            guard let lineIndex = lineStarts.lastIndex(where: { $0 <= match.range.location }) else { continue }
            var attributes: [String] = []
            var index = lineIndex - 1
            while index >= 0 {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("@") {
                    attributes.insert(line, at: 0)
                } else if !line.isEmpty {
                    break
                }
                index -= 1
            }
            found.append((lines[lineIndex].trimmingCharacters(in: .whitespaces), attributes.joined(separator: "\n")))
        }
        return found
    }

    static func isDeprecatedFor4718(_ attributes: String) -> Bool {
        attributes.contains("@available(*, deprecated") && attributes.contains("#4718")
    }
}
