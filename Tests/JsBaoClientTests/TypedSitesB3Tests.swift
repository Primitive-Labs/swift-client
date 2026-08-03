import XCTest
@testable import JsBaoClient

/// Server-free tests for the non-mechanical conversions of #1991 Phase B3:
/// `AuthController` (behavior 5), `DoDb` (behavior 6), `MeAPI` (behavior 9's
/// `MeAPI.get` parity edge case), and `BlobManager` (behavior 8's blob call
/// site).
///
/// Everything runs against a `RecordingTransport`, so each test asserts the
/// exact bytes the converted site puts on the wire and the typed value it
/// gets back.
final class TypedSitesB3Tests: XCTestCase {

    // MARK: - Helpers

    private func makeController(
        transport: (any Transport)? = nil,
        refreshProxy: RefreshProxyConfig? = nil,
        emitter: EventEmitter = EventEmitter()
    ) -> AuthController {
        let controller = AuthController(
            appId: "test-app",
            apiUrl: "http://localhost:8787",
            logger: Logger(level: .error),
            offlineStore: OfflineStore(),
            emitter: emitter,
            refreshProxy: refreshProxy,
            persistConfig: AuthConfig()
        )
        if let transport = transport { controller.setTransport(transport) }
        return controller
    }

    // MARK: - Behavior 5: AuthController holds a lock-guarded one-shot transport

    func testAuthControllerThrowsUntilATransportIsInstalled() async throws {
        let controller = makeController()

        do {
            _ = try await controller.otpRequest(email: "a@b.c")
            XCTFail("expected an unavailable error before setTransport")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }

    func testSetTransportInstallsTheTransportForEveryRequestPath() async throws {
        let transport = RecordingTransport(json: #"{"success": true}"#)
        let controller = makeController()
        controller.setTransport(transport)

        let requested = try await controller.otpRequest(email: "a@b.c")

        XCTAssertTrue(requested)
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/auth/otp/request")
        XCTAssertEqual(transport.lastCall?.jsonBody?["email"]?.stringValue, "a@b.c")
    }

    // MARK: - Behavior 5: typed DTOs, decoding moved inward

    func testOtpVerifyReturnsTheTypedResultAndAppliesTheToken() async throws {
        let token = makeTestJwt(userId: "u-otp")
        let transport = RecordingTransport(json: #"""
        {"token": "\#(token)", "user": {"userId": "u-otp", "email": "otp@example.com"}, "isNewUser": true}
        """#)
        let controller = makeController(transport: transport)

        let result = try await controller.otpVerify(email: "otp@example.com", code: "123456")

        XCTAssertEqual(result, OtpVerifyResult(
            user: AuthUser(userId: "u-otp", email: "otp@example.com", name: nil),
            isNewUser: true
        ))
        // The envelope's `token` never reaches the caller — it is applied.
        XCTAssertEqual(controller.getToken(), token)
        XCTAssertEqual(controller.getUserId(), "u-otp")
    }

    func testMagicLinkVerifyReturnsTheTypedResultAndAppliesTheToken() async throws {
        let token = makeTestJwt(userId: "u-ml")
        let transport = RecordingTransport(json: #"""
        {"token": "\#(token)", "user": {"userId": "u-ml", "email": "ml@example.com"}, "promptAddPasskey": true}
        """#)
        let controller = makeController(transport: transport)

        let result = try await controller.magicLinkVerify(token: "ml-token")

        XCTAssertEqual(result.user.userId, "u-ml")
        XCTAssertEqual(result.promptAddPasskey, true)
        XCTAssertEqual(controller.getToken(), token)
    }

    /// A 2xx with a `user` but no `token` used to return a fully-populated
    /// "success" result while the client stayed signed out — and since the
    /// typed surface hides the token, the caller had no way to notice. It is
    /// now the contract violation it always was.
    func testVerifyWithoutATokenFailsInsteadOfReturningAFalseSuccess() async throws {
        let body = #"{"user": {"userId": "u-x", "email": "x@example.com"}}"#

        for verify in [
            { (c: AuthController) in try await c.magicLinkVerify(token: "t") as Any },
            { (c: AuthController) in try await c.otpVerify(email: "x@example.com", code: "1") as Any },
            { (c: AuthController) in
                try await c.passkeyAuthFinish(credential: .object([:]), challengeToken: "ct") as Any
            },
        ] {
            let controller = makeController(transport: RecordingTransport(json: body))
            do {
                _ = try await verify(controller)
                XCTFail("a token-less 2xx must not read as a successful sign-in")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .unavailable)
            }
            XCTAssertNil(controller.getToken(), "no session should have been established")
        }
    }

    /// Magic-link and OTP tokens are single-use, so the token is applied
    /// *before* the rest of the envelope decodes: a mismatch on a sibling
    /// field must not burn the credential and leave the user with no session
    /// and no retry.
    func testVerifyAppliesTheTokenBeforeDecodingTheRestOfTheEnvelope() async throws {
        let token = makeTestJwt(userId: "u-early")
        // `user` is required by the envelope and missing here.
        let transport = RecordingTransport(json: #"{"token": "\#(token)", "isNewUser": true}"#)
        let controller = makeController(transport: transport)

        do {
            _ = try await controller.magicLinkVerify(token: "ml-token")
            XCTFail("expected the envelope decode to fail")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, HttpError.decodingFailedCode)
            XCTAssertNil(error.body, "an auth-path decode failure must not carry the raw body")
        }

        XCTAssertEqual(controller.getToken(), token, "the single-use token must already be applied")
    }

    func testHandleOAuthCallbackReturnsTheTypedResult() async throws {
        let token = makeTestJwt(userId: "u-oauth")
        let transport = RecordingTransport(json: #"{"token": "\#(token)", "isNewUser": true}"#)
        let controller = makeController(transport: transport)

        let result = try await controller.handleOAuthCallback(code: "code", state: "state")

        XCTAssertEqual(result, OAuthCallbackResult(token: token, isNewUser: true))
        XCTAssertEqual(controller.getToken(), token)
        // No PKCE verifier was pending, so the legacy GET path is used.
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/oauth/callback?code=code&state=state")
    }

    func testPasskeyAuthStartSplitsOptionsFromTheChallengeToken() async throws {
        let transport = RecordingTransport(json: #"""
        {"challengeToken": "ct-1", "rpId": "example.com", "challenge": "Y2hhbGxlbmdl"}
        """#)
        let controller = makeController(transport: transport)

        let result = try await controller.passkeyAuthStart()

        XCTAssertEqual(result.challengeToken, "ct-1")
        XCTAssertEqual(result.options["rpId"]?.stringValue, "example.com")
        XCTAssertNil(
            result.options["challengeToken"],
            "the challenge token is lifted out of the WebAuthn options"
        )
    }

    func testPasskeyAuthStartRejectsAResponseWithNoChallengeToken() async throws {
        let transport = RecordingTransport(json: #"{"rpId": "example.com"}"#)
        let controller = makeController(transport: transport)

        do {
            _ = try await controller.passkeyAuthStart()
            XCTFail("expected an unavailable error")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }

    func testEnableOfflineAccessProjectsTheGrantResponse() async throws {
        let transport = RecordingTransport(json: #"""
        {"rootDocId": "doc-1", "email": "a@b.c", "name": "A", "expiresAt": "2099-01-01T00:00:00Z"}
        """#)
        let controller = makeController(transport: transport)

        let result = try await controller.enableOfflineAccess()

        // Same projection AuthAPI used to apply to the raw grant dict: a
        // decodable response counts as enabled.
        XCTAssertTrue(result.enabled)
        XCTAssertNil(result.reason)
        XCTAssertEqual(controller.getOfflineGrantStatus().expiresAt, "2099-01-01T00:00:00Z")
    }

    func testNon2xxOnTheAuthPathSurfacesAsHttpError() async throws {
        let transport = RecordingTransport(
            status: 401,
            json: #"{"code": "INVALID_CODE", "error": "bad code"}"#
        )
        let controller = makeController(transport: transport)

        do {
            _ = try await controller.otpVerify(email: "a@b.c", code: "000000")
            XCTFail("expected an HttpError")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.serverCode, "INVALID_CODE")
            XCTAssertEqual(error.serverMessage, "bad code")
        }
    }

    // MARK: - Behavior 6: DoDb round-trips dynamic record fields

    func testDoDbSaveRoundTripsEveryJsonFieldKindWithoutLoss() async throws {
        let transport = RecordingTransport(json: #"{"id": "rec-1"}"#)
        let db = DoDb(databaseId: "db-1", transport: transport)

        let record: [String: JSONValue] = [
            "id": .string("rec-1"),
            "title": .string("hello"),
            "done": .bool(false),
            "count": .number(3),
            "note": .null,
            "tags": .array([.string("a"), .string("b")]),
            "nested": .object(["deep": .object(["deeper": .string("yes")])]),
        ]

        let savedId = try await db.save(modelName: "Task", data: record)

        XCTAssertEqual(savedId, "rec-1")
        let body = try XCTUnwrap(transport.lastCall?.jsonBody)
        XCTAssertEqual(body["modelName"]?.stringValue, "Task")
        XCTAssertEqual(body["id"]?.stringValue, "rec-1")
        // Every field kind survives the encode byte-for-byte, including the
        // explicit null and the nested object.
        XCTAssertEqual(body["data"], .object(record))
        XCTAssertEqual(body["data"]?["note"]?.isNull, true)
        XCTAssertEqual(body["data"]?["nested"]?["deep"]?["deeper"]?.stringValue, "yes")
    }

    func testDoDbQueryDecodesTheTypedResultAndSendsTheEngineBody() async throws {
        let transport = RecordingTransport(json: #"""
        {"data": [{"id": "rec-1", "title": "hello"}], "count": 1}
        """#)
        let db = DoDb(databaseId: "db-1", transport: transport)

        let result = try await db.query(
            modelName: "Task",
            filter: .object(["done": .bool(false)])
        )

        XCTAssertEqual(result.data.count, 1)
        XCTAssertEqual(result.data.first?["title"]?.stringValue, "hello")
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(
            transport.lastCall?.path,
            "/databases/db-1/records/query?docId=db-1"
        )
        XCTAssertEqual(
            transport.lastCall?.jsonBody?["filter"]?["done"]?.boolValue, false
        )
    }

    func testDoDbCountAcceptsANonIntegralJsonNumber() async throws {
        let transport = RecordingTransport(json: #"{"count": 7.0}"#)
        let db = DoDb(databaseId: "db-1", transport: transport)

        let count = try await db.count(modelName: "Task")

        XCTAssertEqual(count, 7)
    }

    /// A count the server could never legitimately send must not take the
    /// process down with it. `Int(_: Double)` is a **trapping** conversion —
    /// NaN, ±infinity and anything past `Int.max` abort — and this is a
    /// response parser reading untrusted bytes (same failure class as #2056).
    func testDoDbCountRejectsAnUnrepresentableNumberInsteadOfTrapping() async throws {
        for wire in ["1e300", "-1e300"] {
            let transport = RecordingTransport(json: #"{"count": \#(wire)}"#)
            let db = DoDb(databaseId: "db-1", transport: transport)
            do {
                _ = try await db.count(modelName: "Task")
                XCTFail("expected a DoDbError for \(wire)")
            } catch let error as DoDbError {
                XCTAssertEqual(error, .unexpectedResponse(field: "count"))
            }
        }
    }

    func testDoDbSurfacesAMissingContractFieldAsDoDbError() async throws {
        let transport = RecordingTransport(json: #"{}"#)
        let db = DoDb(databaseId: "db-1", transport: transport)

        do {
            _ = try await db.delete(modelName: "Task", id: "rec-1")
            XCTFail("expected a DoDbError")
        } catch let error as DoDbError {
            XCTAssertEqual(error, .unexpectedResponse(field: "success"))
        }
    }

    func testDoDbListIndexesAcceptsBothDocumentedShapes() async throws {
        let enveloped = RecordingTransport(json: #"""
        {"indexes": [{"model_name": "Task", "field_name": "done", "field_type": "boolean", "is_unique": 0, "created_at": "2026-01-01"}]}
        """#)
        let bare = RecordingTransport(json: #"""
        [{"model_name": "Task", "field_name": "done", "field_type": "boolean", "is_unique": 0, "created_at": "2026-01-01"}]
        """#)

        let fromEnvelope = try await DoDb(databaseId: "db-1", transport: enveloped).listIndexes()
        let fromArray = try await DoDb(databaseId: "db-1", transport: bare).listIndexes()

        XCTAssertEqual(fromEnvelope.count, 1)
        XCTAssertEqual(fromArray.count, 1)
        XCTAssertEqual(fromEnvelope.first?.fieldName, "done")
        XCTAssertEqual(fromArray.first?.fieldName, "done")
    }

    // MARK: - MeAPI: nil on empty AND on a malformed body (edge case)

    func testMeGetReturnsTheProfileFromTheTypedPath() async throws {
        let transport = RecordingTransport(json: #"""
        {"userId": "u1", "email": "me@example.com", "appRole": "member", "appId": "app-1"}
        """#)
        let me = MeAPI(transport: transport)

        let profile = try await me.get()

        XCTAssertEqual(profile?.userId, "u1")
        XCTAssertEqual(transport.lastCall?.path, "/me")
    }

    func testMeGetReturnsNilForAnEmptyBody() async throws {
        let me = MeAPI(transport: RecordingTransport(status: 200, body: Data()))
        let profile = try await me.get()
        XCTAssertNil(profile)
    }

    func testMeGetReturnsNilForAMalformedBody() async throws {
        // Legacy parity: before the typed spine a malformed JSON body came
        // back as text and the `try?` decode produced nil. `MeAPI.get` is the
        // one deliberate leniency site left on the typed path.
        let me = MeAPI(transport: RecordingTransport(status: 200, json: "{not json"))
        let profile = try await me.get()
        XCTAssertNil(profile)
    }

    func testMeGetStillThrowsOnANon2xxStatus() async throws {
        let me = MeAPI(transport: RecordingTransport(status: 500, json: #"{"error": "boom"}"#))
        do {
            _ = try await me.get()
            XCTFail("expected an HttpError")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 500)
        }
    }

    func testMeGetCachesThroughTheJsonCacheAndServesTheSecondCallFromIt() async throws {
        let transport = RecordingTransport(json: #"""
        {"userId": "u1", "email": "me@example.com", "appRole": "member", "appId": "app-1"}
        """#)
        let cache = CacheFacade(
            kvCache: KvCache(),
            getNetworkMode: { .auto },
            transport: transport
        )
        let me = MeAPI(transport: transport, cache: cache)

        let first = try await me.get()
        let second = try await me.get()

        XCTAssertEqual(first?.userId, "u1")
        XCTAssertEqual(second?.userId, "u1", "the cached JSON decodes back to the same profile")
        XCTAssertEqual(transport.calls.count, 1, "the second get is served from the cache")
    }

    /// `me.update` clears the cached profile only when the server actually
    /// applied the change. A rejected update (400/403/404/409) changed nothing
    /// server-side, so the cached profile is still good and must survive —
    /// otherwise an offline-first `me.get()` after a rejected update has
    /// nothing to serve.
    func testMeUpdateKeepsTheCachedProfileWhenTheServerRejectsTheUpdate() async throws {
        let profile = #"""
        {"userId": "u1", "email": "me@example.com", "appRole": "member", "appId": "app-1"}
        """#
        let transport = RecordingTransport(responder: { call in
            if call.method == .patch {
                return TransportResponse(
                    status: 403,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error": "forbidden"}"#.utf8)
                )
            }
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(profile.utf8)
            )
        })
        let cache = CacheFacade(
            kvCache: KvCache(),
            getNetworkMode: { .auto },
            transport: transport
        )
        let me = MeAPI(transport: transport, cache: cache)

        _ = try await me.get()
        XCTAssertEqual(transport.calls.count, 1, "the priming get fetched once")

        do {
            _ = try await me.update(params: UpdateMeParams(name: "New Name"))
            XCTFail("a 403 PATCH must propagate")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }

        let afterReject = try await me.get()
        XCTAssertEqual(afterReject?.userId, "u1", "the cached profile survived the rejection")
        XCTAssertEqual(
            transport.calls.count, 2,
            "only the priming GET and the rejected PATCH hit the wire — the second get came from the cache"
        )
    }

    /// The other half of the same rule: on a 2xx the server-side update *has*
    /// happened, so the cached profile is stale even when the response body
    /// doesn't decode (`CLIENT_DECODE_FAILED`). That branch must still clear.
    func testMeUpdateClearsTheCacheWhenA2xxBodyDoesNotDecode() async throws {
        let profile = #"""
        {"userId": "u1", "email": "me@example.com", "appRole": "member", "appId": "app-1"}
        """#
        let transport = RecordingTransport(responder: { call in
            if call.method == .patch {
                return TransportResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"unexpected": true}"#.utf8)
                )
            }
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(profile.utf8)
            )
        })
        let cache = CacheFacade(
            kvCache: KvCache(),
            getNetworkMode: { .auto },
            transport: transport
        )
        let me = MeAPI(transport: transport, cache: cache)

        _ = try await me.get()

        do {
            _ = try await me.update(params: UpdateMeParams(name: "New Name"))
            XCTFail("an undecodable 2xx body must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, HttpError.decodingFailedCode)
        }

        let info = await me.cacheInfo()
        XCTAssertNil(info.updatedAt, "the applied update invalidated the cached profile")

        _ = try await me.get()
        XCTAssertEqual(
            transport.calls.count, 3,
            "the cleared cache forces a fresh GET after the update"
        )
    }

    // MARK: - CacheFacade.fetchHttp verb handling

    private func makeFacade(_ transport: any Transport) -> CacheFacade {
        CacheFacade(kvCache: KvCache(), getNetworkMode: { .auto }, transport: transport)
    }

    /// `fetchHttp` is public and takes the verb as a `String`. An unknown verb
    /// used to fall back to `.get`, so a `HEAD` (the very verb the bodyless
    /// check above it names) issued a `GET` on the wire with nothing
    /// reported.
    func testFetchHttpSendsHeadAsHeadAndRejectsAnUnknownVerb() async throws {
        let transport = RecordingTransport(json: #"{"ok": true}"#)
        let facade = makeFacade(transport)

        let _: [String: Any]? = try await facade.fetchHttp(method: "head", path: "/things")
        XCTAssertEqual(try XCTUnwrap(transport.lastCall).method, .head)

        do {
            let _: [String: Any]? = try await facade.fetchHttp(method: "TRACE", path: "/things")
            XCTFail("an unsupported verb must not be silently downgraded to GET")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
        XCTAssertEqual(transport.calls.count, 1, "the rejected verb never reached the wire")
    }

    /// GET/HEAD carry no body — the legacy `encodeLegacyBody` path dropped it,
    /// and the typed path must too.
    func testFetchHttpDropsTheBodyOnBodylessVerbs() async throws {
        let transport = RecordingTransport(json: #"{"ok": true}"#)
        let facade = makeFacade(transport)

        let _: [String: Any]? = try await facade.fetchHttp(
            method: "GET", path: "/things", body: ["a": 1]
        )

        XCTAssertNil(try XCTUnwrap(transport.lastCall).body, "a GET must not carry a JSON body")
    }

    func testMeUploadAvatarSendsRawBytesWithTheContentType() async throws {
        let transport = RecordingTransport(json: #"{"avatarUrl": "https://cdn/a.png"}"#)
        let me = MeAPI(transport: transport)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE])

        let result = try await me.uploadAvatar(imageData: bytes, contentType: .png)

        XCTAssertEqual(result.avatarUrl, "https://cdn/a.png")
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .post)
        XCTAssertEqual(call.path, "/me/avatar")
        XCTAssertEqual(call.body, bytes, "the image bytes go on the wire untouched")
        XCTAssertEqual(call.options?.rawBody, true)
        XCTAssertEqual(call.options?.customHeaders["Content-Type"], "image/png")
    }

    // MARK: - Behavior 8: BlobManager uploads raw bytes through requestData

    func testBlobUploadSendsUntouchedBytesAndItsHeaders() async throws {
        let transport = RecordingTransport(status: 200, json: #"{}"#)
        let manager = BlobManager(logger: Logger(level: .error), transport: transport)

        // Deliberately not valid UTF-8: the old raw closure reconstructed the
        // body from decoded text, which corrupted bytes like these.
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

        let result = try await manager.uploadImmediate(
            documentId: "doc-1",
            blobId: "blob-1",
            data: bytes,
            options: BlobUploadSourceOptions(filename: "photo.jpg", contentType: "image/jpeg")
        )

        XCTAssertEqual(result.numBytes, bytes.count)
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .put)
        XCTAssertEqual(call.path, "/documents/doc-1/blobs/blob-1")
        XCTAssertEqual(call.body, bytes)
        XCTAssertEqual(call.options?.rawBody, true)
        XCTAssertEqual(call.options?.customHeaders["Content-Type"], "image/jpeg")
        XCTAssertEqual(call.options?.customHeaders["X-Blob-Size"], "\(bytes.count)")
    }

    func testBlobUploadThrowsHttpErrorOnANon2xxStatus() async throws {
        let transport = RecordingTransport(status: 507, json: #"{"error": "full"}"#)
        let manager = BlobManager(logger: Logger(level: .error), transport: transport)

        do {
            _ = try await manager.uploadImmediate(
                documentId: "doc-1",
                blobId: "blob-1",
                data: Data([0x01])
            )
            XCTFail("expected an HttpError")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 507)
        }
    }
}
