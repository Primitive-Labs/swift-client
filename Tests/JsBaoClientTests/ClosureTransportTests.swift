import XCTest
@testable import JsBaoClient

/// Server-free tests for the deprecated-closure adapter (#1991 Phase B1,
/// behaviors 2 and 10).
///
/// `ClosureTransport` is what lets converted and un-converted API classes
/// coexist during the migration. The risk it carries is that the four legacy
/// closure shapes disagree about how a *successful empty response* is spelled:
/// `-> Any?` says `nil`, `-> Any` boxes `Optional.none` inside a non-optional
/// `Any` (`… as Any` — the shape `JsBaoClient` actually hands the API classes),
/// `-> HttpClientResponse` carries an empty `text`, and the blob shape carries
/// zero bytes. All four must arrive on the typed side as "empty", and errors
/// must keep their exact legacy mapping.
final class ClosureTransportTests: XCTestCase {

    struct Payload: Codable, Sendable, Equatable {
        let name: String
    }

    // MARK: - Boxed nil through every legacy shape (behavior 10)

    func testBoxedOptionalNoneThroughAnyClosureIsAnEmptyResponse() async throws {
        // Exactly how JsBaoClient builds the closure today:
        //   `try await self.makeRequest(method, path, data) as Any`
        let legacy: (String, String, Any?) async throws -> Any = { _, _, _ in
            let underlying: Any? = nil
            return underlying as Any
        }
        let transport = ClosureTransport(makeRequest: legacy)

        let optional: Payload? = try await transport.requestOptional(method: .get, path: "/me")
        XCTAssertNil(optional, "a boxed Optional.none must survive as an empty body, not as `null`")

        // And `send` must not throw on it — the old path returned nil happily.
        try await transport.send(method: .delete, path: "/things/1")
    }

    func testNilThroughOptionalClosureIsAnEmptyResponse() async throws {
        // AuthController's shape, which is honest about the optional.
        let transport = ClosureTransport(optionalRequest: { _, _, _ in nil })
        let optional: Payload? = try await transport.requestOptional(method: .get, path: "/auth/me")
        XCTAssertNil(optional)
    }

    func testEmptyResponseThroughHttpClientResponseClosure() async throws {
        // IntegrationsAPI's shape.
        let transport = ClosureTransport(responseRequest: { _, _, _ in
            HttpClientResponse(ok: true, status: 204, headers: [:], data: nil, text: nil)
        })
        let optional: Payload? = try await transport.requestOptional(method: .get, path: "/integrations")
        XCTAssertNil(optional)

        let raw = try await transport.requestRaw(method: .get, path: "/integrations")
        XCTAssertEqual(raw.status, 204)
    }

    /// A legacy `HttpClientResponse` closure that returns a parsed `data` but
    /// no `Content-Type` header — a hand-written closure, or a test fake —
    /// must still reach the typed side as JSON. Re-deriving the body from
    /// `text` alone lost it: with no `application/json` header the classifier
    /// hands back the raw string, and `IntegrationsAPI`'s `data?.objectValue`
    /// (the only `requestRaw` caller, and the compat path this shim exists to
    /// preserve) goes `nil`.
    func testParsedDataSurvivesAHeaderlessResponseClosure() async throws {
        let transport = ClosureTransport(responseRequest: { _, _, _ in
            HttpClientResponse(
                ok: true,
                status: 200,
                headers: [:],
                data: .object(["status": .number(201), "body": .string("hi")]),
                text: nil
            )
        })

        let raw = try await transport.requestRaw(method: .post, path: "/integrations/x/call")
        let object = try XCTUnwrap(raw.data?.objectValue, "the closure's parsed data must survive")
        XCTAssertEqual(object["status"]?.numberValue, 201)
        XCTAssertEqual(object["body"]?.stringValue, "hi")

        // And the typed path decodes it too.
        let payload: Payload? = try await ClosureTransport(responseRequest: { _, _, _ in
            HttpClientResponse(
                ok: true,
                status: 200,
                headers: [:],
                data: .object(["name": .string("typed")]),
                text: nil
            )
        }).requestOptional(method: .get, path: "/anything")
        XCTAssertEqual(payload, Payload(name: "typed"))
    }

    /// When the closure supplies both, `data` wins — `text` is only the
    /// fallback for a closure that never parsed anything.
    func testResponseClosureFallsBackToTextWhenThereIsNoParsedData() async throws {
        let transport = ClosureTransport(responseRequest: { _, _, _ in
            HttpClientResponse(
                ok: true,
                status: 200,
                headers: ["Content-Type": "application/json"],
                data: nil,
                text: "{\"name\":\"from-text\"}"
            )
        })
        let payload: Payload? = try await transport.requestOptional(method: .get, path: "/anything")
        XCTAssertEqual(payload, Payload(name: "from-text"))
    }

    func testEmptyBytesThroughBlobClosure() async throws {
        let transport = ClosureTransport(
            makeRequest: { _, _, _ in NSNull() },
            makeRawRequest: { _, _, _, _ in (Data(), 204) }
        )
        let (data, status) = try await transport.requestData(method: .get, path: "/blobs/1")
        XCTAssertEqual(data, Data())
        XCTAssertEqual(status, 204)
    }

    func testBlobClosureRoundTripsInvalidUtf8Bytes() async throws {
        let binary = Data([0xFF, 0x00, 0xFE, 0x01])
        let transport = ClosureTransport(
            makeRequest: { _, _, _ in NSNull() },
            makeRawRequest: { _, _, body, headers in
                XCTAssertEqual(body, Data([9, 9]))
                XCTAssertEqual(headers["X-Test"], "1")
                return (binary, 200)
            }
        )
        let (data, _) = try await transport.requestData(
            method: .put,
            path: "/blobs/1",
            body: Data([9, 9]),
            options: RequestOptions(customHeaders: ["X-Test": "1"])
        )
        XCTAssertEqual(data, binary)
    }

    // MARK: - Value and error pass-through

    func testValuesRoundTripThroughTheAdapter() async throws {
        let transport = ClosureTransport(makeRequest: { method, path, body in
            XCTAssertEqual(method, "POST")
            XCTAssertEqual(path, "/things")
            // The adapter converts the encoded bytes back into the graph the
            // legacy closure expects.
            let dict = try XCTUnwrap(body as? [String: Any])
            XCTAssertEqual(dict["name"] as? String, "sent")
            return ["name": "decoded"] as Any
        })

        let result: Payload = try await transport.request(
            method: .post,
            path: "/things",
            body: Payload(name: "sent")
        )
        XCTAssertEqual(result, Payload(name: "decoded"))
    }

    func testLegacyErrorsPassThroughUnchanged() async throws {
        // The legacy closure already maps non-2xx to HttpError; the adapter
        // must not re-wrap or re-classify it.
        let thrown = HttpError(
            status: 403,
            message: "HTTP 403",
            body: #"{"code":"INVITATION_REQUIRED"}"#,
            serverCode: "INVITATION_REQUIRED",
            serverMessage: "This app is invite-only"
        )
        let transport = ClosureTransport(makeRequest: { _, _, _ in throw thrown })

        do {
            let _: Payload = try await transport.request(method: .get, path: "/things")
            XCTFail("expected the legacy error to propagate")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.serverCode, "INVITATION_REQUIRED")
            XCTAssertEqual(error.serverMessage, "This app is invite-only")
        }
    }

    func testNullFromLegacyClosureStaysNullNotEmpty() async throws {
        // A literal JSON `null` is not the same as an absent body — NSNull
        // must not be collapsed into "empty".
        let transport = ClosureTransport(makeRequest: { _, _, _ in NSNull() })
        let optional: Payload? = try await transport.requestOptional(method: .get, path: "/me")
        XCTAssertNil(optional, "JSON null decodes to nil for an optional response")

        do {
            let _: Payload = try await transport.request(method: .get, path: "/me")
            XCTFail("a required response cannot be decoded from null")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, HttpError.decodingFailedCode)
        }
    }

    // MARK: - Options it cannot carry

    func testUnsupportedRequestOptionsAreRejectedNotSilentlyDropped() async throws {
        let transport = ClosureTransport(makeRequest: { _, _, _ in ["ok": true] as Any })

        for options in [
            RequestOptions(customHeaders: ["X-Custom": "1"]),
            RequestOptions(timeout: 3),
        ] {
            do {
                let _: Payload = try await transport.request(
                    method: .get,
                    path: "/things",
                    options: options
                )
                XCTFail("the legacy closure cannot carry \(options) — it must throw, not drop it")
            } catch let error as HttpError {
                XCTAssertEqual(error.serverCode, ClosureTransport.unsupportedOptionsCode)
            }
        }
    }

    func testRawBodyWithoutARawClosureIsRejected() async throws {
        let transport = ClosureTransport(makeRequest: { _, _, _ in ["ok": true] as Any })
        do {
            _ = try await transport.requestData(method: .get, path: "/blobs/1")
            XCTFail("rawBody has no legacy JSON equivalent — it must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, ClosureTransport.unsupportedOptionsCode)
        }
    }

    /// The raw closure takes headers but has no timeout parameter. Custom
    /// headers are forwarded; a timeout must be rejected rather than dropped —
    /// the one place the "reject, never drop" rule was previously not applied
    /// (now reachable from `BlobBucketsAPI` through the deprecated init).
    func testRawBodyPathForwardsHeadersButRejectsATimeout() async throws {
        let seen = HeaderBox()
        let transport = ClosureTransport(
            makeRequest: { _, _, _ in ["ok": true] as Any },
            makeRawRequest: { _, _, _, headers in
                seen.headers = headers
                return (Data("ok".utf8), 200)
            }
        )

        let (body, status) = try await transport.requestData(
            method: .get,
            path: "/blobs/1",
            options: RequestOptions(customHeaders: ["X-Blob-Filename": "a.bin"])
        )
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, Data("ok".utf8))
        XCTAssertEqual(seen.headers["X-Blob-Filename"], "a.bin", "custom headers are carried")

        do {
            _ = try await transport.requestData(
                method: .get,
                path: "/blobs/1",
                options: RequestOptions(timeout: 3)
            )
            XCTFail("the legacy raw closure has no timeout — it must throw, not drop it")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, ClosureTransport.unsupportedOptionsCode)
        }
    }

    // MARK: - Deprecated init shim still works (behavior 2)

    /// Marked deprecated so the deliberate reference to the deprecated
    /// initializer sits inside a deprecated context and emits no warning —
    /// the same pattern `DeprecationWindowInternalUseTests` uses (#1913).
    /// XCTest still discovers and runs deprecated test methods.
    @available(*, deprecated, message: "Deprecated context: exercises the deprecated init(makeRequest:) on purpose (#1991).")
    func testDeprecatedApiInitializerStillCompilesAndRoutesThroughTheAdapter() async throws {
        let recorded = Recorder()
        let api = CollectionsAPI(makeRequest: { method, path, _ in
            await recorded.record("\(method) \(path)")
            return [
                "collectionId": "col_1",
                "appId": "app_1",
                "name": "Reference",
                "collectionType": "default",
                "documentCount": 0,
                "createdAt": "2026-01-01T00:00:00.000Z",
                "createdBy": "user_1",
                "modifiedAt": "2026-01-01T00:00:00.000Z",
            ] as Any
        })

        let info = try await api.get(collectionId: "col_1")
        XCTAssertEqual(info.collectionId, "col_1")
        let calls = await recorded.calls
        XCTAssertEqual(calls, ["GET /collections/col_1"])
    }

    private actor Recorder {
        var calls: [String] = []
        func record(_ call: String) { calls.append(call) }
    }

    /// The legacy raw closure is not `@Sendable`, so a plain reference box is
    /// enough to observe the headers it was handed.
    private final class HeaderBox: @unchecked Sendable {
        var headers: [String: String] = [:]
    }
}
