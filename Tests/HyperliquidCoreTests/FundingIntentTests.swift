import Foundation
import Testing

@testable import HyperliquidCore

private let fundingOwner = "0x1111111111111111111111111111111111111111"
private let fundingRecipient = "0x2222222222222222222222222222222222222222"
private func fundingToken(_ spot: Bool = false) throws -> FundingToken {
    try FundingToken(
        index: spot ? 1 : 0, name: spot ? "PURR" : "USDC",
        tokenID: "0x11111111111111111111111111111111", decimals: spot ? 8 : 6)
}

@Test func fundingActionsMatchIndependentSDKDigestSignaturesAndHumanReadableData() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            contentsOf: root.appendingPathComponent("docs/verification/funding/sdk-vectors.json")))
    #expect(
        fixture["source_sha256"].string
            == "938ec0a1f9611874b423ca946696e19a71d32d14709f521ea5d526f4398c0b85")
    #expect(fixture["vectors"].array.count == 12)
    let bytes: Data? = Data(hex: "0123456789012345678901234567890123456789012345678901234567890123")
    let publicKey = try #require(bytes)
    let key = try EphemeralSigningKey(testKey: publicKey)
    for row in fixture["vectors"].array {
        let network = try #require(row["network"].string)
        let environment = try #require(NetworkEnvironment(rawValue: network))
        let rawChain = try #require(row["chainID"].int64)
        let chain = try #require(UInt64(exactly: rawChain))
        let spot = row["kind"].string == "spotSend"
        let intent = try FundingIntent(
            owner: key.address, destination: fundingRecipient, amount: "25.125000",
            operation: row["kind"].string == "withdraw3" ? .withdraw : .send,
            source: spot ? .spot : .perp,
            token: fundingToken(spot), environment: environment, chainID: chain, available: 100)
        let nonce: UInt64 = 1_700_000_000_010
        let digest = intent.digest(nonce: nonce)
        #expect(digest.hex == row["digest"].string)
        #expect(try intent.typedData(nonce: nonce) == row["typedData"])
        #expect(
            try JSONDecoder().decode(JSONValue.self, from: intent.action(nonce: nonce).jsonData())
                == row["action"])
        let signature = try key.sign(digest: digest)
        for (value, name) in [(signature.r, "r"), (signature.s, "s")] {
            let raw = try #require(row["signature"][name].string)
            let hex = String(raw.dropFirst(2))
            #expect(value == "0x" + String(repeating: "0", count: 64 - hex.count) + hex)
        }
        #expect(Int64(signature.v) == row["signature"]["v"].int64)
        let request = try JSONDecoder().decode(
            JSONValue.self, from: intent.request(signature: signature, nonce: nonce))
        #expect(request["action"]["time"] == request["nonce"])
        #expect(request["vaultAddress"] == .null && request["expiresAfter"] == .null)
        let other = try EphemeralSigningKey()
        #expect(throws: WalletError.self) {
            try intent.request(signature: other.sign(digest: digest), nonce: nonce)
        }
    }
}

@Test func fundingPreviewsRejectInvalidAmountsAddressesUnsupportedSourcesAndChangedTokens() throws {
    let token = try fundingToken()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    for amount in [
        "0", "-1", "1e2", "NaN", "1.0000001", "101", "1\n", "1 ",
        "100000000000000000000000000000000000000"
    ] {
        #expect(throws: (any Error).self) {
            try FundingIntent(
                owner: fundingOwner, destination: fundingRecipient, amount: amount,
                operation: .send,
                source: .perp, token: token, environment: .testnet, chainID: 42161, available: 100)
        }
    }
    for destination in [
        fundingOwner, "0x" + String(repeating: "0", count: 40), "0x123", fundingRecipient + "\n"
    ] {
        #expect(throws: WalletError.self) {
            try FundingIntent(
                owner: fundingOwner, destination: destination, amount: "10", operation: .send,
                source: .perp, token: token, environment: .testnet, chainID: 42161, available: 100)
        }
    }
    let intent = try FundingIntent(
        owner: fundingOwner, destination: fundingOwner, amount: "25.125", operation: .withdraw,
        source: .perp, token: token, environment: .testnet, chainID: 42161, available: 100,
        now: date)
    #expect(intent.estimatedFee == 1 && intent.estimatedReceived == Decimal(string: "24.125"))
    try intent.validate(available: 25.125, token: token, now: date.addingTimeInterval(29))
    for (balance, time) in [(Decimal(24), 0.0), (Decimal(100), 30.0), (Decimal(100), -1.0)] {
        #expect(throws: WalletError.self) {
            try intent.validate(
                available: balance, token: token, now: date.addingTimeInterval(time))
        }
    }
    #expect(throws: WalletError.self) {
        try intent.validate(available: 100, token: fundingToken(true), now: date)
    }
    #expect(throws: WalletError.self) {
        try FundingIntent(
            owner: fundingOwner, destination: fundingRecipient, amount: "10", operation: .withdraw,
            source: .spot, token: token, environment: .mainnet, chainID: 1, available: 100)
    }
    #expect(throws: WalletError.self) {
        try FundingIntent(
            owner: fundingOwner, destination: fundingRecipient, amount: "10", operation: .send,
            source: .perp, token: fundingToken(true), environment: .mainnet, chainID: 1,
            available: 100)
    }
}

@Test func fundingTokenMetadataRejectsDuplicateIdentityAndUsesExactTransferPrecision() throws {
    let row: JSONValue = .object([
        "index": .integer(1), "name": .string("PURR"), "weiDecimals": .integer(8),
        "tokenId": .string("0x11111111111111111111111111111111")
    ])
    let tokens = try FundingToken.parse(meta: .object(["tokens": .array([row])]))
    #expect(tokens == [try fundingToken(true)])
    #expect(throws: APIError.self) {
        try FundingToken.parse(meta: .object(["tokens": .array([row, row])]))
    }
    #expect(throws: APIError.self) { try FundingToken.parse(meta: .null) }
    // Preserve the literal name, including the trailing space in a real testnet token.
    let spaced: JSONValue = .object([
        "index": .integer(3), "name": .string("JPL "),
        "weiDecimals": .integer(5), "tokenId": .string("0x68046c075c2c34873fd465c76804ef90")
    ])
    let exact = try FundingToken.parse(meta: .object(["tokens": .array([row, spaced])]))
    #expect(exact[1].wireName == "JPL :0x68046c075c2c34873fd465c76804ef90")
    let transfer = try FundingIntent(
        owner: fundingOwner, destination: "0x2222222222222222222222222222222222222222",
        amount: "1.23456", operation: .send, source: .spot, token: exact[1], environment: .testnet,
        chainID: 421614, available: 2)
    #expect(try transfer.typedData(nonce: 100)["message"]["token"].string == exact[1].wireName)
    let unpadded: JSONValue = .object([
        "index": .integer(3), "name": .string("SHORT"),
        "weiDecimals": .integer(5), "tokenId": .string("0x1")
    ])
    #expect(
        try FundingToken.parse(meta: .object(["tokens": .array([unpadded])]))[0].wireName
            == "SHORT:0x1")
    let padded: JSONValue = .object([
        "index": .integer(4), "name": .string("JPL"),
        "weiDecimals": .integer(5), "tokenId": .string("0x00000000000000000000000000000001")
    ])
    #expect(throws: APIError.self) {
        try FundingToken.parse(meta: .object(["tokens": .array([unpadded, padded])]))
    }
    #expect(try FundingIntent.normalize("0.00000001", decimals: 8) == "0.00000001")
    #expect(try FundingIntent.normalize("00025.125000", decimals: 6) == "25.125")
    #expect(throws: WalletError.self) { try FundingIntent.normalize("1.0", decimals: 0) }
    #expect(throws: WalletError.self) { try FundingIntent.normalize("1.000000001", decimals: 8) }
}

@Test func bridgeDepositsEncodeExactUSDCTransferAndBindNetworkWalletBalancesAndReceiptAge() throws {
    for environment in NetworkEnvironment.allCases {
        let intent = try BridgeDepositIntent(
            owner: fundingOwner, amount: "5.125000", environment: environment)
        let route = ArbitrumBridge(environment: environment)
        let transaction = try intent.transaction
        #expect(transaction.to == route.token && transaction.from == fundingOwner)
        #expect(
            transaction.data == "0xa9059cbb" + String(repeating: "0", count: 24)
                + route.bridge.dropFirst(2) + String(repeating: "0", count: 58) + "4e3388")
        #expect(transaction.json["value"].string == "0x0")
        #expect(try EthereumQuantity.parse("0x4e3388") == 5_125_000)
        let start = ReceiptClock.now
        let snapshot = BridgeDepositSnapshot(
            owner: fundingOwner, route: route, transaction: transaction,
            availableUSDC: 6, nativeWei: 1_000_000_000_000, gasLimit: 100_000, gasPrice: 1_000_000,
            startedAt: start)
        try snapshot.validate(intent: intent, now: start + 14)
        #expect(throws: WalletError.self) { try snapshot.validate(intent: intent, now: start + 15) }
        #expect(throws: WalletError.self) { try snapshot.validate(intent: intent, now: start - 1) }
        let connection = try WalletConnection(address: fundingOwner, chainID: route.chainID)
        try intent.validate(snapshot: snapshot, connection: connection)
        let wrong = try WalletConnection(address: fundingOwner, chainID: 1)
        #expect(throws: WalletError.self) {
            try intent.validate(snapshot: snapshot, connection: wrong)
        }
    }
    for amount in ["4.999999", "0", "-5", "5.0000001", "NaN"] {
        #expect(throws: (any Error).self) {
            try BridgeDepositIntent(owner: fundingOwner, amount: amount, environment: .testnet)
        }
    }
    for value in ["", "0x", "0xG", "1", "0x" + String(repeating: "f", count: 64)] {
        #expect(throws: APIError.self) { try EthereumQuantity.parse(value) }
    }
    #expect(try EthereumQuantity.parse("0x20000000000001") == 9_007_199_254_740_993)
    #expect(throws: WalletError.self) { try WalletTransaction.requireHash("0x123") }
    #expect(throws: WalletError.self) {
        try WalletTransaction.requireHash("0x" + String(repeating: "a", count: 64) + "\n")
    }
}
