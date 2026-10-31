import Foundation
import Testing

@testable import HyperliquidCore

@Test func ownershipSignatureIsBoundToExactConnectionAndChallengeExpiry() throws {
    let signer = try EphemeralSigningKey(testKey: Data(repeating: 0, count: 31) + Data([1]))
    let connection = try WalletConnection(address: signer.address, chainID: 42161)
    let challenge = try WalletOwnershipChallenge(connection: connection, environment: .testnet, now: 1000)
    let signature = try signer.sign(digest: challenge.digest)
    let proof = try challenge.verify(signature: signature, current: connection, now: 1001)
    #expect(proof.connection == connection)
    #expect(proof.environment == .testnet)
    #expect(proof.validUntil == 601_000)
    #expect(throws: WalletError.self) { try challenge.verify(signature: signature, current: nil, now: 1001) }
    let reconnected = try WalletConnection(address: signer.address, chainID: 42161)
    #expect(throws: WalletError.self) { try challenge.verify(signature: signature, current: reconnected, now: 1001) }
    #expect(throws: WalletError.self) { try challenge.verify(signature: signature, current: connection, now: 999) }
    #expect(throws: WalletError.self) { try challenge.verify(signature: signature, current: connection, now: 121_000) }
}

@Test func ownershipSignatureCannotBeReplayedForAnotherNetworkOrNonce() throws {
    let signer = try EphemeralSigningKey(testKey: Data(repeating: 0, count: 31) + Data([1]))
    let connection = try WalletConnection(address: signer.address, chainID: 42161)
    let first = try WalletOwnershipChallenge(connection: connection, environment: .testnet, now: 1000)
    let signature = try signer.sign(digest: first.digest)
    let next = try WalletOwnershipChallenge(connection: connection, environment: .testnet, now: 1000)
    let mainnet = try WalletOwnershipChallenge(connection: connection, environment: .mainnet, now: 1000)
    #expect(first.nonce != next.nonce)
    #expect(throws: WalletError.self) { try next.verify(signature: signature, current: connection, now: 1001) }
    #expect(throws: WalletError.self) { try mainnet.verify(signature: signature, current: connection, now: 1001) }
    let other = try EphemeralSigningKey(testKey: Data(repeating: 0, count: 31) + Data([2]))
    let wrongSignature = try other.sign(digest: first.digest)
    #expect(throws: WalletError.self) { try first.verify(signature: wrongSignature, current: connection, now: 1001) }
}
