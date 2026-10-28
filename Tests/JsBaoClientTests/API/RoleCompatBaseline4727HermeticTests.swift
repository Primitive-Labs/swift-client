import XCTest
@testable import JsBaoClient

/// Today's Swift group and collection calls, kept as the baseline R4 is
/// checked against (#4727, project `role-based-groups-collections`).
///
/// R4's invariant: after the Swift client changes in phase 3,
/// `callsEveryMethod(client:)` still compiles, with old labels deprecated
/// rather than removed (removal is #4718). It is never run; the test target
/// compiling it is the claim, and the build gate builds the tests warning-free.
/// When phase 3 deprecates a label called here, the method itself is marked
/// `@available(*, deprecated)` so the warning gate stays clean.
///
/// Server-free: the coverage test reads `Sources/` by path.
final class RoleCompatBaseline4727HermeticTests: XCTestCase {

    /// Every group and collection call as a caller writes it today, with the
    /// compatibility fields it reads (`groupType`, `collectionType`,
    /// `permission`, `addedBy`) typed. The Swift client has no database
    /// group-permission API (retired in #3189), so none is called here.
    ///
    /// Deprecated since #4737 moved the client to the role model: the body
    /// calls the typed and `permission` labels, which #4718 removes.
    @available(*, deprecated)
    static func callsEveryMethod(client: JsBaoClient) async throws {
        // The server mints the group's id (#4917); every later call addresses it.
        let created: GroupInfo = try await client.groups.create(params: CreateGroupParams(
            groupType: "team", name: "Baseline Team", description: "Compatibility baseline"
        ))
        let baseline: String = created.groupId
        let groupType: String = created.groupType
        let page: PaginatedResult<GroupInfo> = try await client.groups.list(
            options: ListGroupsOptions(type: groupType)
        )
        _ = try await client.groups.list(options: ListGroupsOptions(
            limit: 10, cursor: page.nextCursor, includeSystem: true
        ))
        _ = try await client.groups.list()
        let fetched: GroupInfo = try await client.groups.get(groupType: "team", groupId: baseline)
        _ = fetched.memberCount as Int
        _ = try await client.groups.update(
            groupType: "team", groupId: baseline,
            params: UpdateGroupParams(name: "Baseline Team Renamed", description: "Renamed")
        ) as GroupInfo

        let byId: GroupAddMemberResult = try await client.groups.addMember(
            groupType: "team", groupId: baseline, params: .userId("user-1")
        )
        if case let .direct(direct) = byId {
            _ = direct.addedBy as String
        }
        let byEmail: GroupAddMemberResult = try await client.groups.addMember(
            groupType: "team", groupId: baseline, params: .email("invitee@example.com")
        )
        if case let .deferred(deferred) = byEmail {
            _ = deferred.groupType as String
            _ = deferred.inviteToken as String?
        }
        let members: PaginatedResult<GroupMemberInfo> = try await client.groups.listMembers(
            groupType: "team", groupId: baseline
        )
        _ = members.items.first?.addedBy as String?
        _ = try await client.groups.listMembers(
            groupType: "team", groupId: baseline,
            options: PaginationOptions(limit: 50, cursor: members.nextCursor),
            include: .profiles
        ) as PaginatedResult<GroupMemberInfo>
        _ = try await client.groups.listPendingInvitations(
            groupType: "team", groupId: baseline
        ) as [PendingGroupInvitationEntry]
        let memberships: [GroupMembershipInfo] = try await client.groups.listUserMemberships(
            userId: "user-1", groupType: "team"
        )
        _ = memberships.first?.groupType as String?
        _ = try await client.groups.listUserMemberships(userId: "user-1") as [GroupMembershipInfo]
        let groupDocuments: [GroupDocumentInfo] = try await client.groups.listDocuments(
            groupType: "team", groupId: baseline
        )
        _ = groupDocuments.first?.permission as String?
        let groupDatabases: [GroupDatabaseInfo] = try await client.groups.listDatabases(
            groupType: "team", groupId: baseline
        )
        _ = groupDatabases.first?.permission as String?

        let granted: DocumentGroupPermissionEntry = try await client.documents.grantGroupPermission(
            documentId: "doc-1",
            params: GrantGroupPermissionParams(groupType: "team", groupId: baseline, permission: "reader")
        )
        _ = granted.groupType as String
        _ = try await client.documents.listGroupPermissions(documentId: "doc-1")
            as [DocumentGroupPermissionEntry]
        _ = try await client.documents.listGroupPermissions(documentId: "doc-1", includeSystem: true)
            as [DocumentGroupPermissionEntry]
        _ = try await client.documents.revokeGroupPermission(
            documentId: "doc-1", groupType: "team", groupId: baseline
        ) as SuccessResult

        _ = try await client.groups.removeMemberByEmail(
            groupType: "team", groupId: baseline, email: "invitee@example.com"
        ) as SuccessResult
        _ = try await client.groups.removeMember(
            groupType: "team", groupId: baseline, userId: "user-1"
        ) as SuccessResult
        _ = try await client.groups.delete(groupType: "team", groupId: baseline) as SuccessResult

        let collection: CollectionInfo = try await client.collections.create(
            params: CreateCollectionParams(name: "Baseline Collection", description: "Compatibility baseline")
        )
        let typed: CollectionInfo = try await client.collections.create(
            params: CreateCollectionParams(name: "Baseline Typed Collection", collectionType: "default")
        )
        _ = typed.collectionType as String
        let id = collection.collectionId
        _ = try await client.collections.get(collectionId: id) as CollectionInfo
        _ = try await client.collections.update(
            collectionId: id,
            params: UpdateCollectionParams(name: "Baseline Collection Renamed", description: "Renamed")
        ) as CollectionInfo
        _ = try await client.collections.addDocument(collectionId: id, documentId: "doc-1")
            as CollectionDocumentInfo
        _ = try await client.collections.listDocuments(
            collectionId: id, options: PaginationOptions(limit: 10)
        ) as PaginatedResult<CollectionDocumentInfo>
        _ = try await client.collections.listCollectionsForDocument(
            documentId: "doc-1", options: PaginationOptions(limit: 10)
        ) as PaginatedResult<DocumentCollectionInfo>

        let reader: CollectionAddMemberResult = try await client.collections.addMember(
            collectionId: id, params: .user("reader-1", permission: .reader)
        )
        if case let .direct(direct) = reader {
            _ = direct.permission as CollectionPermission
            _ = direct.addedBy as String
        }
        _ = try await client.collections.addMember(
            collectionId: id, params: .user("writer-1", permission: .readWrite, sendEmail: false)
        ) as CollectionAddMemberResult
        _ = try await client.collections.addMember(
            collectionId: id,
            params: .email(
                "invitee@example.com", permission: .reader, sendEmail: false,
                collectionUrl: "https://example.com/collections/baseline", note: "Welcome"
            )
        ) as CollectionAddMemberResult
        let pending: [PendingCollectionInvitationEntry] = try await client.collections.listPendingInvitations(
            collectionId: id
        )
        _ = pending.first?.permission as CollectionPermission?
        let grant: CollectionGroupPermissionInfo = try await client.collections.grantGroupPermission(
            collectionId: id,
            params: GrantCollectionGroupPermissionParams(groupType: "team", groupId: "baseline2", permission: "reader")
        )
        _ = grant.groupType as String
        let access: CollectionAccessInfo = try await client.collections.getAccess(collectionId: id)
        _ = access.members.first?.addedBy as String?
        _ = access.groups.first?.groupType as String?
        let mine: PaginatedResult<CollectionInfo> = try await client.collections.list(
            options: PaginationOptions(limit: 10)
        )
        _ = mine.items.first?.permission as CollectionPermission?
        _ = try await client.collections.listAll(limit: 10, cursor: mine.nextCursor)
            as PaginatedResult<CollectionInfo>
        _ = try await client.collections.revokeGroupPermission(
            collectionId: id, groupType: "team", groupId: "baseline2"
        ) as SuccessResult
        _ = try await client.collections.removeDocument(collectionId: id, documentId: "doc-1")
            as SuccessResult
        _ = try await client.collections.removeMember(collectionId: id, userId: "writer-1")
            as SuccessResult
        _ = try await client.collections.delete(collectionId: id) as SuccessResult
    }

    /// The same calls on the role model (#4737): every group, collection and
    /// document group-grant method under its current label, with the role
    /// fields it reads typed. Never run, like the frozen body; the name guard
    /// below reads both. It is not deprecated, so a call here to a deprecated
    /// label fails the warning gate.
    static func callsEveryRoleMethod(client: JsBaoClient) async throws {
        let page: PaginatedResult<GroupInfo> = try await client.groups.list(
            options: ListGroupsOptions(limit: 10, includeSystem: true)
        )
        let group: GroupInfo = try await client.groups.get(groupId: "baseline")
        _ = group.custodian as String?
        _ = group.settings?.memberList as MemberListSetting?
        _ = try await client.groups.update(
            groupId: "baseline",
            params: UpdateGroupParams(name: "Renamed", settings: ResourceSettings(memberList: .managers))
        ) as GroupInfo
        let added: GroupAddMemberResult = try await client.groups.addMember(
            groupId: "baseline", params: .userId("user-1", role: .manager)
        )
        if case let .direct(direct) = added {
            _ = direct.role as GroupRole?
        }
        let invited: GroupAddMemberResult = try await client.groups.addMember(
            groupId: "baseline", params: .email("invitee@example.com", role: .member)
        )
        if case let .deferred(deferred) = invited {
            _ = deferred.role as GroupRole?
        }
        let members: PaginatedResult<GroupMemberInfo> = try await client.groups.listMembers(
            groupId: "baseline", options: PaginationOptions(limit: 50, cursor: page.nextCursor), include: .profiles
        )
        _ = members.items.first?.role as String?
        let changed: GroupMemberRole = try await client.groups.setMemberRole(
            groupId: "baseline", userId: "user-1", role: .member
        )
        _ = changed.role as GroupRole
        _ = try await client.groups.listPendingInvitations(groupId: "baseline") as [PendingGroupInvitationEntry]
        let memberships: [GroupMembershipInfo] = try await client.groups.listUserMemberships(userId: "user-1")
        _ = memberships.first?.role as String?
        _ = try await client.groups.listDocuments(groupId: "baseline") as [GroupDocumentInfo]
        _ = try await client.groups.listDatabases(groupId: "baseline") as [GroupDatabaseInfo]
        _ = try await client.groups.transfer(groupId: "baseline", to: "user:user-1") as GroupInfo

        _ = try await client.documents.grantGroupPermission(
            documentId: "doc-1", params: GrantGroupPermissionParams(groupId: "baseline", permission: "reader")
        ) as DocumentGroupPermissionEntry
        _ = try await client.documents.listGroupPermissions(documentId: "doc-1") as [DocumentGroupPermissionEntry]
        _ = try await client.documents.revokeGroupPermission(documentId: "doc-1", groupId: "baseline")
            as SuccessResult

        _ = try await client.groups.removeMemberByEmail(groupId: "baseline", email: "invitee@example.com")
            as SuccessResult
        _ = try await client.groups.removeMember(groupId: "baseline", userId: "user-1") as SuccessResult
        _ = try await client.groups.delete(groupId: "baseline") as SuccessResult

        let collection: CollectionInfo = try await client.collections.create(
            params: CreateCollectionParams(name: "Baseline Collection", settings: ResourceSettings(memberList: .members))
        )
        _ = collection.custodian as String?
        _ = collection.role as CollectionRole?
        _ = collection.settings?.memberList as MemberListSetting?
        let id = collection.collectionId
        _ = try await client.collections.get(collectionId: id) as CollectionInfo
        _ = try await client.collections.update(
            collectionId: id,
            params: UpdateCollectionParams(name: "Renamed", settings: ResourceSettings(memberList: .managers))
        ) as CollectionInfo
        _ = try await client.collections.addDocument(collectionId: id, documentId: "doc-1")
            as CollectionDocumentInfo
        _ = try await client.collections.listDocuments(collectionId: id, options: nil)
            as PaginatedResult<CollectionDocumentInfo>
        _ = try await client.collections.listCollectionsForDocument(documentId: "doc-1", options: nil)
            as PaginatedResult<DocumentCollectionInfo>
        let viewerAdded: CollectionAddMemberResult = try await client.collections.addMember(
            collectionId: id, params: .user("viewer-1", role: .viewer)
        )
        if case let .direct(direct) = viewerAdded {
            _ = direct.role as CollectionRole?
            _ = direct.principal as String?
        }
        let editorInvited: CollectionAddMemberResult = try await client.collections.addMember(
            collectionId: id,
            params: .email(
                "invitee@example.com", role: .editor, sendEmail: false,
                collectionUrl: "https://example.com/collections/baseline", note: "Welcome"
            )
        )
        if case let .deferred(deferred) = editorInvited {
            _ = deferred.role as CollectionRole?
        }
        let groupAdd: CollectionGroupMemberAdd = try await client.collections.addGroupMember(
            collectionId: id, groupId: "baseline", role: .manager
        )
        _ = groupAdd.principal as String
        let principals: [CollectionMemberEntry] = try await client.collections.listMembers(collectionId: id)
        _ = principals.first?.role as CollectionRole?
        _ = principals.first?.principal as String?
        _ = try await client.collections.setMemberRole(
            collectionId: id, principal: "group:baseline", role: .viewer
        ) as CollectionMemberEntry
        let resolved: ResolvedCollectionRole = try await client.collections.resolveRole(
            collectionId: id, userId: "viewer-1"
        )
        _ = resolved.source as CollectionRoleSource?
        let pending: [PendingCollectionInvitationEntry] = try await client.collections.listPendingInvitations(
            collectionId: id
        )
        _ = pending.first?.role as CollectionRole?
        _ = try await client.collections.list(options: nil) as PaginatedResult<CollectionInfo>
        _ = try await client.collections.listAll(limit: 10) as PaginatedResult<CollectionInfo>
        _ = try await client.collections.transfer(collectionId: id, to: "user:viewer-1") as CollectionInfo
        _ = try await client.collections.removeDocument(collectionId: id, documentId: "doc-1")
            as SuccessResult
        _ = try await client.collections.removeMember(collectionId: id, principal: "group:baseline")
            as SuccessResult
        _ = try await client.collections.delete(collectionId: id) as SuccessResult
    }

    private static var ownSource: String {
        get throws {
            try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        }
    }

    /// Every `public func` name declared in a client source file.
    private static func publicFuncs(_ relativePath: String) throws -> [String] {
        let code = try ClientSourceText.code(relativePath)
        let regex = try NSRegularExpression(pattern: #"public func (\w+)\("#)
        let range = NSRange(code.startIndex..., in: code)
        var names: [String] = []
        for match in regex.matches(in: code, range: range) {
            if let name = Range(match.range(at: 1), in: code).map({ String(code[$0]) }),
               !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// The baseline method's body, so a call made elsewhere in this file
    /// cannot count. The anchor is split so this literal cannot match itself.
    private static func baselineBody() throws -> String {
        try ClientSourceText.slice(
            ClientSourceText.stripComments(ownSource),
            from: "static func callsEveryMethod" + "(client: JsBaoClient)",
            to: "\n    }\n"
        )
    }

    /// The role-model body, sliced the same way.
    private static func roleBody() throws -> String {
        try ClientSourceText.slice(
            ClientSourceText.stripComments(ownSource),
            from: "static func callsEveryRoleMethod" + "(client: JsBaoClient)",
            to: "\n    }\n"
        )
    }

    /// A method name counts when either body calls it: the frozen body holds
    /// the old labels, the role body the new ones (#4737).
    func testBaselineCallsEveryGroupAndCollectionMethod() throws {
        let body = try Self.baselineBody() + Self.roleBody()
        for (file, namespace) in [
            ("API/GroupsAPI.swift", "groups"),
            ("API/CollectionsAPI.swift", "collections"),
        ] {
            let names = try Self.publicFuncs(file)
            XCTAssertGreaterThan(names.count, 10, "no public funcs read from \(file)")
            for name in names {
                XCTAssertTrue(
                    body.contains("client.\(namespace).\(name)("),
                    "\(namespace).\(name) is not called by the baseline"
                )
            }
        }
    }

    /// Every method the group and collection files declare without a
    /// deprecation, and the three document group-grant methods, are called
    /// from the role body under their own first label, so a new method or
    /// label cannot land uncalled (#4737). Deprecated overloads are left to
    /// the frozen body.
    func testRoleBodyCallsEveryCurrentLabel() throws {
        let body = try Self.roleBody()
        for (file, namespace) in [
            ("API/GroupsAPI.swift", "groups"),
            ("API/CollectionsAPI.swift", "collections"),
        ] {
            let code = try ClientSourceText.code(file)
            let current = RoleSurfacesHermeticTests.declarations(in: code, matching: #"public func \w+\(\w+"#)
                .filter { !$0.attributes.contains("@available(*, deprecated") }
            XCTAssertGreaterThan(current.count, 10, "no current public funcs read from \(file)")
            for (decl, _) in current {
                let signature = try XCTUnwrap(
                    decl.range(of: #"\w+\(\w+"#, options: .regularExpression).map { String(decl[$0]) }
                )
                let parts = signature.split(separator: "(")
                let call = #"client\.\#(namespace)\.\#(parts[0])\(\s*\#(parts[1]):"#
                XCTAssertNotNil(
                    body.range(of: call, options: .regularExpression),
                    "\(namespace).\(parts[0])(\(parts[1]):) is not called by the role body"
                )
            }
        }
        for call in [
            #"client\.documents\.grantGroupPermission\(\s*documentId: [^,]+, params: GrantGroupPermissionParams\(groupId:"#,
            #"client\.documents\.listGroupPermissions\(documentId:"#,
            #"client\.documents\.revokeGroupPermission\(documentId: [^,]+, groupId:"#,
        ] {
            XCTAssertNotNil(body.range(of: call, options: .regularExpression), "role body lacks \(call)")
        }
    }

    // MARK: - Recorded responses decode (R4)

    /// `Fixtures/RoleCompatResponses`: today's responses, recorded from the
    /// local dev server by `tests/api/http/role-compat-baseline-4727.test.ts`
    /// and read by path from both suites.
    private static var fixtureDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../Tests/JsBaoClientTests/API/<this file>
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/RoleCompatResponses")
    }

    private struct Header: Decodable {
        let name: String
        let status: Int
    }

    private struct Recorded<Body: Decodable>: Decodable {
        let body: Body
    }

    private typealias Decode = (Data) throws -> Void

    private static func model<T: Decodable>(_ type: T.Type) -> Decode {
        { data in _ = try JSONDecoder().decode(Recorded<T>.self, from: data) }
    }

    /// Each 2xx entry's Swift model; `nil` marks an entry no Swift model reads
    /// (database group permissions: the Swift client has none, #3189).
    private static var decodeTable: [String: Decode?] { [
        "groups.create": model(GroupInfo.self),
        "groups.get": model(GroupInfo.self),
        "groups.update": model(GroupInfo.self),
        "groups.list": model(PaginatedResult<GroupInfo>.self),
        "groups.list.includeSystem": model(PaginatedResult<GroupInfo>.self),
        "groups.listMembers": model(PaginatedResult<GroupMemberInfo>.self),
        "groups.listMembers.profiles": model(PaginatedResult<GroupMemberInfo>.self),
        "groups.listMembers.asMember": model(PaginatedResult<GroupMemberInfo>.self),
        "groups.addMember.userId": model(GroupAddMemberResult.self),
        "groups.addMember.again": model(GroupAddMemberResult.self),
        "groups.addMember.email": model(GroupAddMemberResult.self),
        "groups.listPendingInvitations": model(ItemsEnvelope<PendingGroupInvitationEntry>.self),
        "groups.listUserMemberships": model([GroupMembershipInfo].self),
        "groups.listDocuments": model([GroupDocumentInfo].self),
        "groups.listDatabases": model([GroupDatabaseInfo].self),
        "groups.removeMemberByEmail": model(SuccessResult.self),
        "groups.selfLeave": model(SuccessResult.self),
        "groups.removeMember": model(SuccessResult.self),
        "groups.delete": model(SuccessResult.self),
        "documents.grantGroupPermission": model(DocumentGroupPermissionEntry.self),
        "documents.listGroupPermissions": model([DocumentGroupPermissionEntry].self),
        "documents.revokeGroupPermission": model(SuccessResult.self),
        "databases.grantGroupPermission": nil,
        "databases.listGroupPermissions": nil,
        "databases.revokeGroupPermission": nil,
        "collections.create": model(CollectionInfo.self),
        "collections.create.withType": model(CollectionInfo.self),
        "collections.get": model(CollectionInfo.self),
        "collections.update": model(CollectionInfo.self),
        "collections.addDocument": model(CollectionDocumentInfo.self),
        "collections.listDocuments": model(CollectionDocumentPage.self),
        "collections.listCollectionsForDocument": model(DocumentCollectionPage.self),
        "collections.addMember.reader": model(CollectionAddMemberResult.self),
        "collections.addMember.readWrite": model(CollectionAddMemberResult.self),
        "collections.addMember.again": model(CollectionAddMemberResult.self),
        "collections.addMember.email": model(CollectionAddMemberResult.self),
        "collections.listPendingInvitations": model(ItemsEnvelope<PendingCollectionInvitationEntry>.self),
        "collections.grantGroupPermission": model(CollectionGroupPermissionInfo.self),
        "collections.getAccess": model(CollectionAccessInfo.self),
        "collections.list": model(CollectionInfoPage.self),
        "collections.list.asReader": model(CollectionInfoPage.self),
        "collections.listAll": model(CollectionInfoPage.self),
        "collections.revokeGroupPermission": model(SuccessResult.self),
        "collections.removeDocument": model(SuccessResult.self),
        "collections.selfLeave.reader": model(SuccessResult.self),
        "collections.removeMember": model(SuccessResult.self),
        "collections.delete": model(SuccessResult.self),
    ] }

    private static func fixtureFiles() throws -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: fixtureDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory.appendingPathComponent("\(name).json"))
    }

    func testEveryRecordedSuccessDecodesIntoTodaysModel() throws {
        let files = try Self.fixtureFiles()
        XCTAssertGreaterThan(files.count, 40, "no fixtures recorded in \(Self.fixtureDirectory.path)")
        for file in files {
            let data = try Data(contentsOf: file)
            let header = try JSONDecoder().decode(Header.self, from: data)
            XCTAssertEqual("\(header.name).json", file.lastPathComponent, "fixture name and file differ")
            guard (200..<300).contains(header.status) else { continue }
            guard let entry = Self.decodeTable[header.name] else {
                XCTFail("\(header.name): no row in the decode table")
                continue
            }
            guard let decode = entry else { continue }
            XCTAssertNoThrow(try decode(data), "\(header.name) no longer decodes")
        }
    }

    /// E8: `collections.get` carries no `permission` while list rows do; both
    /// decode into `CollectionInfo`. `permission` is deprecated since #4737,
    /// so this reading test is a deprecated test method.
    @available(*, deprecated)
    func testCollectionPermissionIsAbsentOnGetAndPresentOnList() throws {
        let fetched = try JSONDecoder().decode(
            Recorded<CollectionInfo>.self, from: try Self.fixture("collections.get")
        ).body
        XCTAssertNil(fetched.permission)
        let listed = try JSONDecoder().decode(
            Recorded<CollectionInfoPage>.self, from: try Self.fixture("collections.list")
        ).body
        XCTAssertFalse(listed.items.isEmpty)
        XCTAssertTrue(listed.items.allSatisfy { $0.permission != nil })
    }

    func testBaselineCallsTheDocumentGroupPermissionMethods() throws {
        let body = try Self.baselineBody()
        let declared = try Self.publicFuncs("API/DocumentsAPI.swift")
        for name in ["listGroupPermissions", "grantGroupPermission", "revokeGroupPermission"] {
            XCTAssertTrue(declared.contains(name), "DocumentsAPI.\(name) is not declared")
            XCTAssertTrue(
                body.contains("client.documents.\(name)("),
                "documents.\(name) is not called by the baseline"
            )
        }
    }
}
