import CryptoKit
import Foundation

public struct SessionApproval: Codable, Sendable, Identifiable {
    public let id: UUID
    public let owner: String
    public let agentAddress: String
    public let validUntil: UInt64
    public let chainID: UInt64
    public let nonce: UInt64
    public let environment: NetworkEnvironment
    public let createdAt: UInt64
    public let revoking: Bool
    public static let name = "HyperliquidX"
    public var agentName: String { revoking ? Self.name : "\(Self.name) valid_until \(validUntil)" }
    public var action: WireValue {
        .map([
            ("type", .string("approveAgent")),
            ("hyperliquidChain", .string(environment == .mainnet ? "Mainnet" : "Testnet")),
            ("signatureChainId", .string("0x" + String(chainID, radix: 16))),
            ("agentAddress", .string(agentAddress)),
            ("agentName", .string(agentName)), ("nonce", .uint(nonce))
        ])
    }
    public var typedData: JSONValue {
        func field(_ name: String, _ type: String) -> JSONValue {
            .object(["name": .string(name), "type": .string(type)])
        }
        return .object([
            "domain": .object([
                "name": .string("HyperliquidSignTransaction"), "version": .string("1"),
                "chainId": .integer(Int64(chainID)),
                "verifyingContract": .string("0x0000000000000000000000000000000000000000")
            ]),
            "types": .object([
                "EIP712Domain": .array([
                    field("name", "string"), field("version", "string"),
                    field("chainId", "uint256"),
                    field("verifyingContract", "address")
                ]),
                "HyperliquidTransaction:ApproveAgent": .array([
                    field("hyperliquidChain", "string"), field("agentAddress", "address"),
                    field("agentName", "string"),
                    field("nonce", "uint64")
                ])
            ]),
            "primaryType": .string("HyperliquidTransaction:ApproveAgent"),
            "message": .object([
                "hyperliquidChain": .string(environment == .mainnet ? "Mainnet" : "Testnet"),
                "agentAddress": .string(agentAddress), "agentName": .string(agentName),
                "nonce": .integer(Int64(nonce))
            ])
        ])
    }
    public var digest: Data {
        get throws {
            let message = Keccak256.hash(
                EthereumSigning.text(
                    "HyperliquidTransaction:ApproveAgent(string hyperliquidChain,address agentAddress,string agentName,uint64 nonce)"
                )
                + EthereumSigning.text(environment == .mainnet ? "Mainnet" : "Testnet")
                + (try EthereumSigning.addressWord(agentAddress))
                + EthereumSigning.text(agentName) + EthereumSigning.word(nonce))
            return Keccak256.hash(
                Data([0x19, 0x01])
                    + EthereumSigning.domain(name: "HyperliquidSignTransaction", chainID: chainID)
                    + message)
        }
    }
    public func request(signature: WalletSignature) throws -> Data {
        guard try EthereumSigning.recover(signature: signature, digest: digest) == owner else {
            throw WalletError.invalid("Signature does not match the connected wallet")
        }
        // User-signed approvals do not support expiresAfter or vaultAddress.
        return try WireValue.map([
            ("action", action), ("nonce", .uint(nonce)), ("signature", signature.wire)
        ])
        .jsonData()
    }
}

public enum SessionState: String, Sendable {
    case inactive, prepared, authorizing, unverified, active, expired
}

/// Trading key with account/network binding and a finite authority window.
/// Persistence is opt-in and only exports authenticated ciphertext protected by a passkey.
/// This actor never submits requests; callers must run the native confirmation workflow first.
public actor TradingSession {
    public private(set) var state: SessionState = .inactive
    public private(set) var approval: SessionApproval?
    private var key: EphemeralSigningKey?
    private var lastNonce: UInt64 = 0
    private var recoveryKey: SymmetricKey?
    private var recoveryBinding: Data?
    public init() {}
    public static var timestamp: UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    public func prepare(
        owner: String, chainID: UInt64, environment: NetworkEnvironment, now: UInt64 = timestamp,
        id: UUID = UUID(), duration: UInt64 = 28_800_000
    ) throws -> SessionApproval {
        guard state == .inactive || state == .expired else {
            throw WalletError.invalid("End or resolve the existing session first")
        }
        guard Address.isValid(owner), chainID > 0, chainID <= UInt64(Int64.max),
              (3_600_000...604_800_000).contains(duration),
              now <= UInt64(Int64.max) - duration
        else { throw WalletError.invalid("Invalid session account or chain") }
        let key = try EphemeralSigningKey()
        let approval = SessionApproval(
            id: id, owner: owner.lowercased(), agentAddress: key.address,
            validUntil: now + duration,
            chainID: chainID, nonce: now, environment: environment, createdAt: now, revoking: false)
        self.key = key
        self.approval = approval
        lastNonce = 0
        state = .prepared
        return approval
    }
    public func beginApproval(id: UUID, owner: String, chainID: UInt64, now: UInt64 = timestamp)
    throws
    -> SessionApproval {
        guard state == .prepared, let approval, approval.id == id,
              approval.owner == owner.lowercased(),
              approval.chainID == chainID,
              now >= approval.createdAt, now - approval.createdAt < 30_000
        else {
            throw WalletError.invalid(
                "Session preview expired or wallet changed. Create a new preview.")
        }
        state = .authorizing
        return approval
    }
    public func markUnverified(id: UUID) {
        guard approval?.id == id, state == .authorizing else { return }
        state = .unverified
    }
    public func acknowledge(id: UUID, receipt: JSONValue) throws {
        guard approval?.id == id, state == .authorizing else {
            throw WalletError.invalid("Session changed while authorizing")
        }
        try Self.requireAcknowledgement(receipt)
        state = .unverified
    }
    public static func requireAcknowledgement(_ receipt: JSONValue) throws {
        if receipt["status"].string == "err" {
            throw ExchangeRejection.rejected(
                receipt["response"].string ?? "Session authorization rejected")
        }
        guard receipt["status"].string == "ok", receipt["response"]["type"].string == "default"
        else {
            throw APIError.malformed("Unverified session authorization response")
        }
    }
    public func verifyRegistration(id: UUID, agents: JSONValue, now: UInt64 = timestamp) throws {
        if let approval, approval.id == id, now >= approval.validUntil {
            end()
            state = .expired
            throw WalletError.invalid("Trading session expired")
        }
        guard let approval, approval.id == id, state == .unverified || state == .active,
              now < approval.validUntil,
              key != nil
        else { throw WalletError.invalid("Trading session is unavailable or expired") }
        guard case .array(let values) = agents else {
            throw APIError.malformed("Invalid API-wallet registration response")
        }
        guard
            values.contains(where: {
                $0["address"].string?.lowercased() == approval.agentAddress
                    && $0["name"].string == SessionApproval.name
                    && $0["validUntil"].int64 == Int64(approval.validUntil)
            })
        else {
            if state == .active { end() }
            throw WalletError.invalid(
                "This session's registration is not confirmed. Check again or end the local session."
            )
        }
        state = .active
    }
    public func signedRequest(
        action: WireValue, owner: String, environment: NetworkEnvironment, now: UInt64 = timestamp
    ) throws -> Data {
        guard state == .active, let approval, let key, approval.owner == owner.lowercased(),
              approval.environment == environment
        else {
            throw WalletError.invalid("Authorize a trading session for this account and network")
        }
        guard now < approval.validUntil else {
            end()
            state = .expired
            throw WalletError.invalid("Trading session expired")
        }
        guard case .map(let fields) = action,
              case .string(let type)? = fields.first(where: { $0.0 == "type" })?.1,
              ["order", "cancel", "batchModify", "updateLeverage"].contains(type)
        else { throw WalletError.invalid("Action is outside this client's trading session policy") }
        guard lastNonce < UInt64(Int64.max) - 120_000,
              now < UInt64(Int64.max) - 120_000 else {
            throw WalletError.invalid("Signing clock is outside the supported range")
        }
        let nonce = max(now, lastNonce + 1)
        guard nonce < approval.validUntil else {
            throw WalletError.invalid("Trading session expired")
        }
        lastNonce = nonce
        let expires = min(nonce + 120_000, approval.validUntil)
        let digest = try EthereumSigning.actionDigest(
            action: action, nonce: nonce, environment: environment, expiresAfter: expires)
        let signature = try key.sign(digest: digest)
        return try SigningPayload.request(
            action: action, signature: signature, nonce: nonce, expiresAfter: expires)
    }
    public func end() {
        key = nil
        approval = nil
        state = .inactive
        lastNonce = 0
        recoveryKey = nil
        recoveryBinding = nil
    }
    public func enableRecovery(key: SymmetricKey, binding: Data) throws -> TradingSessionRecovery {
        guard state == .active, key.bitCount == 256, !binding.isEmpty else {
            throw WalletError.invalid("Verify an active session before enabling recovery")
        }
        recoveryKey = key
        recoveryBinding = binding
        return try encryptedRecovery()
    }
    public func disableRecovery() {
        recoveryKey = nil
        recoveryBinding = nil
    }
    public func encryptedRecovery() throws -> TradingSessionRecovery {
        guard let approval, let key, let recoveryKey, let recoveryBinding,
              state == .active, Self.timestamp < approval.validUntil else {
            throw WalletError.invalid("Passkey recovery is unavailable")
        }
        let sealed = try key.seal(
            using: recoveryKey, nonce: lastNonce,
            authenticating: TradingSessionRecovery.authenticationData(approval, binding: recoveryBinding))
        return TradingSessionRecovery(approval: approval, sealedKey: sealed)
    }
    public func restore(
        _ recovery: TradingSessionRecovery, key: SymmetricKey, binding: Data,
        environment: NetworkEnvironment, now: UInt64 = timestamp
    ) throws -> SessionApproval {
        guard state == .inactive || state == .expired else {
            throw WalletError.invalid("End the existing session before restoring a wallet")
        }
        let approval = recovery.approval
        try recovery.validate(environment: environment, now: now)
        guard key.bitCount == 256, !binding.isEmpty else {
            throw WalletError.invalid("Invalid passkey encryption key")
        }
        var plaintext = try AES.GCM.open(
            AES.GCM.SealedBox(combined: recovery.sealedKey), using: key,
            authenticating: TradingSessionRecovery.authenticationData(approval, binding: binding))
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count == 40 else {
            throw WalletError.invalid("Invalid encrypted trading session")
        }
        let restored = try plaintext.withUnsafeBytes { buffer in
            try EphemeralSigningKey(restoring: UnsafeRawBufferPointer(rebasing: buffer.prefix(32)))
        }
        let nonce = plaintext.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard restored.address == approval.agentAddress, nonce < approval.validUntil else {
            throw WalletError.invalid("Recovery does not match this trading authorization")
        }
        self.key = restored
        self.approval = approval
        lastNonce = nonce
        recoveryKey = key
        recoveryBinding = binding
        // A passkey alone never proves that the exchange still accepts this API wallet.
        state = .unverified
        return approval
    }
    public func end(id: UUID) { if approval?.id == id { end() } }
    public static func revocation(
        owner: String, chainID: UInt64, environment: NetworkEnvironment, nonce: UInt64 = timestamp
    ) throws -> SessionApproval {
        guard Address.isValid(owner), chainID > 0, chainID <= UInt64(Int64.max),
              nonce <= UInt64(Int64.max)
        else {
            throw WalletError.invalid("Invalid revocation account or chain")
        }
        return SessionApproval(
            id: UUID(), owner: owner.lowercased(),
            agentAddress: "0x0000000000000000000000000000000000000000",
            validUntil: nonce,
            chainID: chainID, nonce: nonce, environment: environment, createdAt: nonce,
            revoking: true)
    }
}
