import Foundation

public struct ProtectionAccountSnapshot: Sendable {
    public let owner: String
    public let environment: NetworkEnvironment
    public let market: Market
    public let positions: [Position]
    public let orders: [OpenOrder]
    public let asset: ActiveAssetData
    public let fees: UserFeeRates
    public let startedAt: Double
    public let receivedAt: Double
    public let abstraction: String
    public init(
        owner: String, environment: NetworkEnvironment, market: Market, positions: [Position],
        orders: [OpenOrder], asset: ActiveAssetData, fees: UserFeeRates,
        startedAt: Double, receivedAt: Double, abstraction: String
    ) {
        self.owner = owner.lowercased()
        self.environment = environment
        self.market = market
        self.positions = positions
        self.orders = orders
        self.asset = asset
        self.fees = fees
        self.startedAt = startedAt
        self.receivedAt = receivedAt
        self.abstraction = abstraction
    }
    public var position: Position? { positions.first { $0.coin == market.coin } }
    public var mark: Double { Double(asset.markPx) ?? 0 }
    public func validateContext(
        owner: String, market: Market, environment: NetworkEnvironment,
        now: Double = ReceiptClock.now
    ) throws {
        guard self.owner == owner.lowercased(), self.market == market,
              self.environment == environment,
              ["default", "disabled"].contains(abstraction),
              positions.filter({ $0.coin == market.coin }).count <= 1,
              startedAt.isFinite, receivedAt.isFinite, now.isFinite,
              startedAt >= 0, receivedAt >= startedAt, now >= receivedAt, now < startedAt + 15
        else {
            throw OrderValidationError.invalid(
                "TP/SL account data changed or expired. Refresh the review.")
        }
        try asset.validate(address: owner, market: market)
    }
    public func validate(_ batch: ProtectionBatch, now: Double = ReceiptClock.now) throws
    -> [OrderFeeEstimate] {
        try validateContext(
            owner: batch.owner, market: batch.market, environment: batch.environment, now: now)
        try batch.validateFreshness()
        let flat = try ProtectionOrders.flattened(orders)
        if let parent = batch.linkedParent {
            guard orders.filter({ $0.oid == parent.oid }) == [parent] else {
                throw OrderValidationError.invalid(
                    "The linked parent changed, filled or was canceled. Refresh its children.")
            }
        }
        for leg in batch.legs {
            let intent = leg.intent
            if let original = intent.modificationGuard {
                try original.validate(currentOrders: flat, intent: intent, address: batch.owner)
            }
            if intent.positionGuard != nil { try intent.validatePosition(position) }
            if leg.role == .entry {
                guard asset.leverage.value == intent.leverage else {
                    throw OrderValidationError.invalid(
                        "Set the entry leverage separately before reviewing a one-signature bracket."
                    )
                }
                try PerpTradingCapacity(
                    asset: asset, address: batch.owner, market: batch.market, side: intent.side,
                    limitPrice: PerpTradingCapacity.limitPrice(for: intent)
                ).validate(intent)
            } else {
                let trigger = try ReviewDecimal.parse(intent.trigger)
                let mark = try ReviewDecimal.parse(asset.markPx)
                let above = (intent.kind == .takeProfit) == (intent.side == .sell)
                guard above ? trigger > mark : trigger < mark else {
                    throw OrderValidationError.invalid(
                        "A TP/SL trigger crossed the current mark. Review the pair again.")
                }
            }
        }
        return try batch.legs.map { try fees.estimate(for: $0.intent) }
    }
}

/// Read-only boundary; no wallet approval or exchange submission is exposed here.
public protocol ProtectionReadClient: Sendable {
    func protectionSnapshot(owner: String, market: Market) async throws -> ProtectionAccountSnapshot
    func protectionRisk(
        parent: OrderIntent, owner: String, asset: ActiveAssetData,
        fees: OrderFeeEstimate
    ) async throws -> OrderRiskEstimate
    func protectionLimits(batch: ProtectionBatch) async throws
    func protectionStatus(owner: String, clientID: String) async throws -> JSONValue
    func protectionOriginalStatus(owner: String, oid: UInt64) async throws -> JSONValue
}

extension HyperliquidAPI: ProtectionReadClient {
    public func protectionSnapshot(owner: String, market: Market) async throws
    -> ProtectionAccountSnapshot {
        let start = ReceiptClock.now
        async let state = account(address: owner)
        async let orders = self.orders(address: owner)
        async let fees = userFees(address: owner)
        async let asset = activeAssetData(address: owner, market: market)
        async let mode = info(["type": .string("userAbstraction"), "user": .string(owner)])
        let (account, rows, rates, limits, abstraction) = try await (
            state, orders, fees, asset, mode
        )
        guard let mode = abstraction.string else {
            throw APIError.malformed("Account mode is unavailable")
        }
        let result = ProtectionAccountSnapshot(
            owner: owner, environment: environment, market: market,
            positions: account.assetPositions.map(\.position), orders: rows, asset: limits,
            fees: rates, startedAt: start, receivedAt: ReceiptClock.now, abstraction: mode)
        try result.validateContext(owner: owner, market: market, environment: environment)
        return result
    }
    public func protectionRisk(
        parent: OrderIntent, owner: String, asset: ActiveAssetData,
        fees: OrderFeeEstimate
    ) async throws -> OrderRiskEstimate {
        try await orderRisk(intent: parent, address: owner, asset: asset, fees: fees)
    }
    public func protectionLimits(batch: ProtectionBatch) async throws {
        // Bracket children do not reduce a live position yet; check exposure on the parent.
        // Position pairs and replacements check their guarded position instead.
        let intent = batch.parent ?? batch.legs[0].intent
        let limits = try await openInterestSnapshot(intent: intent, address: batch.owner)
        try limits?.validate(intent: intent, address: batch.owner, environment: batch.environment)
    }
    public func protectionStatus(owner: String, clientID: String) async throws -> JSONValue {
        try await info([
            "type": .string("orderStatus"), "user": .string(owner), "oid": .string(clientID)
        ])
    }
    public func protectionOriginalStatus(owner: String, oid: UInt64) async throws -> JSONValue {
        guard let value = Int64(exactly: oid) else {
            throw APIError.malformed("Invalid original order ID")
        }
        return try await info([
            "type": .string("orderStatus"), "user": .string(owner), "oid": .integer(value)
        ])
    }
}
