import Foundation

/// How a client reports its version and platform: two headers on every
/// app-API request, the same two names as URL parameters on the socket. Every
/// site that sets `X-Global-Admin-App-Id` applies this beside it. Reports
/// nothing unless both values are known.
struct ClientVersionHeaders: Sendable, Equatable {
    static let versionName = "X-Primitive-App-Version"
    static let platformName = "X-Primitive-App-Platform"

    /// Reports nothing.
    static let none = ClientVersionHeaders(version: nil, platform: nil)

    let version: String?
    let platform: String?

    private var pairs: [(String, String)] {
        guard let version, let platform else { return [] }
        return [(Self.versionName, version), (Self.platformName, platform)]
    }

    /// Set both headers. Call it before the request's custom headers are
    /// applied, so an app's own value for either name wins.
    func apply(to request: inout URLRequest) {
        for (name, value) in pairs {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// Both values as socket URL parameters.
    var queryItems: [URLQueryItem] {
        pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
    }
}
