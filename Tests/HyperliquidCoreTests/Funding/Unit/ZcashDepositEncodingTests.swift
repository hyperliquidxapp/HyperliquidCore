import Foundation
import Testing

@testable import HyperliquidCore

@Test func zcashDepositTEXEncodingMatchesZIP320VectorAndRejectsChangedChecksumAndNetwork() throws {
    let address = "tex1s2rt77ggv6q989lr49rkgzmh5slsksa9khdgte"
    #expect(try ZcashDepositEncoding.transparentAddress(fromTEX: address, environment: .mainnet)
        == "t1VmmGiyjVNeCjxDZzg7vZmd99WyzVby9yC")
    #expect(throws: (any Error).self) {
        try ZcashDepositEncoding.transparentAddress(fromTEX: address, environment: .testnet)
    }
    #expect(throws: (any Error).self) {
        try ZcashDepositEncoding.transparentAddress(fromTEX: String(address.dropLast()) + "q", environment: .mainnet)
    }
}

@Test func zcashDepositAddressAuthenticatesTheExactRecipientBehindTheReturnedTEXAddress() throws {
    let response: JSONValue = .object([
        "status": .string("OK"), "address": .string("tex133pe24m5utaqrfjhln0xd3resg74z2rhenesz0"),
        "signatures": .object([
            "field-node": .string("tNY/nGrmLSf2JasSZAak3vQ1Wb0tebiTCxqcrziGiGR9mLlvDqscNDlMqNs+I7NZbFg259aWvaFb+NVe9XtAqA=="),
            "hl-node": .string("o+T8aWlLCoJYVoCnSPzRH3mWUXxCqeGpS6Pu1uPGKXX3EcX1q1FCLZugdDO/qKo7OpB0lZgHJXqjIZWfIWrCbQ==")
        ])
    ])
    let owner = "0x5742261Ef0516AD70C4217cc573fa21485289D3B"
    let verified = try UnitDepositAddress(response: response, asset: .zec, owner: owner, environment: .mainnet)
    #expect(verified.address == response["address"].string && verified.owner == owner.lowercased())
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(response: response, asset: .zec, owner: "0x1111111111111111111111111111111111111111",
                               environment: .mainnet)
    }
}
