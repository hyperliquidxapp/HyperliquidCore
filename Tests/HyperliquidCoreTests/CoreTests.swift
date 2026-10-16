import Foundation
import Testing

@testable import HyperliquidCore

private let eth = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 50, kind: .perp)
private let hypeSpot = Market(
    coin: "@107", symbol: "HYPE", assetID: 10107, sizeDecimals: 2, maxLeverage: 1, kind: .spot)

@Test func marketPreviewSupportsSmallDecimalPricesAndFreshness() throws {
    let small = Market(
        coin: "@1", symbol: "SMALL", assetID: 10001, sizeDecimals: 0, maxLeverage: 1, kind: .spot)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let intent = try OrderPlanner.preview(
        market: small, side: .buy, kind: .market, size: "100", isUSD: true, price: "", trigger: nil,
        mark: 0.000001,
        leverage: 1, reduceOnly: false, now: date)
    #expect(!intent.price.contains("e"))
    #expect(Double(intent.price) == 0.000001)
    #expect(intent.size == "100000000")
    try intent.validateFreshness(now: date.addingTimeInterval(29.9))
    #expect(throws: OrderValidationError.self) {
        try intent.validateFreshness(now: date.addingTimeInterval(30))
    }
    #expect(throws: OrderValidationError.self) {
        try intent.validateFreshness(now: date.addingTimeInterval(-1))
    }
}

@Test func marketPriceRoundingStaysInsideSlippageBound() throws {
    for mark in [0.015027, 99.994, 1756.625, 99999.5] {
        for side in [OrderSide.buy, .sell] {
            let intent = try OrderPlanner.preview(
                market: eth, side: side, kind: .market, size: "100", isUSD: true, price: "",
                trigger: nil, mark: mark,
                leverage: 1, reduceOnly: false)
            let price = try #require(Double(intent.price))
            #expect(side == .buy ? price <= mark * 1.005 : price >= mark * 0.995)
        }
    }
}

@Test func keccakKnownAnswers() {
    #expect(
        Keccak256.hash(Data()).hex
            == "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    #expect(
        Keccak256.hash(Data("abc".utf8)).hex
            == "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
}

@Test func officialProductionActionHash() throws {
    // Official Python SDK tests/signing_test.py, test_phantom_agent_creation_matches_production.
    let wire = ExchangeAction.orderWire(
        assetID: 4, buy: true, price: "1670.1", size: "0.0147", reduceOnly: false, kind: .market)
    let hash = try SigningPayload.actionHash(
        action: ExchangeAction.orderAction(wires: [wire]), nonce: 1_677_777_606_040)
    #expect(hash.hex == "0x0fcbeda5ae3c4950a548021552a4fea2226858c4453571bf3f24ba017eac2908")
}

@Test func signingBindsNonceVaultExpiryAndNetwork() throws {
    let action = ExchangeAction.leverage(assetID: 1, value: 5, cross: true)
    let hash = try SigningPayload.actionHash(action: action, nonce: 1)
    #expect(hash != (try SigningPayload.actionHash(action: action, nonce: 2)))
    #expect(hash != (try SigningPayload.actionHash(action: action, nonce: 1, expiresAfter: 123)))
    #expect(
        hash
            != (try SigningPayload.actionHash(
                action: action, nonce: 1, vaultAddress: "0x1111111111111111111111111111111111111111"
            )))
    let main = try SigningPayload.typedData(action: action, nonce: 1, environment: .mainnet)
    let test = try SigningPayload.typedData(action: action, nonce: 1, environment: .testnet)
    #expect(main["message"]["source"].string == "a")
    #expect(test["message"]["source"].string == "b")
    #expect(main["domain"]["chainId"].double == 1337)
    #expect(throws: APIError.self) {
        try SigningPayload.actionHash(action: action, nonce: 1, vaultAddress: "bad")
    }
}

@Test func messagePackBoundaryAndKeyOrder() throws {
    #expect(WireValue.uint(127).messagePack().hex == "0x7f")
    #expect(WireValue.uint(128).messagePack().hex == "0xcc80")
    #expect(WireValue.uint(65536).messagePack().hex == "0xce00010000")
    #expect(WireValue.uint(UInt64.max).messagePack().hex == "0xcfffffffffffffffff")
    #expect(
        WireValue.string(String(repeating: "a", count: 32)).messagePack().prefix(2).hex == "0xd920")
    let first = WireValue.map([("a", .uint(1)), ("b", .bool(true))])
    let second = WireValue.map([("b", .bool(true)), ("a", .uint(1))])
    #expect(first.messagePack() != second.messagePack())
    // Preserve UTF-8 replacement decoding; encoded JSON is UTF-8 and error text may be invalid.
    // swiftlint:disable:next optional_data_string_conversion
    #expect(String(decoding: try first.jsonData(), as: UTF8.self) == "{\"a\":1,\"b\":true}")
}

@Test func sizeAlwaysRoundsDown() throws {
    #expect(try OrderPlanner.normalizeSize("1.234567", decimals: 4) == "1.2345")
    #expect(try OrderPlanner.normalizeSize("1.00", decimals: 4) == "1")
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.normalizeSize("0.00001", decimals: 4)
    }
}

@Test func priceRulesAndIntegerException() throws {
    #expect(try OrderPlanner.normalizePrice("1234.56", market: eth) == "1234.6")
    #expect(try OrderPlanner.normalizePrice("123456", market: eth) == "123456")
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.normalizePrice("0.00123456", market: eth)
    }
    let lowPrice = Market(
        coin: "TEST", symbol: "TEST", assetID: 2, sizeDecimals: 1, maxLeverage: 3, kind: .perp)
    #expect(try OrderPlanner.normalizePrice("0.00123456", market: lowPrice) == "0.00123")
}

@Test func spotPriceAndMinimumNotional() throws {
    #expect(try OrderPlanner.normalizePrice("0.000123456", market: hypeSpot) == "0.000123")
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.preview(
            market: eth, side: .buy, kind: .limit, size: "9.99", isUSD: true, price: "100",
            trigger: nil, mark: 100,
            leverage: 1, reduceOnly: false)
    }
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.preview(
            market: hypeSpot, side: .sell, kind: .stop, size: "1", isUSD: false, price: "50",
            trigger: "50", mark: 50,
            leverage: 1, reduceOnly: true)
    }
}

@Test func marketPreviewUsesIOCSlippageAndUSDSize() throws {
    let buy = try OrderPlanner.preview(
        market: eth, side: .buy, kind: .market, size: "500", isUSD: true, price: "", trigger: nil,
        mark: 2000,
        leverage: 5, reduceOnly: false)
    #expect(buy.size == "0.25")
    #expect(buy.price == "2010")
    let sell = try OrderPlanner.preview(
        market: eth, side: .sell, kind: .market, size: "500", isUSD: true, price: "", trigger: nil,
        mark: 2000,
        leverage: 5, reduceOnly: false)
    #expect(sell.price == "1990")
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.preview(
            market: eth, side: .buy, kind: .market, size: "500", isUSD: true, price: "",
            trigger: nil, mark: .nan,
            leverage: 5, reduceOnly: false)
    }
}

@Test func inputsRejectInvalidNumbers() {
    for raw in ["", "NaN", "Inf", "-1", "1,000", "1e3", "0", "1.2.3"] {
        #expect(throws: OrderValidationError.self) {
            try OrderPlanner.normalizeSize(raw, decimals: 4)
        }
    }
}

@Test func addressesAndFuzzySearch() {
    #expect(Address.isValid("0x1111111111111111111111111111111111111111"))
    #expect(!Address.isValid("0x1111"))
    #expect(!Address.isValid("0xGG11111111111111111111111111111111111111"))
    #expect(MarketSearch.results("et", markets: [hypeSpot, eth]).first?.coin == "ETH")
    #expect(MarketSearch.results("hp", markets: [hypeSpot, eth]).first?.coin == "@107")
    #expect(MarketSearch.results("notamarket", markets: [eth]).isEmpty)
}

@Test func catalogPreservesAssetIDsAcrossDelistingAndSpotIndex() throws {
    let perp = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            #"[{"universe":[{"name":"OLD","szDecimals":1,"maxLeverage":3,"isDelisted":true},{"name":"ETH","szDecimals":4,"maxLeverage":50}]},[{"markPx":"1","prevDayPx":"1","dayNtlVlm":"0"},{"markPx":"2000","prevDayPx":"1900","dayNtlVlm":"50000"}]]"#
                .utf8))
    let spot = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            #"[{"tokens":[{"name":"USDC","index":0,"szDecimals":8},{"name":"HYPE","index":150,"szDecimals":2}],"universe":[{"name":"@107","index":107,"tokens":[150,0]}]},[{"markPx":"50","prevDayPx":"49","dayNtlVlm":"10000"}]]"#
                .utf8))
    let catalog = try HyperliquidAPI.parseCatalog(perp: perp, spot: spot)
    #expect(catalog.markets.count == 2)
    #expect(catalog.markets[0].assetID == 1)
    #expect(catalog.markets[1].assetID == 10107)
    #expect(catalog.markets[1].coin == "@107")
    #expect(catalog.contexts["@107"]?.price == 50)
}

@Test func catalogPreservesExplicitMarginRulesIndependentlyOfDeprecatedIsolationFlag() throws {
    let specifications: [(String?, Bool, Bool, Bool)] = [
        (nil, false, false, true), (nil, true, true, false),
        ("noCross", false, true, true), ("noCross", true, true, true),
        ("strictIsolated", false, true, false), ("strictIsolated", true, true, false),
        ("futureMode", false, false, false)
    ]
    let universe = specifications.enumerated().map { index, item -> JSONValue in
        var raw: [String: JSONValue] = [
            "name": .string("COIN\(index)"), "szDecimals": .integer(4),
            "maxLeverage": .integer(25), "onlyIsolated": .bool(item.1)
        ]
        if let mode = item.0 { raw["marginMode"] = .string(mode) }
        return .object(raw)
    }
    let catalog = try HyperliquidAPI.parseCatalog(
        perp: .array([.object(["universe": .array(universe)]), .array([])]),
        spot: .array([.object(["tokens": .array([]), "universe": .array([])]), .array([])]))
    #expect(catalog.markets.count == specifications.count)
    for (index, market) in catalog.markets.enumerated() {
        let expected = specifications[index]
        #expect(market.assetID == index && market.marginMode == expected.0)
        #expect(market.onlyIsolated == expected.2)
        #expect(market.allowsIsolatedMarginRemoval == expected.3)
        #expect(try JSONDecoder().decode(Market.self, from: JSONEncoder().encode(market)) == market)
    }
    let legacy = try JSONValue.object([
        "coin": .string("ETH"), "symbol": .string("ETH"), "assetID": .integer(1),
        "sizeDecimals": .integer(4), "maxLeverage": .integer(25), "kind": .string("perp"),
        "onlyIsolated": .bool(true), "isStablePair": .bool(false)
    ]).decode(Market.self)
    #expect(legacy.marginMode == nil && !legacy.allowsIsolatedMarginRemoval)
}

@Test func catalogRejectsMalformedMarginMetadataRatherThanInferringUnrestrictedMode() {
    for (key, value) in [
        ("marginMode", JSONValue.bool(false)), ("marginMode", .integer(0)),
        ("onlyIsolated", .string("false")), ("onlyIsolated", .integer(0))
    ] {
        var raw: [String: JSONValue] = [
            "name": .string("ETH"), "szDecimals": .integer(4), "maxLeverage": .integer(25)
        ]
        raw[key] = value
        #expect(throws: APIError.self) {
            try HyperliquidAPI.parseCatalog(
                perp: .array([.object(["universe": .array([.object(raw)])]), .array([])]),
                spot: .array([.object(["tokens": .array([]), "universe": .array([])]), .array([])]))
        }
    }
}

@Test func walletSignatureValidatesLengthAndRecovery() throws {
    let raw = "0x" + String(repeating: "01", count: 64) + "00"
    let signature = try WalletSignature(hex: raw)
    #expect(signature.v == 27)
    #expect(signature.r.count == 66)
    #expect(throws: APIError.self) { try WalletSignature(hex: "0x1234") }
    #expect(throws: APIError.self) {
        try WalletSignature(hex: "0x" + String(repeating: "00", count: 64) + "1b")
    }
}
