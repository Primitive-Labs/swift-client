import Foundation

/// The blob download boundary for the hermetic suites (#4968): a `URLProtocol`
/// that records every request a session from `makeCaptureSession()` sends,
/// and answers the configured status and body (404 and no bytes until
/// `configure` says otherwise).
///
/// `BlobManager.read` downloads on its `networkSession`, not through the
/// `Transport`, so a `RecordingTransport` never sees a download; a manager
/// built with `networkSession: makeCaptureSession()` sends it here. State is
/// static (the loading system makes a protocol instance per request) and kept
/// in one `LockedBox`; suites call `reset()` in `setUp`.
final class BlobDownloadCaptureURLProtocol: URLProtocol {
    /// One request as it reached the boundary.
    struct Captured: Sendable {
        let url: String
        let headers: [String: String]
    }

    private struct Script {
        var status = 404
        var body = Data()
        var requests: [Captured] = []
    }

    private static let script = LockedBox(Script())

    /// Answer every request with `status` and `body`.
    static func configure(status: Int, body: Data) {
        script.withValue {
            $0.status = status
            $0.body = body
        }
    }

    static func reset() {
        script.value = Script()
    }

    /// Every request sent since the last `reset()`, oldest first.
    static var requests: [Captured] { script.value.requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let captured = Captured(url: request.url?.absoluteString ?? "", headers: request.allHTTPHeaderFields ?? [:])
        let (status, body) = Self.script.withValue { script -> (Int, Data) in
            script.requests.append(captured)
            return (script.status, script.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A session whose every request reaches `BlobDownloadCaptureURLProtocol`.
func makeCaptureSession() -> URLSession {
    makeStubSession(protocolClass: BlobDownloadCaptureURLProtocol.self)
}
