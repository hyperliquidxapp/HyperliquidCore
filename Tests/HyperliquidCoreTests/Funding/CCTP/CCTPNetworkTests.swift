import Foundation
import Testing
@testable import HyperliquidCore

@Test(arguments: USDCSourceNetwork.allCases, [NetworkEnvironment.mainnet, .testnet])
func cctpNetworkBurnTargetsHyperCoreWithMatchingFeesAndSource(
    network: USDCSourceNetwork, environment: NetworkEnvironment
) throws {
    let route = CCTPRoute(environment: environment, sourceNetwork: network)
    let owner = "0x1111111111111111111111111111111111111111"
    let response: JSONValue = .array([1000, 2000].map { finality in
        .object(["finalityThreshold": .integer(Int64(finality)),
                 "minimumFee": .integer(finality == 1000 ? 2 : 0),
                 "forwardFee": .object(["high": .integer(finality == 1000 ? 250_000 : 200_000)])])
    })
    let quote = try CCTPFeeQuote.parse(response, environment: environment,
        startedAt: ReceiptClock.now, sourceNetwork: network)
    #expect(quote.units == (route.finality == .fast ? 250_000 : 200_000))
    for destination in [FundingSource.perp, .spot] {
        let intent = try CCTPDepositIntent(owner: owner, amount: "10", environment: environment,
            source: destination, sourceNetwork: network, authorization: .allowance, quote: quote)
        let burn = try intent.burnTransaction
        let bytes = try #require(Data(hex: burn.data))
        func word(_ index: Int) -> Data { Data(bytes.dropFirst(4 + index * 32).prefix(32)) }
        #expect(burn.chainID == route.chainID && burn.to == route.tokenMessenger)
        #expect(word(0) == EthereumSigning.word(10_000_000))
        #expect(word(1) == EthereumSigning.word(19))
        #expect(word(2) == (try EthereumSigning.addressWord(route.forwarder)))
        #expect(word(3) == (try EthereumSigning.addressWord(route.token)))
        #expect(word(4) == word(2))
        #expect(word(5) == EthereumSigning.word(intent.feeUnits))
        #expect(word(6) == EthereumSigning.word(route.finality.rawValue))
        #expect(intent.hook.count == 56)
        #expect(intent.hook.dropFirst(32).prefix(20) == Data(hex: owner))
        #expect(intent.hook.suffix(4) == Data(repeating: destination == .perp ? 0 : 255, count: 4))
        #expect(try intent.approvalTransaction.to == route.token)
        if !route.supportsSignatureDeposit {
            #expect(throws: WalletError.self) {
                try CCTPDepositIntent(owner: owner, amount: "10", environment: environment,
                    sourceNetwork: network, authorization: .signature, quote: quote)
            }
        }
    }
    let wrongMode: JSONValue = .array(response.array.filter {
        $0["finalityThreshold"].int64 != Int64(route.finality.rawValue)
    })
    #expect(throws: APIError.self) {
        try CCTPFeeQuote.parse(wrongMode, environment: environment,
            startedAt: ReceiptClock.now, sourceNetwork: network)
    }
    #expect(route.network.walletConfiguration["nativeCurrency"]["symbol"].string
        == route.network.nativeCurrencySymbol)
}

@Test func cctpNetworkRegistryHasUniqueDeploymentsAndDocumentedGasCurrencies() {
    for environment in [NetworkEnvironment.mainnet, .testnet] {
        let routes = USDCSourceNetwork.allCases.map { CCTPRoute(environment: environment, sourceNetwork: $0) }
        #expect(Set(routes.map(\.sourceDomain)).count == routes.count)
        #expect(Set(routes.map(\.chainID)).count == routes.count)
        #expect(routes.allSatisfy { Address.isValid($0.token) && $0.sourceDomain != 19 })
    }
    let avalanche = CCTPRoute(environment: .mainnet, sourceNetwork: .avalanche)
    #expect(avalanche.sourceDomain == 1 && avalanche.chainID == 43114)
    #expect(avalanche.token == "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e")
    #expect(avalanche.finality == .standard && avalanche.network.nativeCurrencySymbol == "AVAX")
    #expect(CCTPRoute(environment: .mainnet, sourceNetwork: .polygon).network.nativeCurrencySymbol == "POL")
    #expect(CCTPRoute(environment: .mainnet, sourceNetwork: .arc).network.gasUsesUSDC)
}

@Test func cctpArcReservesGasInAdditionToTheUSDCBeingBurned() throws {
    let quote = CCTPFeeQuote(environment: .testnet, units: 200_000,
        startedAt: ReceiptClock.now, sourceNetwork: .arc)
    let intent = try CCTPDepositIntent(owner: "0x1111111111111111111111111111111111111111",
        amount: "10", environment: .testnet, sourceNetwork: .arc, authorization: .allowance, quote: quote)
    let burn = try intent.burnTransaction
    func snapshot(_ native: Decimal) -> CCTPDepositSnapshot {
        .init(owner: intent.owner, environment: .testnet, availableUSDC: 10,
            nativeWei: native, gasPrice: 1_000_000_000, gasLimit: 100_000,
            transaction: burn, quote: quote, startedAt: ReceiptClock.now, allowance: 10)
    }
    let tenUSDC = Decimal(10) * 1_000_000_000_000_000_000
    #expect(throws: WalletError.self) { try snapshot(tenUSDC).validate(intent: intent, transaction: burn) }
    try snapshot(tenUSDC + 100_000_000_000_000).validate(intent: intent, transaction: burn)
}

/// Opt-in, read-only: does not sign, approve, burn, or broadcast transactions.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_CCTP_NETWORK_PROBE"] == "1"),
      arguments: USDCSourceNetwork.allCases, [NetworkEnvironment.mainnet, .testnet])
func cctpNetworkReadOnlyDeploymentProbe(network: USDCSourceNetwork, environment: NetworkEnvironment) async throws {
    let client = CCTPDepositClient(environment: environment, sourceNetwork: network)
    let route = client.route
    let chain = try EthereumQuantity.parse(await client.rpc("eth_chainId", params: []).string)
    #expect(chain == Decimal(route.chainID))
    let code = try await client.rpc("eth_getCode", params: [.string(route.tokenMessenger), .string("latest")])
    #expect((code.string?.count ?? 0) > 2)
    let decimals = try await client.rpc("eth_call", params: [
        .object(["to": .string(route.token), "data": .string("0x313ce567")]), .string("latest")])
    #expect(try EthereumQuantity.parse(decimals.string) == 6)
    let localDomain = try await client.rpc("eth_call", params: [
        .object(["to": .string(route.tokenMessenger), "data": .string(
            Keccak256.hash(Data("localMessageTransmitter()".utf8)).prefix(4).hex)]), .string("latest")])
    #expect((localDomain.string?.count ?? 0) == 66)
    let transmitter = "0x" + String(try #require(localDomain.string).suffix(40))
    let domain = try await client.rpc("eth_call", params: [
        .object(["to": .string(transmitter), "data": .string(
            Keccak256.hash(Data("localDomain()".utf8)).prefix(4).hex)]), .string("latest")])
    #expect(try EthereumQuantity.parse(domain.string) == Decimal(route.sourceDomain))
    let quote = try await client.quote()
    #expect(quote.units > 0 && quote.sourceNetwork == network)
    print("CCTP read-only: \(network.rawValue) / \(environment.rawValue), chain \(route.chainID), domain \(route.sourceDomain), native USDC, messenger, transmitter and HyperCore forwarding quote checked. No transaction sent.")
}
