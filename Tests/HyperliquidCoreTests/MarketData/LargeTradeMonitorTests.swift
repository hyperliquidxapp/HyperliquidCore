import Foundation
import Testing

@testable import HyperliquidCore

private func eventTrade(
    _ id: Int64, time: Int64 = 10_000, side: String = "B", price: String = "100",
    size: String = "1000",
    coin: String = "ETH"
) -> Trade {
    Trade(coin: coin, side: side, px: price, sz: size, time: time, tid: id)
}

@Test func largeTradesHaveQuietBaselinesAndCountEveryUniqueBurstTradeBeyondDisplayLimits() throws {
    var monitor = LargeTradeMonitor(coin: "ETH")
    #expect(monitor.ingest([], now: 10_000).isEmpty)
    let first = eventTrade(0)
    #expect(monitor.ingest([first], now: 10_000) == [first] && monitor.takeBatch() == nil)
    let trades: [Trade] = (1...1_000).map { (index: Int) -> Trade in
        let side = index % 2 == 0 ? "B" : "A"
        let size = String(500 + index)
        return eventTrade(Int64(index), side: side, size: size)
    }
    _ = monitor.ingest(trades + trades + [first], now: 10_001)
    let drained = monitor.takeBatch()
    let batch = try #require(drained)
    #expect(
        batch.coin == "ETH" && batch.tradeCount == 1000 && batch.buyCount == 500
            && batch.sellCount == 500)
    #expect(batch.notional == 100_050_000 && batch.largest.tid == 1000 && !batch.capacityLimited)
    #expect(monitor.takeBatch() == nil)
    _ = monitor.ingest(trades, now: 10_002)
    #expect(monitor.takeBatch() == nil)
    _ = monitor.ingest([eventTrade(1, time: 10_003)], now: 10_003)
    #expect(monitor.takeBatch()?.tradeCount == 1)  // tid alone is not a globally unique ID.
}

@Test func largeTradesRejectInvalidForeignFutureAndOldAlertRecordsAndRespectThreshold() throws {
    var monitor = LargeTradeMonitor(coin: "ETH")
    let invalid = [
        eventTrade(1, side: "?"), eventTrade(-1), eventTrade(2, time: -1),
        eventTrade(3, price: "NaN"),
        eventTrade(4, price: "0"), eventTrade(5, size: "-1"),
        eventTrade(6, price: "1e308", size: "1e308"),
        eventTrade(7, coin: "BTC"), eventTrade(8, time: 105_001)
    ]
    #expect(monitor.ingest(invalid, now: 100_000).isEmpty)
    _ = monitor.ingest([eventTrade(0, time: 100_000)], now: 100_000)
    #expect(monitor.takeBatch() == nil)  // Invalid packets did not consume the baseline.
    let small = eventTrade(9, time: 100_001, size: "499.99")
    let threshold = eventTrade(10, time: 100_001, size: "500")
    let old = eventTrade(11, time: 39_999)
    let skew = eventTrade(12, time: 105_001)
    let valid = monitor.ingest(invalid + [small, threshold, old, skew], now: 100_001)
    #expect(valid == [eventTrade(8, time: 105_001), small, threshold, old, skew])
    let drained = monitor.takeBatch()
    let batch = try #require(drained)
    #expect(batch.tradeCount == 3 && batch.notional == 250_000)
    #expect(monitor.ingest([threshold], now: -1).isEmpty)
    #expect(monitor.ingest([threshold], now: 100_000).isEmpty)
    #expect(monitor.takeBatch() == nil)
}

@Test func largeTradeReplayIndexIsBoundedAndDisclosesCapacityLossAndReconnectBaselines() throws {
    var monitor = LargeTradeMonitor(coin: "ETH", capacity: 2)
    _ = monitor.ingest([eventTrade(0, time: 1_000)], now: 1_000)
    _ = monitor.ingest(
        [eventTrade(1, time: 1_001), eventTrade(2, time: 1_002), eventTrade(3, time: 1_003)],
        now: 1_003)
    let drained = monitor.takeBatch()
    let batch = try #require(drained)
    #expect(batch.tradeCount == 3 && batch.capacityLimited && monitor.retainedIdentityCount <= 2)
    _ = monitor.ingest(
        [eventTrade(1, time: 1_001), eventTrade(2, time: 1_002), eventTrade(3, time: 1_003)],
        now: 1_004)
    #expect(monitor.takeBatch() == nil)
    monitor.reconnect()
    _ = monitor.ingest([eventTrade(4, time: 1_005)], now: 1_005)
    #expect(monitor.takeBatch() == nil)
    _ = monitor.ingest([eventTrade(5, time: 62_000)], now: 62_000)
    #expect(monitor.takeBatch()?.capacityLimited == false && monitor.retainedIdentityCount == 1)
}

@Test func largeTradeAggregationDoesNotDisplayInfiniteTotalsOrLoseValidCounts() throws {
    var monitor = LargeTradeMonitor(coin: "ETH")
    _ = monitor.ingest([eventTrade(0)], now: 10_000)
    let huge = eventTrade(1, price: "1e308", size: "1")
    _ = monitor.ingest(
        [huge, eventTrade(2, price: "1e308", size: "1"), eventTrade(3, size: "1000")], now: 10_000)
    let drained = monitor.takeBatch()
    let batch = try #require(drained)
    #expect(batch.tradeCount == 3 && batch.notional == nil && batch.largest == huge)
}
