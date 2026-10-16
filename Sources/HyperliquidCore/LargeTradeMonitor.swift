import Foundation

public struct LargeTradeBatch: Sendable, Equatable {
    public let coin: String
    public fileprivate(set) var tradeCount: Int
    public fileprivate(set) var buyCount: Int
    public fileprivate(set) var sellCount: Int
    public fileprivate(set) var notional: Double?
    public fileprivate(set) var largest: Trade
    public fileprivate(set) var capacityLimited: Bool
}

/// Live alerts are independent of the capped display tape. The first nonempty
/// valid packet of each connection establishes a quiet baseline. Older than
/// one-minute trades never become new live alerts; the hourly archive is separate.
public struct LargeTradeMonitor: Sendable {
    public let coin: String
    public let capacity: Int
    public private(set) var retainedIdentityCount = 0
    public var capacityLimited: Bool { ignoredThrough != nil }
    private var seen: [String: Int64] = [:]
    private var needsBaseline = true
    private var pending: LargeTradeBatch?
    private var lastReceipt: Int64?
    private var ignoredThrough: Int64?
    private var lastPrunedSecond: Int64?
    public init(coin: String, capacity: Int = 20_000) {
        self.coin = coin
        self.capacity = max(1, capacity)
    }
    public mutating func reconnect() { needsBaseline = true }

    /// Returns validated display records, including historical baseline records.
    public mutating func ingest(_ incoming: [Trade], now: Int64) -> [Trade] {
        guard now >= 0, lastReceipt.map({ now >= $0 }) ?? true else { return [] }
        lastReceipt = now
        let cutoff = max(0, now - 60_000)
        let upper = now.addingReportingOverflow(5_000)
        let maximumTime = upper.overflow ? Int64.max : upper.partialValue
        if lastPrunedSecond != now / 1_000 {
            seen = seen.filter { $0.value >= cutoff }
            lastPrunedSecond = now / 1_000
        }
        if let ignoredThrough, ignoredThrough < cutoff { self.ignoredThrough = nil }
        let valid = incoming.filter {
            $0.coin == coin && $0.time <= maximumTime && $0.validNotional != nil
        }
        guard !valid.isEmpty else {
            retainedIdentityCount = seen.count
            return []
        }
        let baseline = needsBaseline
        needsBaseline = false
        for trade in valid where trade.time >= cutoff && trade.time > (ignoredThrough ?? -1) {
            guard seen.updateValue(trade.time, forKey: trade.id) == nil else { continue }
            guard !baseline, let amount = trade.validNotional, amount >= 50_000 else { continue }
            if var batch = pending {
                batch.tradeCount += 1
                if trade.side == "B" { batch.buyCount += 1 } else { batch.sellCount += 1 }
                if let total = batch.notional {
                    let sum = total + amount
                    batch.notional = sum.isFinite ? sum : nil
                }
                if amount > (batch.largest.validNotional ?? 0) { batch.largest = trade }
                pending = batch
            } else {
                pending = LargeTradeBatch(
                    coin: coin, tradeCount: 1, buyCount: trade.side == "B" ? 1 : 0,
                    sellCount: trade.side == "A" ? 1 : 0, notional: amount, largest: trade,
                    capacityLimited: false)
            }
        }
        if seen.count > capacity {
            // Evict a chunk so sustained bursts do not sort the full index for
            // every packet. A watermark suppresses replay of evicted identities.
            let target = max(1, capacity - max(1, capacity / 4))
            let removed = seen.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
            }.prefix(
                seen.count - target)
            for (identity, time) in removed {
                seen.removeValue(forKey: identity)
                ignoredThrough = max(ignoredThrough ?? time, time)
            }
        }
        retainedIdentityCount = seen.count
        if ignoredThrough != nil { pending?.capacityLimited = true }
        return valid
    }
    public mutating func takeBatch() -> LargeTradeBatch? {
        defer { pending = nil }
        return pending
    }
}
