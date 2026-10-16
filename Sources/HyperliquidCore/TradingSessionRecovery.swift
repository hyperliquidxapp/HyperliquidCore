import Foundation

/// Contains public authority metadata and AES-GCM ciphertext, never the wallet's master key.
public struct TradingSessionRecovery: Codable, Sendable {
    public let approval: SessionApproval
    public let sealedKey: Data

    public init(approval: SessionApproval, sealedKey: Data) {
        self.approval = approval
        self.sealedKey = sealedKey
    }

    public func validate(environment: NetworkEnvironment, now: UInt64 = TradingSession.timestamp) throws {
        guard approval.environment == environment, !approval.revoking,
              Address.isValid(approval.owner), approval.owner == approval.owner.lowercased(),
              Address.isValid(approval.agentAddress), approval.agentAddress == approval.agentAddress.lowercased(),
              approval.agentAddress != "0x0000000000000000000000000000000000000000",
              approval.chainID > 0, approval.chainID <= UInt64(Int64.max),
              approval.createdAt <= now, approval.nonce == approval.createdAt,
              approval.validUntil > now, approval.validUntil <= UInt64(Int64.max),
              approval.validUntil > approval.createdAt,
              approval.validUntil - approval.createdAt <= 604_800_000,
              sealedKey.count == 68 else {
            throw WalletError.invalid("The remembered wallet is expired or belongs to another network")
        }
    }

    static func authenticationData(_ approval: SessionApproval, binding: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data("HyperliquidX.passkey.session.v1\0".utf8) + (try encoder.encode(approval)) + binding
    }
}
