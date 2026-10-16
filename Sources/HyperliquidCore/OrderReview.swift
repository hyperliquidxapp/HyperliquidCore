import Foundation

/// User-specific rates already include the account's tier and staking discount.
/// Applies the official additional referral and stable-pair factors for the
/// current catalog: validator perps and USDC-quoted spot, without builders.
public struct UserFeeRates: Sendable, Equatable {
    public let perpMaker: Decimal
    public let perpTaker: Decimal
    public let spotMaker: Decimal
    public let spotTaker: Decimal
    public let referralDiscount: Decimal
    public init(response: JSONValue) throws {
        perpMaker = try ReviewDecimal.parse(response["userAddRate"].string)
        perpTaker = try ReviewDecimal.parse(response["userCrossRate"].string)
        spotMaker = try ReviewDecimal.parse(response["userSpotAddRate"].string)
        spotTaker = try ReviewDecimal.parse(response["userSpotCrossRate"].string)
        referralDiscount = try ReviewDecimal.parse(response["activeReferralDiscount"].string)
        guard perpTaker >= 0, spotTaker >= 0, referralDiscount >= 0, referralDiscount <= 1,
              [perpMaker, perpTaker, spotMaker, spotTaker].allSatisfy({ abs($0) <= 1 })
        else {
            throw OrderValidationError.invalid("Invalid account fee rates")
        }
    }
    public func estimate(for intent: OrderIntent) throws -> OrderFeeEstimate {
        guard
            intent.market.kind == .perp
                ? intent.market.assetID < 10_000 : intent.market.quoteTokenIndex == 0
        else {
            throw OrderValidationError.invalid(
                "Fee estimates for this market's collateral are not supported yet")
        }
        let stableScale: Decimal =
            intent.market.kind == .spot && intent.market.isStablePair ? Decimal(string: "0.2")! : 1
        var maker = (intent.market.kind == .spot ? spotMaker : perpMaker) * stableScale
        if maker > 0 { maker *= 1 - referralDiscount }
        let taker =
            (intent.market.kind == .spot ? spotTaker : perpTaker) * stableScale
            * (1 - referralDiscount)
        let notional =
            try ReviewDecimal.parse(intent.size) * ReviewDecimal.parse(intent.referencePrice)
        guard !notional.isNaN, notional > 0, NSDecimalNumber(decimal: notional).doubleValue.isFinite
        else {
            throw OrderValidationError.invalid("Order value is too large to estimate fees")
        }
        let makerOnly = intent.kind == .limit && intent.timeInForce == .postOnly
        let takerOnly =
            intent.kind == .market || (intent.kind == .limit && intent.timeInForce == .ioc)
            || (intent.kind.conditional && intent.triggerExecution == .market)
        let lower = makerOnly ? maker : takerOnly ? taker : min(maker, taker)
        let upper = makerOnly ? maker : takerOnly ? taker : max(maker, taker)
        return OrderFeeEstimate(
            lower: notional * lower, upper: notional * upper, maximumRate: upper)
    }
}

public struct OrderFeeEstimate: Sendable, Equatable {
    public let lower: Decimal
    public let upper: Decimal
    public let maximumRate: Decimal
    public func validate(current: OrderFeeEstimate) throws {
        guard current.maximumRate <= maximumRate else {
            throw OrderValidationError.invalid(
                "Account fees increased. Create a new preview to review the current estimate.")
        }
    }
}

public struct ActiveAssetData: Decodable, Sendable, Equatable {
    public let user: String
    public let coin: String
    public let leverage: Leverage
    public let maxTradeSzs: [String]
    public let availableToTrade: [String]
    public let markPx: String
    public func validate(address: String, market: Market) throws {
        guard market.kind == .perp, user.lowercased() == address.lowercased(), coin == market.coin,
              (1...market.maxLeverage).contains(leverage.value),
              ["cross", "isolated"].contains(leverage.type),
              maxTradeSzs.count == 2, availableToTrade.count == 2
        else {
            throw OrderValidationError.invalid(
                "Trading limits do not match the requested account and market")
        }
        let limits = try maxTradeSzs.map { try ReviewDecimal.parse($0) }
        _ = try availableToTrade.map { try ReviewDecimal.parse($0) }
        guard limits.allSatisfy({ $0 >= 0 }), try ReviewDecimal.parse(markPx) > 0 else {
            throw OrderValidationError.invalid("Invalid trading limit response")
        }
    }
    public func validateLeverage(intent: OrderIntent, reviewed: Leverage?, targetApplied: Bool)
    throws {
        guard !intent.reduceOnly else { return }
        guard let reviewed, leverage.type == reviewed.type else {
            throw OrderValidationError.invalid(
                "Margin mode changed since preview. Review the order again.")
        }
        if targetApplied, leverage.value != intent.leverage {
            throw OrderValidationError.invalid(
                "Leverage changed before submission. Review the order again.")
        }
    }
}

public enum ReviewDecimal {
    public static func parse(_ raw: String?) throws -> Decimal {
        guard let raw,
              raw.range(of: "^-?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) == raw
                .startIndex..<raw.endIndex,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN,
              NSDecimalNumber(decimal: value).doubleValue.isFinite
        else {
            throw OrderValidationError.invalid("Account data contains an invalid decimal value")
        }
        return value
    }
}

/// Checks spend against free tokens. The limit price is the worst-case spend
/// for a buy, including bounded IOC orders. Fees are estimated separately.
public enum SpotOrderBudget {
    private static func maintenanceAvailable(token: Int, balances: JSONValue, required: Bool = false) throws
    -> Decimal? {
        guard case .array(let limits) = balances["tokenToAvailableAfterMaintenance"] else {
            if !required && balances["tokenToAvailableAfterMaintenance"] == .null { return nil }
            throw OrderValidationError.invalid(
                "Available balance after maintenance margin is unavailable. Refresh and retry.")
        }
        let matching = limits.filter { $0.array.first?.int64 == Int64(token) }
        guard matching.count <= 1 else {
            throw OrderValidationError.invalid("Duplicate available balance in account response")
        }
        guard let row = matching.first else {
            if required {
                throw OrderValidationError.invalid(
                    "Available balance for this token is unavailable. Refresh and retry.")
            }
            return nil
        }
        guard row.array.count == 2 else {
            throw OrderValidationError.invalid("Invalid available balance after maintenance margin")
        }
        return max(0, try ReviewDecimal.parse(row.array[1].string))
    }
    public static func available(token: Int, balances: JSONValue) throws -> Decimal {
        guard case .array(let rows) = balances["balances"] else {
            throw OrderValidationError.invalid("Spot balances are unavailable")
        }
        let matching = rows.filter { $0["token"].int64 == Int64(token) }
        guard matching.count <= 1 else {
            throw OrderValidationError.invalid("Duplicate token balance in account response")
        }
        guard let row = matching.first else { return 0 }
        let total = try ReviewDecimal.parse(row["total"].string)
        let hold = try ReviewDecimal.parse(row["hold"].string)
        guard total >= 0, hold >= 0, hold <= total else {
            throw OrderValidationError.invalid("Invalid held token balance")
        }
        let free = total - hold
        return try maintenanceAvailable(token: token, balances: balances).map { min(free, $0) } ?? free
    }
    public static func validate(
        _ intent: OrderIntent, balances: JSONValue, replacing: OpenOrder? = nil,
        accountMode: String = "disabled"
    ) throws {
        guard intent.market.kind == .spot else { return }
        guard ["default", "disabled", "unifiedAccount"].contains(accountMode) else {
            throw OrderValidationError.invalid("Spot trading is not yet supported for account mode: \(accountMode)")
        }
        guard let base = intent.market.baseTokenIndex, let quote = intent.market.quoteTokenIndex
        else {
            throw OrderValidationError.invalid(
                "Refresh this market's token metadata before trading")
        }
        let token = intent.side == .buy ? quote : base
        let maintenance = try maintenanceAvailable(
            token: token, balances: balances, required: accountMode == "unifiedAccount")
        var free = try available(token: token, balances: balances)
        if let order = replacing {
            guard order.coin == intent.market.coin, order.orderType == "Limit", order.oid >= 0,
                  ["A", "B"].contains(order.side)
            else {
                throw OrderValidationError.invalid(
                    "The order being modified changed. Create a new preview.")
            }
            // Replacing an order releases its existing hold only on the spend
            // side of that order. Never borrow hold from another token/order.
            if (order.side == "B") == (intent.side == .buy) {
                let size = try ReviewDecimal.parse(order.sz)
                let price = try ReviewDecimal.parse(order.limitPx)
                guard size > 0, price > 0 else {
                    throw OrderValidationError.invalid("Invalid existing order amount")
                }
                let credit = intent.side == .buy ? size * price : size
                let row = balances["balances"].array.first { $0["token"].int64 == Int64(token) }
                let held = try ReviewDecimal.parse(row?["hold"].string ?? "0")
                free += min(credit, held)
            }
        }
        if let maintenance { free = min(free, maintenance) }
        let size = try ReviewDecimal.parse(intent.size)
        let price = try ReviewDecimal.parse(intent.price)
        guard size > 0, price > 0 else {
            throw OrderValidationError.invalid("Invalid order amount")
        }
        let required = intent.side == .buy ? size * price : size
        guard required <= free else {
            throw OrderValidationError.invalid(
                intent.side == .buy
                    ? "Insufficient available spot USDC at the order's price bound"
                    : "Insufficient available spot tokens; open orders may reserve part of the balance"
            )
        }
    }
    public static func percentageSize(
        market: Market, side: OrderSide, balances: JSONValue, priceBound: String, percentage: Int
    ) throws -> String {
        guard market.kind == .spot, (1...100).contains(percentage),
              let base = market.baseTokenIndex,
              let quote = market.quoteTokenIndex
        else {
            throw OrderValidationError.invalid("Spot token metadata is unavailable")
        }
        let budget =
            try available(token: side == .buy ? quote : base, balances: balances)
            * (Decimal(percentage) / 100)
        let price = try ReviewDecimal.parse(priceBound)
        guard price > 0 else { throw OrderValidationError.invalid("Enter a valid price first") }
        return try OrderPlanner.normalizeSize(
            NSDecimalNumber(decimal: side == .buy ? budget / price : budget).stringValue,
            decimals: market.sizeDecimals)
    }
}
