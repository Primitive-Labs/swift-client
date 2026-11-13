import XCTest
@testable import JsBaoClient

/// #5896 phase 3 — one tree, both tools: the committed models in this
/// directory, which swift-bao-codegen writes for `db3-types/board.toml` (whose
/// fields ref the shared enums in `schemas/common.toml`), and `Generated/`,
/// which `primitive functions codegen --lang swift` writes for the tree (its
/// `Primitive.generated.swift` committed as `BoardShared.generated.swift`, a
/// name of its own in this target), compiled together and run against a real
/// client with no server.
///
/// A ref'd field is typed by the shared enum, so a `String` cannot be
/// assigned to it, while the stored string is kept in `<field>Raw`: a stored
/// value outside the enum reads as `nil` without failing the row, survives a
/// save that did not assign the field, a full copy and a Codable round trip.
final class SharedEnumModelRuntimeHermeticTests: XCTestCase {

    private static let db3Id = "01JD5896SHAREDENVMXXXXXXXX"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    /// A client over its own SQLite store with no server, holding the db3
    /// `db3Id`, with the fixture's models registered and configured as the
    /// default client.
    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/shared-enum-model-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "shared-enum-model-5896",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([EnumPostRecord.self, EnumStepRecord.self, EnumTicketRecord.self, EnumIssueRecord.self, EnumLabelRecord.self])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        JsBaoClient.configureDefault(client)
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Board", "createdBy": "user-a", "createdAt": "2026-11-12T00:00:00.000Z",
         "modifiedAt": "2026-11-12T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": null, "tags": []}
        """
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 201, json: answer), client: client)
            .create(title: "Board", custodian: "user:user-a")
        XCTAssertTrue(try XCTUnwrap(client.recordLogBinding(Self.db3Id)).isResident)
        return client
    }

    /// Store `values` for post `id` as another client would: any string.
    private func storePost(_ client: JsBaoClient, id: String, _ values: [String: PrimitiveValue]) throws -> PrimitiveRecord {
        try client.codegen.save(EnumPostRecord.primitiveSchema, id: id, values: values, in: Self.db3Id)
    }

    private func storedStatus(_ client: JsBaoClient, id: String) throws -> JSONValue? {
        try XCTUnwrap(client.codegen.find(EnumPostRecord.primitiveSchema, id: id))["status"]
    }

    // MARK: - Behavior 19: the field is the shared type

    /// Whether this file can write through `path`: overload resolution picks
    /// the `WritableKeyPath` form only where the property's setter is
    /// visible, which is what code outside the generated file can do.
    private static func writable<Root, Value>(_ path: KeyPath<Root, Value>) -> Bool { false }
    private static func writable<Root, Value>(_ path: WritableKeyPath<Root, Value>) -> Bool { true }

    func testTheFieldIsAWritableSharedEnumAndTheRawStringIsReadOnly() {
        let status: WritableKeyPath<EnumPostRecord, Phase?> = \EnumPostRecord.status
        XCTAssertNotNil(status)
        XCTAssertTrue(Self.writable(\EnumPostRecord.status))
        XCTAssertTrue(Self.writable(\EnumPostRecord.title))
        XCTAssertFalse(Self.writable(\EnumPostRecord.statusRaw), "statusRaw has no setter outside its file")
        let raw: KeyPath<EnumPostRecord, String?> = \EnumPostRecord.statusRaw
        XCTAssertNotNil(raw)
        XCTAssertFalse((Phase.self as Any.Type) is any ExpressibleByStringLiteral.Type, "a String literal is not a Phase")
        let required: WritableKeyPath<EnumStepRecord, Phase?> = \EnumStepRecord.status
        XCTAssertNotNil(required)
        XCTAssertFalse(Self.writable(\EnumStepRecord.statusRaw))
    }

    // MARK: - Behavior 20: a stored value outside the enum

    func testAStoredValueOutsideTheEnumReadsNilAndKeepsTheString() async throws {
        let client = try await client()
        let record = try storePost(client, id: "p1", ["title": .string("Old"), "status": .string("archived")])
        let rows = [
            ("record", try XCTUnwrap(EnumPostRecord(record: record))),
            ("row", try XCTUnwrap(EnumPostRecord(row: try XCTUnwrap(client.codegen.find(EnumPostRecord.primitiveSchema, id: "p1"))))),
            ("query", try XCTUnwrap(try EnumPostRecord.query(options: QueryOptions(db3: [Self.db3Id])).first { $0.id == "p1" })),
        ]
        for (path, post) in rows {
            XCTAssertNil(post.status, path)
            XCTAssertEqual(post.statusRaw, "archived", path)
            XCTAssertEqual(post.primitiveValues()["status"], .string("archived"), path)
            XCTAssertEqual(post._changedFields, [], path)
        }

        // A save that did not assign the field does not write it.
        var post = rows[0].1
        post.title = "New"
        XCTAssertEqual(post._changedFields, ["title"])
        let saved = try post.save(in: Self.db3Id)
        XCTAssertEqual(saved.statusRaw, "archived")
        XCTAssertEqual(try storedStatus(client, id: "p1"), .string("archived"))

        // A full copy writes the stored string back.
        var copy = saved
        copy.markAllChanged()
        XCTAssertTrue(copy._changedFields.contains("status"))
        _ = try client.codegen.save(EnumPostRecord.primitiveSchema, id: "p1", values: ["status": .string("open")], in: Self.db3Id)
        _ = try copy.save(in: Self.db3Id)
        XCTAssertEqual(try storedStatus(client, id: "p1"), .string("archived"))
    }

    func testAValueInTheEnumReadsAsItsCase() async throws {
        let client = try await client()
        let record = try storePost(client, id: "p2", ["status": .string("closed")])
        XCTAssertEqual(EnumPostRecord(record: record)?.status, .closed)
        XCTAssertEqual(EnumPostRecord(row: try XCTUnwrap(client.codegen.find(EnumPostRecord.primitiveSchema, id: "p2")))?.status, .closed)
    }

    // MARK: - Behavior 21: Codable and equality keep the stored string

    func testACodableRoundTripKeepsAStoredValueOutsideTheEnum() async throws {
        let client = try await client()
        let post = try XCTUnwrap(EnumPostRecord(record: try storePost(client, id: "p3", ["status": .string("archived")])))
        let data = try JSONEncoder().encode(post)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "archived")
        XCTAssertNil(json["statusRaw"])
        let decoded = try JSONDecoder().decode(EnumPostRecord.self, from: data)
        XCTAssertEqual(decoded.statusRaw, "archived")
        XCTAssertNil(decoded.status)
        XCTAssertEqual(decoded, post)
        XCTAssertTrue(decoded._changedFields.contains("status"))

        let other = try XCTUnwrap(EnumPostRecord(record: try storePost(client, id: "p3", ["status": .string("retired")])))
        XCTAssertNil(other.status)
        XCTAssertNotEqual(other, post, "two values outside the enum are not equal")
    }

    // MARK: - Behavior 22: assigning the typed accessor

    func testAssigningACaseWritesItsRawValueAndNilClears() async throws {
        let client = try await client()
        var post = try XCTUnwrap(EnumPostRecord(record: try storePost(client, id: "p4", ["title": .string("T")])))
        XCTAssertNil(post.statusRaw)
        post.status = .closed
        XCTAssertEqual(post.statusRaw, "closed")
        XCTAssertEqual(post._changedFields, ["status"])
        post = try post.save(in: Self.db3Id)
        XCTAssertEqual(try storedStatus(client, id: "p4"), .string("closed"))
        post.status = nil
        XCTAssertNil(post.statusRaw)
        XCTAssertEqual(post._changedFields, ["status"])
        post = try post.save(in: Self.db3Id)
        XCTAssertNil(post.status)
        XCTAssertNil(EnumPostRecord(row: try XCTUnwrap(client.codegen.find(EnumPostRecord.primitiveSchema, id: "p4")))?.statusRaw)

        // Initializers take the shared type.
        let made = EnumPostRecord(title: "Made", status: .open)
        XCTAssertEqual(made.statusRaw, "open")
        XCTAssertEqual(made.primitiveValues()["status"], .string("open"))
        XCTAssertEqual(EnumPostRecord(id: "p5", status: nil).statusRaw, nil)
    }

    // MARK: - Behavior 23: a required ref'd field

    func testARequiredFieldTakesTheEnumAndIgnoresNil() async throws {
        let client = try await client()
        var step = EnumStepRecord(status: .open)
        XCTAssertEqual(step.statusRaw, "open")
        step.status = nil
        XCTAssertEqual(step.statusRaw, "open", "nil leaves a required field's value")
        XCTAssertEqual(step.status, .open)
        step.status = .closed
        XCTAssertEqual(step.statusRaw, "closed")
        let record = try client.codegen.save(EnumStepRecord.primitiveSchema, id: "s1", values: ["status": .string("archived")], in: Self.db3Id)
        let read = try XCTUnwrap(EnumStepRecord(record: record), "a stored value outside the enum does not fail a required field")
        XCTAssertNil(read.status)
        XCTAssertEqual(read.statusRaw, "archived")
    }

    // MARK: - Edge case: defs named like the model's members (CSO-5896-010)

    /// `EnumLabelRecord.status` refs the def `status`, and its required
    /// `state` refs `stateRaw`, the name of its own stored string. The model
    /// compiles, and the accessors read and write the cases.
    func testDefsNamedLikeTheModelsMembersReadAndWrite() async throws {
        let client = try await client()
        var label = EnumLabelRecord(status: .closed, state: .on)
        XCTAssertEqual(label.statusRaw, "closed")
        XCTAssertEqual(label.stateRaw, "on")
        label.state = .off
        XCTAssertEqual(label.state, .off)
        let typed: WritableKeyPath<EnumLabelRecord, status?> = \EnumLabelRecord.status
        XCTAssertEqual(label[keyPath: typed], .closed)
        let record = try client.codegen.save(
            EnumLabelRecord.primitiveSchema, id: "l1", values: ["status": .string("open"), "state": .string("gone")], in: Self.db3Id
        )
        let read = try XCTUnwrap(EnumLabelRecord(record: record))
        XCTAssertEqual(read.status, .open)
        XCTAssertNil(read.state)
        XCTAssertEqual(read.stateRaw, "gone")
    }

    // MARK: - Behaviors 24, 40, 41: the deprecated names and the shared types

    @available(*, deprecated, message: "reads the deprecated names on purpose")
    func testTheDeprecatedNamesResolveToTheSharedEnum() throws {
        XCTAssertTrue(EnumPostRecord.StatusValue.self == Phase.self)
        XCTAssertTrue(EnumStepRecord.StatusValue.self == Phase.self)
        XCTAssertEqual(EnumPostRecord.allowedStatusValues, ["open", "closed"])
        XCTAssertEqual(EnumTicketRecord.allowedStatusValues, ["draft", "on hold", "done"])
        var post = EnumPostRecord(status: .closed)
        XCTAssertEqual(post.statusEnum, post.status)
        post.status = nil
        XCTAssertNil(post.statusEnum)
        XCTAssertEqual(EnumIssueRecord(kind: .on_hold).kindEnum, .on_hold)
        XCTAssertTrue(EnumIssueRecord.KindValue.self == StatusValue.self)
    }

    func testAFieldThatRefsStatusValueIsTypedByTheModuleLevelEnum() {
        // `EnumTicketRecord` declares no nested `StatusValue`, so its field
        // and its deprecated accessor name the module's.
        let ticket = EnumTicketRecord(status: .on_hold)
        let typed: StatusValue? = ticket.status
        XCTAssertEqual(typed, .on_hold)
        XCTAssertEqual(ticket.statusRaw, "on hold")
        // `EnumIssueRecord` refs both, and keeps them apart.
        let issue = EnumIssueRecord(status: .open, kind: .done, default: .closed)
        let status: Phase? = issue.status
        let kind: StatusValue? = issue.kind
        XCTAssertEqual(status, .open)
        XCTAssertEqual(kind, .done)
        XCTAssertEqual(issue.default, .closed)
        XCTAssertEqual(issue.defaultRaw, "closed")
        XCTAssertEqual(issue.primitiveValues()["default"], .string("closed"))
    }

    // MARK: - Behaviors 27 and 43: the projections and the function are the models' type

    /// A value passes between a model, a db3 projection and a function's input
    /// and output with no conversion: `PostsRow.status`, `PostsDeclared.status`,
    /// the inline `BoardReadOutput.Strict.status` and `BoardReadInput.want` are
    /// the model's `Phase`.
    func testTheFunctionAndItsProjectionsShareTheModelsType() throws {
        let post = EnumPostRecord(title: "T", status: .closed)
        let row = PostsRow(id: post.id, title: post.title, status: post.status)
        let draft = PostsDeclared(title: post.title, status: row.status)
        let input = BoardReadInput(draft: draft, want: post.status)
        XCTAssertEqual(input.want, .closed)
        let strict = BoardReadOutput.Strict(id: post.id, status: .open)
        var copy = post
        copy.status = strict.status
        XCTAssertEqual(copy.statusRaw, "open")
        let output = BoardReadOutput(post: row, strict: strict)
        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(BoardReadOutput.self, from: data)
        XCTAssertEqual(decoded.post.status, post.status)
        XCTAssertEqual(decoded.strict?.status, .open)
        XCTAssertTrue(type(of: row.status) == Phase?.self)
        XCTAssertTrue(type(of: strict.status) == Phase.self)
    }

    /// The same enum value passes between two models with no conversion.
    func testOneSharedValuePassesBetweenModels() {
        let post = EnumPostRecord(status: .closed)
        var issue = EnumIssueRecord()
        issue.status = post.status
        issue.default = post.status
        XCTAssertEqual(issue.statusRaw, "closed")
        XCTAssertEqual(issue.default, .closed)
    }
}
