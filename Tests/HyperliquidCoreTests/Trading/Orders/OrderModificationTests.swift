import Foundation
import Testing

@testable import HyperliquidCore

@Test func orderModificationSigningMatchesIndependentOfficialSDKVectors() throws {
    let key = try EphemeralSigningKey(
        testKey: Data(hex: "0123456789012345678901234567890123456789012345678901234567890123")!)
    let vectors: [(String, String?, String, String, String, UInt64)] = [
        (
            "Limit", nil,
            "331d144d43e9c7bcf5979850caf4860d521886b2534495a042349361e9839e23",
            "3245c2f64e4ab0aabca5047856b06998977472e788e772605bf72c8551aef98e",
            "5b85e483eb1885e0a1f79f482f73790714fbf5a339adbf0b45a031a1e6e1b1f9", 28
        ),
        (
            "Limit", "0x11111111111111111111111111111111",
            "d7826e3a34f63842bfbcbefb7bd9d52642f472177a5b8a5ced0b362dfe7c6890",
            "f43f4ae077c12f4f7ba434a538a29de4f49943b24f9fd741b874726b8ba02c2b",
            "18ad7370778b0764c588dffef9549274aa4959924fdca320bfd17ee1e7d34c0c", 28
        ),
        (
            "Stop Market", nil,
            "9c45cce17c8a41d7696a96f2113d60952b6db6699b1594c10f94d2218d7486bd",
            "5729e54dc0ac32eaeb7afcd3bcce0c69bc600ca6d0d5f7d4da138920e61a458",
            "5f2775e3a75e28f0513ce95a5e983641f87bff2fea14e66790d92989c252dd4f", 28
        ),
        (
            "Stop Market", "0x11111111111111111111111111111111",
            "a5d9797c1629b737a2e03c681eeb1698d6bebc80efb5bca9ecfa832d51b91dbc",
            "f74c4c13ffef45ec2d3ad67a61cbc483e52254327b1681b7866c3541edc0d966",
            "66389bd7ae036af32bf893c9b8387c6e0e8599495229622a5d069349be14ef84", 27
        ),
        (
            "Stop Limit", nil,
            "b0e7d163e0f02726289c55bcb33833de4f1229f58cf0a4f5a5504d314a9e1a33",
            "c6b97ffee64ee3fb266b2aafbbe17912be9f1cd7050997adf3d943cc0059dd68",
            "129228440ff80a9172204cc98372f65e079f88187097418edb487408c8c8e0c1", 28
        ),
        (
            "Stop Limit", "0x11111111111111111111111111111111",
            "408c07c0e4d2367aef27d8779001546112e73c7cb6644c67a029cc7374c6f1ae",
            "8bd1482bb61b54bc47c3862008fcf0ef5a09468e265624639d0d6b2afc345081",
            "2a8cdb7fca1e620f27a4b2b46182e5a3fa1549d0802ae119d21eb91524c99c0e", 27
        ),
        (
            "Take Profit Market", nil,
            "11b3af228ab7b5ef416145f73e51e2a79eea279d0f3494e564f1ebd41f5d9955",
            "69f6af13bef1bf0798bc5fe6d7fc4ed326210cb35de47d000c5abc135ac1022c",
            "483746c58e2e3437aa7d055a4071486c116e24383ca643a94b4d66add51764fb", 27
        ),
        (
            "Take Profit Market", "0x11111111111111111111111111111111",
            "663c8315580bab100a016f2851f7537c3b78137e340ea4cb63fc19fd50d5068a",
            "fe210f496e25f02e600b3c3850f64e2dd5ac3f71cea157c8c4d463d17522b6c5",
            "2fba2d5c893f38588e5376cad91786380115eba4dc483d02dc2b42c5b644f1e3", 28
        ),
        (
            "Take Profit Limit", nil,
            "356f82fbeb595cc981ab21a086c2f7700ea12d0117e8ac4bb307d1f9b492be4f",
            "a2aea4536b3b65a305e1a5fb74abd9ccf94373aceec99536a59a08b5c79764bf",
            "7bde0cd234f649706fa76c8ceeef4d8f5f6c331510566ff61ac882c9f8b4108d", 28
        ),
        (
            "Take Profit Limit", "0x11111111111111111111111111111111",
            "ae2a255154be112b070885be8754ecbd1fcef78a56e3258f39d09a9a1843363e",
            "ed675c6c913af2103e7d9c53ff75b0622b3a1f43f08d8d85e9f2a018cbc36a1",
            "6c12508d8a149b3410d287d740278c9e24257cf4a1149967c12ad81c730ae044", 28
        )
    ]
    for (type, clientID, hash, r, s, v) in vectors {
        let original = modificationOrder(type: type, isTrigger: type != "Limit")
        let guardValue = try OrderModificationGuard(
            address: modificationOwner, order: original, market: modificationMarket)
        let action = ExchangeAction.modify(
            oid: 123, intent: try modificationIntent(guardValue), cloid: clientID)
        #expect(
            try SigningPayload.actionHash(
                action: action, nonce: 1_700_000_000_000, expiresAfter: 1_700_000_120_000
            ).hex == "0x" + hash)
        let signature = try key.sign(
            digest: EthereumSigning.actionDigest(
                action: action, nonce: 1_700_000_000_000,
                environment: .testnet, expiresAfter: 1_700_000_120_000))
        // Python hex(int) omits leading zeros; native signature words are 32 bytes.
        #expect(signature.r == "0x" + String(repeating: "0", count: 64 - r.count) + r)
        #expect(signature.s == "0x" + String(repeating: "0", count: 64 - s.count) + s)
        #expect(signature.v == v)
    }
}

private let modificationOwner = "0x1111111111111111111111111111111111111111"
private let modificationMarket = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 25, kind: .perp)
private func modificationOrder(
    type: String = "Stop Market", size: String = "1", price: String = "2300",
    trigger: String = "2100",
    oid: Int64 = 123, coin: String = "ETH", side: String = "B", reduceOnly: Bool? = false,
    isTrigger: Bool? = true, positionTpsl: Bool? = false, children: [JSONValue]? = nil
) -> OpenOrder {
    OpenOrder(
        coin: coin, limitPx: price, sz: size, side: side, oid: oid, timestamp: 100,
        orderType: type, reduceOnly: reduceOnly, tif: type == "Limit" ? "Alo" : nil,
        isTrigger: isTrigger, triggerPx: trigger, isPositionTpsl: positionTpsl, children: children)
}
private func modificationIntent(_ guardValue: OrderModificationGuard) throws -> OrderIntent {
    try OrderPlanner.preview(
        market: modificationMarket, side: guardValue.original.side == "B" ? .buy : .sell,
        kind: guardValue.kind, size: "0.5", isUSD: false, price: "2050",
        trigger: guardValue.kind == .takeProfit ? "1900" : "2150", mark: 2000,
        leverage: 5, reduceOnly: guardValue.original.reduceOnly ?? false,
        triggerExecution: guardValue.triggerExecution, modificationGuard: guardValue)
}

@Test func orderModificationPreservesAllSupportedKindsAndExactTriggerEncoding() throws {
    for type in ["Limit", "Stop Market", "Stop Limit", "Take Profit Market", "Take Profit Limit"] {
        let original = modificationOrder(type: type, isTrigger: type != "Limit")
        let guardValue = try OrderModificationGuard(
            address: modificationOwner, order: original, market: modificationMarket)
        let intent = try modificationIntent(guardValue)
        try guardValue.validate(
            currentOrders: [original], intent: intent, address: modificationOwner.uppercased())
        try intent.validateModificationTarget(oid: 123, address: modificationOwner)
        let wire = try JSONDecoder().decode(
            JSONValue.self, from: ExchangeAction.modify(oid: 123, intent: intent).jsonData())
        #expect(wire["type"] == .string("batchModify") && wire["modifies"].array.count == 1)
        #expect(wire["a"] == .bool(true))
        let clientID = "0x11111111111111111111111111111111"
        let identified = try JSONDecoder().decode(
            JSONValue.self,
            from: ExchangeAction.modify(oid: 123, intent: intent, cloid: clientID).jsonData())
        #expect(identified["modifies"].array[0]["order"]["c"] == .string(clientID))
        #expect(identified["modifies"].array[0]["oid"] == .integer(123))
        #expect(identified["a"] == .bool(true))
        let replacement = wire["modifies"].array[0]
        #expect(replacement["order"]["c"] == .null)
        #expect(replacement["oid"] == .integer(123) && replacement["order"]["s"] == .string("0.5"))
        #expect(
            replacement["order"]["b"] == .bool(true) && replacement["order"]["r"] == .bool(false))
        if intent.kind.conditional {
            #expect(
                replacement["order"]["t"]["trigger"]["isMarket"] == .bool(type.hasSuffix("Market")))
            #expect(replacement["order"]["t"]["trigger"]["triggerPx"] == .string(intent.trigger!))
            #expect(
                replacement["order"]["t"]["trigger"]["tpsl"]
                    == .string(intent.kind == .stop ? "sl" : "tp"))
        } else {
            #expect(replacement["order"]["t"]["limit"]["tif"] == .string("Gtc"))
        }
    }
}

@Test func orderModificationRejectsMissingChangedPartialOrForeignOriginals() throws {
    let original = modificationOrder()
    let guardValue = try OrderModificationGuard(
        address: modificationOwner, order: original, market: modificationMarket)
    let intent = try modificationIntent(guardValue)
    let changed: [[OpenOrder]] = [
        [], [original, original], [modificationOrder(size: "0.8")],
        [modificationOrder(price: "2400")], [modificationOrder(trigger: "2200")],
        [modificationOrder(type: "Stop Limit")], [modificationOrder(oid: 124)],
        [modificationOrder(coin: "BTC")], [modificationOrder(side: "A")],
        [modificationOrder(reduceOnly: true)], [modificationOrder(positionTpsl: true)]
    ]
    for rows in changed {
        #expect(throws: OrderValidationError.self) {
            try guardValue.validate(currentOrders: rows, intent: intent, address: modificationOwner)
        }
    }
    #expect(throws: OrderValidationError.self) {
        try guardValue.validate(
            currentOrders: [original], intent: intent,
            address: "0x2222222222222222222222222222222222222222")
    }
    // Equivalent decimal representations are not a changed quantity/price.
    try guardValue.validate(
        currentOrders: [modificationOrder(size: "1.00", price: "2300.0", trigger: "2100.00")],
        intent: intent, address: modificationOwner)
    for oid in [UInt64(124), nil] {
        #expect(throws: OrderValidationError.self) {
            try intent.validateModificationTarget(oid: oid, address: modificationOwner)
        }
    }
}

@Test func orderModificationDoesNotInferMissingOrWholePositionProtectionDetails() throws {
    for original in [
        modificationOrder(reduceOnly: nil), modificationOrder(isTrigger: nil),
        modificationOrder(positionTpsl: nil), modificationOrder(positionTpsl: true),
        modificationOrder(trigger: "nan"), modificationOrder(size: "0"),
        modificationOrder(oid: -1), modificationOrder(type: "Unknown"),
        modificationOrder(children: [.object(["oid": .integer(456)])])
    ] {
        #expect(OrderModificationGuard.kind(for: original) == nil)
        #expect(throws: OrderValidationError.self) {
            try OrderModificationGuard(
                address: modificationOwner, order: original, market: modificationMarket)
        }
    }
    let original = modificationOrder()
    let value = try OrderModificationGuard(
        address: modificationOwner, order: original, market: modificationMarket)
    for (side, kind, reduceOnly) in [
        (OrderSide.sell, OrderKind.stop, false), (.buy, .limit, false), (.buy, .stop, true)
    ] {
        #expect(throws: OrderValidationError.self) {
            try OrderPlanner.preview(
                market: modificationMarket, side: side, kind: kind, size: "1", isUSD: false,
                price: "2050", trigger: side == .buy ? "2150" : "1900", mark: 2000,
                leverage: 5, reduceOnly: reduceOnly, modificationGuard: value)
        }
    }
}

@Test func orderModificationMetadataSurvivesMatchingSnapshotsButNotDelayedDifferentTriggerData()
throws {
    let full = modificationOrder()
    var stream = try AccountStream(address: modificationOwner)
    let bare = OpenOrder(coin: "ETH", limitPx: "2300", sz: "1", side: "B", oid: 123, timestamp: 100)
    let encoded = try JSONEncoder().encode([bare])
    let values = try JSONDecoder().decode(JSONValue.self, from: encoded)
    try stream.ingest(
        SocketMessage(
            channel: "openOrders",
            data: .object([
                "user": .string(modificationOwner), "dex": .string(""), "orders": values
            ])))
    #expect(stream.needsOrderDetails)
    stream.enrichOrderDetails([modificationOrder(price: "2400", trigger: "2200")])
    #expect(stream.orders[0].triggerPx == nil && stream.needsOrderDetails)
    stream.enrichOrderDetails([full])
    #expect(
        stream.orders[0].triggerPx == "2100" && stream.orders[0].isTrigger == true
            && !stream.needsOrderDetails)
    #expect(stream.takeEvents().isEmpty)
    let roundTrip = try JSONDecoder().decode(OpenOrder.self, from: JSONEncoder().encode(full))
    #expect(roundTrip == full)
    // Child descriptors need not carry a complete parent-order schema.
    let linked = modificationOrder(children: [.object(["oid": .integer(456)])])
    let linkedCopy = try JSONDecoder().decode(OpenOrder.self, from: JSONEncoder().encode(linked))
    #expect(linkedCopy.children?.first?["oid"] == .integer(456))
    #expect(OrderModificationGuard.kind(for: linkedCopy) == nil)
}
