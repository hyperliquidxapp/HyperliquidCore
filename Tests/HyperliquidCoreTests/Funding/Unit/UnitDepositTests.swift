import Foundation
import Testing

@testable import HyperliquidCore

private let unitOwner = "0xabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
// Frozen official guardian proofs for a synthetic owner; no network requests in these tests.
private func unitResponse(_ environment: NetworkEnvironment) -> JSONValue {
    if environment == .mainnet {
        return .object([
            "address": .string("0x7483A1F4f90fED731f17EAa75655AE10d08b1520"),
            "signatures": .object([
                "field-node": .string(
                    "TmFVbTLDomZT6uYwXpzl/WiJ9rZ/JC4YyPfn10HQpdA8R+ZTYRVN8tjnIO9fQRLIV5Vj4mSerGhPRhOKSRDAfw=="
                ),
                "hl-node": .string(
                    "F7xw13GkLGX4oggW4swKpQlZLCGwhf5kXccdv8LyU+0UR4prSG+qWcyrUs4j1nq5HfVxXAdAOQEFTHniEDj2/g=="
                ),
                "unit-node": .string(
                    "1XL55hALNn9uKWdUUXL3iVMflAUYa9nLugqk+c8HujB4IS6FyhObGhvjuqK6QFiClKZ6lF4/yWL9hvocqKEozw=="
                ),
            ]),
            "status": .string("OK"),
        ])
    }
    return .object([
        "address": .string("0x701cCbF884f8d6e51804f2C714b8B6d5c6201E58"),
        "signatures": .object([
            "field-node": .string(
                "9e2W4U8VT6jDMyKJYMw26Pza4me+uhkobEnAtalp5+pzPBUT3ugEDI63MYsqJi0cafZJGu3IKsXrYxFgIDAcug=="
            ),
            "hl-node-testnet": .string(
                "1PANpxIRwznylWRbFc0T0tSnvaadfOd4cxiwK/16pDmkhB2ui97zjPb3m0UPbtk4NHDcePYY53yvsxL2P4HGSg=="
            ),
            "node-1": .string(
                "onVvp11r3nbhtDuJQTlzL0UjuYQ9igbYpxfaSqZPW35OLT5v7YTTW2P2H1tlP8u/YKDDsTUGmsvjwgf8YjUILA=="
            ),
        ]),
        "status": .string("OK"),
    ])
}

@Test(arguments: NetworkEnvironment.allCases)
func unitDepositAddressVerifiesOfficialSignaturesAndRejectsChangedOwnerChainOrAddress(
    environment: NetworkEnvironment
) throws {
    let response = unitResponse(environment)
    let address = try UnitDepositAddress(
        response: response, asset: .eth,
        owner: unitOwner.uppercased().replacingOccurrences(of: "0X", with: "0x"),
        environment: environment)
    #expect(address.owner == unitOwner && address.asset == .eth)
    #expect(address.address == response["address"].string)
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(
            response: response, asset: .eth, owner: "0x1111111111111111111111111111111111111111",
            environment: environment)
    }
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(
            response: response, asset: .sol, owner: unitOwner, environment: environment)
    }
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(
            response: response, asset: .eth, owner: unitOwner,
            environment: environment == .mainnet ? .testnet : .mainnet)
    }
    guard case .object(var changed) = response else { return }
    changed["address"] = .string("0x1111111111111111111111111111111111111111")
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(
            response: .object(changed), asset: .eth, owner: unitOwner, environment: environment)
    }
}

@Test func unitDepositAddressRequiresTwoAuthenticatedGuardiansAndNeverCountsAliasesTwice() throws {
    guard case .object(var response) = unitResponse(.testnet),
        case .object(var signatures) = response["signatures"]
    else { return }
    signatures.removeValue(forKey: "field-node")
    response["signatures"] = .object(signatures)
    #expect(
        try UnitDepositAddress(
            response: .object(response), asset: .eth, owner: unitOwner, environment: .testnet
        ).owner == unitOwner)
    signatures.removeValue(forKey: "hl-node-testnet")
    signatures["unit-node"] = signatures["node-1"]
    signatures["unknown"] = signatures["node-1"]
    response["signatures"] = .object(signatures)
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(
            response: .object(response), asset: .eth, owner: unitOwner, environment: .testnet)
    }
    response["coinType"] = .string("bitcoin")
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(
            response: .object(response), asset: .eth, owner: unitOwner, environment: .testnet)
    }
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"
            && ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"] != nil))
func unitDepositPublicAddressAndEVMBalanceProbe() async throws {
    let owner = try #require(ProcessInfo.processInfo.environment["HL_TESTNET_ACCOUNT"])
    for environment in NetworkEnvironment.allCases {
        let client = UnitDepositClient(environment: environment)
        await withTaskGroup(of: Void.self) { group in
            for asset in DepositAsset.available(environment: environment) where asset != .usdc {
                group.addTask {
                    do {
                        let address = try await client.depositAddress(asset: asset, owner: owner)
                        #expect(address.asset == asset && address.owner == owner.lowercased())
                        if asset.canReadSourceBalance {
                            let source = asset.usesEVMWallet ? owner : address.address
                            let balance = try await client.balance(asset: asset, owner: source)
                            #expect(!balance.isNaN && balance >= 0)
                        }
                    } catch {
                        Issue.record("\(environment.rawValue) \(asset.rawValue): \(error)")
                    }
                }
            }
            await group.waitForAll()
        }
    }
}
