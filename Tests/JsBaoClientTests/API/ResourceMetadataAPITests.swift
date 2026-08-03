import XCTest
@testable import JsBaoClient

/// Wire-shape and decode tests for `ResourceMetadataAPI` (#1373, parity with
/// the JS client's `src/client/api/resourceMetadataApi.ts` from #1352/#1402).
///
/// These drive the sub-API through `RecordingTransport`, which records the
/// `(method, path, body)` triple and replays scripted bytes through the real
/// `Transport` decode policy — so the union decodes and the partial-success
/// batch shapes can be pinned without a server. The live behavior lives in
/// `ResourceMetadataTests.swift`.
final class ResourceMetadataAPITests: XCTestCase {

    private func api(_ transport: RecordingTransport) -> ResourceMetadataAPI {
        ResourceMetadataAPI(transport: transport)
    }

    /// The request body as a `JSONValue` object, for wire-shape assertions.
    private func bodyObject(_ transport: RecordingTransport) throws -> [String: JSONValue] {
        let json = try XCTUnwrap(transport.lastCall?.jsonBody, "Expected a request body")
        guard case .object(let object) = json else {
            XCTFail("Request body should be a JSON object")
            return [:]
        }
        return object
    }

    // MARK: - set (behavior 1)

    func test_set_putsWrappedDataAndDecodesWriteResult() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"user","resourceId":"u1","category":"profile",
         "data":{"tier":"pro","note":"hello"},"schemaVersion":1,"size":34}
        """)

        let result = try await api(transport).set(
            resourceType: "user",
            resourceId: "u1",
            category: "profile",
            data: ["tier": "pro", "note": "hello"]
        )

        XCTAssertEqual(transport.lastCall?.method, .put)
        XCTAssertEqual(transport.lastCall?.path, "/resources/user/u1/metadata/profile")

        // The body is `{ "data": {...} }` — the wrapped form the JS client sends.
        let body = try bodyObject(transport)
        XCTAssertEqual(body["data"], .object(["tier": .string("pro"), "note": .string("hello")]))

        XCTAssertEqual(result.resourceType, "user")
        XCTAssertEqual(result.resourceId, "u1")
        XCTAssertEqual(result.category, "profile")
        XCTAssertEqual(result.data["tier"], .string("pro"))
        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.size, 34)
    }

    /// `data` is round-tripped verbatim through `JSONValue` — nested objects,
    /// arrays, numbers, booleans, and `null` all survive in both directions.
    func test_set_roundTripsNestedJSONValues() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"db","resourceId":"d1","category":"settings",
         "data":{"nested":{"a":[1,2,3]},"flag":true,"count":7,"empty":null},
         "schemaVersion":2,"size":51}
        """)

        let sent: [String: JSONValue] = [
            "nested": .object(["a": .array([1, 2, 3])]),
            "flag": true,
            "count": 7,
            "empty": .null,
        ]
        let result = try await api(transport).set(
            resourceType: "db", resourceId: "d1", category: "settings", data: sent
        )

        XCTAssertEqual(try bodyObject(transport)["data"], .object(sent))
        XCTAssertEqual(result.data["nested"], .object(["a": .array([1, 2, 3])]))
        XCTAssertEqual(result.data["flag"], .bool(true))
        XCTAssertEqual(result.data["count"], .number(7))
        XCTAssertEqual(result.data["empty"], .null)
    }

    // MARK: - get (behaviors 2, 3)

    func test_get_decodesTheExistingReadShape() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"user","resourceId":"u1","category":"profile",
         "data":{"tier":"pro"},"schemaVersion":1,"exists":true}
        """)

        let result = try await api(transport).get(
            resourceType: "user", resourceId: "u1", category: "profile"
        )

        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/resources/user/u1/metadata/profile")
        XCTAssertNil(transport.lastCall?.body, "A GET must not carry a body")
        XCTAssertTrue(result.exists)
        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.data["tier"], .string("pro"))
    }

    /// Behavior 3 / edge case: nothing stored is a SUCCESS — `exists: false`,
    /// empty `data`, and a `null` `schemaVersion` that decodes to `nil`.
    func test_get_decodesTheMissingReadShapeWithNullSchemaVersion() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"user","resourceId":"u2","category":"profile",
         "data":{},"schemaVersion":null,"exists":false}
        """)

        let result = try await api(transport).get(
            resourceType: "user", resourceId: "u2", category: "profile"
        )

        XCTAssertFalse(result.exists)
        XCTAssertNil(result.schemaVersion)
        XCTAssertTrue(result.data.isEmpty)
    }

    /// Edge case: a field the client does not know about must not fail the
    /// decode — the server can add response fields without breaking old apps.
    func test_get_toleratesUnknownResponseFields() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"user","resourceId":"u1","category":"profile",
         "data":{"tier":"pro"},"schemaVersion":1,"exists":true,
         "somethingNewTheServerAdded":{"x":1}}
        """)

        let result = try await api(transport).get(
            resourceType: "user", resourceId: "u1", category: "profile"
        )
        XCTAssertTrue(result.exists)
    }

    // MARK: - getBatch (behaviors 4, 5, 6)

    func test_getBatch_postsRequestsAndDecodesPerCategoryResults() async throws {
        let transport = RecordingTransport(json: """
        {"results":[
          {"resourceType":"user","resourceId":"uA","ok":true,"categories":{
             "profile":{"ok":true,"data":{"tier":"pro"},"schemaVersion":1,"exists":true},
             "billing":{"ok":false,"status":403,"code":"FORBIDDEN","message":"denied"}}},
          {"resourceType":"user","resourceId":"uB","ok":true,"categories":{
             "profile":{"ok":true,"data":{},"schemaVersion":null,"exists":false}}}
        ]}
        """)

        let result = try await api(transport).getBatch(requests: [
            .init(resourceType: "user", resourceId: "uA", categories: ["profile", "billing"]),
            .init(resourceType: "user", resourceId: "uB", categories: ["profile"]),
        ])

        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/resources/metadata/batch")

        // Wire shape: `{ "requests": [ { resourceType, resourceId, categories } ] }`.
        let body = try bodyObject(transport)
        XCTAssertEqual(
            body["requests"],
            .array([
                .object([
                    "resourceType": .string("user"),
                    "resourceId": .string("uA"),
                    "categories": .array([.string("profile"), .string("billing")]),
                ]),
                .object([
                    "resourceType": .string("user"),
                    "resourceId": .string("uB"),
                    "categories": .array([.string("profile")]),
                ]),
            ])
        )

        // Results come back in request order.
        XCTAssertEqual(result.results.count, 2)
        XCTAssertEqual(result.results.map(\.resourceId), ["uA", "uB"])

        // Behavior 5: a denied category is an entry, not a thrown error, and
        // its successful sibling still decodes.
        let uA = try XCTUnwrap(result.results.first)
        XCTAssertTrue(uA.ok)
        let profile = try XCTUnwrap(uA.categories?["profile"])
        XCTAssertTrue(profile.ok)
        XCTAssertEqual(profile.exists, true)
        XCTAssertEqual(profile.data?["tier"], .string("pro"))
        XCTAssertNil(profile.error)

        let billing = try XCTUnwrap(uA.categories?["billing"])
        XCTAssertFalse(billing.ok)
        XCTAssertNil(billing.data)
        let billingError = try XCTUnwrap(billing.error)
        XCTAssertEqual(billingError.status, 403)
        XCTAssertEqual(billingError.code, "FORBIDDEN")
        XCTAssertEqual(billingError.message, "denied")

        // The `null` schemaVersion on the `ok: true` arm decodes to nil.
        let uBProfile = try XCTUnwrap(result.results.last?.categories?["profile"])
        XCTAssertEqual(uBProfile.exists, false)
        XCTAssertNil(uBProfile.schemaVersion)
    }

    /// Behavior 6: a whole-item fault carries the error triple at the resource
    /// level and no `categories` map.
    func test_getBatch_decodesWholeItemFailures() async throws {
        let transport = RecordingTransport(json: """
        {"results":[
          {"resourceType":"user","resourceId":"uA","ok":false,
           "status":400,"code":"INVALID_REQUEST","message":"categories is required"}
        ]}
        """)

        let result = try await api(transport).getBatch(requests: [
            .init(resourceType: "user", resourceId: "uA", categories: []),
        ])

        let item = try XCTUnwrap(result.results.first)
        XCTAssertFalse(item.ok)
        XCTAssertNil(item.categories)
        let error = try XCTUnwrap(item.error)
        XCTAssertEqual(error.status, 400)
        XCTAssertEqual(error.code, "INVALID_REQUEST")
        XCTAssertEqual(error.message, "categories is required")
    }

    // MARK: - resolve (#2139)

    /// A hit decodes into both fields and surfaces through `resolved`, and the
    /// lookup travels in the POST body of the static `/metadata/resolve` path.
    func test_resolve_postsTheLookupBodyAndDecodesAHit() async throws {
        let transport = RecordingTransport(json: """
        {"resourceId":"u1","resourceType":"user"}
        """)

        let result = try await api(transport).resolve(
            resourceType: "user",
            category: "billing",
            key: "stripeCustomerId",
            value: "cus_ABC"
        )

        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/metadata/resolve")

        XCTAssertEqual(
            try bodyObject(transport),
            [
                "resourceType": .string("user"),
                "category": .string("billing"),
                "key": .string("stripeCustomerId"),
                "value": .string("cus_ABC"),
            ]
        )

        XCTAssertEqual(result.resourceId, "u1")
        XCTAssertEqual(result.resourceType, "user")
        XCTAssertEqual(
            result.resolved,
            ResourceMetadataResolvedResource(resourceId: "u1", resourceType: "user")
        )
    }

    /// A miss is a SUCCESS with `resourceId: null` and no `resourceType` —
    /// never a thrown error.
    func test_resolve_decodesAMissAsNilResourceId() async throws {
        let transport = RecordingTransport(json: #"{"resourceId":null}"#)

        let result = try await api(transport).resolve(
            resourceType: "user",
            category: "billing",
            key: "stripeCustomerId",
            value: "cus_NOBODY"
        )

        XCTAssertNil(result.resourceId)
        XCTAssertNil(result.resourceType)
        XCTAssertNil(result.resolved)
    }

    /// A rule-denied resolve must be indistinguishable from a genuine miss: the
    /// server answers both with the same miss shape, so the client must decode
    /// both to the same value and must not expose any extra signal.
    ///
    /// The denial arm is fed a body carrying an extra `denied` field the current
    /// result type does not model, so the assertion is a real constraint on the
    /// type rather than `decode(x) == decode(x)`: it fails the moment
    /// `ResourceMetadataResolveResult` grows a field that lets a caller tell a
    /// denial from a miss.
    func test_resolve_ruleDeniedIsIndistinguishableFromAMiss() async throws {
        let missTransport = RecordingTransport(json: #"{"resourceId":null}"#)
        let miss = try await api(missTransport).resolve(
            resourceType: "user", category: "billing",
            key: "stripeCustomerId", value: "cus_NOBODY"
        )

        // A value that exists but whose readRule denies this caller.
        let deniedTransport = RecordingTransport(json: #"{"resourceId":null,"denied":true}"#)
        let denied = try await api(deniedTransport).resolve(
            resourceType: "user", category: "billing",
            key: "stripeCustomerId", value: "cus_OWNED_BY_SOMEONE_ELSE"
        )

        XCTAssertEqual(denied, miss)
        XCTAssertNil(denied.resolved)
    }

    /// `NOT_UNIQUE_FIELD` is a configuration error, not a miss: it throws, and
    /// the code is readable off `HttpError.serverCode` — the same typed-error
    /// convention the namespace's other verbs use.
    func test_resolve_notUniqueFieldThrowsA400ConfigError() async throws {
        let transport = RecordingTransport(
            status: 400,
            json: """
            {"error":"\\"status\\" is not a declared unique field on category \\"billing\\" (user)",
             "code":"NOT_UNIQUE_FIELD"}
            """
        )

        do {
            _ = try await api(transport).resolve(
                resourceType: "user", category: "billing",
                key: "status", value: "active"
            )
            XCTFail("A non-unique key must throw, not report a miss")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.serverCode, "NOT_UNIQUE_FIELD")
        }
    }

    /// An undefined category is a 404, distinct from both a miss and the
    /// non-unique-key config error.
    func test_resolve_undefinedCategoryThrowsHttpError404() async throws {
        let transport = RecordingTransport(
            status: 404,
            json: #"{"error":"Category not found","code":"CATEGORY_NOT_FOUND"}"#
        )

        do {
            _ = try await api(transport).resolve(
                resourceType: "user", category: "nope",
                key: "stripeCustomerId", value: "cus_ABC"
            )
            XCTFail("An undefined category must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
        }
    }

    /// Edge case: the empty string is a valid indexed value, so it must be sent
    /// verbatim and its hit decoded — the client must not shortcut `""` into a
    /// miss or drop the key from the body.
    func test_resolve_sendsAnEmptyStringValueAndDecodesItsHit() async throws {
        let transport = RecordingTransport(json: """
        {"resourceId":"u1","resourceType":"user"}
        """)

        let result = try await api(transport).resolve(
            resourceType: "user", category: "billing",
            key: "stripeCustomerId", value: ""
        )

        XCTAssertEqual(try bodyObject(transport)["value"], .string(""))
        XCTAssertEqual(result.resolved?.resourceId, "u1")
    }

    /// A field the client does not know about must not fail the decode.
    func test_resolve_toleratesUnknownResponseFields() async throws {
        let transport = RecordingTransport(json: """
        {"resourceId":"u1","resourceType":"user","somethingNewTheServerAdded":true}
        """)

        let result = try await api(transport).resolve(
            resourceType: "user", category: "billing",
            key: "stripeCustomerId", value: "cus_ABC"
        )
        XCTAssertEqual(result.resourceId, "u1")
    }

    // MARK: - list (behavior 7)

    func test_list_getsTheResourcePathAndDecodesEntries() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"user","resourceId":"u1","categories":[
          {"category":"profile","data":{"tier":"pro"},"schemaVersion":1},
          {"category":"prefs","data":{"theme":"dark"},"schemaVersion":null}
        ]}
        """)

        let result = try await api(transport).list(resourceType: "user", resourceId: "u1")

        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/resources/user/u1/metadata")
        XCTAssertEqual(result.categories.map(\.category), ["profile", "prefs"])
        XCTAssertEqual(result.categories.first?.data["tier"], .string("pro"))
        XCTAssertEqual(result.categories.first?.schemaVersion, 1)
        XCTAssertNil(result.categories.last?.schemaVersion)
    }

    func test_list_decodesAnEmptyResource() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"user","resourceId":"u9","categories":[]}
        """)

        let result = try await api(transport).list(resourceType: "user", resourceId: "u9")
        XCTAssertTrue(result.categories.isEmpty)
    }

    // MARK: - delete (behavior 8)

    func test_delete_deletesTheCategoryPathAndDecodesTheFlag() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"user","resourceId":"u1","category":"profile","deleted":true}
        """)

        let result = try await api(transport).delete(
            resourceType: "user", resourceId: "u1", category: "profile"
        )

        XCTAssertEqual(transport.lastCall?.method, .delete)
        XCTAssertEqual(transport.lastCall?.path, "/resources/user/u1/metadata/profile")
        XCTAssertTrue(result.deleted)
    }

    func test_delete_decodesTheAbsentItemAsDeletedFalse() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"user","resourceId":"u1","category":"profile","deleted":false}
        """)

        let result = try await api(transport).delete(
            resourceType: "user", resourceId: "u1", category: "profile"
        )
        XCTAssertFalse(result.deleted)
    }

    // MARK: - Denials (behavior 10)

    func test_singleCallDenialThrowsHttpError403() async throws {
        let transport = RecordingTransport(
            status: 403,
            json: #"{"error":"Forbidden","code":"FORBIDDEN"}"#
        )

        do {
            _ = try await api(transport).get(
                resourceType: "user", resourceId: "u1", category: "locked"
            )
            XCTFail("A readRule denial must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
    }

    // MARK: - Path encoding (edge case)

    func test_pathParametersArePercentEncoded() async throws {
        // Space and `#` are outside `.urlPathAllowed`, so a correct
        // implementation escapes them to `%20` / `%23` before the transport
        // assembles the path.
        let transport = RecordingTransport(json: """
        {"resourceType":"t","resourceId":"i","category":"c","data":{},
         "schemaVersion":null,"exists":false}
        """)
        _ = try await api(transport).get(
            resourceType: "res type", resourceId: "id#7", category: "cat name"
        )
        XCTAssertEqual(
            transport.lastCall?.path,
            "/resources/res%20type/id%237/metadata/cat%20name"
        )

        let listTransport = RecordingTransport(json: """
        {"resourceType":"t","resourceId":"i","categories":[]}
        """)
        _ = try await api(listTransport).list(resourceType: "res type", resourceId: "id#7")
        XCTAssertEqual(listTransport.lastCall?.path, "/resources/res%20type/id%237/metadata")

        let deleteTransport = RecordingTransport(json: """
        {"resourceType":"t","resourceId":"i","category":"c","deleted":false}
        """)
        _ = try await api(deleteTransport).delete(
            resourceType: "res type", resourceId: "id#7", category: "cat name"
        )
        XCTAssertEqual(
            deleteTransport.lastCall?.path,
            "/resources/res%20type/id%237/metadata/cat%20name"
        )
    }

    /// A `/` inside a path parameter must be escaped to `%2F`, not passed
    /// through as a path separator.
    ///
    /// `.urlPathAllowed` is the set of characters legal in a whole path, so it
    /// leaves `/` alone; `HttpClient.buildURLRequest` then sets
    /// `.percentEncodedPath`, which passes the string through verbatim. A
    /// slash-carrying `resourceType` / `resourceId` / `category` would
    /// therefore be sent as extra path segments and routed to a different
    /// endpoint. The JS client escapes these with `encodeURIComponent`, so this
    /// pins the shared `URLEncoding.encodeComponent` set (#2076) for every verb
    /// that builds a path.
    func test_pathParametersEscapeSlashAsASegment() async throws {
        let readTransport = RecordingTransport(json: """
        {"resourceType":"t","resourceId":"i","category":"c","data":{},
         "schemaVersion":null,"exists":false}
        """)
        _ = try await api(readTransport).get(
            resourceType: "a/b", resourceId: "foo/bar", category: "x/y"
        )
        XCTAssertEqual(
            readTransport.lastCall?.path,
            "/resources/a%2Fb/foo%2Fbar/metadata/x%2Fy"
        )

        let setTransport = RecordingTransport(json: """
        {"resourceType":"t","resourceId":"i","category":"c","data":{},
         "schemaVersion":1,"size":2}
        """)
        _ = try await api(setTransport).set(
            resourceType: "a/b", resourceId: "foo/bar", category: "x/y", data: [:]
        )
        XCTAssertEqual(
            setTransport.lastCall?.path,
            "/resources/a%2Fb/foo%2Fbar/metadata/x%2Fy"
        )

        let listTransport = RecordingTransport(json: """
        {"resourceType":"t","resourceId":"i","categories":[]}
        """)
        _ = try await api(listTransport).list(resourceType: "a/b", resourceId: "foo/bar")
        XCTAssertEqual(listTransport.lastCall?.path, "/resources/a%2Fb/foo%2Fbar/metadata")

        let deleteTransport = RecordingTransport(json: """
        {"resourceType":"t","resourceId":"i","category":"c","deleted":true}
        """)
        _ = try await api(deleteTransport).delete(
            resourceType: "a/b", resourceId: "foo/bar", category: "x/y"
        )
        XCTAssertEqual(
            deleteTransport.lastCall?.path,
            "/resources/a%2Fb/foo%2Fbar/metadata/x%2Fy"
        )
    }

    /// The common case stays byte-for-byte the raw form: a slug resource type
    /// and a ULID id carry no character the segment-safe set escapes, so
    /// tightening the charset can't have changed any reachable path.
    func test_slugAndUlidPathParametersPassThroughUnchanged() async throws {
        let transport = RecordingTransport(json: """
        {"resourceType":"t","resourceId":"i","category":"c","data":{},
         "schemaVersion":null,"exists":false}
        """)
        _ = try await api(transport).get(
            resourceType: "user",
            resourceId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            category: "profile"
        )
        XCTAssertEqual(
            transport.lastCall?.path,
            "/resources/user/01ARZ3NDEKTSV4RRFFQ69G5FAV/metadata/profile"
        )
    }

    // MARK: - Client wiring (behavior 9)

    func test_clientExposesResourceMetadata() {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://localhost:8787",
            wsUrl: "ws://localhost:8787",
            appId: "app_test",
            token: "test-token",
            offline: true,
            autoNetwork: false
        ))
        XCTAssertNotNil(client.resourceMetadata, "client.resourceMetadata must be wired")
    }
}
