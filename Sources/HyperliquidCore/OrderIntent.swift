import Foundation

public enum OrderKind: String, CaseIterable, Codable, Sendable {
    case market = "Market"
    case limit = "Limit"
    case stop = "Stop"
    case takeProfit = "TP"
    public var conditional: Bool { self == .stop || self == .takeProfit }
}
public enum OrderSide: String, Codable, Sendable { case buy, sell }
public enum TriggerExecution: String, CaseIterable, Codable, Sendable {
    case market = "Market"
    case limit = "Limit"
}
public enum ProtectionSizing: String, CaseIterable, Sendable {
    case fixed = "Fixed quantity"
    case entirePosition = "Entire position"
}
public enum TimeInForce: String, CaseIterable, Codable, Sendable {
    case gtc = "Gtc"
    case ioc = "Ioc"
    case postOnly = "Alo"
    public var title: String {
        switch self {
        case .gtc: "Good til canceled"
        case .ioc: "Immediate or cancel"
        case .postOnly: "Post only"
        }
    }
}
public struct OrderIntent: Sendable, Identifiable {
    public let id = UUID()
    public let market: Market
    public let side: OrderSide
    public let kind: OrderKind
    public let size: String
    public let price: String
    public let trigger: String?
    public let leverage: Int
    public let reduceOnly: Bool
    public let triggerExecution: TriggerExecution
    public let timeInForce: TimeInForce
    public let slippagePercent: String
    public let referencePrice: String
    public let positionGuard: PositionIntentGuard?
    public let modificationGuard: OrderModificationGuard?
    public let protectionSizing: ProtectionSizing
    public let createdAt: Date
    public var notional: Double { (Double(size) ?? 0) * (Double(referencePrice) ?? 0) }
    public var initialMargin: Double { notional / Double(leverage) }
    public var executionTitle: String {
        kind.conditional ? "\(kind.rawValue) \(triggerExecution.rawValue)" : kind.rawValue
    }
    public var sizeSummary: String {
        protectionSizing == .entirePosition ? "Entire position at trigger" : size
    }
    public func validateFreshness(now: Date = Date()) throws {
        let age = now.timeIntervalSince(createdAt)
        guard age >= 0, age < 30 else {
            throw OrderValidationError.invalid(
                "Preview expired. Create a fresh preview using current market data.")
        }
    }
    public func validatePosition(_ current: Position?) throws {
        try positionGuard?.validate(current: current, intent: self)
        guard reduceOnly else { return }
        guard market.kind == .perp, let current, current.coin == market.coin else {
            throw OrderValidationError.invalid(
                "Reduce-only requires a current position in this market")
        }
        let signed = try ReviewDecimal.parse(current.szi)
        let quantity = try ReviewDecimal.parse(size)
        guard signed != 0, quantity > 0, quantity <= abs(signed),
              side == (signed > 0 ? .sell : .buy)
        else {
            throw OrderValidationError.invalid(
                "Reduce-only must trade against the current position and cannot exceed its quantity"
            )
        }
    }
}
public enum OrderValidationError: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// Decimal-only order normalization. Never signs, sends, or changes an account.
public enum OrderPlanner {
    /// App-supported market slippage range, expressed as a percentage rather than a fraction.
    public static func slippageFraction(_ percent: String) throws -> Decimal {
        let value = try positiveDecimal(percent, label: "Slippage")
        guard value >= Decimal(string: "0.01")!, value <= 10 else {
            throw OrderValidationError.invalid("Enter slippage between 0.01% and 10%")
        }
        return value / 100
    }
    public static func normalizeSize(_ raw: String, decimals: Int) throws -> String {
        var value = try positiveDecimal(raw, label: "Size")
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, decimals, .down)
        guard rounded > 0 else {
            throw OrderValidationError.invalid("Size is below this market's minimum increment")
        }
        return canonical(rounded)
    }
    public static func marketPriceBound(
        mark: Double, market: Market, side: OrderSide, slippagePercent: String = "0.5"
    ) throws
    -> String {
        guard mark.isFinite, mark > 0,
              let value = Decimal(string: String(mark), locale: Locale(identifier: "en_US_POSIX"))
        else {
            throw OrderValidationError.invalid("Waiting for a live market price")
        }
        let fraction = try slippageFraction(slippagePercent)
        let bound = value * (side == .buy ? 1 + fraction : 1 - fraction)
        return try normalizePrice(
            canonical(bound), market: market, rounding: side == .buy ? .down : .up)
    }
    public static func normalizePrice(_ raw: String, market: Market) throws -> String {
        try normalizePrice(raw, market: market, rounding: .plain)
    }
    private static func normalizePrice(
        _ raw: String, market: Market, rounding: Decimal.RoundingMode
    ) throws -> String {
        var value = try positiveDecimal(raw, label: "Price")
        let maxDecimals = max(0, (market.kind == .perp ? 6 : 8) - market.sizeDecimals)
        let numeric = NSDecimalNumber(decimal: value).doubleValue
        guard numeric.isFinite else { throw OrderValidationError.invalid("Price is too large") }
        let significantDecimals = max(0, 4 - Int(floor(log10(numeric))))
        var integer = Decimal()
        NSDecimalRound(&integer, &value, 0, .plain)
        if integer == value { return canonical(value) }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, min(maxDecimals, significantDecimals), rounding)
        guard rounded > 0 else {
            throw OrderValidationError.invalid("Price is below this market's minimum increment")
        }
        return canonical(rounded)
    }
    public static func preview(
        market: Market, side: OrderSide, kind: OrderKind, size: String, isUSD: Bool,
        price: String, trigger: String?, mark: Double, leverage: Int, reduceOnly: Bool,
        triggerExecution: TriggerExecution = .limit, timeInForce: TimeInForce = .gtc,
        positionGuard: PositionIntentGuard? = nil,
        modificationGuard: OrderModificationGuard? = nil,
        protectionSizing: ProtectionSizing = .fixed,
        slippagePercent: String = "0.5", now: Date = Date()
    ) throws -> OrderIntent {
        guard !market.isBuilderPerp else {
            throw OrderValidationError.invalid(
                "HIP-3 markets are available for market data only. Trading is not available yet.")
        }
        guard market.supportedMarginMode else {
            throw OrderValidationError.invalid(
                "Market margin rules are unavailable. Refresh the market catalog before trading.")
        }
        guard (1...market.maxLeverage).contains(leverage) else {
            throw OrderValidationError.invalid("Leverage exceeds the market limit")
        }
        if protectionSizing == .entirePosition {
            guard market.kind == .perp, (0..<10_000).contains(market.assetID),
                  !market.coin.contains(":"), kind.conditional, reduceOnly, !isUSD,
                  positionGuard?.purpose == .protect,
                  modificationGuard == nil || modificationGuard?.protectionSizing == .entirePosition
            else {
                throw OrderValidationError.invalid(
                    "Entire-position protection requires a validator perpetual position TP/SL draft without a fixed USD amount or fixed-quantity modification"
                )
            }
        }
        if market.kind == .spot && (reduceOnly || kind == .stop || kind == .takeProfit) {
            throw OrderValidationError.invalid(
                "Spot supports market and limit orders without reduce-only")
        }
        let normalizedTrigger: String?
        if kind.conditional {
            guard let trigger, !trigger.isEmpty else {
                throw OrderValidationError.invalid("Enter a trigger price")
            }
            normalizedTrigger = try normalizePrice(trigger, market: market)
            guard mark.isFinite, mark > 0, let value = Double(normalizedTrigger!) else {
                throw OrderValidationError.invalid("Waiting for a live mark price")
            }
            let mustBeAbove = kind == .stop ? side == .buy : side == .sell
            guard mustBeAbove ? value > mark : value < mark else {
                throw OrderValidationError.invalid(
                    "Trigger must be \(mustBeAbove ? "above" : "below") the current mark price")
            }
        } else {
            normalizedTrigger = nil
        }
        let sizing = try orderSizing(
            market: market, side: side, kind: kind, size: size, isUSD: isUSD,
            price: price, trigger: normalizedTrigger, mark: mark, triggerExecution: triggerExecution,
            slippagePercent: slippagePercent)
        let normalizedSize = sizing.size
        let normalizedPrice = sizing.price
        let ntl = (Decimal(string: normalizedSize) ?? 0) * (Decimal(string: normalizedPrice) ?? 0)
        guard reduceOnly || ntl >= 10 else {
            throw OrderValidationError.invalid(
                "Order value at the price limit is $\(canonical(ntl)) after size rounding; it must be at least $10")
        }
        let intent = OrderIntent(
            market: market, side: side, kind: kind, size: normalizedSize, price: normalizedPrice,
            trigger: normalizedTrigger, leverage: leverage, reduceOnly: reduceOnly,
            triggerExecution: triggerExecution, timeInForce: kind == .market ? .ioc : timeInForce,
            slippagePercent: kind == .market ? slippagePercent : "10",
            referencePrice: sizing.referencePrice, positionGuard: positionGuard,
            modificationGuard: modificationGuard,
            protectionSizing: protectionSizing,
            createdAt: now)
        if let positionGuard { try positionGuard.validateDraft(intent) }
        try modificationGuard?.validateDraft(intent)
        return intent
    }
    /// Shared draft and submission sizing. This computes amounts only; preview still validates the order.
    public static func orderSizing(
        market: Market, side: OrderSide, kind: OrderKind, size: String, isUSD: Bool,
        price: String, trigger: String?, mark: Double, triggerExecution: TriggerExecution = .limit,
        slippagePercent: String = "0.5"
    ) throws -> (size: String, price: String, referencePrice: String) {
        let inputPrice: String
        let sizingPrice: Decimal
        let boundedMarket = kind == .market || (kind.conditional && triggerExecution == .market)
        if kind == .market {
            guard mark > 0, mark.isFinite,
                  let decimalMark = Decimal(
                    string: String(mark), locale: Locale(identifier: "en_US_POSIX")),
                  decimalMark > 0
            else { throw OrderValidationError.invalid("Waiting for a live market price") }
            // Market execution uses a bounded IOC limit, not an unbounded market instruction.
            inputPrice = try marketPriceBound(
                mark: mark, market: market, side: side, slippagePercent: slippagePercent)
            sizingPrice = decimalMark
        } else if kind.conditional, triggerExecution == .market {
            let triggerPrice = try positiveDecimal(normalizePrice(trigger ?? "", market: market), label: "Trigger")
            inputPrice = canonical(
                triggerPrice * (side == .buy ? Decimal(string: "1.1")! : Decimal(string: "0.9")!))
            sizingPrice = triggerPrice
        } else {
            inputPrice = price
            sizingPrice = try positiveDecimal(price, label: "Price")
        }
        let normalizedPrice = try normalizePrice(
            inputPrice, market: market,
            rounding: boundedMarket ? (side == .buy ? .down : .up) : .plain)
        let normalizedSizingPrice =
            boundedMarket ? sizingPrice : try positiveDecimal(normalizedPrice, label: "Price")
        let inputSize = try positiveDecimal(size, label: isUSD ? "Notional" : "Size")
        let normalizedSize = try normalizeSize(
            canonical(isUSD ? inputSize / normalizedSizingPrice : inputSize),
            decimals: market.sizeDecimals)
        return (normalizedSize, normalizedPrice, canonical(normalizedSizingPrice))
    }
    private static func positiveDecimal(_ raw: String, label: String) throws -> Decimal {
        guard raw.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), value > 0,
              NSDecimalNumber(decimal: value).doubleValue.isFinite
        else {
            throw OrderValidationError.invalid("\(label) must be a positive decimal number")
        }
        return value
    }
    private static func canonical(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
