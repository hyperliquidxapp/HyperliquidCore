import Foundation
import Testing

@testable import HyperliquidCore

@Test func transferSigningMatchesIndependentEthAccountEncoder() throws {
    let key = try EphemeralSigningKey(
        testKey: Data(hex: "0123456789012345678901234567890123456789012345678901234567890123")!)
    let nonce: UInt64 = 1_700_000_000_010
    let vectors = [
        (
            true, "4bda4f3129840b572a8bb7c5e92ec228424a628c9c95f1e931a79bee4e3f6ae9",
            "6a9024067be3706e71061bab0cefe92831dc81599825546d34925840074c28880bb0370671bb4904addf718e181a671022f65184ef03185b331dd8abbb99b6cb1c"
        ),
        (
            false, "55a7888625a2e62302347a157209873fe5a2033c14499f95230a247265b50aa0",
            "ac31e29d626c42afe04f8644105bd9812dc980f6909d7a07797d1732ff95505a24da2f6c4446a51b6ac2e2c3123e837f7421bef7b3e9fc076576f1f7412dd7b51b"
        )
    ]
    for (direction, expectedDigest, expectedSignature) in vectors {
        let intent = try BalanceTransferIntent(
            owner: key.address, amount: "25.125000", toPerp: direction, environment: .testnet,
            chainID: 42161,
            available: 100)
        #expect(intent.amount == "25.125")
        #expect(intent.digest(nonce: nonce).hex == "0x" + expectedDigest)
        let signature = try key.sign(digest: intent.digest(nonce: nonce))
        let expected = try WalletSignature(hex: expectedSignature)
        #expect(signature.r == expected.r)
        #expect(signature.s == expected.s)
        #expect(signature.v == expected.v)
        let request = try JSONDecoder().decode(
            JSONValue.self, from: intent.request(signature: expected, nonce: nonce))
        #expect(request["action"]["nonce"] == request["nonce"])
        #expect(request["action"]["toPerp"].bool == direction)
        #expect(request["action"]["hyperliquidChain"].string == "Testnet")
        #expect(request["expiresAfter"] == .null)
        #expect(request["vaultAddress"] == .null)
        let wrongKey = try EphemeralSigningKey()
        #expect(throws: WalletError.self) {
            try intent.request(
                signature: wrongKey.sign(digest: intent.digest(nonce: nonce)), nonce: nonce)
        }
    }
}

@Test func transferPreviewEnforcesAmountBalancePrecisionAndFreshness() throws {
    let owner = "0x1111111111111111111111111111111111111111"
    for amount in [
        "0", "-1", "1e2", "NaN", "0.0000001", "101",
        "100 subaccount:0x1111111111111111111111111111111111111111"
    ] {
        #expect(throws: WalletError.self) {
            try BalanceTransferIntent(
                owner: owner, amount: amount, toPerp: true, environment: .testnet, chainID: 42161,
                available: 100)
        }
    }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let intent = try BalanceTransferIntent(
        owner: owner, amount: "25", toPerp: true, environment: .testnet, chainID: 42161,
        available: 100, now: date)
    try intent.validate(available: 25, now: date.addingTimeInterval(29))
    #expect(throws: WalletError.self) { try intent.validate(available: 24, now: date) }
    #expect(throws: WalletError.self) {
        try intent.validate(available: 25, now: date.addingTimeInterval(30))
    }
    #expect(throws: WalletError.self) {
        try intent.validate(available: 25, now: date.addingTimeInterval(-1))
    }
}

@Test func transferBalanceUsesFreeSpotUSDCAndPerpWithdrawable() throws {
    let account = try JSONDecoder().decode(
        AccountState.self,
        from: Data(
            #"{"marginSummary":{"accountValue":"100","totalNtlPos":"0","totalRawUsd":"100","totalMarginUsed":"80"},"withdrawable":"20","assetPositions":[],"time":1700000000000}"#
                .utf8))
    let spot: JSONValue = .object([
        "balances": .array([
            .object([
                "coin": .string("USDC"), "token": .integer(0), "total": .string("898"),
                "hold": .string("98")
            ]),
            .object([
                "coin": .string("OTHER"), "token": .integer(1), "total": .string("10000"),
                "hold": .string("0")
            ])
        ])
    ])
    #expect(try BalanceTransferIntent.available(toPerp: true, spot: spot, account: account) == 800)
    #expect(try BalanceTransferIntent.available(toPerp: false, spot: spot, account: account) == 20)
    #expect(
        try BalanceTransferIntent.available(
            toPerp: true, spot: .object(["balances": .array([])]), account: account)
            == 0)
    #expect(throws: APIError.self) {
        try BalanceTransferIntent.available(toPerp: true, spot: .null, account: account)
    }
}
