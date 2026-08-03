import Foundation

/// Build an unsigned JWT whose payload decodes, so `AuthController.applyToken`
/// derives a userId from it.
///
/// The client never verifies the signature — it only base64url-decodes the
/// payload segment — so a fixed `h.<payload>.s` shape is enough for any test
/// that needs a token the controller will accept and apply.
func makeTestJwt(userId: String, exp: Int = 9_999_999_999) -> String {
    let payload: [String: Any] = ["userId": userId, "sub": userId, "exp": exp]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let b64 = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "h.\(b64).s"
}
