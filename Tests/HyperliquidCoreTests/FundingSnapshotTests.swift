import Foundation
import Testing

@testable import HyperliquidCore

@Test func fundingSnapshotUsesMatchingTokensFreeSpotBalancesAndFreshClassicPerpWithdrawable() throws {
    let owner = "0x1111111111111111111111111111111111111111"
    let usdc = try FundingToken(
        index: 0, name: "USDC", tokenID: "0x11111111111111111111111111111111", decimals: 8)
    let purr = try FundingToken(
        index: 1, name: "PURR", tokenID: "0x22222222222222222222222222222222", decimals: 8)
    let start = ReceiptClock.now
    func snapshot(hold: String = "25.25", coin: String = "PURR", mode: String = "default") throws
    -> FundingAccountSnapshot {
        try FundingAccountSnapshot(
            address: owner, environment: .testnet, tokens: [usdc, purr],
            spot: .object([
                "balances": .array([
                    .object([
                        "token": .integer(1), "coin": .string(coin), "total": .string("100.125"),
                        "hold": .string(hold)
                    ])
                ])
            ]),
            perpAvailable: 50, startedAt: start, mode: mode)
    }
    let balance = try snapshot()
    #expect(try balance.available(source: .perp, token: usdc) == 50)
    #expect(try balance.available(source: .spot, token: purr) == Decimal(string: "74.875"))
    #expect(try balance.available(source: .spot, token: usdc) == 0)
    let intent = try FundingIntent(
        owner: owner, destination: "0x3333333333333333333333333333333333333333", amount: "70",
        operation: .send, source: .spot, token: purr, environment: .testnet, chainID: 42161,
        available: 74.875)
    try balance.validate(intent: intent)
    for hold in ["101", "-1", "NaN", "1e2"] {
        #expect(throws: (any Error).self) {
            try snapshot(hold: hold).available(source: .spot, token: purr)
        }
    }
    #expect(throws: APIError.self) {
        try snapshot(coin: "OTHER").available(source: .spot, token: purr)
    }
    #expect(throws: WalletError.self) { try balance.available(source: .perp, token: purr) }
    #expect(throws: WalletError.self) { try snapshot(mode: "unifiedAccount") }
    #expect(throws: WalletError.self) { try balance.requireFresh(now: start + 15) }
    #expect(throws: WalletError.self) { try balance.requireFresh(now: start - 1) }
    let mainnet = try FundingAccountSnapshot(
        address: owner, environment: .mainnet, tokens: [usdc, purr], spot: balance.spot,
        perpAvailable: 50, startedAt: start, mode: "default")
    #expect(throws: WalletError.self) { try mainnet.validate(intent: intent) }
}
