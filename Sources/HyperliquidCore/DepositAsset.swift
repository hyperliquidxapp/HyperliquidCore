import Foundation

/// Native deposit routes supported by USDC bridging or the Unit asset bridge.
public enum DepositAsset: String, CaseIterable, Identifiable, Sendable {
    case usdc = "USDC"
    case btc = "BTC"
    case eth = "ETH"
    case sol = "SOL"
    case doubleZero = "2Z"
    case ansem = "ANSEM"
    case avax = "AVAX"
    case bonk = "BONK"
    case fart = "FARTCOIN"
    case mon = "MON"
    case pump = "PUMP"
    case spx = "SPX"
    case virtual = "VIRTUAL"
    case xpl = "XPL"
    case zec = "ZEC"

    public var id: String { rawValue }
    public var unitSymbol: String {
        switch self {
        case .fart: "fart"
        case .spx: "spxs"
        default: rawValue.lowercased()
        }
    }
    public var chain: String {
        switch self {
        case .usdc: "arbitrum"
        case .btc: "bitcoin"
        case .eth: "ethereum"
        case .sol, .pump, .fart, .spx, .bonk, .doubleZero, .ansem: "solana"
        case .xpl: "plasma"
        case .mon: "monad"
        case .avax: "avalanche"
        case .virtual: "base"
        case .zec: "zcash"
        }
    }
    public var usesEVMWallet: Bool {
        [.usdc, .eth, .xpl, .mon, .avax, .virtual].contains(self)
    }
    public var canReadSourceBalance: Bool { self != .zec }
    var solanaMint: (address: String, decimals: Int)? {
        switch self {
        case .doubleZero: ("J6pQQ3FAcJQeWPPGppWRb4nM8jU3wLyYbRrLh7feMfvd", 8)
        case .ansem: ("9cRCn9rGT8V2imeM2BaKs13yhMEais3ruM3rPvTGpump", 6)
        case .bonk: ("DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263", 5)
        case .fart: ("9BB6NFEcjBCtnNLFko2FqVQBq8HHM13kCyYcdQbgpump", 6)
        case .pump: ("pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn", 6)
        case .spx: ("J3NKxxXZcnNiMjKw9hYb2K4LUxgwB6t1FtPtQVsv3KFr", 8)
        default: nil
        }
    }
    public var minimum: String {
        switch self {
        case .usdc: "5"
        case .btc: "0.0003"
        case .eth: "0.007"
        case .sol: "0.12"
        case .ansem: "60"
        case .xpl: "60"
        case .mon: "450"
        case .avax: "1.5"
        case .virtual: "25"
        case .pump: "5500"
        case .fart: "55"
        case .spx: "32"
        case .bonk: "1800000"
        case .doubleZero: "150"
        case .zec: "0.07"
        }
    }
    public func networkName(environment: NetworkEnvironment) -> String {
        let mainnet: String
        switch self {
        case .usdc: return ArbitrumBridge(environment: environment).name
        case .btc: mainnet = "Bitcoin"
        case .eth: mainnet = "Ethereum"
        case .sol, .pump, .fart, .spx, .bonk, .doubleZero, .ansem: mainnet = "Solana"
        case .xpl: mainnet = "Plasma"
        case .mon: mainnet = "Monad"
        case .avax: mainnet = "Avalanche C-Chain"
        case .virtual: mainnet = "Base"
        case .zec: mainnet = "Zcash"
        }
        guard environment == .testnet else { return mainnet }
        switch self {
        case .btc: return "Bitcoin Signet"
        case .eth: return "Ethereum Sepolia"
        case .sol: return "Solana Devnet"
        default: return mainnet + " Testnet"
        }
    }
    public static func available(environment: NetworkEnvironment) -> [Self] {
        // The documented public testnet routes have no production SPL/ERC20 assets.
        environment == .mainnet ? allCases : [.usdc, .btc, .eth, .sol]
    }
}

struct DepositEVMNetwork: Sendable {
    let chainID: UInt64
    let rpcURL: URL
    let contract: String?

    init(asset: DepositAsset, environment: NetworkEnvironment) throws {
        guard asset != .usdc, asset.usesEVMWallet,
              DepositAsset.available(environment: environment).contains(asset)
        else { throw WalletError.invalid("This asset needs its native source wallet.") }
        let rpc: String
        switch asset {
        case .eth:
            chainID = environment == .mainnet ? 1 : 11_155_111
            rpc = environment == .mainnet
                ? "https://ethereum-rpc.publicnode.com" : "https://ethereum-sepolia-rpc.publicnode.com"
        case .xpl:
            chainID = 9745
            rpc = "https://rpc.plasma.to"
        case .mon:
            chainID = 143
            rpc = "https://rpc.monad.xyz"
        case .avax:
            chainID = 43114
            rpc = "https://api.avax.network/ext/bc/C/rpc"
        case .virtual:
            chainID = 8453
            rpc = "https://mainnet.base.org"
        default: throw WalletError.invalid("Unsupported EVM deposit network.")
        }
        rpcURL = URL(string: rpc)!
        contract = asset == .virtual ? "0x0b3e328455c4059eeb9e3f84b5543f74e24e7e1b" : nil
    }
}
