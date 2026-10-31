import Foundation

public struct BalanceTransferIntent: Sendable, Identifiable {
    public let id = UUID()
    public let owner: String
    public let amount: String
    public let toPerp: Bool
    public let environment: NetworkEnvironment
    public let chainID: UInt64
    public let createdAt: Date
    public init(
        owner: String, amount: String, toPerp: Bool, environment: NetworkEnvironment,
        chainID: UInt64,
        available: Decimal, now: Date = Date()
    ) throws {
        guard Address.isValid(owner), chainID > 0, chainID <= UInt64(Int64.max) else {
            throw WalletError.invalid("Invalid transfer account or chain")
        }
        guard amount.range(of: "^[0-9]+(?:\\.[0-9]{1,6})?$", options: .regularExpression) != nil,
              let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")),
              value > 0,
              value <= available
        else {
            throw WalletError.invalid(
                "Enter a positive USDC amount within the available balance, with at most six decimals"
            )
        }
        self.owner = owner.lowercased()
        self.amount = NSDecimalNumber(decimal: value).stringValue
        self.toPerp = toPerp
        self.environment = environment
        self.chainID = chainID
        self.createdAt = now
    }
    public func validate(available: Decimal, now: Date = Date(), maximumAge: TimeInterval = 30)
    throws {
        let age = now.timeIntervalSince(createdAt)
        guard age >= 0, age < maximumAge else {
            throw WalletError.invalid("Transfer preview expired. Create a new preview.")
        }
        guard let value = Decimal(string: amount), value <= available else {
            throw WalletError.invalid("Available balance changed. Create a new preview.")
        }
    }
    public func action(nonce: UInt64) -> WireValue {
        .map([
            ("type", .string("usdClassTransfer")),
            ("hyperliquidChain", .string(environment == .mainnet ? "Mainnet" : "Testnet")),
            ("signatureChainId", .string("0x" + String(chainID, radix: 16))),
            ("amount", .string(amount)),
            ("toPerp", .bool(toPerp)), ("nonce", .uint(nonce))
        ])
    }
    public func typedData(nonce: UInt64) throws -> JSONValue {
        guard nonce <= UInt64(Int64.max) else {
            throw WalletError.invalid("Invalid transfer nonce")
        }
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
                "HyperliquidTransaction:UsdClassTransfer": .array([
                    field("hyperliquidChain", "string"), field("amount", "string"),
                    field("toPerp", "bool"),
                    field("nonce", "uint64")
                ])
            ]), "primaryType": .string("HyperliquidTransaction:UsdClassTransfer"),
            "message": .object([
                "hyperliquidChain": .string(environment == .mainnet ? "Mainnet" : "Testnet"),
                "amount": .string(amount),
                "toPerp": .bool(toPerp), "nonce": .integer(Int64(nonce))
            ])
        ])
    }
    public func digest(nonce: UInt64) -> Data {
        let message = Keccak256.hash(
            EthereumSigning.text(
                "HyperliquidTransaction:UsdClassTransfer(string hyperliquidChain,string amount,bool toPerp,uint64 nonce)"
            )
            + EthereumSigning.text(environment == .mainnet ? "Mainnet" : "Testnet")
            + EthereumSigning.text(amount)
            + EthereumSigning.word(toPerp ? 1 : 0) + EthereumSigning.word(nonce))
        return Keccak256.hash(
            Data([0x19, 0x01])
                + EthereumSigning.domain(name: "HyperliquidSignTransaction", chainID: chainID)
                + message)
    }
    public func request(signature: WalletSignature, nonce: UInt64) throws -> Data {
        guard
            try EthereumSigning.recover(signature: signature, digest: digest(nonce: nonce)) == owner
        else {
            throw WalletError.invalid("Transfer signature does not match the connected wallet")
        }
        return try WireValue.map([
            ("action", action(nonce: nonce)), ("nonce", .uint(nonce)),
            ("signature", signature.wire)
        ]).jsonData()
    }
    public static func available(toPerp: Bool, spot: JSONValue, account: AccountState) throws
    -> Decimal {
        if !toPerp {
            guard let value = Decimal(string: account.withdrawable), value >= 0 else {
                throw APIError.malformed("Invalid withdrawable balance")
            }
            return value
        }
        guard case .array(let balances) = spot["balances"] else {
            throw APIError.malformed("Missing spot balances")
        }
        guard
            let usdc = balances.first(where: {
                $0["token"].int64 == 0 && $0["coin"].string == "USDC"
            })
        else {
            return 0
        }
        guard let totalString = usdc["total"].string, let holdString = usdc["hold"].string,
              let total = Decimal(string: totalString), let hold = Decimal(string: holdString),
              total >= 0, hold >= 0
        else { throw APIError.malformed("Invalid available USDC balance") }
        return max(0, total - hold)
    }
}
