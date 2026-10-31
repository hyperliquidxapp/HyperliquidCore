import Foundation
import Testing

@testable import HyperliquidCore

private let riskAddress = "0x5742261Ef0516AD70C4217cc573fa21485289D3B"
private let riskMarket = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 20, kind: .perp)
private func riskJSON(_ raw: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
}
private func riskPosition(
    size: String = "1", mode: String = "cross", cash: String? = nil, entry: String = "80",
    markValue: String = "100",
    margin: String = "10", coin: String = "ETH"
) -> JSONValue {
    var leverage: [String: JSONValue] = ["type": .string(mode), "value": .integer(10)]
    if let cash { leverage["rawUsd"] = .string(cash) }
    return .object([
        "position": .object([
            "coin": .string(coin), "szi": .string(size), "entryPx": .string(entry),
            "positionValue": .string(markValue), "marginUsed": .string(margin),
            "unrealizedPnl": .string("0"),
            "returnOnEquity": .string("0"), "leverage": .object(leverage)
        ])
    ])
}
private func riskAccount(
    positions: [JSONValue] = [], equity: String = "50", margin: String = "0",
    maintenance: String? = "0",
    includeCross: Bool = true
) throws -> AccountState {
    let summary = JSONValue.object([
        "accountValue": .string(equity), "totalMarginUsed": .string(margin),
        "totalNtlPos": .string("0")
    ])
    var state: [String: JSONValue] = [
        "assetPositions": .array(positions), "marginSummary": summary, "withdrawable": .string("0"),
        "time": .integer(100)
    ]
    if includeCross { state["crossMarginSummary"] = summary }
    if let maintenance { state["crossMaintenanceMarginUsed"] = .string(maintenance) }
    return try JSONValue.object(state).decode(AccountState.self)
}
private func riskAsset(
    mode: String = "cross", leverage: Int = 10, available: String = "100", cash: String? = nil
)
throws -> ActiveAssetData {
    var settings: [String: JSONValue] = ["type": .string(mode), "value": .integer(Int64(leverage))]
    if let cash { settings["rawUsd"] = .string(cash) }
    return try JSONValue.object([
        "user": .string(riskAddress), "coin": .string("ETH"), "leverage": .object(settings),
        "maxTradeSzs": .array([.string("100"), .string("100")]),
        "availableToTrade": .array([.string(available), .string(available)]),
        "markPx": .string("100")
    ]).decode(ActiveAssetData.self)
}
private func riskIntent(
    side: OrderSide = .buy, size: String = "1", price: String = "100", leverage: Int = 10,
    reduceOnly: Bool = false
) throws -> OrderIntent {
    try OrderPlanner.preview(
        market: riskMarket, side: side, kind: .limit, size: size, isUSD: false, price: price,
        trigger: nil, mark: 100, leverage: leverage, reduceOnly: reduceOnly)
}
private func riskFees(_ amount: Decimal = 0) -> OrderFeeEstimate {
    OrderFeeEstimate(lower: amount, upper: amount, maximumRate: 0)
}
private func estimate(
    _ intent: OrderIntent, account: AccountState, asset: ActiveAssetData? = nil, fees: Decimal = 0
)
throws -> OrderRiskEstimate {
    try OrderRiskEstimate.preview(
        intent: intent, address: riskAddress, account: account, asset: asset ?? riskAsset(),
        table: MarginTable(id: 20, bounds: [(0, 20)]), abstraction: "default", fees: riskFees(fees))
}
private func near(
    _ lhs: Decimal, _ rhs: Decimal, tolerance: Decimal = Decimal(string: "0.000000000001")!
) -> Bool {
    abs(lhs - rhs) < tolerance
}

@Test func riskMarginTierDeductionIsContinuousAndUsesActualIDs() throws {
    let meta = try riskJSON(
        #"{"universe":[{"name":"BTC","maxLeverage":40},{"name":"ETH","maxLeverage":20,"marginTableId":57}],"marginTables":[[99,{"marginTiers":[{"lowerBound":"0","maxLeverage":10}]}],[57,{"marginTiers":[{"lowerBound":"0","maxLeverage":20},{"lowerBound":"1000","maxLeverage":10},{"lowerBound":"2000","maxLeverage":5}]}]]}"#
    )
    let table = try MarginTable.parse(meta: meta, market: riskMarket)
    #expect(table.id == 57)
    #expect(table.tiers.map(\.maintenanceDeduction) == [0, 25, 125])
    #expect(try table.maintenance(at: 999) == Decimal(string: "24.975"))
    #expect(try table.maintenance(at: 1000) == 25)
    #expect(try table.maintenance(at: 2000) == 75)
    #expect(try table.maintenance(at: 3000) == 175)
    #expect(try table.tier(at: 1000).maxLeverage == 10)
    let implicit = try riskJSON(#"{"universe":[{}, {"name":"ETH","maxLeverage":20}]}"#)
    #expect(try MarginTable.parse(meta: implicit, market: riskMarket).tiers.count == 1)
}

@Test func riskMarginMetadataRejectsMissingMalformedAndMismatchedTiers() throws {
    for raw in [
        #"{"universe":[{}, {"name":"BTC","maxLeverage":20}]}"#,
        #"{"universe":[{}, {"name":"ETH","maxLeverage":10}]}"#,
        #"{"universe":[{}, {"name":"ETH","maxLeverage":20,"isDelisted":true}]}"#,
        #"{"universe":[{}, {"name":"ETH","maxLeverage":20,"marginTableId":57}]}"#,
        #"{"universe":[{}, {"name":"ETH","maxLeverage":20,"marginTableId":"20"}]}"#,
        #"{"universe":[{}, {"name":"ETH","maxLeverage":20,"marginTableId":57}],"marginTables":[[57,{}],[57,{}]]}"#,
        #"{"universe":[{}, {"name":"ETH","maxLeverage":20,"marginTableId":57}],"marginTables":[[57,{"marginTiers":[{"lowerBound":0,"maxLeverage":20}]}]]}"#,
        #"{"universe":[{}, {"name":"ETH","maxLeverage":20,"marginTableId":57}],"marginTables":[[57,{"marginTiers":[{"lowerBound":"0","maxLeverage":10}]}]]}"#
    ] {
        #expect(throws: OrderValidationError.self) {
            try MarginTable.parse(meta: riskJSON(raw), market: riskMarket)
        }
    }
    for bounds: [(Decimal, Int)] in [
        [], [(1, 20)], [(0, 0)], [(0, 20), (0, 10)], [(0, 20), (100, 40)], [(0, 20), (.nan, 10)]
    ] {
        #expect(throws: OrderValidationError.self) { try MarginTable(id: 20, bounds: bounds) }
    }
}

@Test func riskLiquidationSolvesThePriceTierInsteadOfTheCurrentTier() throws {
    let table = try MarginTable(id: 57, bounds: [(0, 20), (1000, 10), (2000, 5)])
    // Long starts in tier two, liquidates below it: (1100 - 300) / .975.
    let lower = try #require(try table.liquidationPrice(mark: 1100, signedSize: 1, equity: 300))
    #expect(near(lower, 800 / Decimal(string: "0.975")!))
    #expect(try table.tier(at: lower).maxLeverage == 20)
    // Short starts in tier one, liquidates in tier two: (900 + 300 + 25) / 1.05.
    let higher = try #require(try table.liquidationPrice(mark: 900, signedSize: -1, equity: 300))
    #expect(near(higher, 1225 / Decimal(string: "1.05")!))
    #expect(try table.tier(at: higher).maxLeverage == 10)
    // Exact boundary belongs to the upper tier; continuity must preserve its root.
    #expect(try table.liquidationPrice(mark: 1100, signedSize: 1, equity: 125) == 1000)
    #expect(try table.liquidationPrice(mark: 900, signedSize: -1, equity: 125) == 1000)
    for (signed, price, equity, other) in [
        (Decimal(1), Decimal(1100), Decimal(300), Decimal(0)), (-1, 900, 300, 0),
        (2, 1100, 400, 100),
        (-2, 1100, 400, 100)
    ] {
        let root = try #require(
            try table.liquidationPrice(
                mark: price, signedSize: signed, equity: equity, otherMaintenance: other))
        let rootEquity = equity + signed * (root - price)
        #expect(near(rootEquity, try table.maintenance(at: abs(signed) * root) + other))
    }
}

@Test func riskLiquidationHandlesZeroExposureOvercollateralizationAndTinyPrices() throws {
    let table = try MarginTable(id: 20, bounds: [(0, 20)])
    #expect(try table.liquidationPrice(mark: 100, signedSize: 0, equity: 0) == nil)
    #expect(try table.liquidationPrice(mark: 100, signedSize: 1, equity: 100) == nil)
    #expect(try table.liquidationPrice(mark: 100, signedSize: 1, equity: 200) == nil)
    let tiny = Decimal(string: "0.000000000000000000000000000001")!
    let root = try #require(try table.liquidationPrice(mark: tiny, signedSize: 1, equity: 0))
    #expect(root > 0)
    #expect(near(root * Decimal(string: "0.975")!, tiny, tolerance: tiny / 1000))
    let huge = Decimal(string: "1000000000000000000000000")!
    let scaled = try #require(try table.liquidationPrice(mark: huge, signedSize: 2, equity: huge))
    #expect(near(scaled / huge, 1 / Decimal(string: "1.95")!))
    for bad in [Decimal.nan, 0, -1] {
        #expect(throws: OrderValidationError.self) {
            try table.liquidationPrice(mark: bad, signedSize: 1, equity: 10)
        }
    }
    #expect(throws: OrderValidationError.self) {
        try table.liquidationPrice(mark: 100, signedSize: 1, equity: 10, otherMaintenance: -1)
    }
}

@Test func riskCrossOpeningUsesSharedEquityAndRemainsIndependentOfConfiguredLeverage() throws {
    let account = try riskAccount()
    let long = try estimate(riskIntent(), account: account, fees: 1)
    #expect(long.resultingSignedSize == 1 && long.resultingEntryPrice == 100)
    #expect(long.projectedEquity == 49)
    #expect(
        long.initialMarginRequired == 10 && long.maintenanceMarginRequired == Decimal(string: "2.5")
    )
    #expect(near(try #require(long.liquidationPrice), 51 / Decimal(string: "0.975")!))
    let lowerLeverage = try estimate(riskIntent(leverage: 5), account: account, fees: 1)
    #expect(long.liquidationPrice == lowerLeverage.liquidationPrice)
    #expect(lowerLeverage.initialMarginRequired == 20)
    let short = try estimate(riskIntent(side: .sell), account: account, fees: 1)
    #expect(short.resultingSignedSize == -1)
    #expect(near(try #require(short.liquidationPrice), 149 / Decimal(string: "1.025")!))
    #expect(try #require(long.liquidationDistance) > 0 && #require(short.liquidationDistance) > 0)
    let unfunded = try estimate(riskIntent(), account: riskAccount(equity: "0"))
    #expect(unfunded.additionalMarginRequired == 10 && unfunded.belowMaintenance)
    #expect(try #require(unfunded.liquidationDistance) < 0)
    let rebate = try estimate(riskIntent(), account: account, fees: -1)
    #expect(rebate.projectedEquity == 51)
}

@Test func riskCrossProjectionRetainsOtherMaintenanceAndRevaluesOnlyTheSelectedPosition() throws {
    let position = riskPosition()
    let other = riskPosition(size: "2", markValue: "200", margin: "20", coin: "BTC")
    let account = try riskAccount(
        positions: [position, other], equity: "50", margin: "30", maintenance: "7.5")
    let result = try estimate(riskIntent(price: "120"), account: account)
    #expect(result.resultingSignedSize == 2 && result.resultingEntryPrice == 100)
    #expect(result.projectedEquity == 70)  // Existing ETH rises 20; other market stays fixed.
    #expect(result.initialMarginRequired == 44)  // BTC 20 + ETH 240/10.
    #expect(result.maintenanceMarginRequired == 11)  // BTC 5 + ETH 240*.025.
    #expect(near(try #require(result.liquidationPrice), 175 / Decimal(string: "1.95")!))
    let closed = try estimate(riskIntent(side: .sell, reduceOnly: true), account: account)
    #expect(
        closed.resultingSignedSize == 0 && closed.resultingEntryPrice == nil
            && closed.liquidationPrice == nil)
    #expect(closed.initialMarginRequired == 20 && closed.maintenanceMarginRequired == 5)
    let reduced = try estimate(
        riskIntent(side: .sell, size: "0.5", reduceOnly: true), account: account)
    #expect(reduced.resultingEntryPrice == 80)
    let reverse = try estimate(riskIntent(side: .sell, size: "2"), account: account)
    #expect(reverse.resultingSignedSize == -1 && reverse.resultingEntryPrice == 100)
}

@Test func riskIsolatedProjectionAllocatesOpeningMarginAndReleasesClosingMarginProportionally()
throws {
    let asset = try riskAsset(mode: "isolated")
    let empty = try riskAccount(equity: "9999")  // Unrelated account equity cannot protect isolated positions.
    let opened = try estimate(riskIntent(), account: empty, asset: asset, fees: 1)
    #expect(opened.projectedEquity == 9)
    #expect(near(try #require(opened.liquidationPrice), 91 / Decimal(string: "0.975")!))
    let short = try estimate(riskIntent(side: .sell), account: empty, asset: asset)
    #expect(short.projectedEquity == 10)
    #expect(near(try #require(short.liquidationPrice), 110 / Decimal(string: "1.025")!))
    let existing = try riskAccount(positions: [riskPosition(mode: "isolated", cash: "-80")])  // 20 equity at mark 100.
    let addition = try estimate(riskIntent(), account: existing, asset: asset, fees: 1)
    #expect(addition.projectedEquity == 29 && addition.resultingEntryPrice == 90)
    let partial = try estimate(
        riskIntent(side: .sell, size: "0.5", reduceOnly: true), account: existing, asset: asset,
        fees: 1)
    #expect(partial.projectedEquity == 9 && partial.resultingEntryPrice == 80)
    #expect(near(try #require(partial.liquidationPrice), 41 / Decimal(string: "0.4875")!))
    let reverse = try estimate(riskIntent(side: .sell, size: "2"), account: existing, asset: asset)
    #expect(
        reverse.resultingSignedSize == -1 && reverse.projectedEquity == 10
            && reverse.resultingEntryPrice == 100)
    let closed = try estimate(
        riskIntent(side: .sell, reduceOnly: true), account: existing, asset: asset, fees: 1)
    #expect(closed.projectedEquity == 0 && closed.liquidationPrice == nil)
    let noFreeMargin = try riskAsset(mode: "isolated", available: "0")
    let unfundedClose = try estimate(
        riskIntent(side: .sell, reduceOnly: true), account: existing, asset: noFreeMargin, fees: 1)
    #expect(unfundedClose.additionalMarginRequired == 0)
    let costlyReduction = try estimate(
        riskIntent(side: .sell, size: "0.5", reduceOnly: true), account: existing,
        asset: noFreeMargin, fees: 10)
    #expect(costlyReduction.additionalMarginRequired == 0 && costlyReduction.belowMaintenance)
    let unfinanced = try estimate(
        riskIntent(), account: empty, asset: riskAsset(mode: "isolated", available: "0"), fees: 1)
    #expect(unfinanced.additionalMarginRequired == 11)
    let lowerLeverage = try estimate(riskIntent(leverage: 5), account: empty, asset: asset)
    #expect(lowerLeverage.projectedEquity == 20)
    #expect(lowerLeverage.liquidationPrice != opened.liquidationPrice)
}

@Test func riskIsolatedPreviewCannotReuseChangedPositionOrReducedCollateralAfterLeverageUpdate()
throws {
    let intent = try riskIntent(leverage: 20)
    let before = try estimate(
        intent, account: riskAccount(positions: [riskPosition(mode: "isolated", cash: "-80")]),
        asset: riskAsset(mode: "isolated"))
    #expect(before.pendingIsolatedLeverage)
    let reduced = try estimate(
        intent, account: riskAccount(positions: [riskPosition(mode: "isolated", cash: "-90")]),
        asset: riskAsset(mode: "isolated", leverage: 20))
    #expect(!reduced.pendingIsolatedLeverage)
    #expect(throws: OrderValidationError.self) { try before.validateCurrent(reduced) }
    let retained = try estimate(
        intent, account: riskAccount(positions: [riskPosition(mode: "isolated", cash: "-80")]),
        asset: riskAsset(mode: "isolated", leverage: 20))
    try before.validateCurrent(retained)
    let changed = try estimate(
        intent,
        account: riskAccount(positions: [riskPosition(size: "2", mode: "isolated", cash: "-80")]),
        asset: riskAsset(mode: "isolated"))
    #expect(throws: OrderValidationError.self) { try before.validateCurrent(changed) }
    let cross = try estimate(intent, account: riskAccount())
    #expect(throws: OrderValidationError.self) { try before.validateCurrent(cross) }
}

@Test func riskExistingIsolatedShortPreservesSignsForAddsReductionsAndReversals() throws {
    let account = try riskAccount(positions: [
        riskPosition(
            size: "-2", mode: "isolated", cash: "240", entry: "120", markValue: "200", margin: "20")
    ])
    let asset = try riskAsset(mode: "isolated")
    let partial = try estimate(
        riskIntent(side: .buy, price: "110", reduceOnly: true), account: account, asset: asset,
        fees: 1)
    #expect(partial.resultingSignedSize == -1 && partial.resultingEntryPrice == 120)
    #expect(partial.projectedEquity == 9)
    #expect(near(try #require(partial.liquidationPrice), 119 / Decimal(string: "1.025")!))
    let addition = try estimate(
        riskIntent(side: .sell, price: "110"), account: account, asset: asset, fees: 1)
    #expect(addition.resultingSignedSize == -3 && addition.projectedEquity == 30)
    #expect(near(try #require(addition.resultingEntryPrice), 350 / Decimal(3)))
    let reverse = try estimate(
        riskIntent(side: .buy, size: "3", price: "110"), account: account, asset: asset, fees: 1)
    #expect(
        reverse.resultingSignedSize == 1 && reverse.projectedEquity == 10
            && reverse.resultingEntryPrice == 110)
}

@Test func riskRejectsIncompleteMixedAccountSnapshotsAndUnsupportedAccountModes() throws {
    let intent = try riskIntent()
    for mode in ["unifiedAccount", "portfolioMargin", "unexpected"] {
        #expect(throws: OrderValidationError.self) {
            try OrderRiskEstimate.preview(
                intent: intent, address: riskAddress, account: riskAccount(), asset: riskAsset(),
                table: MarginTable(id: 20, bounds: [(0, 20)]), abstraction: mode, fees: riskFees())
        }
    }
    let eth = riskPosition()
    let isolated = riskPosition(mode: "isolated", cash: "-80", coin: "BTC")
    let other = riskPosition(coin: "BTC")
    for snapshot in [
        try riskAccount(positions: [eth, eth], margin: "20", maintenance: "5"),
        try riskAccount(positions: [isolated], includeCross: false),
        try riskAccount(positions: [other], maintenance: nil),
        try riskAccount(positions: [eth], margin: "10", maintenance: "0"),
        try riskAccount(positions: [eth], margin: "0", maintenance: "2.5"),
        try riskAccount(positions: [riskPosition(size: "invalid", coin: "BTC")]),
        try riskAccount(positions: [riskPosition(mode: "unexpected", coin: "BTC")])
    ] { #expect(throws: OrderValidationError.self) { try estimate(intent, account: snapshot) } }
    let legacy = try riskAccount(
        positions: [eth], margin: "10", maintenance: nil, includeCross: false)
    #expect(try estimate(intent, account: legacy).maintenanceMarginRequired == 5)
    #expect(throws: OrderValidationError.self) {
        try estimate(
            intent, account: riskAccount(positions: [riskPosition(mode: "isolated")]),
            asset: riskAsset(mode: "isolated"))
    }
    #expect(throws: OrderValidationError.self) {
        try estimate(riskIntent(side: .sell, reduceOnly: true), account: riskAccount())
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"))
func riskLiveMarginTablesDecodeBothNetworksWithoutAssumingDocumentationExampleValues() async throws {
    for environment in [NetworkEnvironment.mainnet, .testnet] {
        let api = HyperliquidAPI(environment: environment)
        let meta = try await api.info(["type": .string("meta")])
        for (index, asset) in meta["universe"].array.enumerated()
        where asset["isDelisted"].bool != true {
            let market = Market(
                coin: try #require(asset["name"].string),
                symbol: try #require(asset["name"].string),
                assetID: index, sizeDecimals: Int(try #require(asset["szDecimals"].int64)),
                maxLeverage: Int(try #require(asset["maxLeverage"].int64)), kind: .perp,
                onlyIsolated: asset["onlyIsolated"].bool ?? false,
                marginMode: asset["marginMode"].string)
            let table = try MarginTable.parse(meta: meta, market: market)
            #expect(
                table.tiers.first?.lowerBound == 0
                    && table.tiers.first?.maxLeverage == market.maxLeverage)
            #expect(try table.maintenance(at: 10000) >= 0)
        }
    }
}

@Test func marginTablesRejectChangedOrMalformedMarketIsolationRules() throws {
    func metadata(_ mode: JSONValue, isolated: JSONValue) -> JSONValue {
        .object([
            "universe": .array([
                .object([
                    "name": .string("ETH"), "maxLeverage": .integer(25),
                    "marginMode": mode, "onlyIsolated": isolated
                ])
            ])
        ])
    }
    let market = Market(
        coin: "ETH", symbol: "ETH", assetID: 0, sizeDecimals: 4, maxLeverage: 25, kind: .perp,
        marginMode: "noCross")
    for isolated in [false, true] {
        #expect(
            try MarginTable.parse(
                meta: metadata(.string("noCross"), isolated: .bool(isolated)), market: market
            ).tiers[0].maxLeverage == 25)
    }
    for meta in [
        metadata(.string("strictIsolated"), isolated: .bool(true)),
        metadata(.null, isolated: .bool(true)), metadata(.null, isolated: .bool(false)),
        metadata(.bool(true), isolated: .bool(true)),
        metadata(.string("noCross"), isolated: .string("true"))
    ] {
        #expect(throws: OrderValidationError.self) {
            try MarginTable.parse(meta: meta, market: market)
        }
    }
}
