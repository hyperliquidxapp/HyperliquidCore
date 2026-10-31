import Foundation
import Testing

@testable import HyperliquidCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"))
func agentReadOnlyFundingAndVolatilityProbe() async throws {
    let client = AgentReadClient(api: HyperliquidAPI())
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let end = now / 60_000 * 60_000 - 1
    async let candles = client.minuteCandles(coin: "ETH", start: end - 61 * 60_000, end: end)
    async let funding = client.fundingHistory(coin: "ETH", start: now - 86_400_000, end: now)
    async let catalog = client.catalog()
    let (history, rates, metadata) = try await (candles, funding, catalog)
    let volatility = try CandleVolatility.calculate(history, coin: "ETH", now: now)
    let observation = try FundingObservation.calculate(
        rates, coin: "ETH", start: now - 86_400_000, end: now)
    #expect(volatility.returnCount > 0 && volatility.realizedPercent.isFinite)
    #expect(observation.count > 0 && observation.latest.isFinite)
    let selected = try #require(metadata.markets.first { $0.coin == "BTC" })
    let queries: [(String, AgentTool)] = [
        ("我的 ETH 仓位风险怎么样？", .risk), ("如果 ETH 到 4200，我当前仓位盈利多少？", .scenario(4200)),
        ("把 ETH 仓位减掉 25%。", .reduce(Decimal(string: "0.25")!)), ("BTC funding 最近怎么样？", .funding),
        ("ETH OI 多少？", .openInterest), ("MY OPEN ORDERS", .orders)
    ]
    for (question, tool) in queries {
        #expect(
            try AgentQuery.parse(question, markets: metadata.markets, selected: selected).tool
                == tool)
    }
    print("Agent read-only tools: completed minute candles and funding history decoded.")
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"
            && ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"] != nil))
func testnetAccountWebSocketSnapshotProbe() async throws {
    let address = try #require(ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"])
    let socket = HyperliquidSocket()
    do {
        try await socket.connect(
            environment: .testnet, subscriptions: AccountStream.subscriptions(address: address))
        let channels = try await withThrowingTaskGroup(of: Set<String>.self) { group in
            group.addTask {
                var stream = try AccountStream(address: address)
                let expected: Set<String> = [
                    "clearinghouseState", "openOrders", "spotState", "userFills", "userFundings",
                    "userNonFundingLedgerUpdates"
                ]
                var seen = Set<String>()
                while !expected.isSubset(of: seen) {
                    let message = try await socket.receive()
                    if message.channel == "error" {
                        throw APIError.malformed(
                            message.data?.string ?? "Account subscription rejected")
                    }
                    if try stream.ingest(message) { seen.insert(message.channel) }
                }
                #expect(stream.ready)
                #expect(stream.account != nil)
                #expect(stream.balances["balances"] != .null)
                print("Read-only testnet WebSocket: all six account snapshots decoded.")
                return seen
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                await socket.disconnect()
                throw APIError.malformed("Account WebSocket snapshot probe timed out")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
        #expect(channels.count >= 6)
        await socket.disconnect()
    } catch {
        await socket.disconnect()
        throw error
    }
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"
            && ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"] != nil))
func testnetAccountReadOnlyProbe() async throws {
    let address = try #require(ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"])
    #expect(Address.isValid(address))
    let api = HyperliquidAPI(environment: .testnet)
    async let account = api.account(address: address)
    async let spot = api.info(["type": .string("spotClearinghouseState"), "user": .string(address)])
    async let agents = api.info(["type": .string("extraAgents"), "user": .string(address)])
    async let orders = api.orders(address: address)
    async let fees = api.userFees(address: address)
    let catalog = try await api.catalog()
    let eth = try #require(catalog.markets.first { $0.coin == "ETH" && $0.kind == .perp })
    async let active = api.activeAssetData(address: address, market: eth)
    let result = try await (account, spot, agents, orders, fees, active)
    #expect(result.4.perpTaker >= 0)
    #expect(result.5.coin == "ETH")
    for side in [OrderSide.buy, .sell] {
        let capacity = try PerpTradingCapacity(
            asset: result.5, address: address, market: eth, side: side)
        #expect(capacity.maximumSize >= 0 && capacity.availableMargin >= 0)
        if capacity.maximumSize == 0 {
            #expect(throws: OrderValidationError.self) {
                try capacity.percentageSize(
                    requestedLeverage: result.5.leverage.value, percentage: 100)
            }
        } else {
            _ = try capacity.percentageSize(
                requestedLeverage: result.5.leverage.value, percentage: 100)
        }
    }
    #expect(result.0.time > 0)
    let abstraction = try await api.info([
        "type": .string("userAbstraction"), "user": .string(address)
    ])
    if ["default", "disabled"].contains(abstraction.string ?? "") {
        let intent = try OrderPlanner.preview(
            market: eth, side: .buy, kind: .market, size: "100", isUSD: true,
            price: "", trigger: nil, mark: try #require(Double(result.5.markPx)),
            leverage: result.5.leverage.value,
            reduceOnly: false)
        let risk = try await api.orderRisk(
            intent: intent, address: address, asset: result.5, fees: result.4.estimate(for: intent))
        #expect(
            risk.coin == eth.coin && risk.assumedFillPrice > 0
                && risk.maintenanceMarginRequired >= 0)
    }
    #expect(
        try BalanceTransferIntent.available(toPerp: true, spot: result.1, account: result.0) >= 0)
    #expect(
        try BalanceTransferIntent.available(toPerp: false, spot: result.1, account: result.0) >= 0)
    guard case .array = result.2 else { throw APIError.malformed("Invalid registration response") }
    let historyEnd = Int64(Date().timeIntervalSince1970 * 1000)
    for kind in AccountHistoryKind.allCases {
        var cursor = AccountHistoryCursor(
            kind: kind, window: try AccountHistoryPeriod.week.window(endingAt: historyEnd))
        try cursor.append(try await api.info(cursor.request(address: address)))
        print(
            "Read-only testnet archive: \(kind.rawValue), \(cursor.records.count) returned records."
        )
    }
    print("Read-only testnet account schema verified; no exchange requests submitted.")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"))
func mainnetPublicRESTAndWebSocketProbe() async throws {
    // Explicitly opt-in, public market data only. No account, wallet or exchange mutation.
    let api = HyperliquidAPI()
    let catalog = try await api.catalog()
    let hype = try #require(catalog.markets.first { $0.symbol == "HYPE" && $0.kind == .spot })
    #expect(hype.coin == "@107")
    #expect(hype.assetID == 10107)
    #expect(hype.baseTokenIndex == 150 && hype.quoteTokenIndex == 0)
    #expect((catalog.contexts[hype.coin]?.price ?? 0) > 0)
    async let snapshot = api.book(coin: hype.coin)
    async let history = api.candles(coin: hype.coin, timeframe: .m15)
    let (book, candles) = try await (snapshot, history)
    #expect(!book.bids.isEmpty && !book.asks.isEmpty)
    #expect(candles.count > 10)
    #expect(candles.allSatisfy { $0.s == hype.coin && $0.i == "15m" })
    let first = try #require(candles.first)
    let older = try await api.candles(
        coin: hype.coin, timeframe: .m15,
        startTime: first.t - Timeframe.m15.milliseconds * 500, endTime: first.t - 1)
    #expect(!older.isEmpty)
    #expect(older.allSatisfy { $0.t < first.t && $0.s == hype.coin && $0.i == "15m" })
    let socket = HyperliquidSocket()
    do {
        try await socket.connect(
            environment: .mainnet,
            subscriptions: [
                ["type": .string("allMids")],
                ["type": .string("l2Book"), "coin": .string(hype.coin)],
                ["type": .string("trades"), "coin": .string(hype.coin)],
                [
                    "type": .string("candle"), "coin": .string(hype.coin),
                    "interval": .string("15m")
                ],
                ["type": .string("activeAssetCtx"), "coin": .string(hype.coin)]
            ])
        let channels = try await withThrowingTaskGroup(of: Set<String>.self) { group in
            group.addTask {
                var seen = Set<String>()
                let expected: Set<String> = [
                    "allMids", "l2Book", "trades", "candle", "activeSpotAssetCtx"
                ]
                while !expected.isSubset(of: seen) {
                    let message = try await socket.receive()
                    guard let data = message.data else { continue }
                    switch message.channel {
                    case "l2Book": #expect(try data.decode(OrderBook.self).coin == hype.coin)
                    case "trades":
                        #expect(try data.decode([Trade].self).allSatisfy { $0.coin == hype.coin })
                    case "candle": #expect(try data.decode(Candle.self).s == hype.coin)
                    case "activeAssetCtx", "activeSpotAssetCtx":
                        #expect(try data["ctx"].decode(AssetContext.self).price > 0)
                    default: break
                    }
                    if seen.insert(message.channel).inserted {
                        print("Public WS probe channel: \(message.channel)")
                    }
                }
                return seen
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                await socket.disconnect()
                throw APIError.malformed("Public WebSocket probe timed out")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
        #expect(channels.contains("l2Book"))
        await socket.disconnect()
    } catch {
        await socket.disconnect()
        throw error
    }
}

@Test func spotContextsJoinByCoinWithSparseAndReorderedUniverse() throws {
    let perp = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"universe":[]},[]]"#.utf8))
    let spot = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            #"[{"tokens":[{"name":"USDC","index":0,"szDecimals":8},{"name":"HYPE","index":150,"szDecimals":2},{"name":"OTHER","index":1022,"szDecimals":3}],"universe":[{"name":"@868","index":868,"tokens":[1022,0]},{"name":"@107","index":107,"tokens":[150,0]}]},[{"coin":"@107","markPx":"90","prevDayPx":"89","dayNtlVlm":"100"},{"coin":"@1","markPx":"12","prevDayPx":"11","dayNtlVlm":"20"},{"coin":"@868","markPx":"0.1","prevDayPx":"0.09","dayNtlVlm":"1"}]]"#
                .utf8))
    let parsed = try HyperliquidAPI.parseCatalog(perp: perp, spot: spot)
    #expect(parsed.contexts["@107"]?.price == 90)
    #expect(parsed.contexts["@868"]?.price == 0.1)
    #expect(parsed.markets.first { $0.coin == "@868" }?.assetID == 10868)
}
