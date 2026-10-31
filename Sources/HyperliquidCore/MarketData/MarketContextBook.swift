import Foundation

/// Receipt times use a continuous monotonic clock. Mid updates never refresh marks.
/// REST captures revision before its request so late responses cannot rewind WS.
public struct MarketContextBook: Sendable {
    public private(set) var contexts: [String: AssetContext] = [:]
    public private(set) var revision = 0
    private var contextVersions: [String: Int] = [:]
    private var midVersions: [String: Int] = [:]
    private var markReceipts: [String: Double] = [:]
    public init() {}
    public mutating func invalidateMarks() { markReceipts.removeAll() }

    public static func validatorContexts(_ data: JSONValue, markets: [Market]) throws -> [String:
        AssetContext] {
        try assetContexts(data, markets: markets.filter { !$0.isBuilderPerp })
    }

    public static func assetContexts(_ data: JSONValue, markets: [Market]) throws -> [String: AssetContext] {
        guard case .array(let groups) = data["ctxs"] else {
            throw APIError.malformed("Missing asset context groups")
        }
        var byDex: [String: [JSONValue]] = [:]
        for group in groups {
            guard group.array.count == 2, let dex = group.array[0].string,
                  case .array(let values) = group.array[1], byDex[dex] == nil else {
                throw APIError.malformed("Invalid or duplicate asset context group")
            }
            byDex[dex] = values
        }
        guard byDex[""] != nil else { throw APIError.malformed("Missing validator asset contexts") }
        var result: [String: AssetContext] = [:]
        var ids = Set<String>()
        for market in markets where market.kind == .perp {
            // An omitted HIP-3 group cannot refresh its old prices or freshness.
            guard let values = byDex[market.perpDex] else { continue }
            guard let index = market.contextIndex, values.indices.contains(index),
                  ids.insert("\(market.perpDex):\(index)").inserted,
                  result[market.coin] == nil
            else { throw APIError.malformed("Asset contexts do not match the market catalog") }
            result[market.coin] = try values[index].decode(AssetContext.self)
        }
        return result
    }

    public mutating func applyStream(_ updates: [String: AssetContext], receivedAt: Double) {
        guard receivedAt.isFinite, receivedAt >= 0 else { return }
        revision += 1
        for (coin, context) in updates {
            contexts[coin] = context
            contextVersions[coin] = revision
            midVersions[coin] = revision
            if Self.validMark(context.markPx) != nil {
                markReceipts[coin] = receivedAt
            } else {
                markReceipts.removeValue(forKey: coin)
            }
        }
    }

    public mutating func applyMids(_ mids: [String: String]) {
        revision += 1
        for (coin, raw) in mids where Self.validMark(raw) != nil && contexts[coin] != nil {
            contexts[coin]?.midPx = raw
            midVersions[coin] = revision
        }
    }

    public mutating func mergeREST(
        _ updates: [String: AssetContext], startedAt: Int, receivedAt: Double
    ) {
        guard receivedAt.isFinite, receivedAt >= 0, startedAt >= 0, startedAt <= revision else {
            return
        }
        revision += 1
        for (coin, incoming) in updates where (contextVersions[coin] ?? 0) <= startedAt {
            var context = incoming
            if (midVersions[coin] ?? 0) > startedAt {
                context.midPx = contexts[coin]?.midPx
            } else {
                midVersions[coin] = revision
            }
            contexts[coin] = context
            contextVersions[coin] = revision
            if Self.validMark(context.markPx) != nil {
                markReceipts[coin] = receivedAt
            } else {
                markReceipts.removeValue(forKey: coin)
            }
        }
    }

    public func freshMarks(now: Double, maximumAge: Double = 15) -> [String: Double] {
        guard now.isFinite, maximumAge.isFinite, maximumAge >= 0 else { return [:] }
        var result: [String: Double] = [:]
        for (coin, receipt) in markReceipts where now >= receipt && now - receipt <= maximumAge {
            if let raw = contexts[coin]?.markPx, let mark = Self.validMark(raw) {
                result[coin] = mark
            }
        }
        return result
    }
    private static func validMark(_ raw: String) -> Double? {
        guard let value = Double(raw), value.isFinite, value > 0 else { return nil }
        return value
    }
}
