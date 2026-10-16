import Foundation
import Testing

@testable import HyperliquidCore

private func hip3JSON(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func hip3Fixture() throws -> (dexs: JSONValue, metas: JSONValue, spot: JSONValue) {
    let dexs = try hip3JSON("""
    [null,{"name":"xyz"},{"name":"empty"},{"name":"cash"}]
    """)
    let metas = try hip3JSON("""
    [
      {"universe":[],"collateralToken":0},
      {"universe":[
        {"name":"xyz:OLD","isDelisted":true,"szDecimals":2,"maxLeverage":5},
        {"name":"xyz:CRCL","szDecimals":3,"maxLeverage":10}
      ],"collateralToken":0},
      {"universe":[],"collateralToken":0},
      {"universe":[
        {"name":"cash:CRCL","szDecimals":2,"maxLeverage":5,"marginMode":"strictIsolated"}
      ],"collateralToken":360}
    ]
    """)
    let spot = try hip3JSON("""
    [{"tokens":[{"index":360,"name":"USDH"},{"index":0,"name":"USDC"}],"universe":[]},[]]
    """)
    return (dexs, metas, spot)
}

@Test func hip3CatalogPreservesDexOffsetsDelistedSlotsAndCollateral() throws {
    let fixture = try hip3Fixture()
    let markets = try HyperliquidAPI.parseHIP3Markets(dexs: fixture.dexs, metas: fixture.metas, spot: fixture.spot)
    #expect(markets.map(\.coin) == ["xyz:CRCL", "cash:CRCL"])
    #expect(markets.map(\.assetID) == [110001, 130000])
    #expect(markets.map(\.contextIndex) == [1, 0])
    #expect(markets.map(\.title) == ["CRCL-USDC", "CRCL-USDH"])
    #expect(markets.map(\.quoteTokenIndex) == [0, 360])
    #expect(markets[1].onlyIsolated)
    #expect(markets[0].venueDescription == "Perpetual · xyz")
    #expect(markets[0].iconSymbol == "xyz:CRCL")
    #expect(MarketSearch.results("xyz:crcl", markets: markets).map(\.coin) == ["xyz:CRCL"])
    #expect(MarketSearch.results("CRCL", markets: markets).count == 2)
    #expect(try JSONDecoder().decode(Market.self, from: JSONEncoder().encode(markets[0])) == markets[0])
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.preview(market: markets[0], side: .buy, kind: .limit, size: "1", isUSD: false,
                                 price: "100", trigger: nil, mark: 100, leverage: 1, reduceOnly: false)
    }
}

@Test func hip3CatalogRejectsMismatchedDexOrderingAndDuplicateIdentities() throws {
    let fixture = try hip3Fixture()
    let reordered = try hip3JSON("[null,{\"name\":\"cash\"},{\"name\":\"empty\"},{\"name\":\"xyz\"}]")
    for dexs in [reordered, .array([.null]), .array([.null, .null, .null, .null])] {
        #expect(throws: APIError.self) {
            try HyperliquidAPI.parseHIP3Markets(dexs: dexs, metas: fixture.metas, spot: fixture.spot)
        }
    }
    let duplicate = try hip3JSON("""
    [{"universe":[],"collateralToken":0},
     {"universe":[{"name":"xyz:CRCL","szDecimals":3,"maxLeverage":10},
                  {"name":"xyz:CRCL","szDecimals":3,"maxLeverage":10}],"collateralToken":0}]
    """)
    #expect(throws: APIError.self) {
        try HyperliquidAPI.parseHIP3Markets(dexs: .array(Array(fixture.dexs.array.prefix(2))),
                                            metas: duplicate, spot: fixture.spot)
    }
}

@Test func hip3ContextsKeepSameSymbolAndSameLocalIndexInDifferentDexsSeparate() throws {
    let fixture = try hip3Fixture()
    let markets = try HyperliquidAPI.parseHIP3Markets(dexs: fixture.dexs, metas: fixture.metas, spot: fixture.spot)
    let data = try hip3JSON("""
    {"ctxs":[
      ["cash",[{"markPx":"222","prevDayPx":"200","dayNtlVlm":"10"}]],
      ["",[{"markPx":"999","prevDayPx":"900","dayNtlVlm":"20"}]],
      ["xyz",[{"markPx":"1","prevDayPx":"1","dayNtlVlm":"0"},
               {"markPx":"111","prevDayPx":"100","dayNtlVlm":"30"}]]
    ]}
    """)
    let native = Market(coin: "CRCL", symbol: "CRCL", assetID: 0, sizeDecimals: 2, maxLeverage: 5, kind: .perp)
    let contexts = try MarketContextBook.assetContexts(data, markets: markets + [native])
    #expect(contexts["xyz:CRCL"]?.markPx == "111")
    #expect(contexts["cash:CRCL"]?.markPx == "222")
    #expect(contexts["CRCL"]?.markPx == "999")
    let missing = JSONValue.object(["ctxs": .array([data["ctxs"].array[1]])])
    #expect(try MarketContextBook.assetContexts(missing, markets: markets + [native]).keys.sorted() == ["CRCL"])
    #expect(throws: APIError.self) {
        try MarketContextBook.assetContexts(data, markets: markets + markets)
    }
    var book = MarketContextBook()
    book.applyStream(contexts, receivedAt: 10)
    book.mergeREST(["CRCL": contexts["CRCL"]!], startedAt: book.revision, receivedAt: 30)
    #expect(book.freshMarks(now: 30)["xyz:CRCL"] == nil)
    #expect(book.freshMarks(now: 30)["CRCL"] == 999)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"))
func hip3MainnetPublicRESTAndWebSocketProbe() async throws {
    let api = HyperliquidAPI(environment: .mainnet)
    let catalog = try await api.catalogSnapshot()
    #expect(catalog.warning == nil)
    let market = try #require(catalog.markets.first { $0.coin == "xyz:CRCL" })
    #expect(MarketSearch.results("CRCL", markets: catalog.markets).contains(market))
    #expect(market.perpDexIndex == 1 && market.assetID >= 110000 && market.title == "CRCL-USDC")
    async let context = api.builderContext(market: market)
    async let book = api.book(coin: market.coin)
    async let candles = api.candles(coin: market.coin, timeframe: .m15)
    async let trades = api.info(["type": .string("recentTrades"), "coin": .string(market.coin)])
    let snapshots = try await (context, book, candles, trades)
    #expect(snapshots.0.price > 0 && snapshots.1.coin == market.coin)
    #expect(!snapshots.2.isEmpty && snapshots.2.allSatisfy { $0.s == market.coin })
    let prints = try snapshots.3.decode([Trade].self)
    #expect(!prints.isEmpty && prints.allSatisfy { $0.coin == market.coin })
    let socket = HyperliquidSocket()
    do {
        try await socket.connect(environment: .mainnet, subscriptions: [
            ["type": .string("allDexsAssetCtxs")],
            ["type": .string("l2Book"), "coin": .string(market.coin)],
            ["type": .string("activeAssetCtx"), "coin": .string(market.coin)],
            ["type": .string("candle"), "coin": .string(market.coin), "interval": .string("15m")],
            ["type": .string("trades"), "coin": .string(market.coin)]
        ])
        let channels = try await withThrowingTaskGroup(of: Set<String>.self) { group in
            group.addTask {
                var channels = Set<String>()
                while channels.count < 5 {
                    let message = try await socket.receive()
                    guard let data = message.data else { continue }
                    switch message.channel {
                    case "allDexsAssetCtxs":
                        let contexts = try MarketContextBook.assetContexts(data, markets: catalog.markets)
                        guard contexts[market.coin] != nil else { continue }
                    case "l2Book", "activeAssetCtx":
                        guard data["coin"].string == market.coin else { continue }
                    case "candle":
                        guard data["s"].string == market.coin else { continue }
                    case "trades":
                        guard data.array.contains(where: { $0["coin"].string == market.coin }) else { continue }
                    case "error": throw APIError.malformed(data.string ?? "HIP-3 stream rejected")
                    default: continue
                    }
                    channels.insert(message.channel)
                }
                return channels
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                await socket.disconnect()
                throw APIError.malformed("HIP-3 probe timed out")
            }
            defer { group.cancelAll() }
            return try #require(await group.next())
        }
        print("HIP-3 read-only probe: \(catalog.markets.filter(\.isBuilderPerp).count) markets; \(market.coin), asset \(market.assetID), \(channels.sorted()); no wallet or exchange actions.")
        await socket.disconnect()
    } catch {
        await socket.disconnect()
        throw error
    }
}
