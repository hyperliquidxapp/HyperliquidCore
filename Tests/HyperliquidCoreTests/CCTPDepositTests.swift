import Foundation
import Testing

@testable import HyperliquidCore

@Test func cctpDepositAuthorizationHookAndABIEqualIndependentEthAccountAndEthABIVectors() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            contentsOf: root.appendingPathComponent("docs/verification/funding/cctp-vectors.json")))
    let owner = try #require(fixture["owner"].string)
    #expect(fixture["vectors"].array.count == 4)
    for vector in fixture["vectors"].array {
        let networkName = try #require(vector["network"].string)
        let sourceName = try #require(vector["source"].string)
        let environment = try #require(NetworkEnvironment(rawValue: networkName))
        let source = try #require(FundingSource(rawValue: sourceName))
        let quote = CCTPFeeQuote(
            environment: environment, units: 200_000, startedAt: ReceiptClock.now)
        let intent = try CCTPDepositIntent(
            owner: owner, amount: "25.125", environment: environment, source: source,
            quote: quote, nonce: Data(repeating: 0x42, count: 32),
            now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(intent.typedData == vector["typedData"])
        #expect(try intent.digest.hex == vector["digest"].string)
        #expect(intent.hook.hex == vector["hook"].string && intent.hook.count == 56)
        let signature = try WalletSignature(hex: #require(vector["signature"].string))
        let transaction = try intent.transaction(signature: signature)
        #expect(transaction.data == vector["calldata"].string)
        #expect(transaction.from == owner && transaction.to == intent.route.depositContract)
        #expect(
            transaction.chainID == intent.route.chainID && transaction.json["value"].string == "0x0"
        )
        #expect(
            intent.received == Decimal(string: "24.925") && intent.fee == Decimal(string: "0.2"))
        let wrongKeyBytes = try #require(Data(hex: String(repeating: "22", count: 32)))
        let wrongKey = try EphemeralSigningKey(testKey: wrongKeyBytes)
        let wrongSignature = try wrongKey.sign(digest: intent.digest)
        #expect(throws: WalletError.self) { try intent.transaction(signature: wrongSignature) }
    }
    #expect(
        CCTPArbitrumRoute(environment: .testnet).token
            != ArbitrumBridge(environment: .testnet).token)
}

@Test func cctpDepositFeesBalancesGasAndOwnerAreRevalidatedWithoutRoundingOrUnboundedApprovals()
throws {
    let owner = "0x1111111111111111111111111111111111111111"
    let fee = CCTPFeeQuote(environment: .testnet, units: 200_000, startedAt: ReceiptClock.now)
    for amount in ["0", "4.999999", "5.0000001", "5e1", "5\n", "-5", "18446744073709551616"] {
        #expect(throws: (any Error).self) {
            try CCTPDepositIntent(owner: owner, amount: amount, environment: .testnet, quote: fee)
        }
    }
    #expect(throws: WalletError.self) {
        try CCTPDepositIntent(
            owner: owner, amount: "5", environment: .testnet, quote: fee,
            nonce: Data(repeating: 0, count: 31))
    }
    #expect(throws: WalletError.self) { try fee.validate(environment: .mainnet) }
    #expect(throws: WalletError.self) {
        try CCTPDepositIntent(
            owner: owner, amount: "5", environment: .testnet, quote: fee,
            now: Date(timeIntervalSince1970: -1))
    }
    #expect(throws: WalletError.self) {
        try fee.validate(environment: .testnet, now: fee.startedAt + 15)
    }
    let intent = try CCTPDepositIntent(owner: owner, amount: "5", environment: .testnet, quote: fee)
    let snapshot = CCTPDepositSnapshot(
        owner: owner, environment: .testnet, availableUSDC: 10, nativeWei: 1_000_000_000_000_000,
        gasPrice: 1_000_000, gasLimit: nil, transaction: nil, quote: fee,
        startedAt: ReceiptClock.now)
    try snapshot.validate(intent: intent)
    for (balance, eth, quoteUnits) in [
        (Decimal(4), Decimal(1_000_000), UInt64(200_000)), (10, 0, 200_000),
        (10, 1_000_000, 300_000)
    ] {
        let other = CCTPDepositSnapshot(
            owner: owner, environment: .testnet, availableUSDC: balance, nativeWei: eth,
            gasPrice: 1_000_000, gasLimit: nil, transaction: nil,
            quote: .init(environment: .testnet, units: quoteUnits, startedAt: ReceiptClock.now),
            startedAt: ReceiptClock.now)
        #expect(throws: WalletError.self) { try other.validate(intent: intent) }
    }
    let response: JSONValue = .array([
        .object([
            "finalityThreshold": .integer(1000), "minimumFee": .integer(0),
            "forwardFee": .object(["high": .integer(200_000)])
        ])
    ])
    #expect(
        try CCTPFeeQuote.parse(response, environment: .testnet, startedAt: ReceiptClock.now).units
            == 200_000)
    for malformed in [
        JSONValue.null, .array([]), .array(response.array + response.array),
        .array([
            .object([
                "finalityThreshold": .integer(1000), "minimumFee": .integer(-1),
                "forwardFee": .object(["high": .integer(200_000)])
            ])
        ])
    ] {
        #expect(throws: APIError.self) {
            try CCTPFeeQuote.parse(malformed, environment: .testnet, startedAt: ReceiptClock.now)
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"))
func cctpReadOnlyFeesAndPinnedArbitrumContractsProbe() async throws {
    let transport = NIOHTTPTransport()
    if let owner = ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"] {
        let account = try await HyperliquidAPI(environment: .testnet).fundingAccount(address: owner)
        try account.requireFresh()
        let usdc = try #require(account.tokens.first { $0.index == 0 && $0.name == "USDC" })
        #expect(try account.available(source: .perp, token: usdc) >= 0)
        #expect(try account.available(source: .spot, token: usdc) >= 0)
        print("Read-only funding account: live token metadata and free Perp/Spot balances decoded.")
    }
    for environment in [NetworkEnvironment.mainnet, .testnet] {
        let client = CCTPDepositClient(environment: environment)
        let quote = try await client.quote()
        try quote.validate(environment: environment)
        #expect(quote.units > 0)
        let route = client.route
        func rpc(_ method: String, _ params: [JSONValue]) async throws -> JSONValue {
            let request: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .integer(1),
                "method": .string(method), "params": .array(params)
            ])
            let data = try await transport.post(
                url: route.rpcURL, body: JSONEncoder().encode(request))
            let response = try JSONDecoder().decode(JSONValue.self, from: data)
            #expect(response["error"] == .null)
            return response["result"]
        }
        async let chain = rpc("eth_chainId", [])
        async let domain = rpc(
            "eth_call",
            [
                .object(["to": .string(route.token), "data": .string("0x3644e515")]),
                .string("latest")
            ])
        async let code = rpc("eth_getCode", [.string(route.depositContract), .string("latest")])
        let (chainID, separator, contract) = try await (chain, domain, code)
        #expect(try EthereumQuantity.parse(chainID.string) == Decimal(route.chainID))
        #expect(separator.string?.lowercased() == (try route.domainSeparator).hex)
        let contractHex = try #require(contract.string)
        let bytes = try #require(Data(hex: contractHex))
        #expect(!bytes.isEmpty && bytes.contains { $0 != 0 })
        print(
            "Read-only CCTP \(environment.rawValue): current fees, chain, USDC domain and deposit contract checked."
        )
    }
}

@Test func ethereumCCTPFeesAndBurnBindSourceChainAndExactApproval() throws {
    let quote = try CCTPFeeQuote.parse(.array([.object([
        "finalityThreshold": .integer(1000), "minimumFee": .number(1.25),
        "forwardFee": .object(["high": .integer(221014)])
    ])]), environment: .mainnet, startedAt: ReceiptClock.now, sourceNetwork: .ethereum)
    #expect(try quote.totalUnits(for: 10_000_001) == 222265)
    let owner = "0x1111111111111111111111111111111111111111"
    let intent = try CCTPDepositIntent(owner: owner, amount: "10.000001", environment: .mainnet,
        source: .spot, sourceNetwork: .ethereum, authorization: .allowance, quote: quote)
    #expect(intent.route.chainID == 1 && intent.route.sourceDomain == 0)
    #expect(intent.route.token == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(intent.feeUnits == 222265 && intent.received == Decimal(string: "9.777736"))
    let approval = try intent.approvalTransaction
    #expect(approval.chainID == 1 && approval.to == intent.route.token)
    let approvalBytes = try #require(Data(hex: approval.data))
    #expect(approvalBytes.suffix(32) == EthereumSigning.word(10_000_001))
    #expect(approvalBytes.dropFirst(4).prefix(32) == (try EthereumSigning.addressWord(intent.route.tokenMessenger)))
    let burn = try intent.burnTransaction
    #expect(burn.chainID == 1 && burn.to == "0x28b5a0e9c621a5badaa536219b3a228c8168cf5d")
    let bytes = try #require(Data(hex: burn.data))
    func word(_ index: Int) -> Data { Data(bytes.dropFirst(4 + index * 32).prefix(32)) }
    #expect(word(0) == EthereumSigning.word(10_000_001))
    #expect(word(1) == EthereumSigning.word(19))
    #expect(word(2) == (try EthereumSigning.addressWord(intent.route.forwarder)))
    #expect(word(3) == (try EthereumSigning.addressWord(intent.route.token)))
    #expect(word(4) == word(2))
    #expect(word(5) == EthereumSigning.word(222265))
    #expect(word(6) == EthereumSigning.word(1000))
    #expect(intent.hook.suffix(4) == Data(repeating: 255, count: 4))
    try intent.validate(connection: WalletConnection(address: owner, chainID: 1))
    #expect(throws: WalletError.self) {
        try intent.validate(connection: WalletConnection(address: owner, chainID: 42161))
    }
    #expect(throws: WalletError.self) {
        try quote.validate(environment: .mainnet, sourceNetwork: .arbitrum)
    }
    #expect(throws: WalletError.self) {
        try CCTPDepositIntent(owner: owner, amount: "10", environment: .mainnet,
            sourceNetwork: .ethereum, authorization: .signature, quote: quote)
    }
    let route = CCTPRoute(environment: .testnet, sourceNetwork: .ethereum)
    #expect(route.chainID == 11155111 && route.sourceDomain == 0)
    #expect(route.token == "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238")
    #expect(route.network.explorerURL.host == "sepolia.etherscan.io")
}

@Test func cctpProtocolFeeChangesAndSourceChainCannotReuseReviewedSnapshot() throws {
    let owner = "0x1111111111111111111111111111111111111111"
    let quote = CCTPFeeQuote(environment: .testnet, units: 200_000, startedAt: ReceiptClock.now,
                            sourceNetwork: .ethereum, minimumFeeBPS: 1)
    let intent = try CCTPDepositIntent(owner: owner, amount: "100", environment: .testnet,
        sourceNetwork: .ethereum, authorization: .allowance, quote: quote)
    for (network, bps) in [(USDCSourceNetwork.arbitrum, Decimal(1)), (.ethereum, Decimal(2))] {
        let snapshot = CCTPDepositSnapshot(owner: owner, environment: .testnet,
            availableUSDC: 100, nativeWei: 1_000_000_000_000_000, gasPrice: 1000,
            gasLimit: nil, transaction: nil,
            quote: .init(environment: .testnet, units: 200_000, startedAt: ReceiptClock.now,
                         sourceNetwork: network, minimumFeeBPS: bps),
            startedAt: ReceiptClock.now, allowance: 100)
        #expect(throws: WalletError.self) { try snapshot.validate(intent: intent) }
    }
    let overflow = CCTPFeeQuote(environment: .testnet, units: UInt64.max, startedAt: ReceiptClock.now,
                               sourceNetwork: .ethereum, minimumFeeBPS: 1)
    #expect(throws: APIError.self) { try overflow.totalUnits(for: 100_000_000) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"))
func ethereumCCTPReadOnlyContractsBalanceAndFeesProbe() async throws {
    for environment in [NetworkEnvironment.mainnet, .testnet] {
        let client = CCTPDepositClient(environment: environment, sourceNetwork: .ethereum)
        let route = client.route
        let quote = try await client.quote()
        try quote.validate(environment: environment, sourceNetwork: .ethereum)
        #expect(try quote.totalUnits(for: 10_000_000) > 0)
        let owner = "0x1111111111111111111111111111111111111111"
        #expect(try await client.authorization(owner: owner) == .allowance)
        #expect(try await client.usdcBalance(owner: owner, token: route.token) >= 0)
        let code = try await client.rpc("eth_getCode", params: [.string(route.tokenMessenger), .string("latest")])
        let rawCode = try #require(code.string)
        let bytes = try #require(Data(hex: rawCode))
        #expect(!bytes.isEmpty && bytes.contains { $0 != 0 })
        let separator = try await client.rpc("eth_call", params: [
            .object(["to": .string(route.token), "data": .string("0x3644e515")]), .string("latest")
        ])
        #expect(separator.string?.lowercased() == (try route.domainSeparator).hex)
        print("Read-only Ethereum CCTP \(environment.rawValue): pinned chain/token, messenger bytecode, USDC domain and fee API verified.")
    }
}
