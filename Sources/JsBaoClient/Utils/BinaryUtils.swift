import Foundation
import CryptoKit

public func toBase64(_ data: Data) -> String {
    data.base64EncodedString()
}

public func fromBase64(_ string: String) -> Data? {
    Data(base64Encoded: string)
}

public func toBase64(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
}

public func fromBase64Bytes(_ string: String) -> [UInt8]? {
    guard let data = Data(base64Encoded: string) else { return nil }
    return [UInt8](data)
}

public func hashSHA256(_ data: Data) -> Data {
    let digest = SHA256.hash(data: data)
    return Data(digest)
}

public func hashSHA256Base64(_ data: Data) -> String {
    let hashed = hashSHA256(data)
    return toBase64(hashed)
}
