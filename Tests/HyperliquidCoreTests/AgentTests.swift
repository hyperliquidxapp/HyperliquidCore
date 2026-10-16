import Foundation
import Testing

@testable import HyperliquidCore

private let agentETH = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 20, kind: .perp)
private let agentBTC = Market(
    coin: "BTC", symbol: "BTC", assetID: 0, sizeDecimals: 5, maxLeverage: 40, kind: .perp)
private let agentHYPE = Market(
    coin: "HYPE", symbol: "HYPE", assetID: 2, sizeDecimals: 2, maxLeverage: 10, kind: .perp)
private let agentSpot = Market(
    coin: "@107", symbol: "HYPE", assetID: 10107, sizeDecimals: 2, maxLeverage: 1, kind: .spot)
private let agentPEPE = Market(
    coin: "kPEPE", symbol: "1000PEPE", assetID: 3, sizeDecimals: 0, maxLeverage: 10, kind: .perp)
private let agentMarkets = [agentETH, agentBTC, agentHYPE, agentSpot, agentPEPE]
private func parseAgent(_ q: String, selected: Market = agentSpot) throws -> AgentQuery {
    try AgentQuery.parse(q, markets: agentMarkets, selected: selected)
}

@Test func agentResolvesEveryRequestedExampleWithoutExecuting() throws {
    #expect(try parseAgent("我的 ETH 仓位风险怎么样？").tool == .risk)
    #expect(try parseAgent("我的 ETH 仓位风险怎么样？").market == agentETH)
    #expect(try parseAgent("如果 ETH 到 4200，我当前仓位盈利多少？").tool == .scenario(4200))
    #expect(try parseAgent("把 ETH 仓位减掉 25%。").tool == .reduce(Decimal(string: "0.25")!))
    #expect(try parseAgent("BTC funding 最近怎么样？").market == agentBTC)
    #expect(try parseAgent("帮我看过去 1 小时有没有大单。").tool == .largeTrades)
    #expect(try parseAgent("给 ETH 设置止损在 4180。").tool == .protection(.stop, 4180))
}

@Test func agentSeparatesTickerDigitsPercentagesAndPrices() throws {
    let result = try parseAgent("把 1000PEPE 仓位减掉 25%。")
    #expect(result.market == agentPEPE && result.tool == .reduce(Decimal(string: "0.25")!))
    #expect(
        try parseAgent("给 1000PEPE 设置止损在 0.00125。").tool
            == .protection(.stop, Decimal(string: "0.00125")!))
    #expect(
        try parseAgent("Set ETH stop loss at 4,200.50").tool
            == .protection(.stop, Decimal(string: "4200.5")!))
    #expect(try parseAgent("what if ETH reaches 4200").tool == .scenario(4200))
    #expect(
        try parseAgent("reduce ETH 33.333333%", selected: agentBTC).tool
            == .reduce(Decimal(string: "0.33333333")!))
    for question in [
        "reduce ETH 0%", "reduce ETH -25%", "reduce ETH 101%", "reduce ETH 25", "给 ETH 设置止损在 -4180",
        "stop loss ETH at 4,20", "stop loss ETH at 4e3"
    ] {
        #expect(throws: OrderValidationError.self) { try parseAgent(question) }
    }
}

@Test func agentMarketResolutionRejectsAmbiguityAndSubstringMatches() throws {
    #expect(try parseAgent("HYPE funding 最近怎么样？").market == agentHYPE)
    #expect(try parseAgent("HYPE/USDC 最近大单", selected: agentETH).market == agentSpot)
    #expect(try parseAgent("whether there is risk", selected: agentBTC).market == agentBTC)
    #expect(throws: OrderValidationError.self) { try parseAgent("BTC 和 1000PEPE 的风险") }
    #expect(throws: OrderValidationError.self) { try parseAgent("HYPE 现货 funding") }
    #expect(throws: OrderValidationError.self) { try parseAgent("给 ZZZ 设置止损在 4180") }
    #expect(throws: OrderValidationError.self) { try parseAgent("reduce ethx 25%") }
    #expect(throws: OrderValidationError.self) { try parseAgent("close ETH 25") }
    #expect(throws: OrderValidationError.self) { try parseAgent("减掉 ETH 25% 并设置止损在 4180") }
    #expect(try parseAgent("CLOSE ETH ALL").tool == .reduce(1))
    let duplicate = Market(
        coin: "@999", symbol: "HYPE", assetID: 10999, sizeDecimals: 2, maxLeverage: 1, kind: .spot)
    #expect(
        try AgentQuery.parse(
            "HYPE spot large trades", markets: agentMarkets + [duplicate], selected: agentSpot
        ).market
        == agentSpot)
}

@Test func agentQuestionsAndNegationsDoNotBecomeTradingIntents() throws {
    for question in [
        "不要减掉 ETH 25%", "Don't close ETH", "如何给 ETH 设置止损在 4180？", "why reduce ETH 25%",
        "show ETH stop loss at 4180"
    ] {
        #expect(try parseAgent(question).tool.preparesOrder == false)
    }
    #expect(try parseAgent("如果给 ETH 止损在 4180 会怎样？").tool == .scenario(4180))
    #expect(try parseAgent("close ETH").tool == .reduce(1))
    #expect(try parseAgent("ETH 平仓一半").tool == .reduce(Decimal(string: "0.5")!))
}

@Test func agentReadToolsHaveDistinctQueries() throws {
    let examples: [(String, AgentTool)] = [
        ("ETH OI 多少", .openInterest), ("ETH 波动率", .volatility), ("我的挂单", .orders),
        ("ETH 历史成交", .fills),
        ("我的余额", .balances), ("账户怎么样", .account), ("我的仓位", .positions)
    ]
    for (text, tool) in examples { #expect(try parseAgent(text).tool == tool) }
}

private func agentCandle(_ t: Int64, _ close: String, coin: String = "ETH") -> Candle {
    Candle(
        t: t, T: t + 59_999, s: coin, i: "1m", o: close, h: close, l: close, c: close, v: "1", n: 1)
}
@Test func minuteVolatilityUsesCompletedContiguousLogReturns() throws {
    let candles = [
        agentCandle(0, "100"), agentCandle(60_000, "110"), agentCandle(120_000, "100"),
        agentCandle(180_000, "999")
    ]
    let sample = try CandleVolatility.calculate(candles, coin: "ETH", now: 180_000)
    #expect(sample.candleCount == 3 && sample.returnCount == 2 && sample.gapCount == 0)
    #expect(abs(sample.realizedPercent - sqrt(2) * log(1.1) * 100) < 0.000001)
    #expect(sample.changePercent == 0)
    let gaps = try CandleVolatility.calculate(
        [candles[0], candles[1], agentCandle(180_000, "200")], coin: "ETH", now: 300_000)
    #expect(gaps.gapCount == 1 && gaps.returnCount == 1)
    #expect(abs(gaps.realizedPercent - log(1.1) * 100) < 0.000001)
    #expect(throws: OrderValidationError.self) {
        try CandleVolatility.calculate(
            [agentCandle(0, "0"), candles[1]], coin: "ETH", now: 180_000)
    }
    #expect(throws: OrderValidationError.self) {
        try CandleVolatility.calculate([candles[0]], coin: "ETH", now: 180_000)
    }
}

@Test func agentFundingDeduplicatesAndRejectsForeignMarketData() throws {
    let json =
        #"[{"coin":"ETH","time":1,"fundingRate":"0.01"},{"coin":"ETH","time":1,"fundingRate":"0.01"},{"coin":"ETH","time":2,"fundingRate":"-0.005"},{"coin":"ETH","time":9,"fundingRate":"0.9"}]"#
    let rows = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    let result = try FundingObservation.calculate(rows, coin: "ETH", start: 1, end: 2)
    #expect(result.count == 2 && result.latest == -0.005 && result.cumulative == 0.005)
    #expect(throws: APIError.self) {
        try FundingObservation.calculate(rows, coin: "BTC", start: 1, end: 2)
    }
}

@Test func agentScenarioPreservesSignedDecimalPositionSize() throws {
    let json =
        #"{"coin":"ETH","szi":"-0.125","entryPx":"4000.5","liquidationPx":"4400","positionValue":"500","unrealizedPnl":"0","returnOnEquity":"0","marginUsed":"50","leverage":{"type":"cross","value":10}}"#
    let position = try JSONDecoder().decode(Position.self, from: Data(json.utf8))
    #expect(
        try AgentPositionAnalysis.hypotheticalPnL(
            position: position, target: Decimal(string: "4200.5")!) == -25)
    #expect(
        try AgentPositionAnalysis.hypotheticalPnL(
            position: position, target: Decimal(string: "3800.5")!) == 25)
}

private func observedTrade(
    _ id: Int64, _ time: Int64, side: String = "B", price: String = "100", coin: String = "ETH"
)
-> Trade {
    Trade(coin: coin, side: side, px: price, sz: "100", time: time, tid: id)
}
@Test func hourlyTradeArchiveOutlivesShortTapeAndDeduplicates() {
    var window = TradeObservationWindow(coin: "ETH")
    window.connect(at: 0)
    let trades = (1...1_500).map { observedTrade(Int64($0), Int64($0) * 1000) }
    window.ingest(trades + trades, now: 3_600_000)
    let summary = window.summary(now: 3_600_000)
    #expect(summary.tradeCount == 1500 && summary.largeTradeCount == 1500)
    #expect(summary.buyNotional == 15_000_000 && summary.sellNotional == 0)
    #expect(summary.continuousCoverage && summary.largest.count == 3)
    #expect(window.summary(now: 7_200_000).tradeCount == 0)
}

@Test func hourlyObservationReportsReconnectGapsAndExpiresThem() {
    var window = TradeObservationWindow(coin: "ETH")
    window.connect(at: 0)
    window.disconnect(at: 900_000)
    window.connect(at: 1_200_000)
    let partial = window.summary(now: 3_600_000)
    #expect(!partial.continuousCoverage && partial.observedMilliseconds == 3_300_000)
    #expect(window.summary(now: 4_800_000).continuousCoverage)
}

@Test func hourlyCapacityEvictionAndForeignTradesCannotHideMissingData() {
    var window = TradeObservationWindow(coin: "ETH", capacity: 2)
    window.connect(at: 0)
    window.ingest(
        [
            observedTrade(1, 100), observedTrade(2, 200, side: "A"), observedTrade(3, 300),
            observedTrade(4, 400, coin: "BTC")
        ], now: 500)
    let result = window.summary(now: 500)
    #expect(result.tradeCount == 2 && result.truncated && !result.continuousCoverage)
    #expect(result.buyNotional == 10_000 && result.sellNotional == 10_000)
    #expect(!window.summary(now: 3_600_501).truncated)
}

@Test func fillFeeAssetDecodesWithoutInventingUSDC() throws {
    let raw =
        #"{"coin":"@107","px":"100","sz":"1","side":"B","time":1,"tid":1,"fee":"0.0004","feeToken":"HYPE","closedPnl":"0"}"#
    let fill = try JSONDecoder().decode(Fill.self, from: Data(raw.utf8))
    #expect(fill.feeToken == "HYPE")
    let legacyRaw =
        #"{"coin":"@107","px":"100","sz":"1","side":"B","time":1,"tid":1,"fee":"0.0004","closedPnl":"0"}"#
    let legacy = try JSONDecoder().decode(Fill.self, from: Data(legacyRaw.utf8))
    #expect(legacy.feeToken == nil && legacy.id == fill.id)
}

@Test func hourlyWindowRetainsSmallClockSkewAndReportsInvalidRecords() {
    var window = TradeObservationWindow(coin: "ETH")
    window.connect(at: 0)
    window.ingest([observedTrade(1, 1_100)], now: 1_000)
    #expect(window.summary(now: 1_000).tradeCount == 0)
    #expect(window.summary(now: 1_200).tradeCount == 1)
    window.ingest([observedTrade(2, 1_100, price: "NaN"), observedTrade(3, 99_999)], now: 1_200)
    let partial = window.summary(now: 1_200)
    #expect(partial.invalidDataDropped && !partial.capacityLimited && !partial.continuousCoverage)
    #expect(window.summary(now: 3_601_201).invalidDataDropped == false)
}
