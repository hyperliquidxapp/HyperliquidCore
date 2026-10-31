import Foundation
import Testing

@testable import HyperliquidCore

private let market = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 50, kind: .perp)
private func position(_ size: String = "1.2345") throws -> Position {
    Position(
        coin: "ETH", szi: size, entryPx: "2000", liquidationPx: "1500", positionValue: "2469",
        unrealizedPnl: "0",
        returnOnEquity: "0", marginUsed: "493.8", leverage: Leverage(type: "cross", value: 5))
}
private func preview(_ draft: PositionOrderDraft, trigger: String? = nil) throws -> OrderIntent {
    try OrderPlanner.preview(
        market: market, side: draft.side, kind: draft.kind, size: draft.size, isUSD: false,
        price: "2000", trigger: trigger, mark: 2000, leverage: draft.leverage,
        reduceOnly: draft.reduceOnly, triggerExecution: .market, positionGuard: draft.guardValue)
}

@Test func newOrderTypesMatchOfficialSDKActionHashesAndTestnetSignatures() throws {
    // Reproduced by scripts/order-signing-fixtures.py from the frozen official SDK source.
    let vectors:
        [(
            OrderKind, TriggerExecution, TimeInForce, String, String?, String, String, String,
            UInt64
        )] = [
            (
                .limit, .limit, .gtc, "1900", nil,
                "575e4f96cbec9173246c18d9840f6ce006266f2fcfff37c35b0e0b61ebece275",
                "94ae556915a002fb52dc37ea0fa9654090a97034978e65a0bfb9e4108ea82420",
                "d003a265fd6c3ef169a53ef5bd63066a7773d229ad051749b2cde8b1846ce24", 28
            ),
            (
                .limit, .limit, .ioc, "1900", nil,
                "256b22364fa92522ad458fdbe5127dd8a591d9da0e4026a28ee6c3b2317253b2",
                "46e01159b035e5f90bef644e507021e003e72fd349b9e1f84eb6ccf30506a49e",
                "126ee3204901a8a9717dbbf0bc055c135e9687de7e5f49aa31b1116763eeb65a", 28
            ),
            (
                .limit, .limit, .postOnly, "1900", nil,
                "e814e0c2d449cd78935e71427e55099ecff7e3440f4eb427815cc7dc57813c14",
                "2e4a4cd27f8942f2f66ff4d2cdc6f791e08726869c42566ac4f864ec8850398c",
                "6e9e0acaee4da07221396f68106af56878cfbbe5032dede8b352ec377179b2c5", 27
            ),
            (
                .stop, .market, .gtc, "1620", "1800",
                "c33342816e7aea44da41ec68ceda891999baee938380ae59c04d1e6ab60b5957",
                "346cc57375fccd72fc0896f87645fad1d008c3c393504ff4e96cb8cf3e349e54",
                "4e9cd0049673b01f2b0f13da86f09a9543ecf256d1381a0373e3c9a964dde97c", 28
            ),
            (
                .takeProfit, .limit, .gtc, "2190", "2200",
                "a5078053d3497c71e70cb8af65475fd739e190047065f435c3b8764b9ea699cf",
                "755de94d3475e3f487859431770b45e3afb442ef560e9033620de4e33d733a5b",
                "481eb74e79bef20638109413cc41631adb29ccb680e112fb3493d4d812179f02", 27
            )
        ]
    let nonce: UInt64 = 1_700_000_000_000
    let expiry: UInt64 = 1_700_000_120_000
    let key = try EphemeralSigningKey(
        testKey: Data(hex: "0123456789012345678901234567890123456789012345678901234567890123")!)
    for (kind, execution, tif, price, trigger, hash, r, s, v) in vectors {
        let intent = try OrderPlanner.preview(
            market: market, side: .sell, kind: kind, size: "1.2345", isUSD: false,
            price: price, trigger: trigger, mark: 2000, leverage: 5, reduceOnly: true,
            triggerExecution: execution, timeInForce: tif)
        let action = ExchangeAction.place(intent)
        #expect(
            try SigningPayload.actionHash(action: action, nonce: nonce, expiresAfter: expiry).hex
                == "0x" + hash)
        let signature = try key.sign(
            digest: EthereumSigning.actionDigest(
                action: action, nonce: nonce, environment: .testnet, expiresAfter: expiry))
        #expect(signature.r == "0x" + String(repeating: "0", count: 64 - r.count) + r)
        #expect(signature.s == "0x" + String(repeating: "0", count: 64 - s.count) + s)
        #expect(signature.v == v)
    }
}

@Test func closeDraftUsesDecimalFractionsAndOppositeSideForBothDirections() throws {
    for signedSize in ["1.2345", "-1.2345"] {
        let current = try position(signedSize)
        let draft = try PositionOrderDraft.prepare(
            position: current, market: market, purpose: .close, fraction: Decimal(string: "0.25")!,
            kind: .limit)
        #expect(draft.size == "0.3086")
        #expect(draft.reduceOnly)
        #expect(draft.kind == .limit)
        #expect(draft.leverage == 5)
        #expect(draft.side == (signedSize.hasPrefix("-") ? .buy : .sell))
        let intent = try preview(draft)
        try intent.validatePosition(current)
        #expect(throws: OrderValidationError.self) { try intent.validatePosition(position("1.2")) }
        #expect(throws: OrderValidationError.self) { try intent.validatePosition(nil) }
    }
}

@Test func reverseDraftClosesThenOpensEqualOppositeExposureAndGuardsChangedPosition() throws {
    for signed in ["1.2345", "-1.2345"] {
        let current = try position(signed)
        let draft = try PositionOrderDraft.prepare(
            position: current, market: market, purpose: .reverse)
        #expect(draft.size == "2.469")
        #expect(!draft.reduceOnly)
        #expect(draft.kind == .market)
        let intent = try preview(draft)
        try intent.validatePosition(current)
        #expect(throws: OrderValidationError.self) { try intent.validatePosition(position("2")) }
        #expect(throws: OrderValidationError.self) {
            try OrderPlanner.preview(
                market: market, side: draft.side, kind: .market, size: "1", isUSD: false,
                price: "", trigger: nil, mark: 2000, leverage: 5, reduceOnly: false,
                positionGuard: draft.guardValue)
        }
        #expect(throws: OrderValidationError.self) {
            try OrderPlanner.preview(
                market: market, side: draft.side, kind: .market, size: "2.469", isUSD: false,
                price: "", trigger: nil, mark: 2000, leverage: 5, reduceOnly: true,
                positionGuard: draft.guardValue)
        }
    }
}

@Test func protectionDraftCannotIncreaseExposureOrTradeWrongSide() throws {
    let current = try position()
    let draft = try PositionOrderDraft.prepare(
        position: current, market: market, purpose: .protect, kind: .stop)
    let intent = try preview(draft, trigger: "1900")
    #expect(intent.reduceOnly)
    #expect(intent.trigger == "1900")
    #expect(intent.price == "1710")
    for (side, size, reduce) in [
        (OrderSide.buy, "1", true), (.sell, "2", true), (.sell, "1", false)
    ] {
        #expect(throws: OrderValidationError.self) {
            try OrderPlanner.preview(
                market: market, side: side, kind: .stop, size: size, isUSD: false, price: "1900",
                trigger: side == .buy ? "2100" : "1900", mark: 2000, leverage: 5,
                reduceOnly: reduce, triggerExecution: .market, positionGuard: draft.guardValue)
        }
    }
}

@Test func positionDraftRejectsZeroDustWrongMarketAndInvalidFractions() throws {
    let current = try position()
    for fraction in [Decimal(0), -1, 2] {
        #expect(throws: OrderValidationError.self) {
            try PositionOrderDraft.prepare(
                position: current, market: market, purpose: .close, fraction: fraction)
        }
    }
    #expect(throws: OrderValidationError.self) {
        try PositionOrderDraft.prepare(position: position("0"), market: market, purpose: .close)
    }
    #expect(throws: OrderValidationError.self) {
        try PositionOrderDraft.prepare(
            position: position("0.0001"), market: market, purpose: .close,
            fraction: Decimal(string: "0.25")!)
    }
    let other = Market(
        coin: "BTC", symbol: "BTC", assetID: 0, sizeDecimals: 4, maxLeverage: 50, kind: .perp)
    #expect(throws: OrderValidationError.self) {
        try PositionOrderDraft.prepare(position: current, market: other, purpose: .close)
    }
    #expect(throws: OrderValidationError.self) {
        try PositionOrderDraft.prepare(position: current, market: market, purpose: .protect)
    }
}

@Test func positionActionGuardsRejectMalformedQuantitiesBeforeAndAfterPreparation() throws {
    let current = try position()
    let intent = try preview(
        PositionOrderDraft.prepare(position: current, market: market, purpose: .close))
    for raw in ["1.2345bad", "1.2345e0", "NaN", "", " 1.2345", "0bad", "1.2345\n"] {
        let invalid = try position(raw)
        for purpose in [PositionIntentPurpose.close, .protect, .reverse] {
            #expect(throws: OrderValidationError.self) {
                try PositionOrderDraft.prepare(
                    position: invalid, market: market, purpose: purpose,
                    kind: purpose == .protect ? .stop : .market)
            }
        }
        #expect(throws: OrderValidationError.self) { try intent.validatePosition(invalid) }
        let guardValue = PositionIntentGuard(position: invalid, purpose: .close)
        #expect(throws: OrderValidationError.self) { try guardValue.validateDraft(intent) }
    }
    try intent.validatePosition(position("1.234500"))
}

@Test func conditionalMarketWireUsesTriggerBasedSizingAndDirectionalBound() throws {
    for (kind, side, trigger, bound) in [
        (OrderKind.stop, OrderSide.buy, "2200", "2420"),
        (.stop, .sell, "1800", "1620"),
        (.takeProfit, .buy, "1800", "1980"),
        (.takeProfit, .sell, "2200", "1980")
    ] {
        let intent = try OrderPlanner.preview(
            market: market, side: side, kind: kind, size: trigger, isUSD: true,
            price: "", trigger: trigger, mark: 2000, leverage: 5, reduceOnly: false,
            triggerExecution: .market)
        #expect(intent.size == "1")
        #expect(intent.price == bound)
        #expect(intent.referencePrice == trigger)
        let action = try JSONDecoder().decode(
            JSONValue.self, from: ExchangeAction.place(intent).jsonData())
        let wire = try #require(action["orders"].array.first)
        #expect(wire["p"].string == bound)
        #expect(wire["t"]["trigger"]["isMarket"].bool == true)
        #expect(wire["t"]["trigger"]["triggerPx"].string == trigger)
        #expect(wire["t"]["trigger"]["tpsl"].string == (kind == .stop ? "sl" : "tp"))
        #expect(wire["t"]["limit"] == .null)
    }
}

@Test func conditionalOrdersRejectAlreadyCrossedAndRoundedToMarkTriggers() throws {
    for (kind, side, trigger) in [
        (OrderKind.stop, OrderSide.buy, "1900"), (.stop, .sell, "2100"),
        (.takeProfit, .buy, "2100"),
        (.takeProfit, .sell, "1900"), (.stop, .sell, "2000.001")
    ] {
        #expect(throws: OrderValidationError.self) {
            try OrderPlanner.preview(
                market: market, side: side, kind: kind, size: "1", isUSD: false, price: "1900",
                trigger: trigger, mark: 2000, leverage: 5, reduceOnly: true,
                triggerExecution: .market)
        }
    }
    let limit = try OrderPlanner.preview(
        market: market, side: .sell, kind: .stop, size: "1", isUSD: false, price: "1700",
        trigger: "1800",
        mark: 2000, leverage: 5, reduceOnly: true, triggerExecution: .limit)
    let action = try JSONDecoder().decode(
        JSONValue.self, from: ExchangeAction.place(limit).jsonData())
    #expect(action["orders"].array.first?["t"]["trigger"]["isMarket"].bool == false)
    #expect(limit.price == "1700")
}

@Test func limitPlaceAndModifyPreserveEveryTimeInForceAndMarketForcesIOC() throws {
    for tif in TimeInForce.allCases {
        let intent = try OrderPlanner.preview(
            market: market, side: .buy, kind: .limit, size: "1", isUSD: false,
            price: "1900", trigger: nil, mark: 2000, leverage: 5, reduceOnly: false,
            timeInForce: tif)
        let placed = try JSONDecoder().decode(
            JSONValue.self, from: ExchangeAction.place(intent).jsonData())
        let modified = try JSONDecoder().decode(
            JSONValue.self, from: ExchangeAction.modify(oid: 42, intent: intent).jsonData())
        #expect(placed["orders"].array.first?["t"]["limit"]["tif"].string == tif.rawValue)
        #expect(
            modified["modifies"].array.first?["order"]["t"]["limit"]["tif"].string == tif.rawValue)
    }
    let marketIntent = try OrderPlanner.preview(
        market: market, side: .buy, kind: .market, size: "1", isUSD: false,
        price: "", trigger: nil, mark: 2000, leverage: 5, reduceOnly: false, timeInForce: .postOnly)
    #expect(marketIntent.timeInForce == .ioc)
}
