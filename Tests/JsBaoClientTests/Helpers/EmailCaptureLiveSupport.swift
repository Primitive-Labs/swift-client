import Foundation
@testable import JsBaoClient

/// The credentials one captured sign-in email carries, as the dev server's
/// `debug/email-captures` route parses them.
struct SignInCredentials: Decodable, Equatable {
    let code: String?
    let link: String?
    let magicToken: String?
}

/// One email the dev server captured instead of (or before) sending it.
struct CapturedEmail: Decodable {
    let captureId: String
    let emailType: String
    let createdAt: String
    /// Present only for `email-sign-in` captures.
    let signIn: SignInCredentials?
}

private struct CapturedEmailsAnswer: Decodable {
    let captures: [CapturedEmail]
}

extension TestContext {
    /// The newest captures for `recipient` in `appId`, newest first:
    /// `GET /app/{appId}/api/debug/email-captures` with `X-Test-Auth`. The
    /// route exists only on the local dev server (capture and test routes on);
    /// anything but a 2xx throws with the status and body.
    func capturedEmails(
        appId: String, recipient: String, emailType: String? = nil
    ) async throws -> [CapturedEmail] {
        var components = URLComponents(string: "\(TestConfig.httpUrl)/app/\(appId)/api/debug/email-captures")
        var query = [URLQueryItem(name: "recipient", value: recipient)]
        if let emailType { query.append(URLQueryItem(name: "emailType", value: emailType)) }
        components?.queryItems = query
        guard let url = components?.url else {
            throw TestSetupError("bad email-captures URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(ProcessInfo.processInfo.environment["TEST_ADMIN_TOKEN"] ?? "local-test-secret", forHTTPHeaderField: "X-Test-Auth")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TestSetupError("email-captures answered \(status): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(CapturedEmailsAnswer.self, from: data).captures
    }

    /// The newest `email-sign-in` capture for `recipient` whose id is not in
    /// `excluding`, and its credentials. Polls, because the capture index can
    /// lag a read issued right after the email, and because a second request
    /// for an address the test already used must not return the first,
    /// consumed capture: pass the ids already seen. On a timeout the error
    /// carries the last answer (or the last route failure).
    func latestSignInCredentials(
        appId: String, recipient: String, excluding: Set<String> = [], timeout: TimeInterval = 10
    ) async throws -> (captureId: String, signIn: SignInCredentials) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = "no answer"
        while true {
            do {
                let captures = try await capturedEmails(appId: appId, recipient: recipient, emailType: "email-sign-in")
                if let fresh = captures.first(where: { !excluding.contains($0.captureId) }),
                   let signIn = fresh.signIn {
                    return (fresh.captureId, signIn)
                }
                last = "200 with \(captures.count) capture(s), none outside \(excluding.sorted())"
            } catch {
                last = String(describing: error)
            }
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw TestSetupError("no new sign-in email for \(recipient) within \(timeout)s: \(last)")
    }
}
