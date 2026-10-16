import Foundation
import Testing

@testable import HyperliquidCore

private let wholeMarket = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 50, kind: .perp)
private func paddedSDKScalar(_ value: JSONValue) throws -> String {
    let raw = try #require(value.string)
    let hex = String(raw.dropFirst(2))
    #expect(raw.hasPrefix("0x") && (1...64).contains(hex.count))
    #expect(hex.allSatisfy { $0.isHexDigit })
    return "0x" + String(repeating: "0", count: 64 - hex.count) + hex
}
private func wholePosition(_ signed: String = "1.2345") -> Position {
    Position(
        coin: "ETH", szi: signed, entryPx: "2000", liquidationPx: "1500",
        positionValue: "2469", unrealizedPnl: "0", returnOnEquity: "0", marginUsed: "493.8",
        leverage: .init(type: "cross", value: 5))
}
private func wholeIntent(
    signed: String = "1.2345", kind: OrderKind = .stop, mode: TriggerExecution = .market,
    sizing: ProtectionSizing = .entirePosition
) throws -> OrderIntent {
    let draft = try PositionOrderDraft.prepare(
        position: wholePosition(signed), market: wholeMarket, purpose: .protect, kind: kind)
    let trigger = (kind == .stop) == (draft.side == .buy) ? "2100" : "1900"
    return try OrderPlanner.preview(
        market: wholeMarket, side: draft.side, kind: kind, size: draft.size, isUSD: false,
        price: "2000", trigger: trigger, mark: 2000, leverage: 5, reduceOnly: true,
        triggerExecution: mode, positionGuard: draft.guardValue, protectionSizing: sizing)
}

@Test func wholePositionProtectionMatchesIndependentSDKBothSidesTypesModesAndNetworks() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            contentsOf: root.appendingPathComponent(
                "docs/verification/position-protection/sdk-vectors.json")))
    #expect(
        fixture["source_sha256"].string
            == "938ec0a1f9611874b423ca946696e19a71d32d14709f521ea5d526f4398c0b85")
    #expect(fixture["vectors"].array.count == 8)
    let key = try EphemeralSigningKey(
        testKey: #require(
            Data(
                hex:
                    "0123456789012345678901234567890123456789012345678901234567890123")))
    for vector in fixture["vectors"].array {
        let signed = vector["buy"].bool == true ? "-1.2345" : "1.2345"
        let rawKind = try #require(vector["kind"].string)
        let kind = try #require(OrderKind(rawValue: rawKind))
        let mode: TriggerExecution = vector["isMarket"].bool == true ? .market : .limit
        let intent = try wholeIntent(signed: signed, kind: kind, mode: mode)
        let action = ExchangeAction.place(intent, cloid: "0x11111111111111111111111111111111")
        let json = try JSONDecoder().decode(JSONValue.self, from: action.jsonData())
        #expect(json == vector["action"])
        #expect(intent.size == "1.2345" && intent.notional > 0 && intent.reduceOnly)
        #expect(intent.sizeSummary == "Entire position at trigger")
        #expect(
            try SigningPayload.actionHash(
                action: action, nonce: 1_700_000_000_000, expiresAfter: 1_700_000_120_000
            ).hex == vector["hash"].string)
        for environment in [NetworkEnvironment.mainnet, .testnet] {
            let digest = try EthereumSigning.actionDigest(
                action: action, nonce: 1_700_000_000_000, environment: environment,
                expiresAfter: 1_700_000_120_000)
            let signature = try key.sign(digest: digest)
            let expected = vector[environment.rawValue]
            // eth-account exports integer hex without leading zero padding;
            // native signatures retain their complete 32-byte scalar encoding.
            #expect(signature.r == (try paddedSDKScalar(expected["r"])))
            #expect(signature.s == (try paddedSDKScalar(expected["s"])))
            #expect(Int64(signature.v) == expected["v"].int64)
        }
        let fixed = try wholeIntent(signed: signed, kind: kind, mode: mode, sizing: .fixed)
        let fixedWire = try JSONDecoder().decode(
            JSONValue.self, from: ExchangeAction.place(fixed).jsonData())
        #expect(
            fixedWire["grouping"].string == "na"
                && fixedWire["orders"].array.first?["s"].string == "1.2345")
    }
}

@Test func wholePositionProtectionCannotSilentlyIgnoreQuantityUSDKindSideOrPositionChanges() throws {
    let position = wholePosition()
    let guardValue = PositionIntentGuard(position: position, purpose: .protect)
    for (kind, side, size, usd, reduce, context) in [
        (OrderKind.stop, OrderSide.sell, "0.5", false, true, Optional(guardValue)),
        (.stop, .sell, "1.2346", false, true, guardValue),
        (.stop, .sell, "2469", true, true, guardValue),
        (.stop, .sell, "1.2345", false, false, guardValue),
        (.market, .sell, "1.2345", false, true, guardValue),
        (.limit, .sell, "1.2345", false, true, guardValue),
        (.stop, .buy, "1.2345", false, true, guardValue),
        (.stop, .sell, "1.2345", false, true, nil),
        (
            .stop, .sell, "1.2345", false, true,
            PositionIntentGuard(position: position, purpose: .close)
        )
    ] {
        #expect(throws: OrderValidationError.self) {
            try OrderPlanner.preview(
                market: wholeMarket, side: side, kind: kind, size: size, isUSD: usd,
                price: "2000", trigger: side == .buy ? "2100" : "1900", mark: 2000,
                leverage: 5, reduceOnly: reduce, triggerExecution: .market,
                positionGuard: context, protectionSizing: .entirePosition)
        }
    }
    let intent = try wholeIntent()
    try intent.validatePosition(position)
    for current in [
        nil, wholePosition("0"), wholePosition("-1.2345"), wholePosition("1.5"),
        wholePosition("NaN")
    ] {
        #expect(throws: OrderValidationError.self) { try intent.validatePosition(current) }
    }
    let spot = Market(
        coin: "@107", symbol: "HYPE", assetID: 10_107, sizeDecimals: 2, maxLeverage: 1, kind: .spot)
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.preview(
            market: spot, side: .sell, kind: .stop, size: "1", isUSD: false,
            price: "20", trigger: "19", mark: 20, leverage: 1, reduceOnly: true,
            protectionSizing: .entirePosition)
    }
}

@Test func wholePositionProtectionAtOpenInterestCapUsesThePositiveSnapshotForReduction()
async throws {
    let intent = try wholeIntent()
    let address = "0x1111111111111111111111111111111111111111"
    let account = AccountState(
        assetPositions: [.init(position: wholePosition())],
        marginSummary: .init(
            accountValue: "1000", totalMarginUsed: "493.8", totalNtlPos: "2469", totalRawUsd: "1000"
        ),
        crossMarginSummary: nil, crossMaintenanceMarginUsed: "24.69", withdrawable: "500", time: 100
    )
    let accountJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(account))
    let snapshot = try #require(
        await PerpOpenInterestSnapshot.read(
            intent: intent, address: address, environment: .testnet,
            info: { request in
                request["type"] == .string("perpsAtOpenInterestCap")
                    ? .array([.string("ETH")]) : accountJSON
            },
            now: { 50 }))
    try snapshot.validate(intent: intent, address: address, environment: .testnet, now: 50)
    let rates = try UserFeeRates(
        response: .object([
            "userAddRate": .string("0.00015"), "userCrossRate": .string("0.00045"),
            "userSpotAddRate": .string("0.0004"), "userSpotCrossRate": .string("0.0007"),
            "activeReferralDiscount": .string("0")
        ]))
    let fees = try rates.estimate(for: intent)
    #expect(fees.upper > 0 && fees.lower == fees.upper)
    let asset = try JSONValue.object([
        "user": .string(address), "coin": .string("ETH"),
        "leverage": .object(["type": .string("cross"), "value": .integer(5)]),
        "maxTradeSzs": .array([.string("0"), .string("0")]),
        "availableToTrade": .array([.string("0"), .string("0")]), "markPx": .string("2000")
    ]).decode(ActiveAssetData.self)
    try PerpTradingCapacity(asset: asset, address: address, market: wholeMarket, side: .sell)
        .validate(intent)
    let risk = try OrderRiskEstimate.preview(
        intent: intent, address: address, account: account, asset: asset,
        table: MarginTable(id: 50, bounds: [(0, 50)]), abstraction: "default", fees: fees)
    #expect(risk.currentSignedSize == Decimal(string: "1.2345") && risk.resultingSignedSize == 0)
    #expect(risk.initialMarginRequired == 0 && risk.maintenanceMarginRequired == 0)
}

@Test func wholePositionProtectionReturnedMetadataDistinguishesDynamicFixedAndMalformedOrders()
throws {
    func order(_ size: String, dynamic: Bool?, trigger: Bool? = true, reduce: Bool? = true)
    -> OpenOrder {
        OpenOrder(
            coin: "ETH", limitPx: "1710", sz: size, side: "A", oid: 123, timestamp: 100,
            orderType: "Stop Market", reduceOnly: reduce, isTrigger: trigger,
            triggerPx: "1900", isPositionTpsl: dynamic, children: [])
    }
    #expect(order("0", dynamic: true).isEntirePositionProtection)
    #expect(order("1", dynamic: true).isEntirePositionProtection)
    for value in [
        order("1", dynamic: false), order("0", dynamic: false), order("0", dynamic: nil),
        order("0x", dynamic: true), order("0", dynamic: true, trigger: false),
        order("0", dynamic: true, reduce: false)
    ] {
        #expect(!value.isEntirePositionProtection)
    }
    #expect(
        try OrderModificationGuard(
            address: "0x1111111111111111111111111111111111111111", order: order("0", dynamic: true),
            market: wholeMarket
        ).protectionSizing == .entirePosition)
}

private func wholeModifyRow(
    buy: Bool = false, kind: OrderKind = .stop, mode: TriggerExecution = .market,
    size: String = "0", trigger: String? = nil, price: String = "2000",
    dynamic: Bool? = true, children: [JSONValue]? = []
) -> OpenOrder {
    OpenOrder(
        coin: "ETH", limitPx: price, sz: size, side: buy ? "B" : "A", oid: 123, timestamp: 100,
        orderType: "\(kind == .stop ? "Stop" : "Take Profit") \(mode.rawValue)",
        reduceOnly: true, isTrigger: true,
        triggerPx: trigger ?? ((kind == .stop) == buy ? "2200" : "1800"),
        isPositionTpsl: dynamic, children: children)
}
private func wholeReplacement(_ original: OpenOrder, mode: TriggerExecution? = nil) throws
-> OrderIntent {
    let replacement = try OrderModificationGuard(
        address: "0x1111111111111111111111111111111111111111", order: original, market: wholeMarket)
    let position = wholePosition(original.side == "B" ? "-1.2345" : "1.2345")
    let prepared = try replacement.positionDraft(current: position)
    let draft = try #require(prepared)
    return try OrderPlanner.preview(
        market: wholeMarket, side: draft.side, kind: draft.kind, size: draft.size, isUSD: false,
        price: "2000", trigger: (draft.kind == .stop) == (draft.side == .buy) ? "2100" : "1900",
        mark: 2000, leverage: draft.leverage, reduceOnly: true,
        triggerExecution: mode ?? replacement.triggerExecution,
        positionGuard: draft.guardValue, modificationGuard: replacement,
        protectionSizing: replacement.protectionSizing)
}

@Test func wholePositionProtectionModificationMatchesSDKAndNeverChangesItsWireSizing() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            contentsOf:
                root.appendingPathComponent(
                    "docs/verification/position-protection/modification-sdk-vectors.json")))
    #expect(fixture["vectors"].array.count == 8)
    let key = try EphemeralSigningKey(
        testKey: #require(
            Data(
                hex:
                    "0123456789012345678901234567890123456789012345678901234567890123")))
    for vector in fixture["vectors"].array {
        let rawKind = try #require(vector["kind"].string)
        let kind = try #require(OrderKind(rawValue: rawKind))
        let mode: TriggerExecution = vector["isMarket"].bool == true ? .market : .limit
        for reportedSize in ["0", "1.2345"] {
            let original = wholeModifyRow(
                buy: vector["buy"].bool == true, kind: kind, mode: mode, size: reportedSize)
            let intent = try wholeReplacement(original)
            let action = ExchangeAction.modify(
                oid: 123, intent: intent, cloid: "0x11111111111111111111111111111111")
            #expect(
                try JSONDecoder().decode(JSONValue.self, from: action.jsonData())
                    == vector["action"])
            #expect(intent.size == "1.2345" && intent.protectionSizing == .entirePosition)
            try intent.modificationGuard?.validate(
                currentOrders: [original], intent: intent,
                address: "0x1111111111111111111111111111111111111111")
            try intent.validateModificationTarget(
                oid: 123, address: "0x1111111111111111111111111111111111111111")
            #expect(
                try SigningPayload.actionHash(
                    action: action, nonce: 1_700_000_000_000,
                    expiresAfter: 1_700_000_120_000
                ).hex == vector["hash"].string)
            for environment in [NetworkEnvironment.mainnet, .testnet] {
                let signature = try key.sign(
                    digest: EthereumSigning.actionDigest(
                        action: action, nonce: 1_700_000_000_000, environment: environment,
                        expiresAfter: 1_700_000_120_000))
                #expect(signature.r == (try paddedSDKScalar(vector[environment.rawValue]["r"])))
                #expect(signature.s == (try paddedSDKScalar(vector[environment.rawValue]["s"])))
                #expect(Int64(signature.v) == vector[environment.rawValue]["v"].int64)
            }
        }
    }
}

@Test func wholePositionProtectionModificationRejectsLostMetadataLinksChangedOriginalAndPosition()
throws {
    let original = wholeModifyRow()
    let intent = try wholeReplacement(original, mode: .limit)
    let guardValue = try #require(intent.modificationGuard)
    #expect(intent.triggerExecution == .limit)
    for orders in [
        [], [original, original],
        [wholeModifyRow(size: "1")], [wholeModifyRow(trigger: "1810")],
        [wholeModifyRow(price: "1999")], [wholeModifyRow(dynamic: false)],
        [wholeModifyRow(dynamic: nil)], [wholeModifyRow(children: [.object([:])])]
    ] {
        #expect(throws: OrderValidationError.self) {
            try guardValue.validate(
                currentOrders: orders, intent: intent,
                address: "0x1111111111111111111111111111111111111111")
        }
    }
    for position in [nil, wholePosition("0"), wholePosition("-1"), wholePosition("NaN")] {
        #expect(throws: OrderValidationError.self) {
            try guardValue.positionDraft(current: position)
        }
    }
    for position in [wholePosition("1.5"), wholePosition("-1.2345"), nil] {
        #expect(throws: OrderValidationError.self) { try intent.validatePosition(position) }
    }
    for incomplete in [
        wholeModifyRow(children: nil), wholeModifyRow(children: [.object([:])]),
        wholeModifyRow(dynamic: nil), wholeModifyRow(size: "-1"), wholeModifyRow(size: "NaN")
    ] {
        #expect(OrderModificationGuard.kind(for: incomplete) == nil)
    }
    #expect(throws: OrderValidationError.self) {
        try guardValue.validate(
            currentOrders: [original], intent: intent,
            address: "0x2222222222222222222222222222222222222222")
    }
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.preview(
            market: wholeMarket, side: .sell, kind: .stop,
            size: "1.2345", isUSD: false, price: "2000", trigger: "1900", mark: 2000,
            leverage: 5, reduceOnly: true, positionGuard: intent.positionGuard,
            modificationGuard: guardValue, protectionSizing: .fixed)
    }
}
