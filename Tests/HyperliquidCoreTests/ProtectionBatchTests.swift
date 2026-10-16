import Foundation
import Testing

@testable import HyperliquidCore

private let pairOwner = "0x1111111111111111111111111111111111111111"
private let pairMarket = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 50, kind: .perp)
private func pairPosition(_ signed: String = "1.2345") -> Position {
    Position(
        coin: "ETH", szi: signed, entryPx: "2000", liquidationPx: "1500", positionValue: "2469",
        unrealizedPnl: "0", returnOnEquity: "0", marginUsed: "493.8",
        leverage: .init(type: "cross", value: 5))
}
private func pairBatch(short: Bool = false, mode: TriggerExecution = .market) throws
-> ProtectionBatch {
    try ProtectionBatch.position(
        owner: pairOwner, environment: .testnet,
        position: pairPosition(short ? "-1.2345" : "1.2345"),
        market: pairMarket, mark: 2000,
        takeProfit: .init(trigger: short ? "1900" : "2100", execution: mode, limit: "2000"),
        stopLoss: .init(trigger: short ? "2100" : "1900", execution: mode, limit: "2000"))
}
private func pairRow(kind: String, oid: Int64, whole: Bool = true, side: String = "A") -> OpenOrder {
    OpenOrder(
        coin: "ETH", limitPx: "2000", sz: whole ? "0" : "1.2345", side: side, oid: oid,
        timestamp: 1,
        orderType: kind, reduceOnly: true, isTrigger: true,
        triggerPx: kind.hasPrefix("Take Profit") ? "2100" : "1900", isPositionTpsl: whole,
        children: [])
}
private func pairSnapshot(
    owner: String = pairOwner, positions: [Position] = [pairPosition()],
    orders: [OpenOrder] = [], mark: String = "2000", mode: String = "default",
    start: Double = ReceiptClock.now
) throws -> ProtectionAccountSnapshot {
    let asset = try JSONValue.object([
        "user": .string(owner), "coin": .string("ETH"),
        "leverage": .object(["type": .string("cross"), "value": .integer(5)]),
        "maxTradeSzs": .array([.string("10"), .string("10")]),
        "availableToTrade": .array([.string("10000"), .string("10000")]), "markPx": .string(mark)
    ]).decode(ActiveAssetData.self)
    let rates = try UserFeeRates(
        response: .object([
            "userAddRate": .string("0.0001"), "userCrossRate": .string("0.0004"),
            "userSpotAddRate": .string("0.0001"), "userSpotCrossRate": .string("0.0004"),
            "activeReferralDiscount": .string("0")
        ]))
    return ProtectionAccountSnapshot(
        owner: owner, environment: .testnet, market: pairMarket,
        positions: positions, orders: orders, asset: asset, fees: rates,
        startedAt: start, receivedAt: ReceiptClock.now, abstraction: mode)
}

@Test func protectionPairUsesEntirePositionGroupingBothSidesAndRequiresTwoValidTriggers() throws {
    for short in [false, true] {
        for mode in TriggerExecution.allCases {
            let batch = try pairBatch(short: short, mode: mode)
            let action = try JSONDecoder().decode(JSONValue.self, from: batch.action.jsonData())
            #expect(
                action["grouping"].string == "positionTpsl" && action["orders"].array.count == 2)
            #expect(batch.legs.map(\.role) == [.takeProfit, .stopLoss])
            #expect(
                action["orders"].array.allSatisfy {
                    $0["s"].string == "0" && $0["r"].bool == true && $0["b"].bool == short
                })
            #expect(Set(batch.legs.map(\.clientID)).count == 2)
            #expect(batch.legs.allSatisfy { $0.intent.size == "1.2345" && $0.intent.notional > 0 })
            #expect(
                try pairSnapshot(positions: [pairPosition(short ? "-1.2345" : "1.2345")]).validate(
                    batch
                ).count == 2)
        }
    }
    #expect(throws: OrderValidationError.self) {
        try ProtectionBatch.position(
            owner: pairOwner, environment: .testnet, position: pairPosition(), market: pairMarket,
            mark: 2000, takeProfit: .init(trigger: "1900"), stopLoss: .init(trigger: "2100"))
    }
    let batch = try pairBatch()
    for snapshot in [
        try pairSnapshot(owner: "0x2222222222222222222222222222222222222222"),
        try pairSnapshot(positions: []), try pairSnapshot(positions: [pairPosition("1")]),
        try pairSnapshot(positions: [pairPosition(), pairPosition()]),
        try pairSnapshot(mark: "2200"),
        try pairSnapshot(mode: "unifiedAccount"), try pairSnapshot(start: ReceiptClock.now - 16)
    ] { #expect(throws: OrderValidationError.self) { try snapshot.validate(batch) } }
    #expect(throws: OrderValidationError.self) {
        try batch.validateFreshness(now: batch.createdAt.addingTimeInterval(30))
    }
}

@Test func protectionBracketBindsOrderedParentChildrenOppositeSideAndFixedQuantity() throws {
    for side in [OrderSide.buy, .sell] {
        let parent = try OrderPlanner.preview(
            market: pairMarket, side: side, kind: .limit, size: "1.2345", isUSD: false,
            price: "2000", trigger: nil, mark: 2000, leverage: 5, reduceOnly: false)
        let batch = try ProtectionBatch.bracket(
            owner: pairOwner, environment: .testnet, parent: parent, mark: 2000,
            takeProfit: .init(trigger: side == .buy ? "2100" : "1900"),
            stopLoss: .init(trigger: side == .buy ? "1900" : "2100"))
        let action = try JSONDecoder().decode(JSONValue.self, from: batch.action.jsonData())
        #expect(action["grouping"].string == "normalTpsl" && action["orders"].array.count == 3)
        #expect(batch.legs.map(\.role) == [.entry, .takeProfit, .stopLoss])
        #expect(
            batch.legs.allSatisfy {
                $0.intent.size == parent.size && $0.intent.protectionSizing == .fixed
            })
        #expect(
            batch.legs.dropFirst().allSatisfy {
                $0.intent.side != parent.side && $0.intent.reduceOnly
            })
        #expect(try pairSnapshot(positions: []).validate(batch).count == 3)
    }
    let parent = try OrderPlanner.preview(
        market: pairMarket, side: .buy, kind: .limit, size: "1", isUSD: false,
        price: "2150", trigger: nil, mark: 2000, leverage: 5, reduceOnly: false)
    #expect(throws: OrderValidationError.self) {
        try ProtectionBatch.bracket(
            owner: pairOwner, environment: .testnet, parent: parent, mark: 2000,
            takeProfit: .init(trigger: "2100"), stopLoss: .init(trigger: "1900"))
    }
}

@Test func protectionBatchModificationPreservesOriginalsAndRejectsRacesAndForeignChildren() throws {
    let originals = [
        pairRow(kind: "Take Profit Market", oid: 10), pairRow(kind: "Stop Market", oid: 11)
    ]
    let batch = try ProtectionBatch.modification(
        owner: pairOwner, environment: .testnet, market: pairMarket,
        position: pairPosition(), originals: originals, mark: 2000,
        takeProfit: .init(trigger: "2200"), stopLoss: .init(trigger: "1800"))
    let action = try JSONDecoder().decode(JSONValue.self, from: batch.action.jsonData())
    #expect(action["type"].string == "batchModify" && action["a"].bool == true)
    #expect(action["modifies"].array.map { $0["oid"].int64 } == [10, 11])
    #expect(try pairSnapshot(orders: originals).validate(batch).count == 2)
    for rows in [
        Array(originals.prefix(1)), originals + [originals[0]],
        [pairRow(kind: "Take Profit Market", oid: 10, side: "B"), originals[1]]
    ] {
        #expect(throws: (any Error).self) { try pairSnapshot(orders: rows).validate(batch) }
    }
    let children = [
        pairRow(kind: "Take Profit Market", oid: 20, whole: false),
        pairRow(kind: "Stop Market", oid: 21, whole: false)
    ]
    let parent = OpenOrder(
        coin: "ETH", limitPx: "2000", sz: "1.2345", side: "B", oid: 19, timestamp: 1,
        orderType: "Limit", reduceOnly: false, isTrigger: false, isPositionTpsl: false,
        children: try children.map {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0))
        })
    #expect(try ProtectionOrders.flattened([parent]).count == 3)
    let linked = try ProtectionBatch.modification(
        owner: pairOwner, environment: .testnet, market: pairMarket,
        position: nil, originals: children, linkedParent: parent, mark: 2000,
        takeProfit: .init(trigger: "2200"), stopLoss: .init(trigger: "1800"))
    #expect(linked.linkedParent?.oid == 19 && linked.legs.allSatisfy { $0.intent.size == "1.2345" })
    #expect(try pairSnapshot(positions: [], orders: [parent]).validate(linked).count == 2)
    #expect(throws: OrderValidationError.self) {
        try pairSnapshot(orders: children).validate(linked)
    }
    #expect(throws: OrderValidationError.self) {
        try ProtectionBatch.modification(
            owner: pairOwner, environment: .testnet, market: pairMarket,
            position: nil, originals: children, mark: 2000,
            takeProfit: .init(trigger: "2200"), stopLoss: .init(trigger: "1800"))
    }
}

@Test func protectionReceiptRetainsPartialSuccessAndRefusesMisalignedOrInvalidResponses() throws {
    let batch = try pairBatch()
    func response(_ statuses: [JSONValue]) -> JSONValue {
        .object([
            "status": .string("ok"),
            "response": .object([
                "type": .string("order"),
                "data": .object(["statuses": .array(statuses)])
            ])
        ])
    }
    let success: JSONValue = .object(["resting": .object(["oid": .integer(123)])])
    #expect(
        ProtectionReceipt.parse(
            response([success, .object(["error": .string("Invalid trigger")])]), batch: batch)
            == [.resting(123), .rejected("Invalid trigger")])
    #expect(
        ProtectionReceipt.parse(response([success, .object([:])]), batch: batch)[0] == .resting(123)
    )
    #expect(
        ProtectionReceipt.parse(response([success, success]), batch: batch).allSatisfy {
            $0.unverified
        })
    let contradictory: JSONValue = .object([
        "resting": .object(["oid": .integer(124)]), "error": .string("Rejected")
    ])
    #expect(
        ProtectionReceipt.parse(response([success, contradictory]), batch: batch)[1].unverified)
    #expect(ProtectionReceipt.parse(response([success]), batch: batch).allSatisfy { $0.unverified })
    #expect(
        ProtectionReceipt.parse(response([success, success, success]), batch: batch).allSatisfy {
            $0.unverified
        })
    #expect(
        ProtectionReceipt.parse(
            .object(["status": .string("err"), "response": .string("Invalid nonce")]), batch: batch)
            == [.rejected("Invalid nonce"), .rejected("Invalid nonce")])
    #expect(
        ProtectionReceipt.parse(
            response([.string("waitingForTrigger"), .string("waitingForFill")]), batch: batch)
            == [.waiting("waitingForTrigger"), .waiting("waitingForFill")])
    #expect(
        ProtectionReceipt.parse(
            response([
                success,
                .object([
                    "filled": .object([
                        "oid": .integer(124), "totalSz": .string("1\n"), "avgPx": .string("2000")
                    ])
                ])
            ]), batch: batch)[1].unverified)
}

@Test func protectionBatchSigningMatchesFrozenOfficialSDKForPairBracketAndModify() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            contentsOf:
                root.appendingPathComponent(
                    "docs/verification/position-protection/batch-sdk-vectors.json")))
    #expect(
        fixture["source_sha256"].string
            == "938ec0a1f9611874b423ca946696e19a71d32d14709f521ea5d526f4398c0b85")
    #expect(fixture["vectors"].array.count == 12)
    let publicKeyBytes = try #require(
        Data(hex: "0123456789012345678901234567890123456789012345678901234567890123"))
    let key = try EphemeralSigningKey(testKey: publicKeyBytes)
    for vector in fixture["vectors"].array {
        let short = vector["short"].bool == true
        let execution: TriggerExecution = vector["isMarket"].bool == true ? .market : .limit
        let tp = ProtectionTrigger(
            trigger: short ? "1900" : "2100", execution: execution, limit: "2000")
        let sl = ProtectionTrigger(
            trigger: short ? "2100" : "1900", execution: execution, limit: "2000")
        let native: ProtectionBatch
        if vector["mode"].string == "bracket" {
            let parent = try OrderPlanner.preview(
                market: pairMarket, side: short ? .sell : .buy, kind: .limit,
                size: "1.2345", isUSD: false, price: "2000", trigger: nil, mark: 2000, leverage: 5,
                reduceOnly: false)
            native = try ProtectionBatch.bracket(
                owner: pairOwner, environment: .testnet, parent: parent, mark: 2000,
                takeProfit: tp, stopLoss: sl)
        } else if vector["mode"].string == "modify" {
            let originals = [
                pairRow(
                    kind: "Take Profit " + execution.rawValue, oid: 70, side: short ? "B" : "A"),
                pairRow(kind: "Stop " + execution.rawValue, oid: 71, side: short ? "B" : "A")
            ]
            native = try ProtectionBatch.modification(
                owner: pairOwner, environment: .testnet, market: pairMarket,
                position: pairPosition(short ? "-1.2345" : "1.2345"), originals: originals,
                mark: 2000, takeProfit: tp, stopLoss: sl)
        } else {
            native = try pairBatch(short: short, mode: execution)
        }
        let fixedLegs = native.legs.enumerated().map { index, leg in
            ProtectionLeg(
                role: leg.role, intent: leg.intent,
                clientID: "0x" + String(repeating: String(index + 1), count: 32))
        }
        let batch = ProtectionBatch(
            owner: native.owner, environment: native.environment, mode: native.mode,
            legs: fixedLegs, linkedParent: native.linkedParent, createdAt: native.createdAt)
        #expect(
            try JSONDecoder().decode(JSONValue.self, from: batch.action.jsonData())
                == vector["action"])
        #expect(
            try SigningPayload.actionHash(
                action: batch.action, nonce: 1_700_000_000_000, expiresAfter: 1_700_000_120_000
            ).hex == vector["hash"].string)
        for environment in [NetworkEnvironment.mainnet, .testnet] {
            let expected = vector[environment.rawValue]
            let digest = try EthereumSigning.actionDigest(
                action: batch.action, nonce: 1_700_000_000_000,
                environment: environment, expiresAfter: 1_700_000_120_000)
            #expect(digest.hex == expected["digest"].string)
            let signature = try key.sign(digest: digest)
            func padded(_ value: JSONValue) throws -> String {
                let raw = try #require(value.string)
                return "0x" + String(repeating: "0", count: 66 - raw.count) + raw.dropFirst(2)
            }
            #expect(signature.r == (try padded(expected["signature"]["r"])))
            #expect(signature.s == (try padded(expected["signature"]["s"])))
            #expect(Int64(signature.v) == expected["signature"]["v"].int64)
            #expect(
                try EthereumSigning.recover(signature: signature, digest: digest) == key.address)
        }
    }
}
