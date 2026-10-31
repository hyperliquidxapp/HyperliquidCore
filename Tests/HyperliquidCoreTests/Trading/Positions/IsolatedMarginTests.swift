import Foundation
import Testing

@testable import HyperliquidCore

private let marginMarket = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 25, kind: .perp)
private let marginOwner = "0x1111111111111111111111111111111111111111"
private func marginState(
    owner: String = marginOwner, market: Market = marginMarket, size: String = "1",
    cash: String? = nil, available: String = "1000", mode: String = "default",
    leverage: Int = 5, type: String = "isolated", notional: String = "2000",
    tierLeverage: Int = 25
) throws -> IsolatedMarginState {
    let position = Position(
        coin: "ETH", szi: size, entryPx: "2000", liquidationPx: "1450", positionValue: notional,
        unrealizedPnl: "0", returnOnEquity: "0", marginUsed: "600",
        leverage: Leverage(
            type: type, value: leverage, rawUsd: cash ?? (size.hasPrefix("-") ? "2600" : "-1400")))
    let account = AccountState(
        assetPositions: [.init(position: position)],
        marginSummary: .init(
            accountValue: "1600", totalMarginUsed: "600", totalNtlPos: "2000", totalRawUsd: "0"),
        crossMarginSummary: nil, crossMaintenanceMarginUsed: nil, withdrawable: available, time: 100
    )
    return try IsolatedMarginState(
        owner: owner, market: market, account: account, mode: mode,
        table: MarginTable(id: 25, bounds: [(0, tierLeverage)]))
}

@Test func signedMessagePackMatchesIndependentPythonBoundaryVectors() throws {
    // Filled from msgpack 1.1.2, not the Swift encoder.
    let vectors: [(Int64, String)] = [
        (-9_223_372_036_854_775_808, "d38000000000000000"),
        (-2_147_483_649, "d3ffffffff7fffffff"),
        (-2_147_483_648, "d280000000"),
        (-32769, "d2ffff7fff"),
        (-32768, "d18000"),
        (-129, "d1ff7f"),
        (-128, "d080"),
        (-33, "d0df"),
        (-32, "e0"),
        (-1, "ff"),
        (0, "00"),
        (127, "7f"),
        (128, "cc80"),
        (255, "ccff"),
        (256, "cd0100"),
        (65535, "cdffff"),
        (65536, "ce00010000"),
        (2_147_483_648, "ce80000000"),
        (9_223_372_036_854_775_807, "cf7fffffffffffffff")
    ]
    for (value, packed) in vectors {
        #expect(WireValue.int(value).messagePack().hex == "0x" + packed)
        #expect(
            try JSONDecoder().decode(JSONValue.self, from: WireValue.int(value).jsonData())
                == .integer(value))
    }
}

@Test func isolatedMarginUsesSignedEquityAndTransferFloorsForBothPositionDirections() throws {
    for size in ["1", "-1"] {
        let state = try marginState(size: size)
        #expect(state.equity == 600 && state.mark == 2000 && state.availableToRemove == 200)
        let connection = try WalletConnection(address: marginOwner, chainID: 42161)
        let add = try IsolatedMarginIntent(
            state: state, amount: "0001.000001", adding: true,
            environment: .testnet, connection: connection)
        #expect(add.amount == "1.000001" && add.units == 1_000_001)
        #expect(add.resultingEquity == Decimal(string: "601.000001"))
        let remove = try IsolatedMarginIntent(
            state: state, amount: "200", adding: false,
            environment: .testnet, connection: connection)
        #expect(remove.units == -200_000_000 && remove.resultingEquity == 400)
        #expect(remove.liquidationPrice != nil)
        #expect(try marginState(size: size, leverage: 20).availableToRemove == 400)
        #expect(try marginState(size: size, leverage: 20, tierLeverage: 4).availableToRemove == 100)
        #expect(throws: OrderValidationError.self) {
            try IsolatedMarginIntent(
                state: state, amount: "200.000001", adding: false,
                environment: .testnet, connection: connection)
        }
    }
}

@Test func isolatedMarginRejectsUnsupportedModesInvalidAmountsAndChangedSnapshots() throws {
    let connection = try WalletConnection(address: marginOwner, chainID: 42161)
    let state = try marginState()
    for amount in [
        "0", "-1", "1.0000001", "1e2", "1abc", "1\n", " 1", "NaN", "9223372036854.775808",
        "1000.000001"
    ] {
        #expect(throws: OrderValidationError.self) {
            try IsolatedMarginIntent(
                state: state, amount: amount, adding: true, environment: .testnet,
                connection: connection)
        }
    }
    for mode in ["unifiedAccount", "portfolioMargin", "unknown"] {
        #expect(throws: OrderValidationError.self) { try marginState(mode: mode) }
    }
    for size in ["0", "1abc", "NaN"] {
        #expect(throws: OrderValidationError.self) { try marginState(size: size) }
    }
    #expect(throws: OrderValidationError.self) { try marginState(type: "cross") }
    #expect(throws: OrderValidationError.self) {
        try marginState(
            size: "0." + String(repeating: "0", count: 127) + "1",
            notional: "1" + String(repeating: "0", count: 38))
    }
    let strict = Market(
        coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 25, kind: .perp,
        onlyIsolated: true, marginMode: "strictIsolated")
    #expect(try marginState(market: strict).availableToRemove == 0)
    #expect(throws: OrderValidationError.self) {
        try IsolatedMarginIntent(
            state: marginState(market: strict), amount: "1", adding: false,
            environment: .testnet, connection: connection)
    }
    let now = Date(timeIntervalSince1970: 100)
    let intent = try IsolatedMarginIntent(
        state: state, amount: "50", adding: true,
        environment: .testnet, connection: connection, now: now)
    for changed in [
        try marginState(size: "-1"), try marginState(cash: "-1401"),
        try marginState(leverage: 4), try marginState(available: "49"),
        try marginState(tierLeverage: 20),
        try marginState(owner: "0x2222222222222222222222222222222222222222")
    ] {
        #expect(throws: OrderValidationError.self) {
            try intent.validate(current: changed, now: now)
        }
    }
    try intent.validate(
        current: marginState(size: "1.00", cash: "-1400.0"), now: now.addingTimeInterval(29.999))
    for offset in [-1.0, 30, Double.infinity, Double.nan] {
        #expect(throws: OrderValidationError.self) {
            try intent.validate(current: state, now: now.addingTimeInterval(offset))
        }
    }
}

@Test func isolatedMarginSeparatesNoCrossStrictAndUnspecifiedLegacyRestrictions() throws {
    let connection = try WalletConnection(address: marginOwner, chainID: 42161)
    func market(_ mode: String?, isolated: Bool = true) -> Market {
        Market(
            coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 25, kind: .perp,
            onlyIsolated: isolated, marginMode: mode)
    }
    for isolated in [false, true] {
        let state = try marginState(market: market("noCross", isolated: isolated))
        #expect(state.market.onlyIsolated && state.availableToRemove == 200)
        let remove = try IsolatedMarginIntent(
            state: state, amount: "200", adding: false,
            environment: .testnet, connection: connection)
        #expect(remove.units == -200_000_000)
        #expect(throws: OrderValidationError.self) {
            try remove.validate(current: marginState(market: market("strictIsolated")))
        }
        #expect(
            try marginState(market: market("strictIsolated", isolated: isolated)).availableToRemove
                == 0)
    }
    let legacy = try marginState(market: market(nil))
    #expect(legacy.availableToRemove == 0)
    #expect(
        try IsolatedMarginIntent(
            state: legacy, amount: "1", adding: true, environment: .testnet, connection: connection
        ).units == 1_000_000)
    #expect(throws: OrderValidationError.self) {
        try marginState(market: market("futureMode"))
    }
    #expect(throws: OrderValidationError.self) {
        try OrderPlanner.preview(
            market: market("futureMode"), side: .buy, kind: .market, size: "1", isUSD: false,
            price: "", trigger: nil, mark: 2000, leverage: 5, reduceOnly: false)
    }
}

@Test func isolatedMarginSigningMatchesIndependentOfficialSDKBothNetworksAndDirections() throws {
    let key = try EphemeralSigningKey(
        testKey: Data(hex: "0123456789012345678901234567890123456789012345678901234567890123")!)
    let connection = try WalletConnection(address: key.address, chainID: 42161)
    let vectors: [(Bool, Bool, Bool, String, String, String, UInt64)] = [
        (
            true, true, true, "675b41896b8e8ab0468e0eec67ad07bf003cdd0719e6fd9736808c6d20b39f0f",
            "807c9aa0257a0385bb277fbddc9322c012ba1a3ee25854e39fa1504e59c2ac57",
            "7382566fa4e2ce2c0ea01c7ccc9791ea88a16527e096f3ece813c6f962980f3e", 28
        ),
        (
            true, true, false, "675b41896b8e8ab0468e0eec67ad07bf003cdd0719e6fd9736808c6d20b39f0f",
            "7056208ff8e287aaadc262aaa9e62327fcda6c6ca855e4ee91cc80324b65c944",
            "4d24954a1e6889c423e8c7536208ab28a1cb9236cceca8e424b5f45715f8fcf6", 28
        ),
        (
            true, false, true, "ba84b9b31fffe6b2d45232f9513637c55afa01176cd1ad4a64a0995273a9e20d",
            "54cccb37795c34a269d4bac0cd00feeee842c2f6842066d729e17c448cc71383",
            "57720251b720ef947b7d63c970c6ea8cbad66747f6c3ac1a106d0ca71e2f116e", 28
        ),
        (
            true, false, false, "ba84b9b31fffe6b2d45232f9513637c55afa01176cd1ad4a64a0995273a9e20d",
            "2596f4bbb2da0a3461df869e82260c2458acce0167999e8eaef8f20605d132f3",
            "4723a37b14f915cd85af1031ff4363d7523b14264e030c4395b51b7ae4c37bc2", 28
        ),
        (
            false, true, true, "b7ee8b0ea91ab30f8161fd8ba198cbc174353a55b472345717608a91ba72f51a",
            "3eebe39e351277f149ac59069539d48aa48c860963d950253f57bd16c2042220",
            "6b6e3dc2b97aad384c3d9821bb6c3a54c2bc1d38ac98bbde3dd1d0627fe74d81", 28
        ),
        (
            false, true, false, "b7ee8b0ea91ab30f8161fd8ba198cbc174353a55b472345717608a91ba72f51a",
            "170ad069c6d56198cd9dfab34c0d210de0afba07457257d12b3717e3788cca8e",
            "60ccf671639bc9bc1b4def2d4a5f9d7d8e99fc146e0de8a00ed892362388a345", 28
        ),
        (
            false, false, true, "3b05d48d06eb7f1c270e89d8be25e14f036b2dfcab9f17aafba2766fca8e7360",
            "7a00068acd208835673b905abb3784dedd9be0dceacee60ed8029d2c1eb850d8",
            "08b1bac2b95a8a503de7f02c663a7b6782b02fcae2cf14ec4ebae23a40f37056", 28
        ),
        (
            false, false, false, "3b05d48d06eb7f1c270e89d8be25e14f036b2dfcab9f17aafba2766fca8e7360",
            "7b9bd8385cca466088c72ae77aa3acb35e0abf83a9c3ff2b9259a8b5783019c3",
            "502602b512f2b19719b35cc59e52c7c48ffa921503378856f07b218c0128c3e1", 27
        )
    ]
    for (buy, adding, mainnet, hash, r, s, v) in vectors {
        let intent = try IsolatedMarginIntent(
            state: marginState(owner: key.address, size: buy ? "1" : "-1"),
            amount: "125.123456", adding: adding,
            environment: mainnet ? .mainnet : .testnet, connection: connection)
        let nonce: UInt64 = 1_700_000_000_000
        let expiry: UInt64 = 1_700_000_120_000
        #expect(
            try SigningPayload.actionHash(action: intent.action, nonce: nonce, expiresAfter: expiry)
                .hex == "0x" + hash)
        let signature = try key.sign(
            digest: EthereumSigning.actionDigest(
                action: intent.action, nonce: nonce, environment: intent.environment,
                expiresAfter: expiry))
        #expect(signature.r == "0x" + r && signature.s == "0x" + s && signature.v == v)
        let request = try JSONDecoder().decode(
            JSONValue.self,
            from: intent.request(signature: signature, nonce: nonce, expiresAfter: expiry))
        #expect(request["action"]["ntli"] == .integer(adding ? 125_123_456 : -125_123_456))
        #expect(request["action"]["isBuy"] == .bool(buy))
    }
}
