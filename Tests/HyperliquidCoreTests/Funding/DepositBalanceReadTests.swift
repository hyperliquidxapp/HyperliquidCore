import Foundation
import Testing

@testable import HyperliquidCore

@Test(.enabled(
    if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"
        && ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"] != nil))
func depositBalanceReadOnlyRPCProbe() async throws {
    let owner = try #require(ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"])
    for environment in [NetworkEnvironment.mainnet, .testnet] {
        let rpc = BridgeRPC(environment: environment)
        let contracts = Set([
            ArbitrumBridge(environment: environment).token,
            CCTPArbitrumRoute(environment: environment).token
        ])
        for token in contracts {
            let balance = try await rpc.usdcBalance(owner: owner, token: token)
            #expect(!balance.isNaN && balance >= 0)
        }
    }
}
