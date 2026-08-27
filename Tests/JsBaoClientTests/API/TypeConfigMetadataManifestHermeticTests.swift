import Foundation
import XCTest
@testable import JsBaoClient

/// Wire-shape tests for the declared-access manifest on the two type-config
/// surfaces (#2926).
///
/// The JS client carries `metadataManifest: DeclaredMetadataManifest | null`
/// on both the collection and database type-config get/create/update surfaces
/// (`src/client/api/collectionTypeConfigsApi.ts`,
/// `src/client/api/databaseTypeConfigsApi.ts`); these pin the Swift side to
/// the same wire shape without a server.
final class TypeConfigMetadataManifestHermeticTests: XCTestCase {

    /// A manifest with every JS field populated: `self` categories, one
    /// `from`/`via` hop, one `rootFrom` root, plus `secrets` and `vars`.
    ///
    /// Server-valid as written: the `org` hop reads `membership.orgId` off
    /// `self`, so `membership` is declared on `self` — the server rejects a
    /// `via` whose category isn't declared on its source node
    /// (`PATH_VIA_UNDECLARED_CATEGORY`).
    static let manifestJSON = """
    {
      "self": { "categories": ["billing", "membership", "profile"] },
      "paths": {
        "org": {
          "from": "self", "via": "membership.orgId",
          "type": "group", "categories": ["plan"]
        },
        "actor": {
          "rootFrom": "user.userId",
          "type": "user", "categories": ["tier"]
        }
      },
      "secrets": ["STRIPE_KEY"],
      "vars": ["TIER"]
    }
    """

    /// Decodes a JSON string into the type-erased graph, for shape asserts.
    static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: - DeclaredMetadataManifest

    func test_manifest_decodesEveryJSField() throws {
        let manifest = try JSONDecoder().decode(
            DeclaredMetadataManifest.self, from: Data(Self.manifestJSON.utf8)
        )

        XCTAssertEqual(manifest.selfCategories?.categories, ["billing", "membership", "profile"])
        XCTAssertEqual(manifest.secrets, ["STRIPE_KEY"])
        XCTAssertEqual(manifest.vars, ["TIER"])

        guard case .from(let from, let via, let type, let categories) =
            try XCTUnwrap(manifest.paths?["org"])
        else { return XCTFail("`org` should decode as a from/via hop") }
        XCTAssertEqual(from, "self")
        XCTAssertEqual(via, "membership.orgId")
        XCTAssertEqual(type, "group")
        XCTAssertEqual(categories, ["plan"])

        guard case .rootFrom(let rootFrom, let rootType, let rootCategories) =
            try XCTUnwrap(manifest.paths?["actor"])
        else { return XCTFail("`actor` should decode as a rootFrom root") }
        XCTAssertEqual(rootFrom, "user.userId")
        XCTAssertEqual(rootType, "user")
        XCTAssertEqual(rootCategories, ["tier"])
    }

    /// Re-encoding what the server sent must produce the same JSON — including
    /// the `self` wire key, which Swift spells `selfCategories` because `self`
    /// is a keyword.
    func test_manifest_reEncodesTheWireShapeItDecoded() throws {
        let manifest = try JSONDecoder().decode(
            DeclaredMetadataManifest.self, from: Data(Self.manifestJSON.utf8)
        )

        let encoded = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(manifest)
        )
        XCTAssertEqual(encoded, try Self.json(Self.manifestJSON))
    }

    /// A path carries exactly one rooting: the `from`/`via` variant must not
    /// emit a `rootFrom` key (and vice versa), which is what the server's
    /// `validatePathGraph` rejects with a 400.
    func test_manifestPath_omitsTheOtherVariantsKeys() throws {
        let hop = DeclaredManifestPath.from(
            from: "self", via: "membership.orgId", type: "group", categories: ["plan"]
        )
        guard case .object(let hopObject) = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(hop)
        ) else { return XCTFail("A path should encode as a JSON object") }
        XCTAssertEqual(Set(hopObject.keys), ["from", "via", "type", "categories"])

        let root = DeclaredManifestPath.rootFrom(
            rootFrom: "user.userId", type: "user", categories: ["tier"]
        )
        guard case .object(let rootObject) = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(root)
        ) else { return XCTFail("A path should encode as a JSON object") }
        XCTAssertEqual(Set(rootObject.keys), ["rootFrom", "type", "categories"])
    }

    /// Decoding enforces the same exclusivity the enum encodes: a path that
    /// carries both rootings, or a `rootFrom` next to a `via`, is corrupt wire
    /// data (the server 400s it on write), not a `rootFrom` path with some
    /// keys to drop on the next re-encode.
    func test_manifestPath_rejectsAShapeCarryingBothRootings() throws {
        let decode = { (text: String) in
            try JSONDecoder().decode(DeclaredManifestPath.self, from: Data(text.utf8))
        }

        XCTAssertThrowsError(try decode("""
        {"from":"self","via":"membership.orgId","rootFrom":"user.userId",
         "type":"user","categories":["tier"]}
        """), "Both rootings at once must not decode")

        XCTAssertThrowsError(try decode("""
        {"via":"membership.orgId","rootFrom":"user.userId",
         "type":"user","categories":["tier"]}
        """), "A `rootFrom` alongside a `via` must not decode")

        XCTAssertThrowsError(try decode("""
        {"from":"self","type":"group","categories":["plan"]}
        """), "A `from` without its `via` must not decode")

        XCTAssertThrowsError(try decode("""
        {"type":"group","categories":["plan"]}
        """), "A path with no rooting at all must not decode")
    }

    /// An unset field stays off the wire entirely — a manifest declaring only
    /// `self` categories must not send `paths: null` / `secrets: null`.
    func test_manifest_omitsUnsetFields() throws {
        let manifest = DeclaredMetadataManifest(
            selfCategories: .init(categories: ["billing"])
        )
        guard case .object(let object) = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(manifest)
        ) else { return XCTFail("A manifest should encode as a JSON object") }
        XCTAssertEqual(Set(object.keys), ["self"])
    }

    // MARK: - CollectionTypeConfigsAPI

    /// A collection type config row carrying the manifest, as the server
    /// returns it.
    static func collectionConfigJSON(manifest: String?) -> String {
        """
        {
          "appId": "app1", "collectionType": "class-students",
          "ruleSetId": "rs1",
          "metadataManifest": \(manifest ?? "null"),
          "createdAt": "2024-01-01T00:00:00Z",
          "modifiedAt": "2024-01-01T00:00:00Z",
          "createdBy": "u1"
        }
        """
    }

    /// The request body as a JSON object, for wire-shape assertions.
    func bodyObject(_ transport: RecordingTransport) throws -> [String: JSONValue] {
        let json = try XCTUnwrap(transport.lastCall?.jsonBody, "Expected a request body")
        guard case .object(let object) = json else {
            XCTFail("Request body should be a JSON object")
            return [:]
        }
        return object
    }

    func test_collectionTypeConfig_getDecodesManifest() async throws {
        let transport = RecordingTransport(
            json: Self.collectionConfigJSON(manifest: Self.manifestJSON)
        )
        let config = try await CollectionTypeConfigsAPI(transport: transport)
            .get(collectionType: "class-students")

        let manifest = try XCTUnwrap(config.metadataManifest)
        XCTAssertEqual(manifest.selfCategories?.categories, ["billing", "membership", "profile"])
        XCTAssertEqual(manifest.paths?.count, 2)
        XCTAssertEqual(manifest.secrets, ["STRIPE_KEY"])
        XCTAssertEqual(manifest.vars, ["TIER"])
    }

    /// `metadataManifest: null` is the "none set" case, not a decode failure.
    func test_collectionTypeConfig_getDecodesNullManifestAsNil() async throws {
        let transport = RecordingTransport(json: Self.collectionConfigJSON(manifest: nil))
        let config = try await CollectionTypeConfigsAPI(transport: transport)
            .get(collectionType: "class-students")
        XCTAssertNil(config.metadataManifest)
    }

    func test_collectionTypeConfig_createSendsManifest() async throws {
        let transport = RecordingTransport(
            json: Self.collectionConfigJSON(manifest: Self.manifestJSON)
        )
        _ = try await CollectionTypeConfigsAPI(transport: transport).create(
            params: CreateCollectionTypeConfigParams(
                collectionType: "class-students",
                ruleSetId: "rs1",
                metadataManifest: DeclaredMetadataManifest(
                    selfCategories: .init(categories: ["billing"]),
                    paths: ["actor": .rootFrom(
                        rootFrom: "user.userId", type: "user", categories: ["tier"]
                    )]
                )
            )
        )

        let body = try bodyObject(transport)
        XCTAssertEqual(
            body["metadataManifest"],
            try Self.json("""
            {"self":{"categories":["billing"]},
             "paths":{"actor":{"rootFrom":"user.userId","type":"user","categories":["tier"]}}}
            """)
        )
    }

    /// Create omits the key entirely when no manifest is passed — parity with
    /// JS's optional `metadataManifest?`.
    func test_collectionTypeConfig_createOmitsUnsetManifest() async throws {
        let transport = RecordingTransport(json: Self.collectionConfigJSON(manifest: nil))
        _ = try await CollectionTypeConfigsAPI(transport: transport).create(
            params: CreateCollectionTypeConfigParams(collectionType: "class-students")
        )
        XCTAssertNil(try bodyObject(transport)["metadataManifest"])
    }

    func test_collectionTypeConfig_updateSetsClearsAndOmitsManifest() async throws {
        let api = { CollectionTypeConfigsAPI(transport: $0) }

        let setting = RecordingTransport(
            json: Self.collectionConfigJSON(manifest: Self.manifestJSON)
        )
        _ = try await api(setting).update(
            collectionType: "class-students",
            params: UpdateCollectionTypeConfigParams(
                metadataManifest: .value(
                    DeclaredMetadataManifest(secrets: ["STRIPE_KEY"])
                )
            )
        )
        XCTAssertEqual(
            try bodyObject(setting)["metadataManifest"],
            try Self.json(#"{"secrets":["STRIPE_KEY"]}"#)
        )

        let clearing = RecordingTransport(json: Self.collectionConfigJSON(manifest: nil))
        _ = try await api(clearing).update(
            collectionType: "class-students",
            params: UpdateCollectionTypeConfigParams(metadataManifest: .clear)
        )
        XCTAssertEqual(try bodyObject(clearing)["metadataManifest"], .null)

        let omitting = RecordingTransport(json: Self.collectionConfigJSON(manifest: nil))
        _ = try await api(omitting).update(
            collectionType: "class-students",
            params: UpdateCollectionTypeConfigParams(ruleSetId: .value("rs2"))
        )
        XCTAssertNil(try bodyObject(omitting)["metadataManifest"])
    }

    // MARK: - DatabaseTypeConfigsAPI

    /// A database type config row carrying the manifest, as the server returns
    /// it.
    static func databaseConfigJSON(manifest: String?) -> String {
        """
        {
          "appId": "app1", "databaseType": "userDB", "ruleSetId": "rs1",
          "triggers": null, "metadataAccess": null,
          "metadataManifest": \(manifest ?? "null"),
          "createdAt": "2024-01-01T00:00:00Z",
          "modifiedAt": "2024-01-01T00:00:00Z",
          "createdBy": "u1"
        }
        """
    }

    func test_databaseTypeConfig_getDecodesManifest() async throws {
        let transport = RecordingTransport(
            json: Self.databaseConfigJSON(manifest: Self.manifestJSON)
        )
        let config = try await DatabaseTypeConfigsAPI(transport: transport)
            .get(databaseType: "userDB")

        let manifest = try XCTUnwrap(config.metadataManifest)
        XCTAssertEqual(manifest.selfCategories?.categories, ["billing", "membership", "profile"])
        XCTAssertEqual(manifest.paths?.count, 2)
        XCTAssertEqual(manifest.secrets, ["STRIPE_KEY"])
        XCTAssertEqual(manifest.vars, ["TIER"])
    }

    /// `metadataManifest: null` is the "none set" case, not a decode failure.
    func test_databaseTypeConfig_getDecodesNullManifestAsNil() async throws {
        let transport = RecordingTransport(json: Self.databaseConfigJSON(manifest: nil))
        let config = try await DatabaseTypeConfigsAPI(transport: transport)
            .get(databaseType: "userDB")
        XCTAssertNil(config.metadataManifest)
    }

    func test_databaseTypeConfig_createSendsManifest() async throws {
        let transport = RecordingTransport(
            json: Self.databaseConfigJSON(manifest: Self.manifestJSON)
        )
        _ = try await DatabaseTypeConfigsAPI(transport: transport).create(
            params: CreateDatabaseTypeConfigParams(
                databaseType: "userDB",
                // `membership` is declared on `self` because the `org` hop
                // reads `membership.orgId` off it — the server rejects a `via`
                // whose category isn't declared on its source node.
                metadataManifest: DeclaredMetadataManifest(
                    selfCategories: .init(categories: ["billing", "membership"]),
                    paths: ["org": .from(
                        from: "self", via: "membership.orgId",
                        type: "group", categories: ["plan"]
                    )]
                )
            )
        )

        let body = try bodyObject(transport)
        XCTAssertEqual(
            body["metadataManifest"],
            try Self.json("""
            {"self":{"categories":["billing","membership"]},
             "paths":{"org":{"from":"self","via":"membership.orgId",
                             "type":"group","categories":["plan"]}}}
            """)
        )
    }

    /// Create omits the key entirely when no manifest is passed — parity with
    /// JS's optional `metadataManifest?`.
    func test_databaseTypeConfig_createOmitsUnsetManifest() async throws {
        let transport = RecordingTransport(json: Self.databaseConfigJSON(manifest: nil))
        _ = try await DatabaseTypeConfigsAPI(transport: transport).create(
            params: CreateDatabaseTypeConfigParams(databaseType: "userDB")
        )
        XCTAssertNil(try bodyObject(transport)["metadataManifest"])
    }

    func test_databaseTypeConfig_updateSetsClearsAndOmitsManifest() async throws {
        let api = { DatabaseTypeConfigsAPI(transport: $0) }

        let setting = RecordingTransport(
            json: Self.databaseConfigJSON(manifest: Self.manifestJSON)
        )
        _ = try await api(setting).update(
            databaseType: "userDB",
            params: UpdateDatabaseTypeConfigParams(
                metadataManifest: .value(DeclaredMetadataManifest(vars: ["TIER"]))
            )
        )
        XCTAssertEqual(
            try bodyObject(setting)["metadataManifest"],
            try Self.json(#"{"vars":["TIER"]}"#)
        )

        let clearing = RecordingTransport(json: Self.databaseConfigJSON(manifest: nil))
        _ = try await api(clearing).update(
            databaseType: "userDB",
            params: UpdateDatabaseTypeConfigParams(metadataManifest: .clear)
        )
        XCTAssertEqual(try bodyObject(clearing)["metadataManifest"], .null)

        let omitting = RecordingTransport(json: Self.databaseConfigJSON(manifest: nil))
        _ = try await api(omitting).update(
            databaseType: "userDB",
            params: UpdateDatabaseTypeConfigParams(ruleSetId: .value("rs2"))
        )
        XCTAssertNil(try bodyObject(omitting)["metadataManifest"])
    }
}
