import CryptoKit
import Foundation
import Testing

@testable import HyperliquidCore

private let managedOwner = "0x1111111111111111111111111111111111111111"

@Test func managedSessionSupportsAllDurationsAndRejectsBeyondProtocolMaximum() async throws {
  for duration: UInt64 in [
    3_600_000, 86_400_000, 604_800_000, 2_592_000_000, 7_776_000_000, 15_552_000_000,
  ] {
    let session = TradingSession()
    let approval = try await session.prepare(
      owner: managedOwner, chainID: 42161, environment: .mainnet,
      duration: duration)
    #expect(approval.validUntil - approval.createdAt == duration)
    #expect(approval.agentName == "HyperliquidX valid_until \(approval.validUntil)")
    let key = SymmetricKey(size: .bits256)
    let binding = Data("managed-session-test".utf8)
    let recovery = try await session.enableRecovery(key: key, binding: binding)
    try recovery.validate(environment: .mainnet)
    await session.end()
    let restored = try await session.restore(
      recovery, key: key, binding: binding, environment: .mainnet)
    #expect(restored.agentAddress == approval.agentAddress)
    #expect(await session.state == .unverified)
    await #expect(throws: WalletError.self) {
      try await session.signedRequest(
        action: ExchangeAction.leverage(assetID: 1, value: 2, cross: true),
        owner: managedOwner, environment: .mainnet)
    }
  }
  for duration: UInt64 in [0, 3_599_999, 15_552_000_001, UInt64.max] {
    let session = TradingSession()
    await #expect(throws: WalletError.self) {
      try await session.prepare(
        owner: managedOwner, chainID: 42161, environment: .mainnet, duration: duration)
    }
  }
}

@Test func pendingAuthorizationRecoveryStillRequiresExchangeRegistration() async throws {
  let session = TradingSession()
  let approval = try await session.prepare(
    owner: managedOwner, chainID: 42161, environment: .mainnet)
  _ = try await session.beginApproval(id: approval.id, owner: managedOwner, chainID: 42161)
  let key = SymmetricKey(size: .bits256)
  let binding = Data("pending-approval".utf8)
  let recovery = try await session.enableRecovery(key: key, binding: binding)
  await session.end()
  _ = try await session.restore(recovery, key: key, binding: binding, environment: .mainnet)
  await #expect(throws: WalletError.self) {
    try await session.verifyRegistration(id: approval.id, agents: .array([]))
  }
  try await session.verifyRegistration(
    id: approval.id,
    agents: .array([
      .object([
        "name": .string(SessionApproval.name), "address": .string(approval.agentAddress),
        "validUntil": .integer(Int64(approval.validUntil)),
      ])
    ]))
  #expect(await session.state == .active)
}
