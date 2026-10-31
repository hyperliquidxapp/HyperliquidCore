import CryptoKit
import Foundation

public struct PasskeyRegistration: Sendable {
    public let credentialID: Data
    public let publicKey: Data
    public let signatureCounter: UInt32
}

/// Validates the fixed platform-passkey ceremony used to unlock local encrypted API wallets.
public enum PasskeyVerification {
    public static let relyingParty = "hypexapp.xyz"

    public static func registration(
        attestation: Data, clientData: Data, challenge: Data, credentialID: Data
    ) throws -> PasskeyRegistration {
        try verifyClient(clientData, challenge: challenge, type: "webauthn.create")
        var reader = PasskeyCBOR(data: attestation)
        guard case .map(let object) = try reader.read(), reader.complete,
              object[.text("fmt")] == .text("none"),
              case .map(let statement)? = object[.text("attStmt")], statement.isEmpty,
              case .bytes(let authenticator)? = object[.text("authData")],
              authenticator.count >= 55 else {
            throw invalid("Unsupported passkey registration")
        }
        let counter = try verifyAuthenticator(authenticator, registration: true)
        let size = Int(authenticator[53]) << 8 | Int(authenticator[54])
        guard (1...1024).contains(size), 55 + size < authenticator.count,
              credentialID == authenticator.subdata(in: 55..<(55 + size)) else {
            throw invalid("Passkey credential does not match the registration")
        }
        var publicReader = PasskeyCBOR(data: authenticator.subdata(in: (55 + size)..<authenticator.count))
        guard case .map(let cose) = try publicReader.read(),
              cose[.integer(1)] == .integer(2), cose[.integer(3)] == .integer(-7),
              cose[.integer(-1)] == .integer(1),
              case .bytes(let x)? = cose[.integer(-2)], x.count == 32,
              case .bytes(let y)? = cose[.integer(-3)], y.count == 32 else {
            throw invalid("Unsupported passkey public key")
        }
        try verifyExtensions(authenticator, reader: &publicReader)
        let publicKey = Data([4]) + x + y
        _ = try P256.Signing.PublicKey(x963Representation: publicKey)
        return PasskeyRegistration(
            credentialID: credentialID, publicKey: publicKey, signatureCounter: counter)
    }

    public static func assertion(
        authenticator: Data, clientData: Data, signature: Data, challenge: Data,
        credentialID: Data, expectedCredentialID: Data, userID: Data, expectedUserID: Data,
        publicKey: Data, previousCounter: UInt32
    ) throws -> UInt32 {
        guard !credentialID.isEmpty, credentialID == expectedCredentialID, userID == expectedUserID else {
            throw invalid("The selected passkey belongs to a different wallet")
        }
        try verifyClient(clientData, challenge: challenge, type: "webauthn.get")
        let counter = try verifyAuthenticator(authenticator, registration: false)
        if counter != 0 || previousCounter != 0 {
            guard counter > previousCounter else {
                throw invalid("Passkey verification counter did not advance")
            }
        }
        var extensionReader = PasskeyCBOR(data: Data(authenticator.dropFirst(37)))
        try verifyExtensions(authenticator, reader: &extensionReader)
        let key = try P256.Signing.PublicKey(x963Representation: publicKey)
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard key.isValidSignature(parsed, for: authenticator + Data(SHA256.hash(data: clientData))) else {
            throw invalid("Passkey signature verification failed")
        }
        return counter
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private struct ClientData: Decodable {
        let type: String
        let challenge: String
        let origin: String
        let crossOrigin: Bool?
        let topOrigin: String?
    }

    private static func verifyClient(_ data: Data, challenge: Data, type: String) throws {
        guard (32...256).contains(challenge.count), data.count <= 16_384 else {
            throw invalid("Invalid passkey challenge")
        }
        let client = try JSONDecoder().decode(ClientData.self, from: data)
        guard client.type == type, client.challenge == base64URL(challenge),
              client.origin == "https://" + relyingParty,
              client.crossOrigin != true, client.topOrigin == nil else {
            throw invalid("Passkey challenge or website did not match")
        }
    }

    private static func verifyAuthenticator(_ data: Data, registration: Bool) throws -> UInt32 {
        guard (37...65_536).contains(data.count),
              data.prefix(32) == Data(SHA256.hash(data: Data(relyingParty.utf8))) else {
            throw invalid("Passkey website did not match")
        }
        let flags = data[32]
        guard flags & 0x05 == 0x05, (flags & 0x40 != 0) == registration,
              flags & 0x10 == 0 || flags & 0x08 != 0 else {
            throw invalid("Passkey requires verified user presence")
        }
        return data[33..<37].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func verifyExtensions(_ data: Data, reader: inout PasskeyCBOR) throws {
        if data[32] & 0x80 != 0 {
            guard case .map = try reader.read() else { throw invalid("Invalid passkey extensions") }
        }
        guard reader.complete else { throw invalid("Unexpected passkey data") }
    }

    private static func invalid(_ message: String) -> WalletError { .invalid(message) }
}

/// Bounded definite-length CBOR decoding for WebAuthn's attestation and COSE maps.
private struct PasskeyCBOR {
    enum Key: Hashable { case integer(Int64), text(String) }
    indirect enum Value: Equatable {
        case integer(Int64), bytes(Data), text(String), map([Key: Value]), array([Value]), bool(Bool), null
    }
    let data: Data
    private var offset = 0
    var complete: Bool { offset == data.count }
    init(data: Data) { self.data = data }

    mutating func read(depth: Int = 0) throws -> Value {
        guard depth < 12, data.count <= 65_536 else { throw invalid() }
        let byte = try take(1)[0]
        let kind = byte >> 5
        let extra = byte & 31
        if kind == 7 {
            switch extra {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: throw invalid()
            }
        }
        let length = try length(extra)
        guard length <= UInt64(Int64.max) else { throw invalid() }
        switch kind {
        case 0: return .integer(Int64(length))
        case 1: return .integer(-1 - Int64(length))
        case 2: return .bytes(try take(Int(length)))
        case 3:
            guard let text = String(data: try take(Int(length)), encoding: .utf8) else { throw invalid() }
            return .text(text)
        case 4:
            guard length <= 128 else { throw invalid() }
            var values: [Value] = []
            for _ in 0..<length { values.append(try read(depth: depth + 1)) }
            return .array(values)
        case 5:
            guard length <= 128 else { throw invalid() }
            var values: [Key: Value] = [:]
            for _ in 0..<length {
                let key: Key
                switch try read(depth: depth + 1) {
                case .integer(let value): key = .integer(value)
                case .text(let value): key = .text(value)
                default: throw invalid()
                }
                guard values[key] == nil else { throw invalid() }
                values[key] = try read(depth: depth + 1)
            }
            return .map(values)
        default: throw invalid()
        }
    }
    private mutating func length(_ extra: UInt8) throws -> UInt64 {
        switch extra {
        case 0...23: return UInt64(extra)
        case 24: return UInt64(try take(1)[0])
        case 25: return try take(2).reduce(0) { ($0 << 8) | UInt64($1) }
        case 26: return try take(4).reduce(0) { ($0 << 8) | UInt64($1) }
        case 27: return try take(8).reduce(0) { ($0 << 8) | UInt64($1) }
        default: throw invalid()
        }
    }
    private mutating func take(_ size: Int) throws -> Data {
        guard size >= 0, size <= data.count - offset else { throw invalid() }
        defer { offset += size }
        return data.subdata(in: offset..<(offset + size))
    }
    private func invalid() -> WalletError { .invalid("Malformed passkey data") }
}
