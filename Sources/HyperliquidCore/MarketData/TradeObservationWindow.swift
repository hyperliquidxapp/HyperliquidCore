import Foundation

public struct TradeWindowSummary: Sendable, Equatable {
    public let coin: String
    public let tradeCount: Int
    public let largeTradeCount: Int
    public let buyNotional: Double
    public let sellNotional: Double
    public let largest: [Trade]
    public let observedMilliseconds: Int64
    public let requestedMilliseconds: Int64
    public let capacityLimited: Bool
    public let invalidDataDropped: Bool
    public var truncated: Bool { capacityLimited || invalidDataDropped }
    public var continuousCoverage: Bool {
        observedMilliseconds == requestedMilliseconds && !truncated
    }
}

/// One-hour observation, separate from the short UI tape. Minute buckets bound
/// pruning work; capacity eviction and disconnected intervals remain explicit.
public struct TradeObservationWindow: Sendable {
    public let coin: String
    public let capacity: Int
    private var buckets: [Int64: [String: Trade]] = [:]
    private var count = 0
    private var intervals: [ClosedRange<Int64>] = []
    private var connectedAt: Int64?
    private var evictedThrough: Int64?
    private var invalidThrough: Int64?
    private var lastPrunedMinute: Int64?
    public init(coin: String, capacity: Int = 100_000) {
        self.coin = coin
        self.capacity = max(1, capacity)
    }
    public mutating func connect(at time: Int64) { if connectedAt == nil { connectedAt = time } }
    public mutating func disconnect(at time: Int64) {
        if let start = connectedAt {
            intervals.append(start...max(start, time))
            connectedAt = nil
        }
        prune(at: time)
    }
    public mutating func ingest(_ incoming: [Trade], now: Int64) {
        prune(at: now)
        for trade in incoming where trade.coin == coin {
            if trade.time >= 0 && trade.time < max(0, now - 3_600_000) { continue }
            guard trade.time >= 0, trade.time <= now + 5_000 else {
                invalidThrough = now
                continue
            }
            guard ["A", "B"].contains(trade.side), let size = Double(trade.sz),
                  let price = Double(trade.px),
                  price.isFinite, size.isFinite, price > 0, size > 0, trade.notional.isFinite,
                  trade.tid >= 0
            else {
                invalidThrough = now
                continue
            }
            let bucket = trade.time / 60_000
            if buckets[bucket]?[trade.id] == nil { count += 1 }
            buckets[bucket, default: [:]][trade.id] = trade
        }
        while count > capacity, let oldest = buckets.keys.min(), let entries = buckets[oldest] {
            let excess = count - capacity
            let discarded = entries.values.sorted {
                $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time
            }.prefix(
                excess)
            for trade in discarded {
                buckets[oldest]?.removeValue(forKey: trade.id)
                count -= 1
                evictedThrough = max(evictedThrough ?? trade.time, trade.time)
            }
            if buckets[oldest]?.isEmpty == true { buckets.removeValue(forKey: oldest) }
        }
    }
    private mutating func prune(at now: Int64) {
        let minute = now / 60_000
        guard lastPrunedMinute != minute else { return }
        lastPrunedMinute = minute
        let cutoff = max(0, now - 3_600_000)
        for key in buckets.keys.filter({ $0 < cutoff / 60_000 }) {
            count -= buckets.removeValue(forKey: key)?.count ?? 0
        }
        intervals.removeAll { $0.upperBound < cutoff }
        if let evictedThrough, evictedThrough < cutoff { self.evictedThrough = nil }
        if let invalidThrough, invalidThrough < cutoff { self.invalidThrough = nil }
    }
    public func summary(now: Int64, threshold: Double = 10_000) -> TradeWindowSummary {
        let start = max(0, now - 3_600_000)
        let trades = buckets.values.flatMap(\.values).filter { $0.time >= start && $0.time <= now }
        let large = trades.filter { $0.notional >= threshold }
        var segments = intervals
        if let connectedAt { segments.append(connectedAt...max(connectedAt, now)) }
        let clipped = segments.compactMap { range -> ClosedRange<Int64>? in
            let lower = max(start, range.lowerBound)
            let upper = min(now, range.upperBound)
            return lower <= upper ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var covered: Int64 = 0
        var lastEnd = start
        for range in clipped {
            let lower = max(range.lowerBound, lastEnd)
            if range.upperBound > lower { covered += range.upperBound - lower }
            lastEnd = max(lastEnd, range.upperBound)
        }
        return TradeWindowSummary(
            coin: coin, tradeCount: trades.count, largeTradeCount: large.count,
            buyNotional: large.filter { $0.side == "B" }.reduce(0) { $0 + $1.notional },
            sellNotional: large.filter { $0.side == "A" }.reduce(0) { $0 + $1.notional },
            largest: Array(
                large.sorted {
                    $0.notional == $1.notional ? $0.time > $1.time : $0.notional > $1.notional
                }.prefix(3)),
            observedMilliseconds: covered, requestedMilliseconds: now - start,
            capacityLimited: evictedThrough.map { $0 >= start } ?? false,
            invalidDataDropped: invalidThrough.map { $0 >= start } ?? false)
    }
}
