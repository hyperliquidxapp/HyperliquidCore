import Foundation
import Testing

@testable import HyperliquidCore

private let capacityAddress = "0x5742261Ef0516AD70C4217cc573fa21485289D3B"
private let capacityMarket = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 20, kind: .perp)
private func capacityAsset(
    buy: String = "2", sell: String = "3", buyMargin: String = "20", sellMargin: String = "30",
    leverage: Int = 10,
    coin: String = "ETH", mark: String = "100"
) throws -> ActiveAssetData {
    try JSONDecoder().decode(
        ActiveAssetData.self,
        from: Data(
            """
            {"user":"\(capacityAddress.lowercased())","coin":"\(coin)","leverage":{"type":"cross","value":\(leverage)},"maxTradeSzs":["\(buy)","\(sell)"],"availableToTrade":["\(buyMargin)","\(sellMargin)"],"markPx":"\(mark)"}
            """.utf8))
}
private func capacityIntent(
    side: OrderSide = .buy, quantity: String = "1", price: String = "100", leverage: Int = 10,
    kind: OrderKind = .market, trigger: String? = nil, execution: TriggerExecution = .market,
    reduceOnly: Bool = false,
    market: Market = capacityMarket
) throws -> OrderIntent {
    try OrderPlanner.preview(
        market: market, side: side, kind: kind, size: quantity, isUSD: false, price: price,
        trigger: trigger, mark: 100, leverage: leverage, reduceOnly: reduceOnly,
        triggerExecution: execution)
}
private func capacityPosition(_ signed: String, coin: String = "ETH") throws -> Position {
    try JSONDecoder().decode(
        Position.self,
        from: Data(
            """
            {"coin":"\(coin)","szi":"\(signed)","entryPx":"100","liquidationPx":"50","positionValue":"100","unrealizedPnl":"0","returnOnEquity":"0","marginUsed":"10","leverage":{"type":"cross","value":10}}
            """.utf8))
}

@Test func perpCapacitySelectsDirectionAndRoundsDownAtExactDecimalBoundary() throws {
    let asset = try capacityAsset(
        buy: "1.23456789", sell: "3.98765432", buyMargin: "12.3456789", sellMargin: "39.8765432")
    let buy = try PerpTradingCapacity(
        asset: asset, address: capacityAddress, market: capacityMarket, side: .buy)
    let sell = try PerpTradingCapacity(
        asset: asset, address: capacityAddress, market: capacityMarket, side: .sell)
    #expect(buy.maximumSize == Decimal(string: "1.2345"))
    #expect(buy.availableMargin == Decimal(string: "12.3456789"))
    #expect(sell.maximumSize == Decimal(string: "3.9876"))
    #expect(sell.availableMargin == Decimal(string: "39.8765432"))
    try buy.validate(capacityIntent(quantity: "1.2345"))
    #expect(throws: OrderValidationError.self) {
        try buy.validate(capacityIntent(quantity: "1.2346"))
    }
    try sell.validate(capacityIntent(side: .sell, quantity: "3.9876"))
    #expect(throws: OrderValidationError.self) {
        try sell.validate(capacityIntent(side: .sell, quantity: "3.9877"))
    }
}

@Test func perpLimitCapacityUsesTheOfficialDirectionalPriceAdjustment() throws {
    let asset = try capacityAsset(buy: "2", sell: "2")
    for (side, price, expected) in [
        (OrderSide.buy, "50", 4), (.buy, "200", 2), (.sell, "50", 2), (.sell, "200", 1)
    ] {
        let capacity = try PerpTradingCapacity(
            asset: asset, address: capacityAddress, market: capacityMarket, side: side,
            limitPrice: price)
        #expect(capacity.maximumSize == Decimal(expected))
        try capacity.validate(
            capacityIntent(side: side, quantity: String(expected), price: price, kind: .limit))
        #expect(throws: OrderValidationError.self) {
            try capacity.validate(
                capacityIntent(
                    side: side, quantity: String(expected + 1), price: price, kind: .limit))
        }
    }
    #expect(throws: OrderValidationError.self) {
        try PerpTradingCapacity(
            asset: asset, address: capacityAddress, market: capacityMarket, side: .buy,
            limitPrice: "0")
    }
}

@Test func perpCapacityDoesNotTreatIOCOrFutureTriggerBoundsAsLimitPrices() throws {
    let asset = try capacityAsset()
    let immediate = try capacityIntent(quantity: "2")
    #expect(immediate.price == "100.5")
    #expect(PerpTradingCapacity.limitPrice(for: immediate) == nil)
    let conditional = try capacityIntent(quantity: "2", kind: .stop, trigger: "200")
    #expect(conditional.price == "220")
    #expect(PerpTradingCapacity.limitPrice(for: conditional) == nil)
    let capacity = try PerpTradingCapacity(
        asset: asset, address: capacityAddress, market: capacityMarket, side: .buy)
    try capacity.validate(immediate)
    try capacity.validate(conditional)
    let triggerLimit = try capacityIntent(
        price: "180", kind: .stop, trigger: "200", execution: .limit)
    #expect(PerpTradingCapacity.limitPrice(for: triggerLimit) == "180")
}

@Test func reversalChecksItsWholeQuantityWithoutAddingClosingCapacityAgain() throws {
    let position = try capacityPosition("10")
    let draft = try PositionOrderDraft.prepare(
        position: position, market: capacityMarket, purpose: .reverse)
    let intent = try OrderPlanner.preview(
        market: capacityMarket, side: draft.side, kind: draft.kind, size: draft.size,
        isUSD: false, price: "", trigger: nil, mark: 100, leverage: draft.leverage,
        reduceOnly: false,
        positionGuard: draft.guardValue)
    #expect(intent.size == "20")
    try intent.validatePosition(position)
    let constrained = try PerpTradingCapacity(
        asset: capacityAsset(sell: "15"), address: capacityAddress, market: capacityMarket,
        side: .sell)
    #expect(throws: OrderValidationError.self) { try constrained.validate(intent) }
    let adequate = try PerpTradingCapacity(
        asset: capacityAsset(sell: "20"), address: capacityAddress, market: capacityMarket,
        side: .sell)
    try adequate.validate(intent)
}

@Test func capacityShrinkOrUnappliedLeverageRequiresFreshTradingReview() throws {
    let intent = try capacityIntent(quantity: "1.5")
    let reviewed = try PerpTradingCapacity(
        asset: capacityAsset(buy: "2"), address: capacityAddress, market: capacityMarket, side: .buy
    )
    try reviewed.validate(intent)
    let afterApproval = try PerpTradingCapacity(
        asset: capacityAsset(buy: "1"), address: capacityAddress, market: capacityMarket, side: .buy
    )
    #expect(throws: OrderValidationError.self) { try afterApproval.validate(intent) }
    #expect(throws: OrderValidationError.self) {
        try reviewed.validate(capacityIntent(leverage: 5))
    }
    let newConfiguration = try PerpTradingCapacity(
        asset: capacityAsset(leverage: 5), address: capacityAddress, market: capacityMarket,
        side: .buy)
    try newConfiguration.validate(capacityIntent(leverage: 5))
}

@Test func perpCapacityCannotBeReusedForAnotherMarketSidePriceOrAccount() throws {
    let asset = try capacityAsset()
    #expect(throws: OrderValidationError.self) {
        try PerpTradingCapacity(
            asset: asset, address: "0x0000000000000000000000000000000000000000",
            market: capacityMarket, side: .buy)
    }
    let capacity = try PerpTradingCapacity(
        asset: asset, address: capacityAddress, market: capacityMarket, side: .buy, limitPrice: "50"
    )
    #expect(throws: OrderValidationError.self) {
        try capacity.validate(capacityIntent(side: .sell, price: "50", kind: .limit))
    }
    #expect(throws: OrderValidationError.self) {
        try capacity.validate(capacityIntent(price: "100", kind: .limit))
    }
    let other = Market(
        coin: "BTC", symbol: "BTC", assetID: 0, sizeDecimals: 4, maxLeverage: 20, kind: .perp)
    #expect(throws: OrderValidationError.self) {
        try capacity.validate(capacityIntent(price: "50", kind: .limit, market: other))
    }
    for invalid in [
        try capacityAsset(buy: "-1"), try capacityAsset(mark: "0"), try capacityAsset(coin: "BTC")
    ] {
        #expect(throws: OrderValidationError.self) {
            try PerpTradingCapacity(
                asset: invalid, address: capacityAddress, market: capacityMarket, side: .buy)
        }
    }
}

@Test func perpPercentagesUseDirectionalCapacityAndNeverRoundUp() throws {
    let asset = try capacityAsset(buy: "3.99996", sell: "8.76549")
    let capacity = try PerpTradingCapacity(
        asset: asset, address: capacityAddress, market: capacityMarket, side: .buy)
    for (percent, expected) in [(25, "0.9999"), (50, "1.9999"), (75, "2.9999"), (100, "3.9999")] {
        let quantity = try capacity.percentageSize(requestedLeverage: 10, percentage: percent)
        #expect(quantity == expected)
        try capacity.validate(capacityIntent(quantity: quantity))
    }
    for invalid in [0, 101] {
        #expect(throws: OrderValidationError.self) {
            try capacity.percentageSize(requestedLeverage: 10, percentage: invalid)
        }
    }
    let empty = try PerpTradingCapacity(
        asset: capacityAsset(buy: "0", buyMargin: "0"), address: capacityAddress,
        market: capacityMarket, side: .buy)
    #expect(throws: OrderValidationError.self) {
        try empty.percentageSize(requestedLeverage: 10, percentage: 100)
    }
}

@Test func differentLeveragePercentageIsOnlyAnAvailableMarginEstimate() throws {
    let capacity = try PerpTradingCapacity(
        asset: capacityAsset(buy: "3.5", buyMargin: "100"), address: capacityAddress,
        market: capacityMarket, side: .buy
    )
    let estimate = try capacity.percentageSize(requestedLeverage: 5, percentage: 100)
    #expect(estimate == "5")
    // A tiered cap can differ from the margin estimate. The unapplied snapshot
    // cannot validate it, and a fresh post-change cap of four rejects it too.
    let intent = try capacityIntent(quantity: estimate, leverage: 5)
    #expect(throws: OrderValidationError.self) { try capacity.validate(intent) }
    let actual = try PerpTradingCapacity(
        asset: capacityAsset(buy: "4", buyMargin: "100", leverage: 5), address: capacityAddress,
        market: capacityMarket,
        side: .buy)
    #expect(throws: OrderValidationError.self) { try actual.validate(intent) }
    #expect(throws: OrderValidationError.self) {
        try capacity.percentageSize(requestedLeverage: 21, percentage: 100)
    }
}

@Test func manualReduceOnlyRequiresTheCurrentOppositePositionAndCanCloseAtZeroCapacity() throws {
    let asset = try capacityAsset(buy: "0", sell: "0", buyMargin: "-1", sellMargin: "-2")
    let budget = try PerpTradingCapacity(
        asset: asset, address: capacityAddress, market: capacityMarket, side: .buy)
    #expect(budget.availableMargin == 0)
    #expect(throws: OrderValidationError.self) {
        try budget.percentageSize(requestedLeverage: 5, percentage: 100)
    }
    for signed in ["1", "-1"] {
        let closingSide: OrderSide = signed == "1" ? .sell : .buy
        let intent = try capacityIntent(side: closingSide, reduceOnly: true)
        try intent.validatePosition(capacityPosition(signed))
        try PerpTradingCapacity(
            asset: asset, address: capacityAddress, market: capacityMarket, side: closingSide
        )
        .validate(intent)
        #expect(throws: OrderValidationError.self) { try intent.validatePosition(nil) }
        #expect(throws: OrderValidationError.self) {
            try intent.validatePosition(capacityPosition("0"))
        }
        #expect(throws: OrderValidationError.self) {
            try intent.validatePosition(capacityPosition(signed == "1" ? "-1" : "1"))
        }
        #expect(throws: OrderValidationError.self) {
            try intent.validatePosition(capacityPosition(signed, coin: "BTC"))
        }
        #expect(throws: OrderValidationError.self) {
            try intent.validatePosition(capacityPosition(signed == "1" ? "0.5" : "-0.5"))
        }
    }
}
