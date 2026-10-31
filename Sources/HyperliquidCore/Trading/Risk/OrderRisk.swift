import Foundation

public struct MarginTier: Sendable, Equatable {
    public let lowerBound: Decimal
    public let maxLeverage: Int
    public let maintenanceDeduction: Decimal
    public var maintenanceRate: Decimal { 1 / (Decimal(maxLeverage) * 2) }
}

public struct MarginTable: Sendable, Equatable {
    public let id: Int
    public let tiers: [MarginTier]
    public init(id: Int, bounds: [(Decimal, Int)]) throws {
        guard id > 0, !bounds.isEmpty, bounds[0].0 == 0 else {
            throw OrderValidationError.invalid("Missing initial margin tier")
        }
        var result: [MarginTier] = []
        var deduction: Decimal = 0
        for (bound, leverage) in bounds {
            try Self.finite(bound)
            guard bound >= 0, leverage > 0 else {
                throw OrderValidationError.invalid("Invalid margin tier")
            }
            if let previous = result.last {
                guard bound > previous.lowerBound, leverage <= previous.maxLeverage else {
                    throw OrderValidationError.invalid("Invalid margin tier ordering")
                }
                deduction += bound * (1 / (Decimal(leverage) * 2) - previous.maintenanceRate)
            }
            try Self.finite(deduction)
            result.append(
                MarginTier(
                    lowerBound: bound, maxLeverage: leverage, maintenanceDeduction: deduction))
        }
        self.id = id
        tiers = result
    }
    public static func parse(meta: JSONValue, market: Market) throws -> MarginTable {
        guard market.kind == .perp, meta["universe"].array.indices.contains(market.assetID) else {
            throw OrderValidationError.invalid("Margin metadata does not match this market")
        }
        let asset = meta["universe"].array[market.assetID]
        let mode = asset["marginMode"].string
        let isolated =
            (asset["onlyIsolated"].bool ?? false)
            || mode == "noCross" || mode == "strictIsolated"
        guard asset["marginMode"] == .null || mode != nil,
              asset["onlyIsolated"] == .null || asset["onlyIsolated"].bool != nil,
              mode == market.marginMode, isolated == market.onlyIsolated
        else {
            throw OrderValidationError.invalid(
                "Market margin rules changed. Refresh the market catalog.")
        }
        guard asset["name"].string == market.coin, asset["isDelisted"].bool != true,
              let maxLeverage = Self.integer(asset["maxLeverage"]), maxLeverage == market.maxLeverage
        else {
            throw OrderValidationError.invalid(
                "Market leverage metadata changed. Refresh the market catalog.")
        }
        guard asset["marginTableId"] == .null || Self.integer(asset["marginTableId"]) != nil else {
            throw OrderValidationError.invalid("Invalid margin table identifier")
        }
        let id = Self.integer(asset["marginTableId"]) ?? maxLeverage
        guard id > 0, let identifier = Int(exactly: id) else {
            throw OrderValidationError.invalid("Invalid margin table identifier")
        }
        let matches = meta["marginTables"].array.filter {
            Self.integer($0.array.first ?? .null) == id
        }
        guard matches.count <= 1 else {
            throw OrderValidationError.invalid("Duplicate margin table identifier")
        }
        if let row = matches.first {
            guard row.array.count == 2 else {
                throw OrderValidationError.invalid("Invalid margin table response")
            }
            let bounds = try row.array[1]["marginTiers"].array.map { raw -> (Decimal, Int) in
                guard let leverage = Self.integer(raw["maxLeverage"]),
                      let value = Int(exactly: leverage)
                else {
                    throw OrderValidationError.invalid("Invalid tier leverage")
                }
                return (try ReviewDecimal.parse(raw["lowerBound"].string), value)
            }
            let table = try MarginTable(id: identifier, bounds: bounds)
            guard table.tiers[0].maxLeverage == market.maxLeverage else {
                throw OrderValidationError.invalid(
                    "Margin table leverage does not match the market")
            }
            return table
        }
        // Documented legacy single-tier IDs; never fabricate a missing tiered table.
        guard identifier <= 50, identifier == market.maxLeverage else {
            throw OrderValidationError.invalid("Margin tiers are unavailable for this market")
        }
        return try MarginTable(id: identifier, bounds: [(0, identifier)])
    }
    public func tier(at notional: Decimal) throws -> MarginTier {
        try Self.finite(notional)
        guard notional >= 0 else { throw OrderValidationError.invalid("Invalid position notional") }
        return tiers.last { $0.lowerBound <= notional }!
    }
    public func maintenance(at notional: Decimal) throws -> Decimal {
        let tier = try tier(at: notional)
        let amount = notional * tier.maintenanceRate - tier.maintenanceDeduction
        try Self.finite(amount)
        return max(0, amount)
    }
    /// Solve equity(P) = maintenance(P) in each price-dependent tier. Other
    /// cross-position maintenance and prices are held constant for this scenario.
    public func liquidationPrice(
        mark: Decimal, signedSize: Decimal, equity: Decimal, otherMaintenance: Decimal = 0
    )
    throws -> Decimal? {
        for value in [mark, signedSize, equity, otherMaintenance] { try Self.finite(value) }
        guard mark > 0, otherMaintenance >= 0 else {
            throw OrderValidationError.invalid("Invalid liquidation inputs")
        }
        guard signedSize != 0 else { return nil }
        let quantity = abs(signedSize)
        for (index, tier) in tiers.enumerated() {
            let numerator =
                otherMaintenance - tier.maintenanceDeduction - equity + signedSize * mark
            let denominator = signedSize - quantity * tier.maintenanceRate
            var price = numerator / denominator
            try Self.finite(price)
            guard price > 0 else { continue }
            var notional = price * quantity
            try Self.finite(notional)
            let tolerance = max(1, notional) * Decimal(string: "0.0000000000000000000000000001")!
            if tier.lowerBound > 0, abs(notional - tier.lowerBound) <= tolerance {
                notional = tier.lowerBound
                price = notional / quantity
            }
            let upper = index + 1 < tiers.count ? tiers[index + 1].lowerBound : nil
            if let upper, abs(notional - upper) <= tolerance { continue }
            if notional >= tier.lowerBound, upper == nil || notional < upper! { return price }
        }
        return nil
    }
    static func finite(_ value: Decimal) throws {
        guard !value.isNaN, NSDecimalNumber(decimal: value).doubleValue.isFinite else {
            throw OrderValidationError.invalid("Risk calculation exceeds decimal limits")
        }
    }
    private static func integer(_ value: JSONValue) -> Int64? {
        switch value {
        case .integer(let value): value
        case .number(let value): Int64(exactly: value)
        default: nil
        }
    }
}

/// A full-fill scenario at the intent's reference price, with other markets
/// fixed. This is an estimate, not an exchange liquidation-price commitment.
public struct OrderRiskEstimate: Sendable, Equatable {
    public let coin: String
    public let marginMode: String
    public let currentSignedSize: Decimal
    public let resultingSignedSize: Decimal
    public let assumedFillPrice: Decimal
    public let resultingEntryPrice: Decimal?
    public let projectedEquity: Decimal
    public let initialMarginRequired: Decimal
    public let maintenanceMarginRequired: Decimal
    public let additionalMarginRequired: Decimal
    public let liquidationPrice: Decimal?
    public let tierMaxLeverage: Int
    public let pendingIsolatedLeverage: Bool
    public var liquidationDistance: Decimal? {
        guard let liquidationPrice else { return nil }
        return
            (resultingSignedSize > 0
                ? assumedFillPrice - liquidationPrice : liquidationPrice - assumedFillPrice)
            / assumedFillPrice * 100
    }
    public var belowMaintenance: Bool {
        projectedEquity <= maintenanceMarginRequired && resultingSignedSize != 0
    }
    public static func preview(
        intent: OrderIntent, address: String, account: AccountState, asset: ActiveAssetData,
        table: MarginTable, abstraction: String, fees: OrderFeeEstimate
    ) throws -> OrderRiskEstimate {
        guard ["default", "disabled"].contains(abstraction) else {
            throw OrderValidationError.invalid(
                "Liquidation estimates for unified or portfolio margin are unavailable")
        }
        try asset.validate(address: address, market: intent.market)
        let positions = account.assetPositions.map(\.position)
        for position in positions {
            _ = try ReviewDecimal.parse(position.szi)
            guard ["cross", "isolated"].contains(position.leverage.type) else {
                throw OrderValidationError.invalid("Unknown position margin mode")
            }
        }
        let matching = positions.filter { $0.coin == intent.market.coin }
        guard matching.count <= 1 else {
            throw OrderValidationError.invalid("Duplicate position in risk snapshot")
        }
        let position = matching.first
        try intent.validatePosition(position)
        let current = try ReviewDecimal.parse(position?.szi ?? "0")
        let fill = try ReviewDecimal.parse(intent.referencePrice)
        let quantity = try ReviewDecimal.parse(intent.size)
        guard fill > 0, quantity > 0, (1...intent.market.maxLeverage).contains(intent.leverage),
              table.tiers[0].maxLeverage == intent.market.maxLeverage
        else { throw OrderValidationError.invalid("Invalid risk preview inputs") }
        let delta = intent.side == .buy ? quantity : -quantity
        let resulting = current + delta
        try MarginTable.finite(resulting)
        let mode = asset.leverage.type
        guard current == 0 || position?.leverage.type == mode else {
            throw OrderValidationError.invalid("Position margin mode changed. Refresh the preview.")
        }
        let notional = abs(resulting) * fill
        let tier = try table.tier(at: notional)
        let requestedLeverage = intent.reduceOnly ? asset.leverage.value : intent.leverage
        let initial = notional / Decimal(min(requestedLeverage, tier.maxLeverage))
        let ownMaintenance = try table.maintenance(at: notional)
        let debit = fees.upper
        try MarginTable.finite(debit)
        let entry: Decimal?
        if resulting == 0 {
            entry = nil
        } else if current == 0 || (resulting > 0) != (current > 0) {
            entry = fill
        } else {
            let oldEntry = try ReviewDecimal.parse(position?.entryPx)
            guard oldEntry > 0 else {
                throw OrderValidationError.invalid("Current entry price is unavailable")
            }
            entry =
                (delta > 0) == (current > 0)
                ? (abs(current) * oldEntry + quantity * fill) / abs(resulting) : oldEntry
        }
        let equity: Decimal
        let otherMaintenance: Decimal
        let totalInitial: Decimal
        let shortfall: Decimal
        if mode == "cross" {
            let hasIsolated = positions.contains {
                $0.leverage.type == "isolated" && (try? ReviewDecimal.parse($0.szi)) != 0
            }
            guard
                let summary = account.crossMarginSummary
                    ?? (hasIsolated ? nil : account.marginSummary)
            else {
                throw OrderValidationError.invalid("Cross account summary is unavailable")
            }
            let accountEquity = try ReviewDecimal.parse(summary.accountValue)
            let oldNotional = try current == 0 ? 0 : ReviewDecimal.parse(position?.positionValue)
            guard oldNotional >= 0, current == 0 || oldNotional > 0 else {
                throw OrderValidationError.invalid("Current position value is unavailable")
            }
            let oldMaintenance = try table.maintenance(at: oldNotional)
            let hasOtherCross = positions.contains {
                $0.coin != intent.market.coin && $0.leverage.type == "cross"
                    && (try? ReviewDecimal.parse($0.szi)) != 0
            }
            let aggregateMaintenance =
                try account.crossMaintenanceMarginUsed.map { try ReviewDecimal.parse($0) }
                ?? (hasOtherCross ? nil : oldMaintenance)
            guard let aggregateMaintenance, aggregateMaintenance >= 0,
                  aggregateMaintenance + Decimal(string: "0.000001")! >= oldMaintenance
            else {
                throw OrderValidationError.invalid("Cross maintenance snapshot is inconsistent")
            }
            otherMaintenance = max(0, aggregateMaintenance - oldMaintenance)
            let oldMark = current == 0 ? fill : oldNotional / abs(current)
            equity = accountEquity + current * (fill - oldMark) - debit
            let oldInitial = try current == 0 ? 0 : ReviewDecimal.parse(position?.marginUsed)
            let aggregateInitial = try ReviewDecimal.parse(summary.totalMarginUsed)
            guard oldInitial >= 0, aggregateInitial >= 0,
                  aggregateInitial + Decimal(string: "0.000001")! >= oldInitial
            else {
                throw OrderValidationError.invalid("Cross initial margin snapshot is inconsistent")
            }
            totalInitial = max(0, aggregateInitial - oldInitial) + initial
            shortfall = max(0, totalInitial - equity)
        } else {
            otherMaintenance = 0
            totalInitial = initial
            let cash =
                try current == 0
                ? 0 : ReviewDecimal.parse(position?.leverage.rawUsd ?? asset.leverage.rawUsd)
            let before = cash + current * fill
            let opposite = current != 0 && (delta > 0) != (current > 0)
            let closing = opposite ? min(quantity, abs(current)) : 0
            let retained = current == 0 ? 0 : before * (1 - closing / abs(current))
            let opening = quantity - closing
            let allocated = opening * fill / Decimal(min(requestedLeverage, tier.maxLeverage))
            equity = resulting == 0 ? 0 : retained + allocated - debit
            let available = try max(
                0, ReviewDecimal.parse(asset.availableToTrade[intent.side == .buy ? 0 : 1]))
            // Pure closes spend existing isolated equity and release collateral;
            // they do not require funding a new isolated margin allocation.
            shortfall = opening > 0 ? max(0, allocated + max(0, debit) - available) : 0
        }
        let maintenance = ownMaintenance + otherMaintenance
        for value in [equity, totalInitial, maintenance, shortfall] {
            try MarginTable.finite(value)
        }
        if let entry { try MarginTable.finite(entry) }
        let liquidation = try table.liquidationPrice(
            mark: fill, signedSize: resulting, equity: equity, otherMaintenance: otherMaintenance)
        return OrderRiskEstimate(
            coin: intent.market.coin, marginMode: mode, currentSignedSize: current,
            resultingSignedSize: resulting,
            assumedFillPrice: fill, resultingEntryPrice: entry, projectedEquity: equity,
            initialMarginRequired: totalInitial,
            maintenanceMarginRequired: maintenance, additionalMarginRequired: shortfall,
            liquidationPrice: liquidation,
            tierMaxLeverage: tier.maxLeverage,
            pendingIsolatedLeverage: mode == "isolated" && current != 0 && !intent.reduceOnly
                && intent.leverage != asset.leverage.value)
    }
    public func validateCurrent(_ current: OrderRiskEstimate) throws {
        guard coin == current.coin, marginMode == current.marginMode,
              currentSignedSize == current.currentSignedSize
        else {
            throw OrderValidationError.invalid(
                "Position changed since the risk preview. Create a new preview.")
        }
        if pendingIsolatedLeverage, !current.pendingIsolatedLeverage,
           current.projectedEquity < projectedEquity {
            throw OrderValidationError.invalid(
                "The leverage update reduced isolated margin. Review the updated liquidation estimate in a new preview."
            )
        }
    }
}
