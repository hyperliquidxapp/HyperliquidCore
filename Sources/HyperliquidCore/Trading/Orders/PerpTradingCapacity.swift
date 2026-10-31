import Foundation

/// A directional server snapshot, at its configured leverage. A reversing
/// order is checked in full: the server's maximum already includes closing
/// capacity, so callers must not add the current position a second time.
public struct PerpTradingCapacity: Sendable, Equatable {
    public let maximumSize: Decimal
    public let availableMargin: Decimal
    public let leverage: Leverage
    public let side: OrderSide
    private let market: Market
    private let mark: Decimal
    private let limit: Decimal?
    public init(
        asset: ActiveAssetData, address: String, market: Market, side: OrderSide,
        limitPrice: String? = nil
    )
    throws {
        try asset.validate(address: address, market: market)
        let index = side == .buy ? 0 : 1
        let maximum = try ReviewDecimal.parse(asset.maxTradeSzs[index])
        // A negative margin balance is zero spendable capacity, not malformed
        // data. It must not prevent a verified reduce-only close.
        availableMargin = try max(0, ReviewDecimal.parse(asset.availableToTrade[index]))
        leverage = asset.leverage
        self.side = side
        self.market = market
        mark = try ReviewDecimal.parse(asset.markPx)
        limit = try limitPrice.map { try ReviewDecimal.parse($0) }
        var adjusted = try Self.atLimit(maximum, mark: mark, side: side, price: limit)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &adjusted, market.sizeDecimals, .down)
        maximumSize = rounded
    }
    /// Matches the official trade form's directional limit-price adjustment;
    /// no adjustment applies to an IOC bound or to a future trigger price.
    private static func atLimit(_ maximum: Decimal, mark: Decimal, side: OrderSide, price: Decimal?)
    throws -> Decimal {
        guard let limit = price else { return maximum }
        guard limit > 0 else { throw OrderValidationError.invalid("Enter a valid limit price") }
        let value = (side == .buy ? limit < mark : limit >= mark) ? maximum * mark / limit : maximum
        guard !value.isNaN, value >= 0, NSDecimalNumber(decimal: value).doubleValue.isFinite else {
            throw OrderValidationError.invalid("Trading capacity is too large to calculate")
        }
        return value
    }
    public static func limitPrice(for intent: OrderIntent) -> String? {
        intent.kind == .limit || (intent.kind.conditional && intent.triggerExecution == .limit)
            ? intent.price : nil
    }
    public func validate(_ intent: OrderIntent) throws {
        guard intent.market == market, intent.side == side,
              try Self.limitPrice(for: intent).map({ try ReviewDecimal.parse($0) }) == limit
        else {
            throw OrderValidationError.invalid(
                "Refresh trading capacity for the current market, side and price")
        }
        guard !intent.reduceOnly else { return }
        guard intent.leverage == leverage.value else {
            throw OrderValidationError.invalid("Refresh trading capacity after changing leverage")
        }
        let quantity = try ReviewDecimal.parse(intent.size)
        guard quantity > 0, quantity <= maximumSize else {
            throw OrderValidationError.invalid(
                "Order exceeds the current \(side == .buy ? "buy" : "sell") capacity at \(leverage.value)×. Reduce the size or review account margin."
            )
        }
    }
    /// At a different, unapplied leverage this is an estimate from the server's
    /// available margin, not an extrapolation of its current quantity cap.
    /// Execution must fetch the actual cap after leverage is acknowledged.
    public func percentageSize(requestedLeverage: Int, percentage: Int) throws -> String {
        guard market.kind == .perp, (1...100).contains(percentage),
              (1...market.maxLeverage).contains(requestedLeverage)
        else {
            throw OrderValidationError.invalid("Select a valid leverage and percentage")
        }
        let capacity: Decimal
        if requestedLeverage == leverage.value {
            capacity = maximumSize
        } else {
            capacity = try Self.atLimit(
                availableMargin * Decimal(requestedLeverage) / mark, mark: mark, side: side,
                price: limit)
        }
        let quantity = capacity * Decimal(percentage) / 100
        guard !quantity.isNaN, NSDecimalNumber(decimal: quantity).doubleValue.isFinite else {
            throw OrderValidationError.invalid("Trading capacity is too large to calculate")
        }
        guard quantity > 0 else {
            throw OrderValidationError.invalid("No available trading capacity for this side")
        }
        return try OrderPlanner.normalizeSize(
            NSDecimalNumber(decimal: quantity).stringValue, decimals: market.sizeDecimals)
    }
}
