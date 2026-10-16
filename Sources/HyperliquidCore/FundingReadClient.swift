import Foundation

public struct FundingAccountSnapshot: Sendable {
    public let address: String
    public let environment: NetworkEnvironment
    public let tokens: [FundingToken]
    public let spot: JSONValue
    public let perpAvailable: Decimal
    public let startedAt: Double

    public init(
        address: String, environment: NetworkEnvironment, tokens: [FundingToken], spot: JSONValue,
        perpAvailable: Decimal, startedAt: Double, mode: String
    ) throws {
        guard Address.isValid(address), !perpAvailable.isNaN, perpAvailable >= 0,
              startedAt.isFinite, startedAt >= 0,
              mode == "default" || mode == "disabled"
        else {
            throw WalletError.invalid(
                "Funding balance rules for this account mode are unavailable. Refresh the account.")
        }
        guard Set(tokens.map(\.index)).count == tokens.count,
              Set(tokens.map(\.tokenIdentity)).count == tokens.count,
              case .array = spot["balances"]
        else {
            throw APIError.malformed("Ambiguous token metadata or missing spot balances")
        }
        self.address = address.lowercased()
        self.environment = environment
        self.tokens = tokens
        self.spot = spot
        self.perpAvailable = perpAvailable
        self.startedAt = startedAt
    }
    public func requireFresh(now: Double = ReceiptClock.now) throws {
        guard now.isFinite, now >= startedAt, now - startedAt < 15 else {
            throw WalletError.invalid("Funding balance read expired. Refresh before continuing.")
        }
    }
    public func available(source: FundingSource, token: FundingToken) throws -> Decimal {
        try requireFresh()
        guard tokens.contains(token) else {
            throw WalletError.invalid("Transfer token metadata changed.")
        }
        if source == .perp {
            guard token.index == 0, token.name == "USDC" else {
                throw WalletError.invalid("Perpetual transfers use USDC.")
            }
            return perpAvailable
        }
        let matching = spot["balances"].array.filter { $0["token"].int64 == Int64(token.index) }
        guard matching.count <= 1,
              matching.first == nil || matching.first?["coin"].string == token.name
        else {
            throw APIError.malformed("Spot balance does not match the transfer token")
        }
        return try SpotOrderBudget.available(token: token.index, balances: spot)
    }
    public func validate(intent: FundingIntent, maximumAge: TimeInterval = 30) throws {
        guard address == intent.owner, environment == intent.environment else {
            throw WalletError.invalid("Funding account or network changed.")
        }
        try intent.validate(
            available: available(source: intent.source, token: intent.token), token: intent.token,
            maximumAge: maximumAge)
    }
}

public protocol FundingReadClient: Sendable {
    func fundingAccount(address: String) async throws -> FundingAccountSnapshot
}
extension HyperliquidAPI: FundingReadClient {
    public func fundingAccount(address: String) async throws -> FundingAccountSnapshot {
        guard Address.isValid(address) else {
            throw WalletError.invalid("Invalid funding account.")
        }
        let started = ReceiptClock.now
        async let account = self.account(address: address)
        async let spot = spotBalances(address: address)
        async let meta = info(["type": .string("spotMeta")])
        async let mode = info(["type": .string("userAbstraction"), "user": .string(address)])
        let values = try await (account, spot, meta, mode)
        guard let abstraction = values.3.string else {
            throw APIError.malformed("Account funding mode unavailable")
        }
        let snapshot = try FundingAccountSnapshot(
            address: address, environment: environment,
            tokens: FundingToken.parse(meta: values.2), spot: values.1,
            perpAvailable: ReviewDecimal.parse(values.0.withdrawable), startedAt: started,
            mode: abstraction)
        try snapshot.requireFresh()
        return snapshot
    }
}

public protocol BridgeDepositReadClient: Sendable {
    func snapshot(intent: BridgeDepositIntent) async throws -> BridgeDepositSnapshot
    func receipt(hash: String, intent: BridgeDepositIntent) async throws -> Bool?
}
extension BridgeRPC: BridgeDepositReadClient {}

public protocol DepositBalanceReadClient: Sendable {
    func usdcBalance(owner: String, token: String) async throws -> Decimal
}
extension BridgeRPC: DepositBalanceReadClient {}
