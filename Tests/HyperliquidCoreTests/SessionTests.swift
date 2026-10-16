import Foundation
import Testing

@testable import HyperliquidCore

private let start: UInt64 = 1_700_000_000_000
private let acknowledgement: JSONValue = .object([
    "status": .string("ok"), "response": .object(["type": .string("default")])
])
private func registrations(
    _ approval: SessionApproval, address: String? = nil, expiry: UInt64? = nil
) -> JSONValue {
    .array([
        .object([
            "name": .string(SessionApproval.name),
            "address": .string(address ?? approval.agentAddress),
            "validUntil": .integer(Int64(expiry ?? approval.validUntil))
        ])
    ])
}
private func ownerKey() throws -> EphemeralSigningKey {
    try EphemeralSigningKey(
        testKey: Data(hex: "0123456789012345678901234567890123456789012345678901234567890123")!)
}
private let leverageAction = ExchangeAction.leverage(assetID: 1, value: 2, cross: true)

@Test func sessionApprovalRequiresOwnerSignatureAndMatchingContext() async throws {
    let owner = try ownerKey()
    let other = try EphemeralSigningKey()
    let session = TradingSession()
    let approval = try await session.prepare(
        owner: owner.address, chainID: 42161, environment: .testnet, now: start)
    #expect(approval.validUntil == start + 28_800_000)
    #expect(approval.typedData["domain"]["chainId"].int64 == 42161)
    #expect(approval.typedData["message"]["hyperliquidChain"].string == "Testnet")
    await #expect(throws: WalletError.self) {
        try await session.signedRequest(
            action: leverageAction, owner: owner.address, environment: .testnet, now: start)
    }
    await #expect(throws: WalletError.self) {
        try await session.beginApproval(
            id: approval.id, owner: other.address, chainID: 42161, now: start)
    }
    await #expect(throws: WalletError.self) {
        try await session.beginApproval(
            id: approval.id, owner: owner.address, chainID: 1, now: start)
    }
    _ = try await session.beginApproval(
        id: approval.id, owner: owner.address, chainID: 42161, now: start)
    #expect(throws: WalletError.self) {
        try approval.request(signature: other.sign(digest: approval.digest))
    }
    let signature = try owner.sign(digest: approval.digest)
    let body = try JSONDecoder().decode(
        JSONValue.self, from: approval.request(signature: signature))
    #expect(body["nonce"].int64 == Int64(start))
    #expect(body["action"]["nonce"] == body["nonce"])
    #expect(body["action"]["signatureChainId"].string == "0xa4b1")
    #expect(body["expiresAfter"] == .null)
    #expect(body["vaultAddress"] == .null)
    await #expect(throws: ExchangeRejection.self) {
        try await session.acknowledge(
            id: approval.id,
            receipt: .object(["status": .string("err"), "response": .string("Rejected")]))
    }
    try await session.acknowledge(id: approval.id, receipt: acknowledgement)
    #expect(await session.state == .unverified)
    await #expect(throws: WalletError.self) {
        try await session.verifyRegistration(
            id: approval.id, agents: registrations(approval, address: other.address), now: start)
    }
    await #expect(throws: WalletError.self) {
        try await session.verifyRegistration(
            id: approval.id, agents: registrations(approval, expiry: approval.validUntil + 1),
            now: start)
    }
    try await session.verifyRegistration(
        id: approval.id, agents: registrations(approval), now: start)
    #expect(await session.state == .active)
}

@Test func activeSessionBindsNetworkAccountPolicyAndNonce() async throws {
    let owner = try ownerKey()
    let session = TradingSession()
    let approval = try await session.prepare(
        owner: owner.address, chainID: 42161, environment: .testnet, now: start)
    _ = try await session.beginApproval(
        id: approval.id, owner: owner.address, chainID: 42161, now: start)
    // A lost exchange response never activates the key. Matching registration resolves it.
    await session.markUnverified(id: approval.id)
    await #expect(throws: WalletError.self) {
        try await session.signedRequest(
            action: leverageAction, owner: owner.address, environment: .testnet, now: start)
    }
    try await session.verifyRegistration(
        id: approval.id, agents: registrations(approval), now: start)
    await #expect(throws: WalletError.self) {
        try await session.signedRequest(
            action: leverageAction, owner: owner.address, environment: .mainnet, now: start)
    }
    await #expect(throws: WalletError.self) {
        try await session.signedRequest(
            action: leverageAction, owner: approval.agentAddress, environment: .testnet, now: start)
    }
    await #expect(throws: WalletError.self) {
        try await session.signedRequest(
            action: .map([("type", .string("withdraw3"))]), owner: owner.address,
            environment: .testnet, now: start)
    }
    func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
    let first = try decode(
        await session.signedRequest(
            action: leverageAction, owner: owner.address, environment: .testnet, now: start))
    let second = try decode(
        await session.signedRequest(
            action: leverageAction, owner: owner.address, environment: .testnet, now: start))
    #expect(first["nonce"].int64 == Int64(start))
    #expect(second["nonce"].int64 == Int64(start + 1))
    let compact =
        (first["signature"]["r"].string ?? "")
        + String((first["signature"]["s"].string ?? "").dropFirst(2)) + "1"
        + (first["signature"]["v"].int64 == 27 ? "b" : "c")
    let signature = try WalletSignature(hex: compact)
    let digest = try EthereumSigning.actionDigest(
        action: leverageAction, nonce: start, environment: .testnet, expiresAfter: start + 120_000)
    #expect(
        try EthereumSigning.recover(signature: signature, digest: digest) == approval.agentAddress)
    await #expect(throws: WalletError.self) {
        try await session.verifyRegistration(id: approval.id, agents: .array([]), now: start)
    }
    #expect(await session.state == .inactive)
    await #expect(throws: WalletError.self) {
        try await session.signedRequest(
            action: leverageAction, owner: owner.address, environment: .testnet, now: start)
    }
}

@Test func sessionExpiryPreviewFreshnessAndKeyReplacement() async throws {
    let owner = try ownerKey()
    let session = TradingSession()
    let first = try await session.prepare(
        owner: owner.address, chainID: 1, environment: .mainnet, now: start)
    await #expect(throws: WalletError.self) {
        try await session.beginApproval(
            id: first.id, owner: owner.address, chainID: 1, now: start + 30_000)
    }
    await session.end(id: first.id)
    let second = try await session.prepare(
        owner: owner.address, chainID: 1, environment: .mainnet, now: start)
    #expect(first.agentAddress != second.agentAddress)
    await session.end(id: first.id)  // A stale UI task cannot erase a replacement session.
    #expect(await session.state == .prepared)
    _ = try await session.beginApproval(id: second.id, owner: owner.address, chainID: 1, now: start)
    try await session.acknowledge(id: second.id, receipt: acknowledgement)
    try await session.verifyRegistration(id: second.id, agents: registrations(second), now: start)
    await #expect(throws: WalletError.self) {
        try await session.signedRequest(
            action: leverageAction, owner: owner.address, environment: .mainnet,
            now: second.validUntil)
    }
    #expect(await session.state == .expired)
    let revocation = try TradingSession.revocation(
        owner: owner.address, chainID: 1, environment: .mainnet, nonce: start)
    #expect(revocation.revoking)
    #expect(revocation.agentName == "HyperliquidX")
    #expect(revocation.agentAddress == "0x0000000000000000000000000000000000000000")
    _ = try revocation.request(signature: owner.sign(digest: revocation.digest))
}
