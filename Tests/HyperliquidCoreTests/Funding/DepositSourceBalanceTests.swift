import Foundation
import Testing

@testable import HyperliquidCore

@Test func bitcoinDepositBalanceExcludesPendingCreditsAndSpendsAndRejectsAnotherAddress() throws {
    let owner = "bc1qexample"
    let response: JSONValue = .object([
        "address": .string(owner),
        "chain_stats": .object(["funded_txo_sum": .integer(123_456_789), "spent_txo_sum": .integer(20_000_000)]),
        "mempool_stats": .object(["funded_txo_sum": .integer(80_000_000), "spent_txo_sum": .integer(3_000_000)])
    ])
    #expect(try DepositSourceBalance.bitcoin(response, owner: owner) == Decimal(string: "1.00456789"))
    #expect(throws: (any Error).self) { try DepositSourceBalance.bitcoin(response, owner: "bc1qother") }
    #expect(throws: (any Error).self) { try DepositSourceBalance.bitcoin(.null, owner: owner) }
}

@Test func solanaDepositBalancesSumExactTokenUnitsExcludeFrozenAccountsAndRejectWrongMetadata() throws {
    let asset = DepositAsset.spx
    let mint = try #require(asset.solanaMint)
    let owner = "7bTKsATL8zfQXLfqYExraqbuVy5753yRpmMrmZGQ94o3"
    func account(_ address: String, _ raw: String, state: String = "initialized", decimals: Int = 8) -> JSONValue {
        .object([
            "pubkey": .string(address), "account": .object([
                "data": .object(["parsed": .object([
                    "type": .string("account"), "info": .object([
                        "owner": .string(owner), "mint": .string(mint.address), "state": .string(state),
                        "tokenAmount": .object(["amount": .string(raw), "decimals": .integer(Int64(decimals))])
                    ])
                ])])
            ])
        ])
    }
    let accounts = [account("one", "123456789"), account("two", "2"), account("frozen", "100000000", state: "frozen")]
    #expect(try DepositSourceBalance.solanaTokens(.object(["value": .array(accounts)]), asset: asset, owner: owner)
        == Decimal(string: "1.23456791"))
    #expect(try DepositSourceBalance.solanaTokens(.object(["value": .array([])]), asset: asset, owner: owner) == 0)
    for invalid in [
        [account("one", "1", decimals: 6)], [account("one", "18446744073709551616")],
        [account("same", "1"), account("same", "1")]
    ] {
        #expect(throws: (any Error).self) {
            try DepositSourceBalance.solanaTokens(.object(["value": .array(invalid)]), asset: asset, owner: owner)
        }
    }
    #expect(throws: (any Error).self) {
        try DepositSourceBalance.solanaTokens(.object(["value": .array(accounts)]), asset: .pump, owner: owner)
    }
    #expect(throws: (any Error).self) {
        try DepositSourceBalance.solanaTokens(.object(["value": .array(accounts)]), asset: asset, owner: "other")
    }
}
