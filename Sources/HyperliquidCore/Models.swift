import Foundation

public enum NetworkEnvironment: String, CaseIterable, Codable, Sendable {
    case mainnet, testnet
    public var apiURL: URL {
        URL(
            string: self == .mainnet
                ? "https://api.hyperliquid.xyz" : "https://api.hyperliquid-testnet.xyz")!
    }
    public var socketURL: URL {
        URL(
            string: self == .mainnet
                ? "wss://api.hyperliquid.xyz/ws" : "wss://api.hyperliquid-testnet.xyz/ws")!
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .integer(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }
    public var array: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }
    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .integer(let n): return Double(n)
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var int64: Int64? {
        switch self {
        case .integer(let value): return value
        case .string(let value): return Int64(value)
        case .number(let value): return Int64(exactly: value)
        default: return nil
        }
    }
    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.integer(let a), .number(let b)), (.number(let b), .integer(let a)):
            return Int64(exactly: b) == a
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }
}

public struct Market: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case perp, spot }
    public var id: String { coin }
    public let coin: String
    public let symbol: String
    public let assetID: Int
    public let sizeDecimals: Int
    public let maxLeverage: Int
    public let kind: Kind
    public let onlyIsolated: Bool
    public let marginMode: String?
    public var supportedMarginMode: Bool {
        marginMode == nil || marginMode == "noCross" || marginMode == "strictIsolated"
    }
    public var allowsIsolatedMarginRemoval: Bool {
        // The deprecated flag alone cannot distinguish noCross from strictIsolated.
        marginMode == "noCross" || (marginMode == nil && !onlyIsolated)
    }
    public let baseTokenIndex: Int?
    public let quoteTokenIndex: Int?
    public let isStablePair: Bool
    public let collateralSymbol: String?
    public let perpDexIndex: Int?
    public var isBuilderPerp: Bool { kind == .perp && (coin.contains(":") || assetID >= 100_000) }
    public var perpDex: String {
        isBuilderPerp ? String(coin.split(separator: ":", maxSplits: 1).first ?? "") : ""
    }
    public var contextIndex: Int? {
        guard isBuilderPerp else { return kind == .perp ? assetID : nil }
        guard let perpDexIndex, (1..<10_000).contains(perpDexIndex) else { return nil }
        let index = assetID - 100_000 - perpDexIndex * 10_000
        return (0..<10_000).contains(index) ? index : nil
    }
    public var quoteSymbol: String { collateralSymbol ?? "USDC" }
    public var title: String { kind == .perp ? "\(symbol)-\(quoteSymbol)" : "\(symbol)/\(quoteSymbol)" }
    public var venueDescription: String {
        isBuilderPerp ? "Perpetual · \(perpDex)" : kind == .perp ? "Perpetual" : "Spot"
    }
    public var iconSymbol: String { isBuilderPerp ? coin : symbol }
    public init(
        coin: String, symbol: String, assetID: Int, sizeDecimals: Int, maxLeverage: Int, kind: Kind,
        onlyIsolated: Bool = false, marginMode: String? = nil,
        baseTokenIndex: Int? = nil, quoteTokenIndex: Int? = nil,
        isStablePair: Bool = false, collateralSymbol: String? = nil, perpDexIndex: Int? = nil
    ) {
        self.coin = coin
        self.symbol = symbol
        self.assetID = assetID
        self.sizeDecimals = sizeDecimals
        self.maxLeverage = maxLeverage
        self.kind = kind
        self.onlyIsolated =
            onlyIsolated || marginMode == "noCross" || marginMode == "strictIsolated"
        self.marginMode = marginMode
        self.baseTokenIndex = baseTokenIndex
        self.quoteTokenIndex = quoteTokenIndex
        self.isStablePair = isStablePair
        self.collateralSymbol = collateralSymbol
        self.perpDexIndex = perpDexIndex
    }
}

public struct AssetContext: Codable, Sendable, Equatable {
    public var markPx: String
    public var midPx: String?
    public var prevDayPx: String
    public var dayNtlVlm: String
    public var funding: String?
    public var openInterest: String?
    public var oraclePx: String?
    public var price: Double { Double(midPx ?? markPx) ?? 0 }
    public var change: Double {
        let prev = Double(prevDayPx) ?? 0
        return prev > 0 ? (price / prev - 1) * 100 : 0
    }
    public var oiUSD: Double { (Double(openInterest ?? "") ?? 0) * (Double(markPx) ?? 0) }
}

public struct BookLevel: Codable, Sendable, Equatable, Identifiable {
    public let px: String
    public let sz: String
    public let n: Int
    public var id: String { px }
    public var price: Double { Double(px) ?? 0 }
    public var size: Double { Double(sz) ?? 0 }
}
public struct OrderBook: Codable, Sendable, Equatable {
    public let coin: String
    public let time: Int64
    public let levels: [[BookLevel]]
    public var bids: [BookLevel] { levels.first ?? [] }
    public var asks: [BookLevel] { levels.count > 1 ? levels[1] : [] }
    public var spread: Double? {
        guard let ask = asks.first, let bid = bids.first else { return nil }
        return ask.price - bid.price
    }
}
public struct Trade: Codable, Sendable, Equatable, Identifiable {
    public let coin: String
    public let side: String
    public let px: String
    public let sz: String
    public let time: Int64
    public let tid: Int64
    public var id: String { "\(time):\(coin):\(tid)" }
    public var notional: Double { (Double(px) ?? 0) * (Double(sz) ?? 0) }
    public var validNotional: Double? {
        guard !coin.isEmpty, ["A", "B"].contains(side), time >= 0, tid >= 0,
              let price = Double(px), let size = Double(sz), price.isFinite, size.isFinite, price > 0,
              size > 0
        else { return nil }
        let value = price * size
        return value.isFinite && value > 0 ? value : nil
    }
}
public struct Candle: Codable, Sendable, Equatable, Identifiable {
    public let t: Int64
    public let T: Int64
    public let s: String
    public let i: String
    public let o: String
    public let h: String
    public let l: String
    public let c: String
    public let v: String
    public let n: Int
    public var id: Int64 { t }
    public var open: Double { Double(o) ?? 0 }
    public var high: Double { Double(h) ?? 0 }
    public var low: Double { Double(l) ?? 0 }
    public var close: Double { Double(c) ?? 0 }
    public var volume: Double { Double(v) ?? 0 }
}
public enum Timeframe: String, CaseIterable, Codable, Sendable {
    case m1 = "1m"
    case m3 = "3m"
    case m5 = "5m"
    case m15 = "15m"
    case m30 = "30m"
    case h1 = "1h"
    case h4 = "4h"
    case d1 = "1d"
    public var milliseconds: Int64 {
        switch self {
        case .m1: 60_000
        case .m3: 180_000
        case .m5: 300_000
        case .m15: 900_000
        case .m30: 1_800_000
        case .h1: 3_600_000
        case .h4: 14_400_000
        case .d1: 86_400_000
        }
    }
}

public struct Position: Codable, Identifiable, Sendable, Equatable {
    public let coin: String
    public let szi: String
    public let entryPx: String?
    public let liquidationPx: String?
    public let positionValue: String
    public let unrealizedPnl: String
    public let returnOnEquity: String
    public let marginUsed: String
    public let leverage: Leverage
    public var id: String { coin }
    public var signedQuantity: Decimal? { try? ReviewDecimal.parse(szi) }
    /// An invalid quantity cannot establish that a reported position is closed.
    public var hasExposure: Bool { signedQuantity.map { $0 != 0 } ?? true }
    public var size: Double { Double(szi) ?? 0 }
    public var pnl: Double { Double(unrealizedPnl) ?? 0 }
    public func liquidationDistance(mark: Double) -> Double? {
        guard mark.isFinite, mark > 0, let quantity = signedQuantity, quantity != 0,
              let price = try? ReviewDecimal.parse(liquidationPx), price > 0
        else { return nil }
        let liq = NSDecimalNumber(decimal: price).doubleValue
        let distance = (quantity > 0 ? mark - liq : liq - mark) / mark * 100
        return distance.isFinite ? distance : nil
    }
}
public struct Leverage: Codable, Sendable, Equatable {
    public let type: String
    public let value: Int
    public let rawUsd: String?
    public init(type: String, value: Int, rawUsd: String? = nil) {
        self.type = type
        self.value = value
        self.rawUsd = rawUsd
    }
}
public struct AccountState: Codable, Sendable, Equatable {
    public struct AssetPosition: Codable, Sendable, Equatable { public let position: Position }
    public struct Summary: Codable, Sendable, Equatable {
        public let accountValue: String
        public let totalMarginUsed: String
        public let totalNtlPos: String
        public let totalRawUsd: String?
    }
    public let assetPositions: [AssetPosition]
    public let marginSummary: Summary
    public let crossMarginSummary: Summary?
    public let crossMaintenanceMarginUsed: String?
    public let withdrawable: String
    public let time: Int64
    public func hasSameFinancialState(as other: AccountState) -> Bool {
        assetPositions == other.assetPositions && marginSummary == other.marginSummary
            && crossMarginSummary == other.crossMarginSummary
            && crossMaintenanceMarginUsed == other.crossMaintenanceMarginUsed
            && withdrawable == other.withdrawable
    }
}
public struct OpenOrder: Codable, Sendable, Identifiable, Equatable {
    public let coin: String
    public let limitPx: String
    public let sz: String
    public let side: String
    public let oid: Int64
    public let timestamp: Int64
    public let orderType: String?
    public let reduceOnly: Bool?
    public let tif: String?
    public let isTrigger: Bool?
    public let triggerPx: String?
    public let isPositionTpsl: Bool?
    public let children: [JSONValue]?
    public var isEntirePositionProtection: Bool {
        isPositionTpsl == true && isTrigger == true && reduceOnly == true
            && ["Stop Market", "Stop Limit", "Take Profit Market", "Take Profit Limit"].contains(
                orderType ?? "")
            && (try? ReviewDecimal.parse(sz)).map { $0 >= 0 } == true
    }
    public var id: Int64 { oid }
    public init(
        coin: String, limitPx: String, sz: String, side: String, oid: Int64, timestamp: Int64,
        orderType: String? = nil, reduceOnly: Bool? = nil, tif: String? = nil,
        isTrigger: Bool? = nil, triggerPx: String? = nil, isPositionTpsl: Bool? = nil,
        children: [JSONValue]? = nil
    ) {
        self.coin = coin
        self.limitPx = limitPx
        self.sz = sz
        self.side = side
        self.oid = oid
        self.timestamp = timestamp
        self.orderType = orderType
        self.reduceOnly = reduceOnly
        self.tif = tif
        self.isTrigger = isTrigger
        self.triggerPx = triggerPx
        self.isPositionTpsl = isPositionTpsl
        self.children = children
    }
}
public struct Fill: Codable, Sendable, Identifiable, Equatable {
    public let oid: Int64?
    public let coin: String
    public let px: String
    public let sz: String
    public let side: String
    public let dir: String?
    public let time: Int64
    public let tid: Int64
    public let fee: String
    public let feeToken: String?
    public let closedPnl: String
    public var directionLabel: String {
        if let direction = dir?.trimmingCharacters(in: .whitespacesAndNewlines), !direction.isEmpty {
            return direction
        }
        return side == "B" ? "Buy" : "Sell"
    }
    public var id: String { "\(time):\(coin):\(tid)" }
}
public enum Address {
    public static func isValid(_ input: String) -> Bool {
        input.range(of: "^0x[0-9a-fA-F]{40}$", options: .regularExpression) != nil
    }
}

public enum MarketSearch {
    public static func score(_ query: String, market: Market) -> Int? {
        let q = query.uppercased().filter { !$0.isWhitespace }
        let s = market.title.uppercased()
        if q.isEmpty { return 0 }
        if market.symbol.uppercased() == q { return 1000 }
        if market.coin.uppercased() == q { return 1000 }
        if s.hasPrefix(q) { return 800 - s.count }
        if s.contains(q) { return 600 - s.count }
        if market.coin.uppercased().contains(q) { return 500 - market.coin.count }
        let fuzzySymbol = market.symbol.uppercased()
        var cursor = fuzzySymbol.startIndex
        for c in q {
            guard let found = fuzzySymbol[cursor...].firstIndex(of: c) else { return nil }
            cursor = fuzzySymbol.index(after: found)
        }
        return 100 - s.count
    }
    public static func results(_ query: String, markets: [Market]) -> [Market] {
        var ranked: [(market: Market, score: Int)] = []
        for market in markets {
            if let value = score(query, market: market) { ranked.append((market, value)) }
        }
        ranked.sort { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.market.title == rhs.market.title
                    ? lhs.market.coin < rhs.market.coin : lhs.market.title < rhs.market.title
            }
            return lhs.score > rhs.score
        }
        return ranked.map { $0.market }
    }
}
