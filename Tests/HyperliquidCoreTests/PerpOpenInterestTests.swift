import Foundation
import Testing

@testable import HyperliquidCore

private let oiOwner = "0x1111111111111111111111111111111111111111"
private let oiMarket = Market(
    coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 25, kind: .perp)
private func oiIntent(
    side: OrderSide = .sell, size: String = "1.2345", reduceOnly: Bool = false,
    kind: OrderKind = .limit, market: Market = oiMarket
) throws -> OrderIntent {
    try OrderPlanner.preview(
        market: market, side: side, kind: kind, size: size, isUSD: false, price: "2000",
        trigger: kind.conditional ? (kind == .stop ? "1900" : "2100") : nil,
        mark: 2000, leverage: 5, reduceOnly: reduceOnly, triggerExecution: .market)
}
private func oiAccount(_ sizes: [String], coin: String = "ETH") -> JSONValue {
    .object([
        "assetPositions": .array(
            sizes.map { size in
                .object([
                    "position": .object([
                        "coin": .string(coin), "szi": .string(size), "entryPx": .string("2000"),
                        "positionValue": .string("2469"), "unrealizedPnl": .string("0"),
                        "returnOnEquity": .string("0"), "marginUsed": .string("493.8"),
                        "leverage": .object(["type": .string("cross"), "value": .integer(5)])
                    ])
                ])
            }),
        "marginSummary": .object([
            "accountValue": .string("10000"), "totalMarginUsed": .string("493.8"),
            "totalNtlPos": .string("2469")
        ]),
        "withdrawable": .string("9506.2"), "time": .integer(100)
    ])
}
private func oiSnapshot(
    _ intent: OrderIntent, sizes: [String] = ["1.2345"], capped: Bool = true
) async throws -> PerpOpenInterestSnapshot {
    try #require(
        await PerpOpenInterestSnapshot.read(
            intent: intent, address: oiOwner, environment: .testnet,
            info: { request in
                request["type"] == .string("perpsAtOpenInterestCap")
                    ? .array(capped ? [.string("ETH")] : []) : oiAccount(sizes)
            }, now: { 50 }))
}

@Test func openInterestCapsDecodeStrictlyWithoutTreatingMalformedResponsesAsFreeCapacity() throws {
    #expect(try PerpOpenInterestSnapshot.cappedMarkets(.array([])).isEmpty)
    #expect(
        try PerpOpenInterestSnapshot.cappedMarkets(
            .array([
                .string("ETH"), .string("kPEPE"), .string("DELISTED")
            ])) == ["ETH", "kPEPE", "DELISTED"])
    for response in [
        JSONValue.null, .object([:]), .string("ETH"), .array([.integer(1)]),
        .array([.string("")]), .array([.string(" ETH")]), .array([.string("ETH\n")]),
        .array([.string("ETH"), .string("ETH")]), .array([.string("xyz:ETH")]),
        .array(Array(repeating: .string("ETH"), count: 10_001))
    ] {
        #expect(throws: APIError.self) { try PerpOpenInterestSnapshot.cappedMarkets(response) }
    }
}

@Test func openInterestAtCapAllowsExactReductionsButRejectsOpeningIncreasingAndEvenSmallerFlips()
async throws {
    for size in ["1.2345", "-1.2345"] {
        let closing: OrderSide = size.hasPrefix("-") ? .buy : .sell
        for reduceOnly in [false, true] {
            for quantity in ["0.1", "1.2345"] {
                let intent = try oiIntent(side: closing, size: quantity, reduceOnly: reduceOnly)
                let snapshot = try await oiSnapshot(intent, sizes: [size])
                try snapshot.validate(
                    intent: intent, address: oiOwner, environment: .testnet, now: 50)
            }
        }
        for (side, quantity) in [
            (closing, "1.2346"), (closing, "1.5"), (closing, "2.469"),
            (closing == .buy ? OrderSide.sell : .buy, "0.1")
        ] {
            let intent = try oiIntent(side: side, size: quantity)
            let snapshot = try await oiSnapshot(intent, sizes: [size])
            #expect(throws: OrderValidationError.self) {
                try snapshot.validate(
                    intent: intent, address: oiOwner, environment: .testnet, now: 50)
            }
        }
    }
    let opening = try oiIntent(side: .buy)
    for sizes in [[], ["0"], ["-0.0000"]] {
        let snapshot = try await oiSnapshot(opening, sizes: sizes)
        #expect(throws: OrderValidationError.self) {
            try snapshot.validate(intent: opening, address: oiOwner, environment: .testnet, now: 50)
        }
    }
    for kind in [OrderKind.stop, .takeProfit] {
        let intent = try oiIntent(reduceOnly: true, kind: kind)
        let snapshot = try await oiSnapshot(intent)
        try snapshot.validate(intent: intent, address: oiOwner, environment: .testnet, now: 50)
    }
    let unrestricted = try await oiSnapshot(opening, sizes: [], capped: false)
    try unrestricted.validate(intent: opening, address: oiOwner, environment: .testnet, now: 50)
}

@Test func openInterestSnapshotBindsIntentOwnerNetworkAndTheEntireReadWindow() async throws {
    let intent = try oiIntent()
    let snapshot = try await oiSnapshot(intent)
    try snapshot.validate(
        intent: intent, address: oiOwner.uppercased(), environment: .testnet, now: 64.999)
    #expect(!snapshot.isFresh(now: 65))
    for now in [49.999, 65, Double.nan, Double.infinity] {
        #expect(throws: OrderValidationError.self) {
            try snapshot.validate(intent: intent, address: oiOwner, environment: .testnet, now: now)
        }
    }
    for owner in ["0x2222222222222222222222222222222222222222", "invalid"] {
        #expect(throws: OrderValidationError.self) {
            try snapshot.validate(intent: intent, address: owner, environment: .testnet, now: 50)
        }
    }
    #expect(throws: OrderValidationError.self) {
        try snapshot.validate(intent: oiIntent(), address: oiOwner, environment: .testnet, now: 50)
    }
    #expect(throws: OrderValidationError.self) {
        try snapshot.validate(intent: intent, address: oiOwner, environment: .mainnet, now: 50)
    }
}

@Test func openInterestRejectsUnknownDuplicatePositionsAndUnsupportedMarketScopes() async throws {
    let intent = try oiIntent()
    for sizes in [["1abc"], ["NaN"], ["1", "1"], [" 1"], ["1e0"]] {
        await #expect(throws: (any Error).self) { try await oiSnapshot(intent, sizes: sizes) }
    }
    let external = Market(
        coin: "xyz:ETH", symbol: "ETH", assetID: 110_001, sizeDecimals: 4, maxLeverage: 25,
        kind: .perp)
    await #expect(throws: OrderValidationError.self) {
        try await oiSnapshot(oiIntent(market: external))
    }
}

private final class OIClock: @unchecked Sendable {
    private let lock = NSLock()
    private let readings: [Double]
    private var index = 0
    init(_ readings: [Double]) { self.readings = readings }
    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let value = readings[min(index, readings.count - 1)]
        index += 1
        return value
    }
}

@Test func openInterestDoesNotReadAccountsBelowCapOrSpotAndRejectsDelayedReads() async throws {
    let intent = try oiIntent()
    let response: @Sendable ([String: JSONValue]) async throws -> JSONValue = { request in
        #expect(request == ["type": .string("perpsAtOpenInterestCap"), "dex": .string("")])
        return .array([])
    }
    for readings in [[50.0, 65], [50, 49], [-1, 0], [Double.nan, 50], [50, Double.infinity]] {
        let clock = OIClock(readings)
        await #expect(throws: OrderValidationError.self) {
            try await PerpOpenInterestSnapshot.read(
                intent: intent, address: oiOwner, environment: .testnet, info: response,
                now: { clock.now() })
        }
    }
    let spot = Market(
        coin: "@107", symbol: "HYPE", assetID: 10_107, sizeDecimals: 2, maxLeverage: 1, kind: .spot)
    let spotIntent = try OrderPlanner.preview(
        market: spot, side: .buy, kind: .limit, size: "1", isUSD: false, price: "20",
        trigger: nil, mark: 20, leverage: 1, reduceOnly: false)
    #expect(
        try await PerpOpenInterestSnapshot.read(
            intent: spotIntent, address: oiOwner, environment: .testnet,
            info: { _ in
                Issue.record("Spot must not read perpetual caps")
                return .null
            }) == nil)
}

private actor OIReadGate {
    private var pending: CheckedContinuation<JSONValue, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func read() async -> JSONValue {
        await withCheckedContinuation {
            pending = $0
            waiter?.resume()
            waiter = nil
        }
    }
    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() {
        pending?.resume(returning: .array([]))
        pending = nil
    }
}

@Test func openInterestCanceledReadCannotReturnAnAuthorizingSnapshot() async throws {
    let intent = try oiIntent()
    let gate = OIReadGate()
    let task = Task {
        try await PerpOpenInterestSnapshot.read(
            intent: intent, address: oiOwner, environment: .testnet,
            info: { _ in await gate.read() })
    }
    await gate.waitForRead()
    task.cancel()
    await gate.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"))
func openInterestProductionNIOProbeDecodesBothNetworksWithoutAssumingCapAvailability() async throws {
    let owner = ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"] ?? oiOwner
    for environment in [NetworkEnvironment.mainnet, .testnet] {
        let api = HyperliquidAPI(environment: environment)
        let catalog = try await api.catalog()
        let market = try #require(catalog.markets.first { $0.coin == "ETH" && $0.kind == .perp })
        let mark = try #require(Double(catalog.contexts[market.coin]?.markPx ?? ""))
        let intent = try OrderPlanner.preview(
            market: market, side: .buy, kind: .market, size: "20", isUSD: true, price: "",
            trigger: nil, mark: mark, leverage: 1, reduceOnly: false)
        let snapshot = try #require(await api.openInterestSnapshot(intent: intent, address: owner))
        #expect(snapshot.market == market && snapshot.owner == owner.lowercased())
        #expect(snapshot.environment == environment && snapshot.isFresh())
        print(
            "Read-only \(environment.rawValue) ETH open-interest state decoded: \(snapshot.atCap ? "at cap" : "not at cap")."
        )
    }
}
