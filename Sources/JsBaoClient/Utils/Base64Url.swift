import Foundation

// MARK: - Base64url

/// Padding-free base64url encoding (`+`→`-`, `/`→`_`, trailing `=`
/// stripped) — RFC 4648 §5, the format OAuth PKCE (RFC 7636) requires for
/// code verifiers/challenges and Sign in with Apple uses for nonce
/// material. Framework-free and unit-testable on any platform.
public enum Base64Url {
    /// Encode bytes as base64url without padding.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a base64url string (padded or unpadded). Returns `nil` for
    /// malformed input.
    public static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
