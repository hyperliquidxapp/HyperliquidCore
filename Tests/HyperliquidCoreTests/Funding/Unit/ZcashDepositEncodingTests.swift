import Foundation
import Testing

@testable import HyperliquidCore

@Test func zcashDepositTEXEncodingMatchesZIP320VectorAndRejectsChangedChecksumAndNetwork() throws {
    let address = "tex1s2rt77ggv6q989lr49rkgzmh5slsksa9khdgte"
    #expect(
        try ZcashDepositEncoding.transparentAddress(fromTEX: address, environment: .mainnet)
            == "t1VmmGiyjVNeCjxDZzg7vZmd99WyzVby9yC")
    #expect(throws: (any Error).self) {
        try ZcashDepositEncoding.transparentAddress(fromTEX: address, environment: .testnet)
    }
    #expect(throws: (any Error).self) {
        try ZcashDepositEncoding.transparentAddress(
            fromTEX: String(address.dropLast()) + "q", environment: .mainnet)
    }
}

@Test func zcashDepositAddressAuthenticatesTheExactRecipientBehindTheReturnedTEXAddress() throws {
    let response: JSONValue = .object([
        "address": .string("tex1m69nhjfr5vjaa3rqu6u53kkrga0mnlkndntdgn"),
        "signatures": .object([
            "field-node": .string(
                "NrlY68iVAKjCCsr2t4m5QPTaPYe4qYFk1ppaVUGMnI60hIiiG/onqpegkTIA7NCIoL02bLa+WsJMpQhcgFoMxA=="
            ),
            "hl-node": .string(
                "msSGBeopiyo7c1bijWlr3qBKMc39PtZRTBt5i984u5LvRaVtvEuI0JfcM2+cbo6hyExgSCxSb4D6V/xI/t1DYg=="
            ),
        ]),
        "status": .string("OK"),
    ])
    let owner = "0xAbCdAbCdAbCdAbCdAbCdAbCdAbCdAbCdAbCdAbCd"
    let verified = try UnitDepositAddress(
        response: response, asset: .zec, owner: owner, environment: .mainnet)
    #expect(verified.address == response["address"].string && verified.owner == owner.lowercased())
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(
            response: response, asset: .zec, owner: "0x1111111111111111111111111111111111111111",
            environment: .mainnet)
    }
}
