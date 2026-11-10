import XCTest
@testable import JsBaoClient

/// #4968 behaviors 5 and 7 and edge case E5 — `client.db3.blobs(id)
/// .downloadRequest` is the authenticated GET of the URL `downloadUrl`
/// answers, for an image library (Kingfisher, Nuke) to send, and `read`
/// sends exactly it.
///
/// The URL is `downloadUrl`'s for the same arguments; `Authorization` carries
/// the token in force when it is called, and none without one;
/// `X-Global-Admin-App-Id` is the client's when it has one. A manager with no
/// API URL or app id cannot build it and throws `.invalidArgument`. `read`
/// sends it once on the manager's `networkSession`, observed at a capturing
/// `URLProtocol`.
final class Db3BlobDownloadRequestHermeticTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BlobDownloadCaptureURLProtocol.reset()
    }

    private func blobs(
        apiUrl: String? = "https://api.test",
        appId: String? = "app1",
        getToken: (@Sendable () -> String?)? = nil,
        getGlobalAdminAppId: (@Sendable () -> String)? = nil,
        networkSession: URLSession = NetworkSession.uncached
    ) -> Db3BlobContext {
        let transport = RecordingTransport()
        var getApiUrl: (@Sendable () -> String)?
        if let apiUrl { getApiUrl = { apiUrl } }
        var getAppId: (@Sendable () -> String)?
        if let appId { getAppId = { appId } }
        let manager = BlobManager(
            logger: createLogger(level: .error, scope: "test"), transport: transport,
            getApiUrl: getApiUrl, getAppId: getAppId,
            getToken: getToken, getGlobalAdminAppId: getGlobalAdminAppId,
            networkSession: networkSession
        )
        return Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport, blobManager: manager).blobs("D1")
    }

    // MARK: - Behavior 5

    func testTheRequestIsAGetOfTheDownloadUrl() throws {
        let context = blobs(getToken: { "t1" })
        let plain = try context.downloadRequest(blobId: "B1")
        XCTAssertEqual(plain.httpMethod, "GET")
        XCTAssertEqual(plain.url?.absoluteString, context.downloadUrl(blobId: "B1"))
        XCTAssertEqual(plain.url?.absoluteString, "https://api.test/app/app1/api/db3/D1/blobs/B1/download")

        let inline = try context.downloadRequest(blobId: "B1", disposition: .inline)
        XCTAssertEqual(inline.url?.absoluteString, context.downloadUrl(blobId: "B1", disposition: .inline))

        let attachment = try context.downloadRequest(blobId: "B/1", disposition: .attachment, attachmentFilename: "résumé 1.pdf")
        XCTAssertEqual(
            attachment.url?.absoluteString,
            context.downloadUrl(blobId: "B/1", disposition: .attachment, attachmentFilename: "résumé 1.pdf")
        )
        XCTAssertEqual(
            attachment.url?.absoluteString,
            "https://api.test/app/app1/api/db3/D1/blobs/B%2F1/download?disposition=attachment&attachmentFilename=UTF-8''r%C3%A9sum%C3%A9%201.pdf"
        )
    }

    func testTheBearerIsTheTokenInForceWhenItIsCalled() throws {
        let token = LockedBox<String?>("first-token")
        let context = blobs(getToken: { token.value })
        XCTAssertEqual(try context.downloadRequest(blobId: "B1").value(forHTTPHeaderField: "Authorization"), "Bearer first-token")
        token.value = "second-token"
        XCTAssertEqual(try context.downloadRequest(blobId: "B1").value(forHTTPHeaderField: "Authorization"), "Bearer second-token")
        token.value = nil
        XCTAssertNil(try context.downloadRequest(blobId: "B1").value(forHTTPHeaderField: "Authorization"), "no token, no header")
        XCTAssertNil(try blobs().downloadRequest(blobId: "B1").value(forHTTPHeaderField: "Authorization"))
    }

    func testTheGlobalAdminAppIdIsSentWhenTheClientHasOne() throws {
        let admin = try blobs(getToken: { "t" }, getGlobalAdminAppId: { "admin-app" }).downloadRequest(blobId: "B1")
        XCTAssertEqual(admin.value(forHTTPHeaderField: "X-Global-Admin-App-Id"), "admin-app")
        let none = try blobs(getToken: { "t" }).downloadRequest(blobId: "B1")
        XCTAssertNil(none.value(forHTTPHeaderField: "X-Global-Admin-App-Id"))
    }

    // MARK: - Behavior 7

    func testReadSendsTheDownloadRequestOnceOnTheManagersSession() async throws {
        let stub = Data("stub bytes".utf8)
        BlobDownloadCaptureURLProtocol.configure(status: 200, body: stub)
        let context = blobs(getToken: { "t1" }, getGlobalAdminAppId: { "admin-app" }, networkSession: makeCaptureSession())

        let bytes = try await context.read(blobId: "B1", force: true)
        XCTAssertEqual(bytes, stub)
        let expected = try context.downloadRequest(blobId: "B1", disposition: .inline)
        let sent = BlobDownloadCaptureURLProtocol.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.url, expected.url?.absoluteString)
        XCTAssertEqual(sent.first?.headers["Authorization"], "Bearer t1")
        XCTAssertEqual(sent.first?.headers["X-Global-Admin-App-Id"], "admin-app")
    }

    // MARK: - E5

    func testAManagerWithNoApiUrlOrAppIdThrowsInvalidArgument() {
        for context in [blobs(apiUrl: nil), blobs(appId: nil)] {
            XCTAssertThrowsError(try context.downloadRequest(blobId: "B1")) { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
            }
        }
    }
}
