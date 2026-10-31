import Foundation

/// Source-chain configuration shared by CCTP and wallet network switching.
public struct EVMDepositNetwork: Sendable, Equatable {
    public let environment: NetworkEnvironment
    public let sourceNetwork: USDCSourceNetwork
    public init(environment: NetworkEnvironment, sourceNetwork: USDCSourceNetwork = .arbitrum) {
        self.environment = environment
        self.sourceNetwork = sourceNetwork
    }
    private var deployment: CCTPNetworkDeployment {
        let definition = CCTPNetworkRegistry.definition(for: sourceNetwork)
        return environment == .mainnet ? definition.mainnet : definition.testnet
    }
    public var chainID: UInt64 { deployment.chainID }
    public var name: String { deployment.name }
    public var rpcURL: URL { URL(string: deployment.rpc)! }
    public var explorerURL: URL { URL(string: deployment.explorer)! }
    public var nativeCurrencySymbol: String { deployment.nativeCurrencySymbol }
    public var usdc: String { deployment.usdc }
    public var gasUsesUSDC: Bool { nativeCurrencySymbol == "USDC" }
    public var walletConfiguration: JSONValue {
        .object([
            "chainId": .string("0x" + String(chainID, radix: 16)), "chainName": .string(name),
            "nativeCurrency": .object(["name": .string(deployment.nativeCurrencyName), "symbol": .string(nativeCurrencySymbol), "decimals": .integer(18)]),
            "rpcUrls": .array([.string(rpcURL.absoluteString)]),
            "blockExplorerUrls": .array([.string(explorerURL.absoluteString)])
        ])
    }
}

/// A source-chain burn routed through HyperEVM's forwarder into HyperCore.
/// Only Arbitrum has the ReceiveWithAuthorization extension; other sources use allowance + burn.
public struct CCTPRoute: Sendable, Equatable {
    public let environment: NetworkEnvironment
    public let sourceNetwork: USDCSourceNetwork
    public init(environment: NetworkEnvironment, sourceNetwork: USDCSourceNetwork = .arbitrum) {
        self.environment = environment
        self.sourceNetwork = sourceNetwork
    }
    public var network: EVMDepositNetwork { .init(environment: environment, sourceNetwork: sourceNetwork) }
    public var chainID: UInt64 { network.chainID }
    public var sourceDomain: Int { CCTPNetworkRegistry.definition(for: sourceNetwork).domain }
    public var finality: CCTPFinality { CCTPNetworkRegistry.definition(for: sourceNetwork).finality }
    public var supportsSignatureDeposit: Bool { sourceNetwork == .arbitrum }
    public var token: String { network.usdc }
    public var depositContract: String {
        environment == .mainnet
            ? "0xa95d9c1f655341597c94393fddc30cf3c08e4fce"
            : "0x8e4e3d0e95c1bec4f3ec7f69aa48473e0ab6eb8d"
    }
    public var forwarder: String {
        CCTPHyperCoreDestination.forwarder(environment: environment)
    }
    public var circleURL: URL {
        URL(
            string: environment == .mainnet
                ? "https://iris-api.circle.com" : "https://iris-api-sandbox.circle.com")!
    }
    public var rpcURL: URL { network.rpcURL }
    public var tokenDomainName: String {
        sourceNetwork == .ethereum && environment == .testnet ? "USDC" : "USD Coin"
    }
    public var domainSeparator: Data {
        get throws {
            Keccak256.hash(
                EthereumSigning.text(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                )
                + EthereumSigning.text(tokenDomainName) + EthereumSigning.text("2")
                + EthereumSigning.word(chainID) + (try EthereumSigning.addressWord(token)))
        }
    }
}

public typealias CCTPArbitrumRoute = CCTPRoute
