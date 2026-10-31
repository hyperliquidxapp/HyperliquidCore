import CryptoKit
import Foundation
import Testing

@testable import HyperliquidCore

private let recoveryOwner = "0x12403356d523ff2e7c2e762a17b7306ad0fbd839"
private let recoveryAction = ExchangeAction.leverage(assetID: 1, value: 2, cross: true)
private func recoveryAgents(_ value: SessionApproval) -> JSONValue {
    .array([.object(["name": .string(SessionApproval.name), "address": .string(value.agentAddress),
                     "validUntil": .integer(Int64(value.validUntil))])])
}
private func authorizedRecoverySession() async throws -> (TradingSession, SessionApproval) {
    let session = TradingSession()
    let approval = try await session.prepare(owner: recoveryOwner, chainID: 42161, environment: .testnet)
    _ = try await session.beginApproval(id: approval.id, owner: recoveryOwner, chainID: 42161)
    try await session.acknowledge(id: approval.id, receipt: .object([
                                                                        "status": .string("ok"), "response": .object(["type": .string("default")])]))
    try await session.verifyRegistration(id: approval.id, agents: recoveryAgents(approval))
    return (session, approval)
}

@Test func encryptedSessionRecoveryRequiresFreshRegistrationAndPreservesNonceAndAgent() async throws {
    let (session, approval) = try await authorizedRecoverySession()
    let key = SymmetricKey(size: .bits256)
    let binding = Data("passkey-credential-and-account".utf8)
    _ = try await session.enableRecovery(key: key, binding: binding)
    let firstBody = try await session.signedRequest(
        action: recoveryAction, owner: recoveryOwner, environment: .testnet, now: approval.createdAt + 1000)
    let first = try JSONDecoder().decode(JSONValue.self, from: firstBody)
    let encrypted = try await session.encryptedRecovery()
    #expect(encrypted.sealedKey.count == 68)
    let another = try await session.encryptedRecovery()
    #expect(encrypted.sealedKey != another.sealedKey)
    await session.end()
    let restored = TradingSession()
    let restoredAuthority = try await restored.restore(encrypted, key: key, binding: binding, environment: .testnet)
    #expect(restoredAuthority.id == approval.id)
    #expect(await restored.state == .unverified)
    await #expect(throws: (any Error).self) {
        try await restored.signedRequest(action: recoveryAction, owner: recoveryOwner, environment: .testnet)
    }
    try await restored.verifyRegistration(id: approval.id, agents: recoveryAgents(approval))
    let secondBody = try await restored.signedRequest(
        action: recoveryAction, owner: recoveryOwner, environment: .testnet, now: approval.createdAt)
    let second = try JSONDecoder().decode(JSONValue.self, from: secondBody)
    let nonce = try #require(second["nonce"].int64)
    #expect(nonce == first["nonce"].int64! + 1)
    let digest = try EthereumSigning.actionDigest(action: recoveryAction, nonce: UInt64(nonce), environment: .testnet,
                                                  expiresAfter: UInt64(try #require(second["expiresAfter"].int64)))
    let r = try #require(second["signature"]["r"].string)
    let s = try #require(second["signature"]["s"].string)
    let v = try #require(second["signature"]["v"].int64)
    let signature = try WalletSignature(hex: r + String(s.dropFirst(2)) + String(v, radix: 16))
    #expect(try EthereumSigning.recover(signature: signature, digest: digest) == approval.agentAddress)
    await #expect(throws: (any Error).self) {
        try await restored.signedRequest(action: .map([("type", .string("withdraw3"))]),
                                         owner: recoveryOwner, environment: .testnet)
    }
    await restored.end()
    #expect(await restored.state == .inactive)
}

@Test func encryptedSessionRecoveryRejectsWrongPasskeyTamperingExpiryAndNetwork() async throws {
    let (session, approval) = try await authorizedRecoverySession()
    let key = SymmetricKey(size: .bits256)
    let binding = Data("credential-binding".utf8)
    let encrypted = try await session.enableRecovery(key: key, binding: binding)
    let restored = TradingSession()
    await #expect(throws: (any Error).self) {
        try await restored.restore(
            encrypted, key: SymmetricKey(size: .bits256), binding: binding, environment: .testnet)
    }
    await #expect(throws: (any Error).self) {
        try await restored.restore(encrypted, key: key, binding: Data("another-credential".utf8), environment: .testnet)
    }
    var tampered = encrypted.sealedKey
    tampered[20] ^= 1
    await #expect(throws: (any Error).self) {
        try await restored.restore(TradingSessionRecovery(approval: approval, sealedKey: tampered),
                                   key: key, binding: binding, environment: .testnet)
    }
    await #expect(throws: (any Error).self) {
        try await restored.restore(encrypted, key: key, binding: binding, environment: .mainnet)
    }
    await #expect(throws: (any Error).self) {
        try await restored.restore(
            encrypted, key: key, binding: binding, environment: .testnet, now: approval.validUntil)
    }
    #expect(await restored.state == .inactive)
}
