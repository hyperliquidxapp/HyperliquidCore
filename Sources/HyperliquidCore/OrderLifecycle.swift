import Foundation

public enum OrderLifecycle: Equatable, Sendable, Codable {
    case open, filled, triggered
    case canceled(String)
    case rejected(String)
    case unrecognized(String)

    public init(_ raw: String) {
        switch raw {
        case "open": self = .open
        case "filled": self = .filled
        case "triggered": self = .triggered
        case "canceled": self = .canceled("Canceled by user")
        case "marginCanceled": self = .canceled("Insufficient margin to fill")
        case "vaultWithdrawalCanceled": self = .canceled("Vault withdrawal")
        case "openInterestCapCanceled": self = .canceled("Open interest cap")
        case "selfTradeCanceled": self = .canceled("Self-trade prevention")
        case "reduceOnlyCanceled": self = .canceled("Order no longer reduces the position")
        case "siblingFilledCanceled": self = .canceled("Other TP/SL order filled")
        case "delistedCanceled": self = .canceled("Asset delisted")
        case "liquidatedCanceled": self = .canceled("Account liquidated")
        case "scheduledCancel": self = .canceled("Scheduled cancellation deadline")
        case "rejected": self = .rejected("Placement rejected")
        case "tickRejected": self = .rejected("Invalid price tick")
        case "minTradeNtlRejected": self = .rejected("Order value below minimum")
        case "perpMarginRejected": self = .rejected("Insufficient margin")
        case "reduceOnlyRejected": self = .rejected("Reduce-only restriction")
        case "badAloPxRejected": self = .rejected("Post-only order would match immediately")
        case "iocCancelRejected": self = .rejected("IOC order could not match")
        case "badTriggerPxRejected": self = .rejected("Invalid trigger price")
        case "marketOrderNoLiquidityRejected": self = .rejected("No market liquidity")
        case "positionIncreaseAtOpenInterestCapRejected", "positionFlipAtOpenInterestCapRejected",
             "tooAggressiveAtOpenInterestCapRejected", "openInterestIncreaseRejected":
            self = .rejected("Open interest cap")
        case "insufficientSpotBalanceRejected": self = .rejected("Insufficient spot balance")
        case "oracleRejected": self = .rejected("Price too far from oracle")
        case "perpMaxPositionRejected": self = .rejected("Position exceeds margin tier limit")
        default: self = .unrecognized(raw)
        }
    }
    public var recognized: Bool {
        if case .unrecognized = self { return false }
        return true
    }
    public var terminal: Bool {
        switch self {
        case .filled, .canceled, .rejected: true
        default: false
        }
    }
}

public struct OrderObservation: Sendable, Equatable {
    public let oid: UInt64
    public let coin: String
    public let status: OrderLifecycle
    public let timestamp: Int64
    public let clientID: String?
    public init(_ record: JSONValue) throws {
        guard case .integer(let oid) = record["order"]["oid"], oid >= 0,
              let coin = record["order"]["coin"].string, !coin.isEmpty,
              let raw = record["status"].string, !raw.isEmpty,
              case .integer(let time) = record["statusTimestamp"], time >= 0
        else {
            throw APIError.malformed("Invalid order status record")
        }
        self.oid = UInt64(oid)
        self.coin = coin
        status = OrderLifecycle(raw)
        timestamp = time
        clientID = record["order"]["cloid"].string
    }
    public static func query(_ value: JSONValue) throws -> OrderObservation? {
        if value["status"].string == "unknownOid" { return nil }
        guard value["status"].string == "order" else {
            throw APIError.malformed("Unrecognized order query response")
        }
        return try OrderObservation(value["order"])
    }
}

public struct TrackedOrder: Equatable, Sendable {
    public let owner: String
    public let coin: String
    public let oid: UInt64
    public private(set) var status: OrderLifecycle
    public private(set) var timestamp: Int64?
    private var activated = false
    public init(owner: String, coin: String, oid: UInt64, status: OrderLifecycle) {
        self.owner = owner.lowercased()
        self.coin = coin
        self.oid = oid
        self.status = status
        activated = status == .triggered
    }
    @discardableResult public mutating func apply(_ observation: OrderObservation, owner: String)
    -> Bool {
        guard self.owner == owner.lowercased(), coin == observation.coin, oid == observation.oid,
              timestamp.map({ observation.timestamp >= $0 }) ?? true
        else { return false }
        // Completed orders cannot return to the book. Trigger activation is not a fill.
        if status.terminal, observation.status != status { return false }
        if activated, observation.status == .open { return false }
        if timestamp == observation.timestamp, status.recognized, !observation.status.recognized {
            return false
        }
        guard timestamp != observation.timestamp || status != observation.status else {
            return false
        }
        timestamp = observation.timestamp
        status = observation.status
        if status == .triggered { activated = true }
        return true
    }
}
