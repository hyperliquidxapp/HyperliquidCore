import Foundation

public enum FundingOperation: String, CaseIterable, Sendable {
    case withdraw, send
}
public enum FundingSource: String, CaseIterable, Sendable {
    case perp, spot
}

/// The identifier is obtained from spotMeta, never inferred from a display symbol.
public struct FundingToken: Sendable, Equatable, Hashable, Identifiable {
    public let index: Int
    public let name: String
    public let tokenID: String
    public let decimals: Int
    public var id: Int { index }
    public var wireName: String { name + ":" + tokenID }
    var tokenIdentity: String {
        String(repeating: "0", count: 34 - tokenID.count) + tokenID.dropFirst(2)
    }

    public init(index: Int, name: String, tokenID: String, decimals: Int) throws {
        guard index >= 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 64, !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil, (0...18).contains(decimals),
              tokenID.range(of: "^0x[0-9a-fA-F]{1,32}$", options: .regularExpression) == tokenID
                .startIndex..<tokenID.endIndex
        else { throw WalletError.invalid("Invalid transfer token metadata. Refresh balances.") }
        self.index = index
        self.name = name
        self.tokenID = tokenID.lowercased()
        self.decimals = decimals
    }
    public static func parse(meta: JSONValue) throws -> [FundingToken] {
        guard case .array(let rows) = meta["tokens"] else {
            throw APIError.malformed("Transfer token metadata is unavailable")
        }
        let tokens = try rows.map { row -> FundingToken in
            guard let index = row["index"].int64, let id = row["tokenId"].string,
                  let name = row["name"].string, let precision = row["weiDecimals"].int64,
                  let nativeIndex = Int(exactly: index), let decimals = Int(exactly: precision)
            else { throw APIError.malformed("Incomplete transfer token metadata") }
            return try FundingToken(index: nativeIndex, name: name, tokenID: id, decimals: decimals)
        }
        guard Set(tokens.map(\.index)).count == tokens.count,
              Set(tokens.map(\.tokenIdentity)).count == tokens.count,
              Set(tokens.map(\.wireName)).count == tokens.count
        else { throw APIError.malformed("Ambiguous transfer token metadata") }
        return tokens
    }
}

/// A human-readable, main-wallet action. API wallets cannot sign these transfers.
public struct FundingIntent: Sendable, Identifiable {
    public let id = UUID()
    public let owner: String
    public let destination: String
    public let amount: String
    public let operation: FundingOperation
    public let source: FundingSource
    public let token: FundingToken
    public let environment: NetworkEnvironment
    public let chainID: UInt64
    public let createdAt: Date
    public var estimatedFee: Decimal { operation == .withdraw ? 1 : 0 }
    public var estimatedReceived: Decimal {
        (Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) ?? 0) - estimatedFee
    }
    public var actionType: String {
        operation == .withdraw ? "withdraw3" : source == .spot ? "spotSend" : "usdSend"
    }
    private var primaryType: String {
        "HyperliquidTransaction:"
            + (operation == .withdraw ? "Withdraw" : source == .spot ? "SpotSend" : "UsdSend")
    }
    private var chainName: String { environment == .mainnet ? "Mainnet" : "Testnet" }

    public init(
        owner: String, destination: String, amount: String, operation: FundingOperation,
        source: FundingSource, token: FundingToken, environment: NetworkEnvironment,
        chainID: UInt64, available: Decimal, now: Date = Date()
    ) throws {
        guard Address.isValid(owner), Address.isValid(destination),
              destination.lowercased() != "0x" + String(repeating: "0", count: 40),
              chainID > 0, chainID <= UInt64(Int64.max),
              operation == .withdraw || owner.lowercased() != destination.lowercased(),
              !available.isNaN, available >= 0
        else {
            throw WalletError.invalid(
                "Enter a valid receiving address and connect the sending wallet.")
        }
        guard source != .perp || (token.index == 0 && token.name == "USDC"),
              operation != .withdraw || (source == .perp && token.index == 0 && token.name == "USDC")
        else {
            throw WalletError.invalid(
                "Arbitrum withdrawal uses perpetual USDC. Transfer spot USDC to Perp first.")
        }
        let normalized = try Self.normalize(
            amount, decimals: operation == .withdraw ? 6 : token.decimals)
        let value = try ReviewDecimal.parse(normalized)
        guard value <= available, operation != .withdraw || value > 1 else {
            throw WalletError.invalid(
                "The amount exceeds the available balance or does not cover the estimated withdrawal fee."
            )
        }
        self.owner = owner.lowercased()
        self.destination = destination.lowercased()
        self.amount = normalized
        self.operation = operation
        self.source = source
        self.token = token
        self.environment = environment
        self.chainID = chainID
        self.createdAt = now
    }
    public static func normalize(_ raw: String, decimals: Int) throws -> String {
        guard (0...18).contains(decimals), raw.count <= 39,
              raw.range(of: "^[0-9]{1,20}(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              (raw.split(separator: ".", omittingEmptySubsequences: false).last?.count ?? 0)
                <= decimals
                || !raw.contains(".")
        else {
            throw WalletError.invalid(
                "Enter an exact positive amount within the token's decimal precision.")
        }
        let value = try ReviewDecimal.parse(raw)
        guard value > 0 else { throw WalletError.invalid("Amount must be greater than zero.") }
        return NSDecimalNumber(decimal: value).stringValue
    }
    public func validate(
        available: Decimal, token: FundingToken, now: Date = Date(), maximumAge: TimeInterval = 30
    ) throws {
        let age = now.timeIntervalSince(createdAt)
        guard maximumAge > 0, age >= 0, age < maximumAge, token == self.token,
              !available.isNaN, available >= (try ReviewDecimal.parse(amount))
        else {
            throw WalletError.invalid(
                "Transfer balance, token or preview changed. Create a fresh preview.")
        }
    }
    public func action(nonce: UInt64) -> WireValue {
        var values: [(String, WireValue)] = [
            ("type", .string(actionType)), ("hyperliquidChain", .string(chainName)),
            ("signatureChainId", .string("0x" + String(chainID, radix: 16))),
            ("destination", .string(destination))
        ]
        if source == .spot { values.append(("token", .string(token.wireName))) }
        values += [("amount", .string(amount)), ("time", .uint(nonce))]
        return .map(values)
    }
    public func typedData(nonce: UInt64) throws -> JSONValue {
        guard nonce <= UInt64(Int64.max) else {
            throw WalletError.invalid("Invalid funding nonce.")
        }
        let stringNames =
            ["hyperliquidChain", "destination"] + (source == .spot ? ["token"] : []) + ["amount"]
        let fields =
            stringNames.map { JSONValue.object(["name": .string($0), "type": .string("string")]) }
            + [.object(["name": .string("time"), "type": .string("uint64")])]
        var message: [String: JSONValue] = [
            "hyperliquidChain": .string(chainName), "destination": .string(destination),
            "amount": .string(amount), "time": .integer(Int64(nonce))
        ]
        if source == .spot { message["token"] = .string(token.wireName) }
        return .object([
            "domain": .object([
                "name": .string("HyperliquidSignTransaction"), "version": .string("1"),
                "chainId": .integer(Int64(chainID)),
                "verifyingContract": .string("0x0000000000000000000000000000000000000000")
            ]),
            "types": .object([
                "EIP712Domain": .array([
                    .object(["name": .string("name"), "type": .string("string")]),
                    .object(["name": .string("version"), "type": .string("string")]),
                    .object(["name": .string("chainId"), "type": .string("uint256")]),
                    .object(["name": .string("verifyingContract"), "type": .string("address")])
                ]), primaryType: .array(fields)
            ]), "primaryType": .string(primaryType), "message": .object(message)
        ])
    }
    public func digest(nonce: UInt64) -> Data {
        let tokenField = source == .spot ? ",string token" : ""
        let type =
            primaryType + "(string hyperliquidChain,string destination" + tokenField
            + ",string amount,uint64 time)"
        var encoded =
            EthereumSigning.text(type) + EthereumSigning.text(chainName)
            + EthereumSigning.text(destination)
        if source == .spot { encoded += EthereumSigning.text(token.wireName) }
        encoded += EthereumSigning.text(amount) + EthereumSigning.word(nonce)
        return Keccak256.hash(
            Data([0x19, 0x01])
                + EthereumSigning.domain(name: "HyperliquidSignTransaction", chainID: chainID)
                + Keccak256.hash(encoded))
    }
    public func request(signature: WalletSignature, nonce: UInt64) throws -> Data {
        guard nonce <= UInt64(Int64.max),
              try EthereumSigning.recover(signature: signature, digest: digest(nonce: nonce)) == owner
        else {
            throw WalletError.invalid(
                "Funding signature does not match the reviewed sending wallet.")
        }
        return try WireValue.map([
            ("action", action(nonce: nonce)), ("nonce", .uint(nonce)),
            ("signature", signature.wire)
        ]).jsonData()
    }
}
