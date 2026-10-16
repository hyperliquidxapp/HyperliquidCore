import Foundation

/// The immutable original order is kept separately from the editable replacement.
/// A changed, partially filled or missing order requires a new user review.
public struct OrderModificationGuard: Sendable {
    public let address: String
    public let original: OpenOrder
    public let market: Market
    public let kind: OrderKind
    public let triggerExecution: TriggerExecution
    public var protectionSizing: ProtectionSizing {
        original.isEntirePositionProtection ? .entirePosition : .fixed
    }
    public var oid: UInt64 { UInt64(original.oid) }

    public static func kind(for order: OpenOrder) -> OrderKind? {
        guard order.oid >= 0, order.timestamp >= 0, ["A", "B"].contains(order.side),
              order.reduceOnly != nil,
              order.children?.isEmpty != false,
              let size = try? ReviewDecimal.parse(order.sz),
              size > 0 || order.isEntirePositionProtection,
              order.isPositionTpsl != true
                || (order.isEntirePositionProtection && order.children?.isEmpty == true),
              let price = try? ReviewDecimal.parse(order.limitPx), price > 0
        else { return nil }
        switch order.orderType {
        case "Limit":
            guard order.isTrigger != true,
                  order.tif == nil || TimeInForce(rawValue: order.tif!) != nil
            else { return nil }
            return .limit
        case "Stop Market", "Stop Limit", "Take Profit Market", "Take Profit Limit":
            guard order.isTrigger == true,
                  order.isPositionTpsl == false || order.isEntirePositionProtection,
                  let trigger = try? ReviewDecimal.parse(order.triggerPx), trigger > 0
            else { return nil }
            return order.orderType?.hasPrefix("Stop") == true ? .stop : .takeProfit
        default: return nil
        }
    }
    public init(address: String, order: OpenOrder, market: Market) throws {
        guard Address.isValid(address), order.coin == market.coin,
              let kind = Self.kind(for: order), market.kind == .perp || kind == .limit,
              !order.isEntirePositionProtection
                || ((0..<10_000).contains(market.assetID) && !market.coin.contains(":"))
        else {
            throw OrderValidationError.invalid(
                "This order cannot be modified. Refresh its details; incomplete or linked protection requires its own management flow."
            )
        }
        self.address = address.lowercased()
        original = order
        self.market = market
        self.kind = kind
        triggerExecution = order.orderType?.hasSuffix("Market") == true ? .market : .limit
    }
    public func validateDraft(_ intent: OrderIntent) throws {
        guard intent.market == market, intent.kind == kind,
              intent.side == (original.side == "B" ? .buy : .sell),
              intent.reduceOnly == original.reduceOnly, intent.protectionSizing == protectionSizing,
              protectionSizing != .entirePosition || intent.positionGuard?.purpose == .protect
        else {
            throw OrderValidationError.invalid(
                "A modification must preserve the original market, side, order kind, reduce-only and quantity mode. Choose New order for a different trade."
            )
        }
    }
    public func validate(currentOrders: [OpenOrder], intent: OrderIntent, address: String) throws {
        try validateDraft(intent)
        let matches = currentOrders.filter { $0.oid == original.oid }
        guard self.address == address.lowercased(), matches.count == 1, let current = matches.first,
              Self.kind(for: current) == kind, current.coin == original.coin,
              current.side == original.side, current.timestamp == original.timestamp,
              current.reduceOnly == original.reduceOnly, current.orderType == original.orderType,
              original.isPositionTpsl == nil || current.isPositionTpsl == original.isPositionTpsl,
              original.tif == nil || current.tif == original.tif,
              try ReviewDecimal.parse(current.sz) == ReviewDecimal.parse(original.sz),
              try ReviewDecimal.parse(current.limitPx) == ReviewDecimal.parse(original.limitPx),
              try
                (!kind.conditional
                    || ReviewDecimal.parse(current.triggerPx) == ReviewDecimal.parse(original.triggerPx))
        else {
            throw OrderValidationError.invalid(
                "The original order changed or is no longer open. Refresh orders and prepare a new modification."
            )
        }
    }
    public func positionDraft(current: Position?) throws -> PositionOrderDraft? {
        guard protectionSizing == .entirePosition else { return nil }
        guard let current, current.coin == market.coin else {
            throw OrderValidationError.invalid(
                "Refresh the current position before modifying entire-position protection.")
        }
        let draft = try PositionOrderDraft.prepare(
            position: current, market: market, purpose: .protect, kind: kind)
        guard draft.side == (original.side == "B" ? .buy : .sell) else {
            throw OrderValidationError.invalid(
                "The protection no longer matches the current position direction.")
        }
        return draft
    }
}

extension OrderIntent {
    public func validateModificationTarget(oid: UInt64?, address: String) throws {
        switch (oid, modificationGuard) {
        case (nil, nil): return
        case (let oid?, let guardValue?)
                where oid == guardValue.oid && address.lowercased() == guardValue.address:
            try guardValue.validateDraft(self)
        default:
            throw OrderValidationError.invalid(
                "The modification target or account changed. Prepare the order again.")
        }
    }
}
