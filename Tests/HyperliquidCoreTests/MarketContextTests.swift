import Foundation
import Testing

@testable import HyperliquidCore

private func context(_ mark: String, mid: String? = nil) throws -> AssetContext {
    let data: JSONValue = .object([
        "markPx": .string(mark), "midPx": mid.map(JSONValue.string) ?? .null,
        "prevDayPx": .string("100"), "dayNtlVlm": .string("1000"), "funding": .string("0.0001"),
        "openInterest": .string("10")
    ])
    return try data.decode(AssetContext.self)
}
private let contextMarkets = [
    Market(coin: "BTC", symbol: "BTC", assetID: 0, sizeDecimals: 5, maxLeverage: 40, kind: .perp),
    Market(coin: "ETH", symbol: "ETH", assetID: 2, sizeDecimals: 4, maxLeverage: 25, kind: .perp),
    Market(
        coin: "@107", symbol: "HYPE", assetID: 10107, sizeDecimals: 2, maxLeverage: 1, kind: .spot)
]

@Test func allDexContextsUseActualValidatorAssetIDsAndExcludeSpotAndHIP3() throws {
    func raw(_ value: String) -> JSONValue {
        .object([
            "markPx": .string(value), "prevDayPx": .string("100"), "dayNtlVlm": .string("1000")
        ])
    }
    let native: JSONValue = .array([.string(""), .array([raw("200"), raw("999"), raw("300")])])
    let external: JSONValue = .array([
        .string("xyz"), .array([raw("800"), raw("900"), raw("1000")])
    ])
    let data: JSONValue = .object(["ctxs": .array([external, native])])
    let parsed = try MarketContextBook.validatorContexts(data, markets: contextMarkets)
    #expect(parsed.count == 2)
    #expect(parsed["BTC"]?.markPx == "200")
    #expect(parsed["ETH"]?.markPx == "300")
    #expect(parsed["@107"] == nil)
    #expect(throws: APIError.self) {
        try MarketContextBook.validatorContexts(
            .object(["ctxs": .array([external])]), markets: contextMarkets)
    }
    #expect(throws: APIError.self) {
        try MarketContextBook.validatorContexts(
            .object(["ctxs": .array([native, native])]), markets: contextMarkets)
    }
    #expect(throws: APIError.self) {
        try MarketContextBook.validatorContexts(
            .object(["ctxs": .array([.array([.string(""), .array([raw("200")])])])]),
            markets: contextMarkets)
    }
    #expect(throws: APIError.self) {
        try MarketContextBook.validatorContexts(data, markets: contextMarkets + [contextMarkets[0]])
    }
}

@Test func contextRESTCannotRewindNewerMarksOrMidsAndUnchangedMarksRefreshTheirAge() throws {
    var book = MarketContextBook()
    book.mergeREST(
        ["ETH": try context("100", mid: "101"), "BTC": try context("200")], startedAt: 0,
        receivedAt: 10)
    let requestRevision = book.revision
    book.applyStream(["ETH": try context("110", mid: "111")], receivedAt: 11)
    book.applyMids(["BTC": "205"])
    book.mergeREST(
        ["ETH": try context("99", mid: "98"), "BTC": try context("201", mid: "202")],
        startedAt: requestRevision,
        receivedAt: 12)
    #expect(book.contexts["ETH"]?.markPx == "110")
    #expect(book.contexts["ETH"]?.midPx == "111")
    #expect(book.contexts["BTC"]?.markPx == "201")
    #expect(book.contexts["BTC"]?.midPx == "205")
    #expect(book.freshMarks(now: 26)["ETH"] == 110)
    #expect(book.freshMarks(now: 26.001)["ETH"] == nil)
    // No displayed price change, but a new receipt establishes actual freshness.
    book.applyStream(["ETH": try context("110", mid: "111")], receivedAt: 27)
    #expect(book.freshMarks(now: 28)["ETH"] == 110)
}

@Test func midPricesInvalidMarksAndClockChangesCannotInventFreshRiskData() throws {
    var book = MarketContextBook()
    book.applyStream(["ETH": try context("100")], receivedAt: 10)
    book.applyMids(["ETH": "101", "Unknown": "30"])
    #expect(book.freshMarks(now: 26).isEmpty)
    #expect(book.contexts["Unknown"] == nil)
    #expect(book.freshMarks(now: 9).isEmpty)
    #expect(book.freshMarks(now: .nan).isEmpty)
    #expect(book.freshMarks(now: 11, maximumAge: -1).isEmpty)
    for invalid in ["nan", "inf", "-1", "0", "not a price"] {
        book.applyStream(["ETH": try context(invalid)], receivedAt: 26)
        #expect(book.freshMarks(now: 26).isEmpty)
    }
    book.applyStream(["ETH": try context("100")], receivedAt: 30)
    book.invalidateMarks()
    #expect(book.freshMarks(now: 30).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"))
func allMarketContextStreamDecodesAllDexMarketsOnBothNetworks() async throws {
    for environment in NetworkEnvironment.allCases {
        let catalog = try await HyperliquidAPI(environment: environment).catalog()
        let socket = HyperliquidSocket()
        do {
            try await socket.connect(
                environment: environment, subscriptions: [["type": .string("allDexsAssetCtxs")]])
            let parsed = try await withThrowingTaskGroup(of: [String: AssetContext].self) { group in
                group.addTask {
                    while true {
                        let message = try await socket.receive()
                        if message.channel == "error" {
                            throw APIError.malformed(
                                message.data?.string ?? "Context subscription rejected")
                        }
                        if message.channel == "allDexsAssetCtxs", let data = message.data {
                            return try MarketContextBook.assetContexts(
                                data, markets: catalog.markets)
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    await socket.disconnect()
                    throw APIError.malformed("All-market context probe timed out")
                }
                defer { group.cancelAll() }
                let result = try await group.next()
                return try #require(result)
            }
            #expect(
                Set(parsed.keys) == Set(catalog.markets.filter { $0.kind == .perp }.map(\.coin)))
            #expect(
                Double(try #require(parsed["ETH"]?.markPx)).map { $0.isFinite && $0 > 0 } == true)
            print(
                "Read-only \(environment.rawValue) global contexts decoded: \(parsed.count) perpetual markets."
            )
            await socket.disconnect()
        } catch {
            await socket.disconnect()
            throw error
        }
    }
}
