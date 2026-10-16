import Foundation
import Testing

@testable import HyperliquidCore

private func reviewJSON(_ raw: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
}
private let reviewSpot = Market(
    coin: "@107", symbol: "HYPE", assetID: 10107, sizeDecimals: 2, maxLeverage: 1, kind: .spot,
    baseTokenIndex: 150,
    quoteTokenIndex: 0)
private let reviewPerp = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 20, kind: .perp)
private func reviewIntent(
    market: Market = reviewSpot, side: OrderSide = .buy, kind: OrderKind = .limit,
    size: String = "1",
    price: String = "100", tif: TimeInForce = .gtc
) throws -> OrderIntent {
    try OrderPlanner.preview(
        market: market, side: side, kind: kind, size: size, isUSD: false, price: price,
        trigger: nil, mark: 100,
        leverage: 1, reduceOnly: false, timeInForce: tif)
}
private func reviewFees(maker: String = "0.0004", referral: String = "0.1") throws -> UserFeeRates {
    try UserFeeRates(
        response: reviewJSON(
            """
            {"userAddRate":"0.00015","userCrossRate":"0.00045","userSpotAddRate":"\(maker)","userSpotCrossRate":"0.0007","activeReferralDiscount":"\(referral)","activeStakingDiscount":{"discount":"0.4"}}
            """))
}

@Test func accountFeeEstimateAppliesReferralWithoutRepeatingStakingDiscount() throws {
    let fees = try reviewFees()
    let limit = try fees.estimate(for: reviewIntent())
    #expect(limit.lower == Decimal(string: "0.036"))
    #expect(limit.upper == Decimal(string: "0.063"))
    let maker = try fees.estimate(for: reviewIntent(tif: .postOnly))
    #expect(maker.lower == maker.upper && maker.upper == limit.lower)
    let taker = try fees.estimate(for: reviewIntent(kind: .market))
    #expect(taker.lower == taker.upper && taker.upper == limit.upper)
    let perp = try fees.estimate(for: reviewIntent(market: reviewPerp, kind: .market))
    #expect(perp.upper == Decimal(string: "0.0405"))
}

@Test func makerRebatesRemainNegativeAndStablePairsApplyTheirOwnScale() throws {
    let stable = Market(
        coin: "@10", symbol: "USD", assetID: 10010, sizeDecimals: 2, maxLeverage: 1, kind: .spot,
        baseTokenIndex: 9,
        quoteTokenIndex: 0, isStablePair: true)
    let fees = try reviewFees(maker: "-0.00001", referral: "0.2")
    let estimate = try fees.estimate(for: reviewIntent(market: stable))
    #expect(estimate.lower == Decimal(string: "-0.0002"))
    #expect(estimate.upper == Decimal(string: "0.0112"))
}

@Test func higherFeesRequireNewReviewAndInvalidRatesAreRejected() throws {
    let intent = try reviewIntent(kind: .market)
    let old = try reviewFees(referral: "0.1").estimate(for: intent)
    let increased = try reviewFees(referral: "0").estimate(for: intent)
    #expect(throws: OrderValidationError.self) { try old.validate(current: increased) }
    try increased.validate(current: old)
    #expect(throws: OrderValidationError.self) { try reviewFees(maker: "NaN") }
    #expect(throws: OrderValidationError.self) { try reviewFees(referral: "1.01") }
    #expect(throws: OrderValidationError.self) { try ReviewDecimal.parse("12garbage") }
}

@Test func spotBudgetUsesTokenIdentityHeldBalancesAndMarketPriceBound() throws {
    let balances = try reviewJSON(
        #"{"balances":[{"coin":"HYPE","token":999,"total":"999999","hold":"0"},{"coin":"USDC","token":0,"total":"100","hold":"10"},{"coin":"HYPE","token":150,"total":"2","hold":"1"}]}"#
    )
    #expect(try SpotOrderBudget.available(token: 150, balances: balances) == 1)
    try SpotOrderBudget.validate(reviewIntent(size: "0.9"), balances: balances)
    #expect(throws: OrderValidationError.self) {
        try SpotOrderBudget.validate(reviewIntent(size: "0.91"), balances: balances)
    }
    try SpotOrderBudget.validate(reviewIntent(side: .sell), balances: balances)
    #expect(throws: OrderValidationError.self) {
        try SpotOrderBudget.validate(reviewIntent(side: .sell, size: "1.01"), balances: balances)
    }
    let exactly100 = try reviewJSON(#"{"balances":[{"token":0,"total":"100","hold":"0"}]}"#)
    #expect(throws: OrderValidationError.self) {
        try SpotOrderBudget.validate(reviewIntent(kind: .market), balances: exactly100)
    }
    #expect(try SpotOrderBudget.available(token: 150, balances: exactly100) == 0)
}

@Test func spotPercentageRoundsDownAgainstSpendBound() throws {
    let balances = try reviewJSON(
        #"{"balances":[{"token":0,"total":"100","hold":"0"},{"token":150,"total":"1.234","hold":"0.1"}]}"#
    )
    let bound = try OrderPlanner.marketPriceBound(mark: 100, market: reviewSpot, side: .buy)
    let size = try SpotOrderBudget.percentageSize(
        market: reviewSpot, side: .buy, balances: balances, priceBound: bound, percentage: 100)
    #expect(size == "0.99")
    try SpotOrderBudget.validate(reviewIntent(kind: .market, size: size), balances: balances)
    #expect(
        try SpotOrderBudget.percentageSize(
            market: reviewSpot, side: .sell, balances: balances, priceBound: bound, percentage: 25)
            == "0.28")
    #expect(throws: OrderValidationError.self) {
        try SpotOrderBudget.percentageSize(
            market: reviewSpot, side: .buy, balances: balances, priceBound: "0", percentage: 100)
    }
}

@Test func spotModificationReleasesOnlyMatchingOrdersSpendHold() throws {
    let balances = try reviewJSON(
        #"{"balances":[{"token":0,"total":"100","hold":"80"},{"token":150,"total":"1","hold":"1"}]}"#
    )
    let old = OpenOrder(
        coin: "@107", limitPx: "100", sz: "0.8", side: "B", oid: 123, timestamp: 0,
        orderType: "Limit")
    try SpotOrderBudget.validate(reviewIntent(), balances: balances, replacing: old)
    #expect(throws: OrderValidationError.self) {
        try SpotOrderBudget.validate(reviewIntent(size: "1.01"), balances: balances, replacing: old)
    }
    #expect(throws: OrderValidationError.self) {
        try SpotOrderBudget.validate(reviewIntent(side: .sell), balances: balances, replacing: old)
    }
    let wrong = OpenOrder(
        coin: "@9", limitPx: "100", sz: "0.8", side: "B", oid: 123, timestamp: 0, orderType: "Limit"
    )
    #expect(throws: OrderValidationError.self) {
        try SpotOrderBudget.validate(reviewIntent(), balances: balances, replacing: wrong)
    }
}

@Test func malformedSpotBalancesFailClosed() throws {
    for raw in [
        #"{}"#, #"{"balances":[{"token":0,"total":"1","hold":"2"}]}"#,
        #"{"balances":[{"token":0,"total":"1","hold":"0"},{"token":0,"total":"9","hold":"0"}]}"#,
        #"{"balances":[{"token":0,"total":"1e3","hold":"0"}]}"#
    ] {
        #expect(throws: OrderValidationError.self) {
            try SpotOrderBudget.available(token: 0, balances: reviewJSON(raw))
        }
    }
}

@Test func activeAssetDataBindsAccountAndMarketBeforeLeverageUse() throws {
    let address = "0x5742261Ef0516AD70C4217cc573fa21485289D3B"
    let raw = try reviewJSON(
        """
        {"user":"\(address.lowercased())","coin":"ETH","leverage":{"type":"cross","value":20},"maxTradeSzs":["0.0","0.0"],"availableToTrade":["0.0","0.0"],"markPx":"2659.4"}
        """)
    let data = try raw.decode(ActiveAssetData.self)
    try data.validate(address: address, market: reviewPerp)
    #expect(throws: OrderValidationError.self) {
        try data.validate(address: "0x0000000000000000000000000000000000000000", market: reviewPerp)
    }
    #expect(throws: OrderValidationError.self) {
        try data.validate(address: address, market: reviewSpot)
    }
    let intent = try reviewIntent(market: reviewPerp)
    try data.validateLeverage(intent: intent, reviewed: data.leverage, targetApplied: false)
    #expect(throws: OrderValidationError.self) {
        try data.validateLeverage(intent: intent, reviewed: data.leverage, targetApplied: true)
    }
    #expect(throws: OrderValidationError.self) {
        try data.validateLeverage(
            intent: intent, reviewed: Leverage(type: "isolated", value: 20), targetApplied: false)
    }
    #expect(throws: OrderValidationError.self) {
        try data.validateLeverage(intent: intent, reviewed: nil, targetApplied: false)
    }
    let close = try OrderPlanner.preview(
        market: reviewPerp, side: .sell, kind: .market, size: "1", isUSD: false, price: "",
        trigger: nil, mark: 100,
        leverage: 1, reduceOnly: true)
    try data.validateLeverage(intent: close, reviewed: nil, targetApplied: true)
}

@Test func stableSpotClassificationUsesQuoteUsageAndNotTokenNames() throws {
    let perp = try reviewJSON(#"[{"universe":[]},[]]"#)
    let spot = try reviewJSON(
        #"[{"tokens":[{"index":0,"name":"USDC","szDecimals":8},{"index":5,"name":"USD","szDecimals":2},{"index":6,"name":"HYPE","szDecimals":2},{"index":7,"name":"USDC","szDecimals":2}],"universe":[{"index":1,"tokens":[5,0]},{"index":2,"tokens":[6,0]},{"index":3,"tokens":[6,5]},{"index":4,"tokens":[6,7]}]},[]]"#
    )
    let catalog = try HyperliquidAPI.parseCatalog(perp: perp, spot: spot)
    #expect(catalog.markets.count == 2)
    #expect(catalog.markets.first { $0.symbol == "USD" }?.isStablePair == true)
    #expect(catalog.markets.first { $0.symbol == "HYPE" }?.isStablePair == false)
}

@Test func unifiedSpotBudgetRespectsMaintenanceAndOrderHolds() throws {
    let snapshot = try reviewJSON("""
    {"balances":[{"token":0,"total":"200","hold":"40"}],
     "tokenToAvailableAfterMaintenance":[[0,"100"]]}
    """)
    try SpotOrderBudget.validate(reviewIntent(), balances: snapshot, accountMode: "unifiedAccount")
    #expect(try SpotOrderBudget.available(token: 0, balances: snapshot) == 100)
    let replacing = OpenOrder(
        coin: "@107", limitPx: "100", sz: "0.4", side: "B", oid: 1, timestamp: 0, orderType: "Limit")
    #expect(throws: OrderValidationError.self) {
        try SpotOrderBudget.validate(
            reviewIntent(size: "1.1"), balances: snapshot, replacing: replacing, accountMode: "unifiedAccount")
    }
    for mode in ["portfolioMargin", "dexAbstraction", "unknown"] {
        #expect(throws: OrderValidationError.self) {
            try SpotOrderBudget.validate(reviewIntent(), balances: snapshot, accountMode: mode)
        }
    }
}

@Test func unifiedSpotBudgetRequiresValidMaintenanceBalance() throws {
    for limits in ["null", "[]", "[[150,\"100\"]]", "[[0,\"bad\"]]", "[[0,\"100\"],[0,\"200\"]]"] {
        let snapshot = try reviewJSON("""
        {"balances":[{"token":0,"total":"200","hold":"0"}],"tokenToAvailableAfterMaintenance":\(limits)}
        """)
        #expect(throws: OrderValidationError.self) {
            try SpotOrderBudget.validate(reviewIntent(), balances: snapshot, accountMode: "unifiedAccount")
        }
    }
}

@Test func draftOrderValueUsesRoundedQuantityInsteadOfInputDollars() throws {
    let sizing = try OrderPlanner.orderSizing(
        market: reviewSpot, side: .buy, kind: .limit, size: "10.02", isUSD: true,
        price: "33.4", trigger: nil, mark: 33.4)
    #expect(sizing.size == "0.3")
    #expect(Decimal(string: sizing.size)! * Decimal(string: sizing.price)! == Decimal(string: "10.02"))
    let rounded = try OrderPlanner.orderSizing(
        market: reviewSpot, side: .buy, kind: .limit, size: "10.02", isUSD: true,
        price: "33.5", trigger: nil, mark: 33.5)
    #expect(rounded.size == "0.29")
    #expect(Decimal(string: rounded.size)! * Decimal(string: rounded.price)! == Decimal(string: "9.715"))
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.preview(
            market: reviewSpot, side: .buy, kind: .limit, size: "10.02", isUSD: true,
            price: "33.5", trigger: nil, mark: 33.5, leverage: 1, reduceOnly: false)
    }
}

@Test func marketSellCanEstimateAboveMinimumWhilePriceLimitIsBelowIt() throws {
    let sizing = try OrderPlanner.orderSizing(
        market: reviewSpot, side: .sell, kind: .market, size: "1", isUSD: false,
        price: "", trigger: nil, mark: 10.02)
    #expect(sizing.referencePrice == "10.02")
    #expect(Decimal(string: sizing.size)! * Decimal(string: sizing.price)! < 10)
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.preview(
            market: reviewSpot, side: .sell, kind: .market, size: "1", isUSD: false,
            price: "", trigger: nil, mark: 10.02, leverage: 1, reduceOnly: false)
    }
    let intent = try OrderPlanner.preview(
        market: reviewSpot, side: .sell, kind: .market, size: "2", isUSD: false,
        price: "", trigger: nil, mark: 10.02, leverage: 1, reduceOnly: false)
    #expect(intent.price == sizing.price && intent.referencePrice == sizing.referencePrice)
}

@Test func customSlippageUsesSameBoundsForSizingAndPreview() throws {
    for percent in ["0.01", "0.1", "0.5", "1", "2.5", "5", "8", "10"] {
        for side in [OrderSide.buy, .sell] {
            let bound = try OrderPlanner.marketPriceBound(
                mark: 100, market: reviewSpot, side: side, slippagePercent: percent)
            let intent = try OrderPlanner.preview(
                market: reviewSpot, side: side, kind: .market, size: "1", isUSD: false,
                price: "", trigger: nil, mark: 100, leverage: 1, reduceOnly: false,
                slippagePercent: percent)
            #expect(intent.price == bound)
            #expect(intent.slippagePercent == percent)
            let delta = try OrderPlanner.slippageFraction(percent)
            #expect(Decimal(string: bound) == 100 * (side == .buy ? 1 + delta : 1 - delta))
        }
    }
    for invalid in ["", "0", "-1", "0.001", "10.01", "NaN", "1e2", "1,5"] {
        #expect(throws: OrderValidationError.self) {
            try OrderPlanner.marketPriceBound(mark: 100, market: reviewSpot, side: .buy, slippagePercent: invalid)
        }
    }
}
