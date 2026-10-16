import CryptoKit
import Foundation
import Testing

@testable import HyperliquidCore

private struct PasskeyFixture {
    let key = P256.Signing.PrivateKey()
    let id = Data(repeating: 7, count: 32)
    let userID = Data(repeating: 9, count: 32)
    let challenge = Data(repeating: 11, count: 32)
    var publicKey: Data { key.publicKey.x963Representation }
    func client(_ type: String, origin: String = "https://hypexapp.xyz", crossOrigin: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": type, "origin": origin, "challenge": PasskeyVerification.base64URL(challenge),
            "crossOrigin": crossOrigin
        ])
    }
    func authenticator(flags: UInt8 = 0x05, count: UInt32 = 0) -> Data {
        Data(SHA256.hash(data: Data("hypexapp.xyz".utf8))) + Data([flags])
            + Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
    }
    func signature(_ authenticator: Data, _ client: Data) throws -> Data {
        try key.signature(for: authenticator + Data(SHA256.hash(data: client))).derRepresentation
    }
    func attestation() -> Data {
        let x = publicKey.subdata(in: 1..<33)
        let y = publicKey.subdata(in: 33..<65)
        let cose = Data([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
            + x + Data([0x22, 0x58, 0x20]) + y
        let data = authenticator(flags: 0x45) + Data(repeating: 0, count: 16)
            + Data([0, UInt8(id.count)]) + id + cose
        let format = Data([0xa3, 0x63]) + Data("fmt".utf8) + Data([0x64]) + Data("none".utf8)
        let statement = Data([0x67]) + Data("attStmt".utf8) + Data([0xa0, 0x68])
        let authenticator = Data("authData".utf8) + Data([0x58, UInt8(data.count)]) + data
        return format + statement + authenticator
    }
    func verify(
        authenticator: Data? = nil, client: Data? = nil, signature: Data? = nil,
        challenge: Data? = nil, previousCounter: UInt32 = 0, credentialID: Data? = nil, userID: Data? = nil
    ) throws -> UInt32 {
        let auth = authenticator ?? self.authenticator()
        let client = try client ?? self.client("webauthn.get")
        return try PasskeyVerification.assertion(
            authenticator: auth, clientData: client, signature: signature ?? self.signature(auth, client),
            challenge: challenge ?? self.challenge, credentialID: credentialID ?? id, expectedCredentialID: id,
            userID: userID ?? self.userID, expectedUserID: self.userID,
            publicKey: publicKey, previousCounter: previousCounter)
    }
}

@Test func passkeyRegistrationExtractsVerifiedCredentialAndRejectsMalformedAttestation() throws {
    let fixture = PasskeyFixture()
    let registration = try PasskeyVerification.registration(
        attestation: fixture.attestation(), clientData: fixture.client("webauthn.create"),
        challenge: fixture.challenge, credentialID: fixture.id)
    #expect(registration.publicKey == fixture.publicKey)
    #expect(registration.credentialID == fixture.id)
    #expect(registration.signatureCounter == 0)
    #expect(throws: (any Error).self) {
        try PasskeyVerification.registration(
            attestation: Data(fixture.attestation().dropLast()), clientData: fixture.client("webauthn.create"),
            challenge: fixture.challenge, credentialID: fixture.id)
    }
    #expect(throws: (any Error).self) {
        try PasskeyVerification.registration(
            attestation: fixture.attestation(), clientData: fixture.client("webauthn.create"),
            challenge: fixture.challenge, credentialID: Data(repeating: 8, count: 32))
    }
}

@Test func passkeyAssertionChecksSignatureFreshChallengeDomainAndWalletBinding() throws {
    let fixture = PasskeyFixture()
    #expect(try fixture.verify() == 0)
    #expect(throws: (any Error).self) { try fixture.verify(challenge: Data(repeating: 12, count: 32)) }
    #expect(throws: (any Error).self) { try fixture.verify(client: fixture.client("webauthn.create")) }
    #expect(throws: (any Error).self) { try fixture.verify(client: fixture.client("webauthn.get", origin: "https://other.example")) }
    #expect(throws: (any Error).self) { try fixture.verify(client: fixture.client("webauthn.get", crossOrigin: true)) }
    #expect(throws: (any Error).self) { try fixture.verify(credentialID: Data([1])) }
    #expect(throws: (any Error).self) { try fixture.verify(userID: Data([1])) }
    let other = P256.Signing.PrivateKey()
    let client = try fixture.client("webauthn.get")
    #expect(throws: (any Error).self) {
        try fixture.verify(signature: other.signature(
                            for: fixture.authenticator() + Data(SHA256.hash(data: client))).derRepresentation)
    }
}

@Test func passkeyAssertionRequiresUserVerificationAndChecksNonzeroCounters() throws {
    let fixture = PasskeyFixture()
    #expect(try fixture.verify(authenticator: fixture.authenticator(count: 2), previousCounter: 1) == 2)
    #expect(throws: (any Error).self) {
        try fixture.verify(authenticator: fixture.authenticator(count: 1), previousCounter: 1)
    }
    #expect(throws: (any Error).self) { try fixture.verify(previousCounter: 1) }
    #expect(throws: (any Error).self) { try fixture.verify(authenticator: fixture.authenticator(flags: 0x01)) }
    #expect(throws: (any Error).self) { try fixture.verify(authenticator: fixture.authenticator(flags: 0x04)) }
    var wrongRP = fixture.authenticator()
    wrongRP[0] ^= 1
    #expect(throws: (any Error).self) { try fixture.verify(authenticator: wrongRP) }
}
