import Foundation

/// A classic USDC isolated-position snapshot, with conservative transfer limits.
public struct IsolatedMarginState: Sendable {
    public let owner: String
    public let market: Market
    public let position: Position
    public let table: MarginTable
    public let signedSize: Decimal
    public let cash: Decimal
    public let mark: Decimal
    public let equity: Decimal
    public let availableToAdd: Decimal
    public let availableToRemove: Decimal

    public init(
        owner: String, market: Market, account: AccountState, mode: String, table: MarginTable
    )
    throws {
        guard Address.isValid(owner), market.kind == .perp,
              (0..<10_000).contains(market.assetID), !market.coin.contains(":"),
              ["default", "disabled"].contains(mode), market.supportedMarginMode
        else {
            throw OrderValidationError.invalid(
                "Margin adjustment requires a classic USDC perpetual account.")
        }
        let positions = account.assetPositions.map(\.position).filter { $0.coin == market.coin }
        guard positions.count == 1, let position = positions.first,
              position.leverage.type == "isolated",
              (1...market.maxLeverage).contains(position.leverage.value),
              let size = position.signedQuantity, size != 0
        else {
            throw OrderValidationError.invalid("Select an open isolated position.")
        }
        let cash = try ReviewDecimal.parse(position.leverage.rawUsd)
        let notional = try ReviewDecimal.parse(position.positionValue)
        let available = try ReviewDecimal.parse(account.withdrawable)
        guard notional > 0, available >= 0 else {
            throw OrderValidationError.invalid(
                "Position value or available balance is unavailable.")
        }
        let equity = cash + (size > 0 ? notional : -notional)
        try MarginTable.finite(equity)
        let mark = notional / abs(size)
        try MarginTable.finite(mark)
        guard mark > 0 else { throw OrderValidationError.invalid("Position mark is unavailable.") }
        let tier = try table.tier(at: notional)
        let initial = notional / Decimal(min(position.leverage.value, tier.maxLeverage))
        let minimum = max(initial, notional / 10)
        self.owner = owner.lowercased()
        self.market = market
        self.position = position
        self.table = table
        signedSize = size
        self.cash = cash
        self.mark = mark
        self.equity = equity
        availableToAdd = available
        availableToRemove = market.allowsIsolatedMarginRemoval ? max(0, equity - minimum) : 0
    }
}

public struct IsolatedMarginIntent: Sendable, Identifiable {
    public let id = UUID()
    public let state: IsolatedMarginState
    public let amount: String
    public let adding: Bool
    public let units: Int64
    public let environment: NetworkEnvironment
    public let connection: WalletConnection
    public let createdAt: Date
    public var delta: Decimal { Decimal(units) / 1_000_000 }
    public var resultingEquity: Decimal { state.equity + delta }
    public var liquidationPrice: Decimal? {
        try? state.table.liquidationPrice(
            mark: state.mark, signedSize: state.signedSize, equity: resultingEquity)
    }

    public init(
        state: IsolatedMarginState, amount: String, adding: Bool,
        environment: NetworkEnvironment, connection: WalletConnection, now: Date = Date()
    ) throws {
        guard connection.address.lowercased() == state.owner,
              amount.range(of: "^[0-9]+(?:\\.[0-9]{1,6})?$", options: .regularExpression) != nil
        else {
            throw OrderValidationError.invalid("Enter a USDC amount with at most six decimals.")
        }
        let value = try ReviewDecimal.parse(amount)
        let scaled = value * 1_000_000
        guard value > 0, !scaled.isNaN, scaled <= Decimal(Int64.max) else {
            throw OrderValidationError.invalid("Margin amount is outside the supported range.")
        }
        let integer = NSDecimalNumber(decimal: scaled).int64Value
        guard integer > 0, Decimal(integer) == scaled else {
            throw OrderValidationError.invalid("Margin amount must use whole USDC micro-units.")
        }
        self.state = state
        self.amount = NSDecimalNumber(decimal: value).stringValue
        self.adding = adding
        units = adding ? integer : -integer
        self.environment = environment
        self.connection = connection
        createdAt = now
        try validate(current: state, now: now)
    }

    public func validate(
        current: IsolatedMarginState, now: Date = Date(), maximumAge: TimeInterval = 30
    ) throws {
        let age = now.timeIntervalSince(createdAt)
        guard age.isFinite, age >= 0, age < maximumAge,
              current.owner == state.owner, current.market == state.market,
              current.table == state.table,
              current.signedSize == state.signedSize,
              current.position.leverage.type == state.position.leverage.type,
              current.position.leverage.value == state.position.leverage.value,
              current.cash == state.cash,
              current.position.entryPx == state.position.entryPx
        else {
            throw OrderValidationError.invalid("Position or preview changed. Review margin again.")
        }
        let value = abs(delta)
        guard adding ? value <= current.availableToAdd : value <= current.availableToRemove else {
            throw OrderValidationError.invalid(
                adding
                    ? "Available USDC changed. Review a smaller amount."
                    : "This amount cannot be removed while retaining required margin.")
        }
    }

    public var action: WireValue {
        .map([
            ("type", .string("updateIsolatedMargin")),
            ("asset", .uint(UInt64(state.market.assetID))),
            ("isBuy", .bool(state.signedSize > 0)), ("ntli", .int(units))
        ])
    }

    public func request(signature: WalletSignature, nonce: UInt64, expiresAfter: UInt64) throws
    -> Data {
        let digest = try EthereumSigning.actionDigest(
            action: action, nonce: nonce, environment: environment, expiresAfter: expiresAfter)
        guard try EthereumSigning.recover(signature: signature, digest: digest) == state.owner
        else {
            throw WalletError.invalid("Margin signature does not match the connected wallet.")
        }
        return try SigningPayload.request(
            action: action, signature: signature, nonce: nonce, expiresAfter: expiresAfter)
    }
}
