import Foundation
import Testing

@testable import HyperliquidCore

@Test func walletConnectionRejectsAccountChainAndReconnectChanges() throws {
    let address = "0xAbCdAbCdAbCdAbCdAbCdAbCdAbCdAbCdAbCdAbCd"
    let first = try WalletConnection(address: address, chainID: 42161)
    let equivalent = try WalletConnection(
        address: address.lowercased(), chainID: 42161, id: first.id)
    try first.requireCurrent(equivalent)
    #expect(throws: WalletError.self) { try first.requireCurrent(nil) }
    #expect(throws: WalletError.self) {
        try first.requireCurrent(WalletConnection(address: address, chainID: 42161))
    }
    #expect(throws: WalletError.self) {
        try first.requireCurrent(WalletConnection(address: address, chainID: 1, id: first.id))
    }
    #expect(throws: WalletError.self) {
        try first.requireCurrent(
            WalletConnection(
                address: "0x1111111111111111111111111111111111111111", chainID: 42161, id: first.id)
        )
    }
    #expect(throws: WalletError.self) { try WalletConnection(address: address, chainID: 0) }
    #expect(throws: WalletError.self) {
        try WalletConnection(address: address, chainID: UInt64.max)
    }
}
