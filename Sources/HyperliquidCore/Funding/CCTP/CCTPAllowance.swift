import Foundation

public enum CCTPAuthorization: Sendable, Equatable {
    case signature, allowance

    static func accountCode(_ raw: String?) throws -> Self {
        guard let raw, raw.hasPrefix("0x"), let code = Data(hex: raw) else {
            throw APIError.malformed("Unable to verify the depositing wallet's account type")
        }
        // EIP-7702 accounts have code too. Their ERC-1271 checks can reject raw ECDSA signatures.
        return code.isEmpty ? .signature : .allowance
    }
}

extension CCTPRoute {
    /// Circle's source-chain TokenMessengerV2, used with an exact ERC-20 allowance.
    public var tokenMessenger: String {
        environment == .mainnet
            ? "0x28b5a0e9c621a5badaa536219b3a228c8168cf5d"
            : "0x8fe6b999dc680ccfdd5bf7eb0974218be2542daa"
    }
}

extension CCTPDepositIntent {
    public var approvalTransaction: WalletTransaction {
        get throws {
            guard authorization == .allowance else {
                throw WalletError.invalid("This deposit review does not authorize an ERC-20 approval")
            }
            return try WalletTransaction(
                from: owner, to: route.token,
                data: (Data(hex: "095ea7b3")! + EthereumSigning.addressWord(route.tokenMessenger)
                        + EthereumSigning.word(units)).hex,
                chainID: route.chainID)
        }
    }

    static var burnSelector: Data {
        Keccak256.hash(Data(
                        "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)".utf8)
        ).prefix(4)
    }

    public var burnTransaction: WalletTransaction {
        get throws {
            guard authorization == .allowance else {
                throw WalletError.invalid("This deposit review requires its USDC authorization signature")
            }
            let destination = try EthereumSigning.addressWord(route.forwarder)
            let head = EthereumSigning.word(units) + EthereumSigning.word(CCTPHyperCoreDestination.domain) + destination
                + (try EthereumSigning.addressWord(route.token)) + destination
                + EthereumSigning.word(feeUnits) + EthereumSigning.word(route.finality.rawValue)
                + EthereumSigning.word(8 * 32)
            let tail = EthereumSigning.word(UInt64(hook.count)) + hook
                + Data(repeating: 0, count: (32 - hook.count % 32) % 32)
            return try WalletTransaction(
                from: owner, to: route.tokenMessenger, data: (Self.burnSelector + head + tail).hex,
                chainID: route.chainID)
        }
    }
}

extension CCTPDepositSnapshot {
    public func needsApproval(for intent: CCTPDepositIntent) -> Bool {
        intent.authorization == .allowance && (allowance ?? -1) < Decimal(intent.units) / 1_000_000
    }
}

extension CCTPDepositClient {
    public func authorization(owner: String) async throws -> CCTPAuthorization {
        guard Address.isValid(owner) else { throw WalletError.invalid("Invalid depositing wallet") }
        if !route.supportsSignatureDeposit { return .allowance }
        return try CCTPAuthorization.accountCode(
            await rpc("eth_getCode", params: [.string(owner), .string("latest")]).string)
    }

    func allowance(owner: String) async throws -> Decimal {
        let call = Data(hex: "dd62ed3e")! + (try EthereumSigning.addressWord(owner))
            + (try EthereumSigning.addressWord(route.tokenMessenger))
        let result = try await rpc("eth_call", params: [
            .object(["to": .string(route.token), "data": .string(call.hex)]), .string("latest")
        ])
        return try Self.allowanceAmount(result.string)
    }

    static func allowanceAmount(_ raw: String?) throws -> Decimal {
        guard let raw, raw.range(of: "^0x[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw APIError.malformed("Invalid USDC allowance")
        }
        let digits = raw.dropFirst(2).drop(while: { $0 == "0" })
        // Only compare against supported UInt64 amounts; do not round a uint256 unlimited allowance.
        let units = digits.count > 16 ? UInt64.max : UInt64(digits, radix: 16) ?? 0
        return Decimal(units) / 1_000_000
    }

    public func approvalReceipt(hash: String, owner: String, transactionData: String) async throws -> Bool? {
        guard let data = Data(hex: transactionData), data.count == 68,
              data.prefix(4) == Data(hex: "095ea7b3"),
              data.dropFirst(4).prefix(32) == (try EthereumSigning.addressWord(route.tokenMessenger))
        else { throw APIError.malformed("Missing exact reviewed USDC approval") }
        return try await verifiedReceipt(
            hash: hash, owner: owner, transactionData: transactionData, to: route.token)
    }

    func verifiedReceipt(hash: String, owner: String, transactionData: String, to: String) async throws -> Bool? {
        let hash = try WalletTransaction.requireHash(hash)
        async let receipt = rpc("eth_getTransactionReceipt", params: [.string(hash)])
        async let transaction = rpc("eth_getTransactionByHash", params: [.string(hash)])
        let (mined, tx) = try await (receipt, transaction)
        return try Self.receiptResult(
            mined: mined, transaction: tx, hash: hash, owner: owner,
            transactionData: transactionData, to: to)
    }

    static func receiptResult(
        mined: JSONValue, transaction tx: JSONValue, hash: String, owner: String,
        transactionData: String, to: String
    ) throws -> Bool? {
        if mined == .null && tx == .null {
            throw WalletError.invalid(
                "This transaction hash is not visible on the source network yet. Check its status and any error in the original wallet before submitting again.")
        }
        guard tx["hash"].string?.lowercased() == hash,
              tx["from"].string?.lowercased() == owner.lowercased(),
              tx["to"].string?.lowercased() == to,
              tx["input"].string?.lowercased() == transactionData.lowercased(),
              try EthereumQuantity.parse(tx["value"].string) == 0
        else { throw APIError.malformed("Transaction does not match the exact reviewed CCTP transaction") }
        if mined == .null { return nil }
        guard mined["transactionHash"].string?.lowercased() == hash,
              mined["from"].string?.lowercased() == owner.lowercased(),
              mined["to"].string?.lowercased() == to,
              try EthereumQuantity.parse(mined["blockNumber"].string) > 0
        else { throw APIError.malformed("Receipt does not match the exact reviewed CCTP transaction") }
        let status = try EthereumQuantity.parse(mined["status"].string)
        guard status == 0 || status == 1 else { throw APIError.malformed("Unknown CCTP transaction status") }
        return status == 1
    }
}

extension CCTPDepositClient: DepositBalanceReadClient {
    public func usdcBalance(owner: String, token: String) async throws -> Decimal {
        guard Address.isValid(owner), token.lowercased() == route.token else {
            throw WalletError.invalid("Invalid depositing wallet or USDC token")
        }
        let chain = try EthereumQuantity.parse(await rpc("eth_chainId", params: []).string)
        guard chain == Decimal(route.chainID) else { throw APIError.malformed("CCTP RPC chain mismatch") }
        let value = try await rpc("eth_call", params: [
            .object(["to": .string(route.token), "data": .string(
                "0x70a08231" + String(repeating: "0", count: 24) + owner.lowercased().dropFirst(2))]),
            .string("latest")
        ])
        return try EthereumQuantity.parse(value.string) / 1_000_000
    }
}
