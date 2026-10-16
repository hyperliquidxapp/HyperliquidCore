import Foundation

public enum ProtectionRole: String, Sendable, Codable {
    case entry = "Entry"
    case takeProfit = "Take profit"
    case stopLoss = "Stop loss"
}

public struct ProtectionTrigger: Sendable {
    public let trigger: String
    public let execution: TriggerExecution
    public let limit: String
    public init(trigger: String, execution: TriggerExecution = .market, limit: String = "") {
        self.trigger = trigger
        self.execution = execution
        self.limit = limit
    }
}

public struct ProtectionLeg: Sendable, Identifiable {
    public let role: ProtectionRole
    public let intent: OrderIntent
    public let clientID: String
    public var id: String { clientID }
    public var originalOID: UInt64? { intent.modificationGuard?.oid }
    public var wire: WireValue {
        ExchangeAction.orderWire(
            assetID: intent.market.assetID, buy: intent.side == .buy, price: intent.price,
            size: intent.protectionSizing == .entirePosition ? "0" : intent.size,
            reduceOnly: intent.reduceOnly, kind: intent.kind, trigger: intent.trigger,
            cloid: clientID, triggerExecution: intent.triggerExecution,
            timeInForce: intent.timeInForce)
    }
}

/// An ordered, immutable action: a pair, a parent followed by its pair, or two replacements.
/// A batch is deliberately not described as an all-or-nothing exchange transaction.
public struct ProtectionBatch: Sendable, Identifiable {
    public enum Mode: String, Sendable {
        case position = "Position TP / SL"
        case bracket = "Entry with TP / SL"
        case modify = "Modify TP / SL"
    }
    public let id = UUID()
    public let owner: String
    public let environment: NetworkEnvironment
    public let mode: Mode
    public let legs: [ProtectionLeg]
    public let linkedParent: OpenOrder?
    public let createdAt: Date
    public var market: Market { legs[0].intent.market }
    public var parent: OrderIntent? { legs.first { $0.role == .entry }?.intent }
    public var action: WireValue {
        if mode == .modify {
            return .map([
                ("type", .string("batchModify")),
                (
                    "modifies",
                    .array(
                        legs.map {
                            .map([("oid", .uint($0.originalOID!)), ("order", $0.wire)])
                        })
                ),
                // Trigger modifications require always_place. The confirmation discloses the cancel race.
                ("a", .bool(true))
            ])
        }
        return .map([
            ("type", .string("order")), ("orders", .array(legs.map(\.wire))),
            ("grouping", .string(mode == .bracket ? "normalTpsl" : "positionTpsl"))
        ])
    }
    public func validateFreshness(now: Date = Date()) throws {
        let age = now.timeIntervalSince(createdAt)
        guard age >= 0, age < 30 else {
            throw OrderValidationError.invalid("TP/SL preview expired. Prepare a fresh review.")
        }
    }
    public static func position(
        owner: String, environment: NetworkEnvironment, position: Position, market: Market,
        mark: Double, takeProfit: ProtectionTrigger, stopLoss: ProtectionTrigger,
        now: Date = Date()
    ) throws -> ProtectionBatch {
        try validateMarket(owner: owner, market: market)
        let draft = try PositionOrderDraft.prepare(
            position: position, market: market, purpose: .protect, kind: .takeProfit)
        let intents = try [takeProfit, stopLoss].enumerated().map { index, trigger in
            try OrderPlanner.preview(
                market: market, side: draft.side, kind: index == 0 ? .takeProfit : .stop,
                size: draft.size, isUSD: false, price: trigger.limit, trigger: trigger.trigger,
                mark: mark, leverage: draft.leverage, reduceOnly: true,
                triggerExecution: trigger.execution, positionGuard: draft.guardValue,
                protectionSizing: .entirePosition, now: now)
        }
        return ProtectionBatch(
            owner: owner.lowercased(), environment: environment, mode: .position,
            legs: makeLegs(intents, roles: [.takeProfit, .stopLoss]), linkedParent: nil,
            createdAt: now)
    }
    public static func bracket(
        owner: String, environment: NetworkEnvironment, parent: OrderIntent, mark: Double,
        takeProfit: ProtectionTrigger, stopLoss: ProtectionTrigger, now: Date = Date()
    ) throws -> ProtectionBatch {
        try validateMarket(owner: owner, market: parent.market)
        try parent.validateFreshness(now: now)
        guard [.market, .limit].contains(parent.kind), !parent.reduceOnly,
              parent.positionGuard == nil, parent.modificationGuard == nil
        else {
            throw OrderValidationError.invalid(
                "Attach TP/SL to a new opening market or limit order.")
        }
        let children = try [takeProfit, stopLoss].enumerated().map { index, trigger in
            let child = try OrderPlanner.preview(
                market: parent.market, side: parent.side == .buy ? .sell : .buy,
                kind: index == 0 ? .takeProfit : .stop, size: parent.size, isUSD: false,
                price: trigger.limit, trigger: trigger.trigger, mark: mark,
                leverage: parent.leverage, reduceOnly: true, triggerExecution: trigger.execution,
                now: now)
            let anchor = try ReviewDecimal.parse(parent.referencePrice)
            let price = try ReviewDecimal.parse(child.trigger)
            let above = (child.kind == .takeProfit) == (parent.side == .buy)
            guard above ? price > anchor : price < anchor else {
                throw OrderValidationError.invalid(
                    "TP and SL must also bracket the reviewed entry price.")
            }
            return child
        }
        return ProtectionBatch(
            owner: owner.lowercased(), environment: environment, mode: .bracket,
            legs: makeLegs([parent] + children, roles: [.entry, .takeProfit, .stopLoss]),
            linkedParent: nil, createdAt: parent.createdAt)
    }
    public static func modification(
        owner: String, environment: NetworkEnvironment, market: Market, position: Position?,
        originals: [OpenOrder], linkedParent: OpenOrder? = nil, mark: Double,
        takeProfit: ProtectionTrigger, stopLoss: ProtectionTrigger, now: Date = Date()
    ) throws -> ProtectionBatch {
        try validateMarket(owner: owner, market: market)
        guard originals.count == 2, Set(originals.map(\.oid)).count == 2 else {
            throw OrderValidationError.invalid("Select one original TP and one original SL.")
        }
        let guards = try originals.map {
            try OrderModificationGuard(address: owner, order: $0, market: market)
        }
        guard guards.map(\.kind) == [.takeProfit, .stop],
              originals[0].side == originals[1].side,
              guards[0].protectionSizing == guards[1].protectionSizing,
              originals.allSatisfy({ $0.reduceOnly == true })
        else {
            throw OrderValidationError.invalid(
                "The selected orders must be a matching reduce-only TP/SL pair.")
        }
        if let linkedParent {
            let children = try ProtectionOrders.children(of: linkedParent)
            guard linkedParent.coin == market.coin, children.count == 2,
                  Set(children.map(\.oid)) == Set(originals.map(\.oid)),
                  originals.allSatisfy({ children.contains($0) && $0.isPositionTpsl == false }),
                  originals[0].side != linkedParent.side
            else {
                throw OrderValidationError.invalid(
                    "The parent no longer owns the selected TP/SL children.")
            }
        } else {
            guard originals.allSatisfy({ $0.isPositionTpsl == true }) else {
                throw OrderValidationError.invalid(
                    "Select explicit position protection, or manage children from their parent.")
            }
        }
        let intents = try zip(guards, [takeProfit, stopLoss]).map { guardValue, trigger in
            let draft = try guardValue.positionDraft(current: position)
            return try OrderPlanner.preview(
                market: market, side: guardValue.original.side == "B" ? .buy : .sell,
                kind: guardValue.kind, size: draft?.size ?? guardValue.original.sz, isUSD: false,
                price: trigger.limit, trigger: trigger.trigger, mark: mark,
                leverage: position?.leverage.value ?? 1, reduceOnly: true,
                triggerExecution: guardValue.triggerExecution,
                positionGuard: draft?.guardValue, modificationGuard: guardValue,
                protectionSizing: guardValue.protectionSizing, now: now)
        }
        if linkedParent != nil {
            guard try ReviewDecimal.parse(intents[0].size) == ReviewDecimal.parse(intents[1].size)
            else {
                throw OrderValidationError.invalid("Linked TP/SL quantities no longer match.")
            }
        }
        return ProtectionBatch(
            owner: owner.lowercased(), environment: environment, mode: .modify,
            legs: makeLegs(intents, roles: [.takeProfit, .stopLoss]),
            linkedParent: linkedParent, createdAt: now)
    }
    private static func validateMarket(owner: String, market: Market) throws {
        guard Address.isValid(owner), market.kind == .perp, (0..<10_000).contains(market.assetID),
              !market.coin.contains(":"), market.supportedMarginMode
        else {
            throw OrderValidationError.invalid(
                "Paired protection supports a connected validator perpetual account.")
        }
    }
    private static func makeLegs(_ intents: [OrderIntent], roles: [ProtectionRole])
    -> [ProtectionLeg] {
        zip(intents, roles).map { intent, role in
            ProtectionLeg(
                role: role, intent: intent,
                clientID: "0x"
                    + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        }
    }
}

public enum ProtectionOrders {
    public static func children(of parent: OpenOrder) throws -> [OpenOrder] {
        guard let raw = parent.children, raw.count <= 2 else {
            throw APIError.malformed("Linked order details are incomplete")
        }
        let children = try raw.map { try $0.decode(OpenOrder.self) }
        guard Set(children.map(\.oid)).count == children.count,
              children.allSatisfy({ $0.oid >= 0 && $0.oid != parent.oid && $0.coin == parent.coin })
        else {
            throw APIError.malformed("Invalid parent/child order identities")
        }
        return children
    }
    public static func flattened(_ orders: [OpenOrder]) throws -> [OpenOrder] {
        guard Set(orders.map(\.oid)).count == orders.count else {
            throw APIError.malformed("Duplicate open order identities")
        }
        var result = orders
        for parent in orders where parent.children?.isEmpty == false {
            for child in try children(of: parent) {
                if let existing = result.first(where: { $0.oid == child.oid }) {
                    guard existing == child else {
                        throw APIError.malformed("Conflicting linked order details")
                    }
                } else {
                    result.append(child)
                }
            }
        }
        return result
    }
}

public enum ProtectionLegStatus: Sendable, Equatable, Codable {
    case resting(UInt64)
    case filled(UInt64, size: String, price: String)
    case waiting(String)
    case rejected(String)
    case observed(UInt64, OrderLifecycle)
    case unknown(String)
    public var unverified: Bool {
        if case .unknown = self { return true }
        return false
    }
    public var failed: Bool {
        if case .rejected = self { return true }
        if case .observed(_, .rejected) = self { return true }
        return false
    }
    public var orderID: UInt64? {
        switch self {
        case .resting(let oid), .filled(let oid, _, _), .observed(let oid, _): oid
        default: nil
        }
    }
    public var originalStillActive: Bool {
        switch self {
        case .resting, .waiting, .observed(_, .open), .observed(_, .triggered): true
        default: false
        }
    }
}

public enum ProtectionReceipt {
    /// Cardinality must match before positional results can be associated with a leg.
    /// An invalid individual result does not erase independently verified sibling results.
    public static func parse(_ value: JSONValue, batch: ProtectionBatch) -> [ProtectionLegStatus] {
        if value["status"].string == "err", let reason = value["response"].string {
            return batch.legs.map { _ in .rejected(reason) }
        }
        guard value["status"].string == "ok", value["response"]["type"].string == "order",
              case .array(let raw) = value["response"]["data"]["statuses"],
              raw.count == batch.legs.count
        else {
            return batch.legs.map { _ in
                .unknown("Response does not match the submitted batch. Check each order.")
            }
        }
        var results: [ProtectionLegStatus] = zip(raw, batch.legs).map { row, leg in
            if case .object(let fields) = row,
               fields.keys.filter({ ["error", "resting", "filled"].contains($0) }).count != 1 {
                return .unknown(
                    "Contradictory or incomplete order result. Query this order before retrying.")
            }
            if let reason = row["error"].string { return .rejected(reason) }
            if let oid = row["resting"]["oid"].int64, oid >= 0 { return .resting(UInt64(oid)) }
            if let oid = row["filled"]["oid"].int64, oid >= 0,
               let size = row["filled"]["totalSz"].string,
               let price = row["filled"]["avgPx"].string,
               let quantity = try? ReviewDecimal.parse(size), quantity > 0,
               let px = try? ReviewDecimal.parse(price), px > 0,
               leg.intent.protectionSizing == .entirePosition
                || quantity <= ((try? ReviewDecimal.parse(leg.intent.size)) ?? 0) {
                return .filled(UInt64(oid), size: size, price: price)
            }
            if leg.role != .entry, let reported = row.string,
               ["waitingForFill", "waitingForTrigger"].contains(reported) {
                return .waiting(reported)
            }
            return .unknown(
                "Unrecognized or invalid order result. Query this order before retrying.")
        }
        let duplicates = Dictionary(grouping: results.compactMap(\.orderID), by: { $0 })
            .filter { $0.value.count > 1 }.keys
        for index in results.indices
        where results[index].orderID.map({ duplicates.contains($0) }) == true {
            results[index] = .unknown(
                "Duplicate order identities in the response. Query this order before retrying.")
        }
        return results
    }
}
