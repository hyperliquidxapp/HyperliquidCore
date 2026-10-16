import Foundation
import Testing

@testable import HyperliquidCore

// Published fixtures from hyperliquid-dex/hyperliquid-python-sdk/tests/signing_test.py.
// This is a public test key, never an application credential.
private let fixtureKey = Data(
    hex: "0123456789012345678901234567890123456789012345678901234567890123")!

@Test func nativeL1SigningMatchesOfficialSDK() throws {
    let key = try EphemeralSigningKey(testKey: fixtureKey)
    let action = WireValue.map([("type", .string("dummy")), ("num", .uint(100_000_000_000))])
    for (environment, r, s, v) in [
        (
            NetworkEnvironment.mainnet,
            "053749d5b30552aeb2fca34b530185976545bb22d0b3ce6f62e31be961a59298",
            "755c40ba9bf05223521753995abb2f73ab3229be8ec921f350cb447e384d8ed8", UInt64(27)
        ),
        (
            .testnet, "542af61ef1f429707e3c76c5293c80d01f74ef853e34b76efffcb57e574f9510",
            "17b8b32f086e8cdede991f1e2c529f5dd5297cbe8128500e00cbaf766204a613", 28
        )
    ] {
        let digest = try EthereumSigning.actionDigest(
            action: action, nonce: 0, environment: environment)
        let signature = try key.sign(digest: digest)
        #expect(signature.r == "0x" + r)
        #expect(signature.s == "0x" + s)
        #expect(signature.v == v)
        #expect(try EthereumSigning.recover(signature: signature, digest: digest) == key.address)
        let changed = try EthereumSigning.actionDigest(
            action: action, nonce: 1, environment: environment)
        #expect(try EthereumSigning.recover(signature: signature, digest: changed) != key.address)
    }
}

@Test func nativeOrderSigningMatchesOfficialSDK() throws {
    let key = try EphemeralSigningKey(testKey: fixtureKey)
    let action = ExchangeAction.orderAction(wires: [
        ExchangeAction.orderWire(
            assetID: 1, buy: true, price: "100", size: "100", reduceOnly: false, kind: .limit)
    ])
    let expected = [
        (
            NetworkEnvironment.mainnet,
            "d65369825a9df5d80099e513cce430311d7d26ddf477f5b3a33d2806b100d78e",
            "2b54116ff64054968aa237c20ca9ff68000f977c93289157748a3162b6ea940e", UInt64(28)
        ),
        (
            .testnet, "82b2ba28e76b3d761093aaded1b1cdad4960b3af30212b343fb2e6cdfa4e3d54",
            "6b53878fc99d26047f4d7e8c90eb98955a109f44209163f52d8dc4278cbbd9f5", 27
        )
    ]
    for (environment, r, s, v) in expected {
        let signature = try key.sign(
            digest: EthereumSigning.actionDigest(action: action, nonce: 0, environment: environment)
        )
        #expect(signature.r == "0x" + r)
        #expect(signature.s == "0x" + s)
        #expect(signature.v == v)
    }
}

@Test func sessionKeyValidationAndGeneration() throws {
    #expect(throws: WalletError.self) {
        try EphemeralSigningKey(testKey: Data(repeating: 0, count: 32))
    }
    #expect(throws: WalletError.self) {
        try EphemeralSigningKey(testKey: Data(repeating: 255, count: 32))
    }
    #expect(throws: WalletError.self) {
        try EphemeralSigningKey(testKey: Data(repeating: 1, count: 31))
    }
    let first = try EphemeralSigningKey()
    let second = try EphemeralSigningKey()
    #expect(Address.isValid(first.address))
    #expect(first.address != second.address)
    #expect(throws: WalletError.self) { try first.sign(digest: Data()) }
}

@Test func approveAgentDigestMatchesIndependentEthAccountEncoder() throws {
    // Generated with eth-account 0.13.7 encode_typed_data, the encoder used by the official SDK.
    let key = try EphemeralSigningKey(testKey: fixtureKey)
    #expect(key.address == "0x14791697260e4c9a71f18484c9f997b308e59325")
    let vectors = [
        (
            NetworkEnvironment.mainnet,
            "a0aaa2603a93e59d7f77e90cb604e090cd596f5ca278284f6e61f839fbd81a16",
            "dff097c52909bef18ea454d86a10448c5ae52fb9342becc909fbcd104724207b3274a685fc50c7cd052b5b547b4f0076fce112475d1b871f68ed43cde09b7d8f1c"
        ),
        (
            .testnet, "2fc0a77e93d6c17ea9501153c6e37af9244b2e3fa84af8bee0de9d076704bf13",
            "fd5e030f5cb350520a2a2d3bb8d66493ff4dd62af5b452b9e5e49b441855e9627823f7a3d7b25a75d2bbd269d9a27c88bc7cbc598fc6d4441ee452224cf947981c"
        )
    ]
    for (environment, digest, signatureHex) in vectors {
        let approval = SessionApproval(
            id: UUID(), owner: key.address,
            agentAddress: "0x1111111111111111111111111111111111111111",
            validUntil: 1_700_028_800_000,
            chainID: 42161, nonce: 1_700_000_000_000, environment: environment,
            createdAt: 1_700_000_000_000,
            revoking: false)
        #expect(try approval.digest.hex == "0x" + digest)
        let expected = try WalletSignature(hex: signatureHex)
        let signature = try key.sign(digest: approval.digest)
        #expect(signature.r == expected.r)
        #expect(signature.s == expected.s)
        #expect(signature.v == expected.v)
        _ = try approval.request(signature: expected)
    }
}
