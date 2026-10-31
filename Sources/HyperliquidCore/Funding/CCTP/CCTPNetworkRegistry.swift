import Foundation

/// Stable persisted identifiers. Deployment data lives in CCTPNetworkRegistry.
public enum USDCSourceNetwork: String, Codable, CaseIterable, Sendable {
    case arbitrum = "Arbitrum"
    case ethereum = "Ethereum"
    case avalanche = "Avalanche"
    case optimism = "OP Mainnet"
    case base = "Base"
    case polygon = "Polygon PoS"
    case unichain = "Unichain"
    case linea = "Linea"
    case codex = "Codex"
    case sonic = "Sonic"
    case worldChain = "World Chain"
    case monad = "Monad"
    case sei = "Sei"
    case xdc = "XDC"
    case ink = "Ink"
    case plume = "Plume"
    case arc = "Arc"
    case injective = "Injective"
    case cronos = "Cronos"
    case plasma = "Plasma"
    case xLayer = "X Layer"
    case morph = "Morph"
    case pharos = "Pharos"
}

public enum CCTPFinality: UInt64, Sendable {
    case fast = 1000, standard = 2000
}

/// Source chain metadata is shared by wallet switching, balances, and transaction construction.
struct CCTPNetworkDeployment: Sendable, Equatable {
    let chainID: UInt64
    let name: String
    let nativeCurrencyName: String
    let nativeCurrencySymbol: String
    let rpc: String
    let explorer: String
    let usdc: String
}

struct CCTPNetworkDefinition: Sendable {
    let domain: Int
    let finality: CCTPFinality
    let mainnet: CCTPNetworkDeployment
    let testnet: CCTPNetworkDeployment
}

/// Reviewed against Circle's supported domains and USDC address tables, 2026-10-16.
/// Network metadata: https://github.com/wevm/viem/tree/main/src/chains/definitions
/// https://developers.circle.com/cctp/concepts/supported-chains-and-domains
/// https://developers.circle.com/stablecoins/usdc-contract-addresses
/// Keep deployment differences here; consumers must not infer chain parameters from names.
enum CCTPNetworkRegistry {
    static func definition(for network: USDCSourceNetwork) -> CCTPNetworkDefinition {
        switch network {
        case .arbitrum:
            return .init(domain: 3, finality: .fast,
                mainnet: .init(chainID: 42161, name: "Arbitrum One",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://arb1.arbitrum.io/rpc", explorer: "https://arbiscan.io",
                    usdc: "0xaf88d065e77c8cc2239327c5edb3a432268e5831"),
                testnet: .init(chainID: 421614, name: "Arbitrum Sepolia",
                    nativeCurrencyName: "Arbitrum Sepolia Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://sepolia-rollup.arbitrum.io/rpc", explorer: "https://sepolia.arbiscan.io",
                    usdc: "0x75faf114eafb1bdbe2f0316df893fd58ce46aa4d"))
        case .ethereum:
            return .init(domain: 0, finality: .fast,
                mainnet: .init(chainID: 1, name: "Ethereum",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://ethereum-rpc.publicnode.com", explorer: "https://etherscan.io",
                    usdc: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"),
                testnet: .init(chainID: 11155111, name: "Ethereum Sepolia",
                    nativeCurrencyName: "Sepolia Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://ethereum-sepolia-rpc.publicnode.com", explorer: "https://sepolia.etherscan.io",
                    usdc: "0x1c7d4b196cb0c7b01d743fbc6116a902379c7238"))
        case .avalanche:
            return .init(domain: 1, finality: .standard,
                mainnet: .init(chainID: 43114, name: "Avalanche",
                    nativeCurrencyName: "Avalanche", nativeCurrencySymbol: "AVAX",
                    rpc: "https://api.avax.network/ext/bc/C/rpc", explorer: "https://snowtrace.io",
                    usdc: "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e"),
                testnet: .init(chainID: 43113, name: "Avalanche Fuji",
                    nativeCurrencyName: "Avalanche Fuji", nativeCurrencySymbol: "AVAX",
                    rpc: "https://api.avax-test.network/ext/bc/C/rpc", explorer: "https://testnet.snowtrace.io",
                    usdc: "0x5425890298aed601595a70ab815c96711a31bc65"))
        case .optimism:
            return .init(domain: 2, finality: .fast,
                mainnet: .init(chainID: 10, name: "OP Mainnet",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://mainnet.optimism.io", explorer: "https://optimistic.etherscan.io",
                    usdc: "0x0b2c639c533813f4aa9d7837caf62653d097ff85"),
                testnet: .init(chainID: 11155420, name: "OP Sepolia",
                    nativeCurrencyName: "Sepolia Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://sepolia.optimism.io", explorer: "https://optimism-sepolia.blockscout.com",
                    usdc: "0x5fd84259d66cd46123540766be93dfe6d43130d7"))
        case .base:
            return .init(domain: 6, finality: .fast,
                mainnet: .init(chainID: 8453, name: "Base",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://mainnet.base.org", explorer: "https://basescan.org",
                    usdc: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"),
                testnet: .init(chainID: 84532, name: "Base Sepolia",
                    nativeCurrencyName: "Sepolia Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://sepolia.base.org", explorer: "https://sepolia.basescan.org",
                    usdc: "0x036cbd53842c5426634e7929541ec2318f3dcf7e"))
        case .polygon:
            return .init(domain: 7, finality: .standard,
                mainnet: .init(chainID: 137, name: "Polygon",
                    nativeCurrencyName: "POL", nativeCurrencySymbol: "POL",
                    rpc: "https://polygon.drpc.org", explorer: "https://polygonscan.com",
                    usdc: "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"),
                testnet: .init(chainID: 80002, name: "Polygon Amoy",
                    nativeCurrencyName: "POL", nativeCurrencySymbol: "POL",
                    rpc: "https://polygon-amoy.drpc.org", explorer: "https://amoy.polygonscan.com",
                    usdc: "0x41e94eb019c0762f9bfcf9fb1e58725bfb0e7582"))
        case .unichain:
            return .init(domain: 10, finality: .fast,
                mainnet: .init(chainID: 130, name: "Unichain",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://mainnet.unichain.org/", explorer: "https://uniscan.xyz",
                    usdc: "0x078d782b760474a361dda0af3839290b0ef57ad6"),
                testnet: .init(chainID: 1301, name: "Unichain Sepolia",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://sepolia.unichain.org", explorer: "https://sepolia.uniscan.xyz",
                    usdc: "0x31d0220469e10c4e71834a79b1f276d740d3768f"))
        case .linea:
            return .init(domain: 11, finality: .fast,
                mainnet: .init(chainID: 59144, name: "Linea Mainnet",
                    nativeCurrencyName: "Linea Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://rpc.linea.build", explorer: "https://lineascan.build",
                    usdc: "0x176211869ca2b568f2a7d4ee941e073a821ee1ff"),
                testnet: .init(chainID: 59141, name: "Linea Sepolia Testnet",
                    nativeCurrencyName: "Linea Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://rpc.sepolia.linea.build", explorer: "https://sepolia.lineascan.build",
                    usdc: "0xfece4462d57bd51a6a552365a011b95f0e16d9b7"))
        case .codex:
            return .init(domain: 12, finality: .fast,
                mainnet: .init(chainID: 81224, name: "Codex",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://rpc.codex.xyz", explorer: "https://explorer.codex.xyz",
                    usdc: "0xd996633a415985dbd7d6d12f4a4343e31f5037cf"),
                testnet: .init(chainID: 812242, name: "Codex Testnet",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://rpc.codex-stg.xyz", explorer: "https://explorer.codex-stg.xyz",
                    usdc: "0x6d7f141b6819c2c9cc2f818e6ad549e7ca090f8f"))
        case .sonic:
            return .init(domain: 13, finality: .standard,
                mainnet: .init(chainID: 146, name: "Sonic",
                    nativeCurrencyName: "Sonic", nativeCurrencySymbol: "S",
                    rpc: "https://rpc.soniclabs.com", explorer: "https://sonicscan.org",
                    usdc: "0x29219dd400f2bf60e5a23d13be72b486d4038894"),
                testnet: .init(chainID: 14601, name: "Sonic Testnet",
                    nativeCurrencyName: "Sonic", nativeCurrencySymbol: "S",
                    rpc: "https://rpc.testnet.soniclabs.com", explorer: "https://testnet.sonicscan.org",
                    usdc: "0x0ba304580ee7c9a980cf72e55f5ed2e9fd30bc51"))
        case .worldChain:
            return .init(domain: 14, finality: .fast,
                mainnet: .init(chainID: 480, name: "World Chain",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://worldchain-mainnet.g.alchemy.com/public", explorer: "https://worldscan.org",
                    usdc: "0x79a02482a880bce3f13e09da970dc34db4cd24d1"),
                testnet: .init(chainID: 4801, name: "World Chain Sepolia",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://worldchain-sepolia.g.alchemy.com/public", explorer: "https://sepolia.worldscan.org",
                    usdc: "0x66145f38cbac35ca6f1dfb4914df98f1614aea88"))
        case .monad:
            return .init(domain: 15, finality: .standard,
                mainnet: .init(chainID: 143, name: "Monad",
                    nativeCurrencyName: "Monad", nativeCurrencySymbol: "MON",
                    rpc: "https://rpc.monad.xyz", explorer: "https://monadscan.com",
                    usdc: "0x754704bc059f8c67012fed69bc8a327a5aafb603"),
                testnet: .init(chainID: 10143, name: "Monad Testnet",
                    nativeCurrencyName: "Testnet MON Token", nativeCurrencySymbol: "MON",
                    rpc: "https://testnet-rpc.monad.xyz", explorer: "https://testnet.monadexplorer.com",
                    usdc: "0x534b2f3a21130d7a60830c2df862319e593943a3"))
        case .sei:
            return .init(domain: 16, finality: .standard,
                mainnet: .init(chainID: 1329, name: "Sei Network",
                    nativeCurrencyName: "Sei", nativeCurrencySymbol: "SEI",
                    rpc: "https://evm-rpc.sei-apis.com/", explorer: "https://seiscan.io",
                    usdc: "0xe15fc38f6d8c56af07bbcbe3baf5708a2bf42392"),
                testnet: .init(chainID: 1328, name: "Sei Testnet",
                    nativeCurrencyName: "Sei", nativeCurrencySymbol: "SEI",
                    rpc: "https://evm-rpc-testnet.sei-apis.com", explorer: "https://testnet.seiscan.io",
                    usdc: "0x4fcf1784b31630811181f670aea7a7bef803eaed"))
        case .xdc:
            return .init(domain: 18, finality: .standard,
                mainnet: .init(chainID: 50, name: "XDC Network",
                    nativeCurrencyName: "XDC", nativeCurrencySymbol: "XDC",
                    rpc: "https://rpc.xdcrpc.com", explorer: "https://xdcscan.com",
                    usdc: "0xfa2958cb79b0491cc627c1557f441ef849ca8eb1"),
                testnet: .init(chainID: 51, name: "Apothem Network",
                    nativeCurrencyName: "TXDC", nativeCurrencySymbol: "TXDC",
                    rpc: "https://erpc.apothem.network", explorer: "https://testnet.xdcscan.com",
                    usdc: "0xb5ab69f7bbada22b28e79c8ffaece55ef1c771d4"))
        case .ink:
            return .init(domain: 21, finality: .fast,
                mainnet: .init(chainID: 57073, name: "Ink",
                    nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://rpc-gel.inkonchain.com", explorer: "https://explorer.inkonchain.com",
                    usdc: "0x2d270e6886d130d724215a266106e6832161eaed"),
                testnet: .init(chainID: 763373, name: "Ink Sepolia",
                    nativeCurrencyName: "Sepolia Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://rpc-gel-sepolia.inkonchain.com", explorer: "https://explorer-sepolia.inkonchain.com/",
                    usdc: "0xfabab97dce620294d2b0b0e46c68964e326300ac"))
        case .plume:
            return .init(domain: 22, finality: .fast,
                mainnet: .init(chainID: 98866, name: "Plume",
                    nativeCurrencyName: "Plume", nativeCurrencySymbol: "PLUME",
                    rpc: "https://rpc.plume.org", explorer: "https://explorer.plume.org",
                    usdc: "0x222365ef19f7947e5484218551b56bb3965aa7af"),
                testnet: .init(chainID: 98867, name: "Plume Testnet",
                    nativeCurrencyName: "Plume", nativeCurrencySymbol: "PLUME",
                    rpc: "https://testnet-rpc.plume.org", explorer: "https://testnet-explorer.plume.org",
                    usdc: "0xcb5f30e335672893c7eb944b374c196392c19d18"))
        case .arc:
            return .init(domain: 26, finality: .standard,
                mainnet: .init(chainID: 5042, name: "Arc",
                    nativeCurrencyName: "USDC", nativeCurrencySymbol: "USDC",
                    rpc: "https://rpc.mainnet.arc.io", explorer: "https://explorer.arc.io",
                    usdc: "0x3600000000000000000000000000000000000000"),
                testnet: .init(chainID: 5042002, name: "Arc Testnet",
                    nativeCurrencyName: "USDC", nativeCurrencySymbol: "USDC",
                    rpc: "https://rpc.testnet.arc.io", explorer: "https://explorer.testnet.arc.io",
                    usdc: "0x3600000000000000000000000000000000000000"))
        case .injective:
            return .init(domain: 29, finality: .standard,
                mainnet: .init(chainID: 1776, name: "Injective",
                    nativeCurrencyName: "Injective", nativeCurrencySymbol: "INJ",
                    rpc: "https://sentry.evm-rpc.injective.network", explorer: "https://blockscout.injective.network",
                    usdc: "0xa00c59ff5a080d2b954d0c75e46e22a0c371235a"),
                testnet: .init(chainID: 1439, name: "Injective Testnet",
                    nativeCurrencyName: "Injective", nativeCurrencySymbol: "INJ",
                    rpc: "https://k8s.testnet.json-rpc.injective.network", explorer: "https://testnet.blockscout.injective.network",
                    usdc: "0x0c382e685bbeefe5d3d9c29e29e341fee8e84c5d"))
        case .cronos:
            return .init(domain: 32, finality: .standard,
                mainnet: .init(chainID: 25, name: "Cronos Mainnet",
                    nativeCurrencyName: "Cronos", nativeCurrencySymbol: "CRO",
                    rpc: "https://evm.cronos.org", explorer: "https://explorer.cronos.org",
                    usdc: "0x3d7f2c478aafdb65542bcb44bceec05849999d2d"),
                testnet: .init(chainID: 338, name: "Cronos Testnet",
                    nativeCurrencyName: "CRO", nativeCurrencySymbol: "tCRO",
                    rpc: "https://evm-t3.cronos.org", explorer: "https://explorer.cronos.org/testnet",
                    usdc: "0xeb33dc5fac03833e132593659e1de7256ab59794"))
        case .plasma:
            return .init(domain: 33, finality: .standard,
                mainnet: .init(chainID: 9745, name: "Plasma",
                    nativeCurrencyName: "Plasma", nativeCurrencySymbol: "XPL",
                    rpc: "https://rpc.plasma.to", explorer: "https://plasmascan.to",
                    usdc: "0x2d661c89d812261039af9764eceaaee884f5f67f"),
                testnet: .init(chainID: 9746, name: "Plasma Testnet",
                    nativeCurrencyName: "Testnet Plasma", nativeCurrencySymbol: "XPL",
                    rpc: "https://testnet-rpc.plasma.to", explorer: "https://testnet.plasmascan.to",
                    usdc: "0xe67fb267022cba8064dd388cc2fed724f3120d9d"))
        case .xLayer:
            return .init(domain: 37, finality: .fast,
                mainnet: .init(chainID: 196, name: "X Layer Mainnet",
                    nativeCurrencyName: "OKB", nativeCurrencySymbol: "OKB",
                    rpc: "https://xlayerrpc.okx.com", explorer: "https://www.oklink.com/xlayer",
                    usdc: "0xb6ceceab302e2e4948951ee7843fc24e92933061"),
                testnet: .init(chainID: 1952, name: "X1 Testnet",
                    nativeCurrencyName: "OKB", nativeCurrencySymbol: "OKB",
                    rpc: "https://xlayertestrpc.okx.com", explorer: "https://www.oklink.com/xlayer-test",
                    usdc: "0xdec90b78111ba2fc6fc6d84d8b9ec159a2d4b9b3"))
        case .morph:
            // https://docs.morph.network/docs/build-on-morph/build-on-morph/integration-one-page/
            return .init(domain: 30, finality: .fast,
                mainnet: .init(chainID: 2818, name: "Morph", nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://rpc-bgw.morph.network", explorer: "https://explorer.morph.network",
                    usdc: "0xcfb1186f4e93d60e60a8bdd997427d1f33bc372b"),
                testnet: .init(chainID: 2910, name: "Morph Hoodi", nativeCurrencyName: "Ether", nativeCurrencySymbol: "ETH",
                    rpc: "https://rpc-hoodi-bgw.morph.network", explorer: "https://explorer-hoodi.morph.network",
                    usdc: "0x7433b41c6c5e1d58d4da99483609520255ab661b"))
        case .pharos:
            // https://docs.pharos.xyz/getting-started/network/pacific-mainnet
            // https://docs.pharos.xyz/getting-started/network/atlantic-testnet
            return .init(domain: 31, finality: .standard,
                mainnet: .init(chainID: 1672, name: "Pharos Pacific", nativeCurrencyName: "Pharos", nativeCurrencySymbol: "PROS",
                    rpc: "https://rpc.pharos.xyz", explorer: "https://www.pharosscan.xyz",
                    usdc: "0xc879c018db60520f4355c26ed1a6d572cdac1815"),
                testnet: .init(chainID: 688689, name: "Pharos Atlantic", nativeCurrencyName: "Pharos", nativeCurrencySymbol: "PHRS",
                    rpc: "https://atlantic.dplabs-internal.com", explorer: "https://atlantic.pharosscan.xyz",
                    usdc: "0xcfc8330f4bcab529c625d12781b1c19466a9fc8b"))
        }
    }
}
