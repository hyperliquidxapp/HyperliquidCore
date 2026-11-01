import Foundation

/// A user-signed approval, independent of approveAgent and of the API wallet's L1 action signature.
public struct BuilderFeeApproval: Sendable {
    public let owner: String
    public let builder: String
    public let feeLimit: Int
    public let chainID: UInt64
    public let nonce: UInt64
    public let environment: NetworkEnvironment
    public var maxFeeRate: String {
        NSDecimalNumber(decimal: Decimal(feeLimit) / 1000).stringValue + "%"
    }

    public init(
        owner: String, builder: String, feeLimit: Int, chainID: UInt64,
        nonce: UInt64, environment: NetworkEnvironment
    ) throws {
        guard Address.isValid(owner), Address.isValid(builder),
            builder.lowercased() != "0x0000000000000000000000000000000000000000"
        else { throw BuilderFeeError.invalidAddress }
        guard (0...1000).contains(feeLimit) else { throw BuilderFeeError.invalidRate }
        guard chainID > 0, chainID <= UInt64(Int64.max), nonce > 0, nonce <= UInt64(Int64.max)
        else {
            throw BuilderFeeError.invalidContext
        }
        self.owner = owner.lowercased()
        self.builder = builder.lowercased()
        self.feeLimit = feeLimit
        self.chainID = chainID
        self.nonce = nonce
        self.environment = environment
    }

    public var action: WireValue {
        .map([
            ("type", .string("approveBuilderFee")),
            ("hyperliquidChain", .string(environment == .mainnet ? "Mainnet" : "Testnet")),
            ("signatureChainId", .string("0x" + String(chainID, radix: 16))),
            ("maxFeeRate", .string(maxFeeRate)), ("builder", .string(builder)),
            ("nonce", .uint(nonce)),
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
                "verifyingContract": .string("0x0000000000000000000000000000000000000000"),
            ]),
            "types": .object([
                "EIP712Domain": .array([
                    field("name", "string"), field("version", "string"),
                    field("chainId", "uint256"),
                    field("verifyingContract", "address"),
                ]),
                "HyperliquidTransaction:ApproveBuilderFee": .array([
                    field("hyperliquidChain", "string"), field("maxFeeRate", "string"),
                    field("builder", "address"), field("nonce", "uint64"),
                ]),
            ]),
            "primaryType": .string("HyperliquidTransaction:ApproveBuilderFee"),
            "message": .object([
                "hyperliquidChain": .string(environment == .mainnet ? "Mainnet" : "Testnet"),
                "maxFeeRate": .string(maxFeeRate), "builder": .string(builder),
                "nonce": .integer(Int64(nonce)),
            ]),
        ])
    }

    public var digest: Data {
        get throws {
            let structure = Keccak256.hash(
                EthereumSigning.text(
                    "HyperliquidTransaction:ApproveBuilderFee(string hyperliquidChain,string maxFeeRate,address builder,uint64 nonce)"
                )
                    + EthereumSigning.text(environment == .mainnet ? "Mainnet" : "Testnet")
                    + EthereumSigning.text(maxFeeRate) + (try EthereumSigning.addressWord(builder))
                    + EthereumSigning.word(nonce))
            return Keccak256.hash(
                Data([0x19, 0x01])
                    + EthereumSigning.domain(name: "HyperliquidSignTransaction", chainID: chainID)
                    + structure
            )
        }
    }

    public func request(signature: WalletSignature) throws -> Data {
        guard try EthereumSigning.recover(signature: signature, digest: digest) == owner else {
            throw BuilderFeeError.signatureMismatch
        }
        return try WireValue.map([
            ("action", action), ("nonce", .uint(nonce)), ("signature", signature.wire),
        ]).jsonData()
    }
}
