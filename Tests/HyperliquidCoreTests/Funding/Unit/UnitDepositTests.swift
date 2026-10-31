import Foundation
import Testing

@testable import HyperliquidCore

private let unitOwner = "0x5742261ef0516ad70c4217cc573fa21485289d3b"
private func unitResponse(_ environment: NetworkEnvironment) -> JSONValue {
    if environment == .mainnet {
        return .object([
            "status": .string("OK"), "address": .string("0xCFDbb9cf18Cd1E5b5Bf37eD873161bc9A0538055"),
            "signatures": .object([
                "field-node": .string("Mhx6T0Z0QzqromXHWre9/abKF8avb6HxbJffXahEG1p//z2XQhlsFqvf5q9aV/93QFmuoeG2GXsSI/e3UtRCyQ=="),
                "hl-node": .string("3lmQKiW09X/92tYMvwQDoQPUbc8WXXAP2jbAP3+iJgSBVFSEmV2tefFCP3jxfnEoUBfPpYvosZwESKtdLIkwtw=="),
                "unit-node": .string("4IMewgEZq7jFPaGUfL6RgTIq8RqZLgeoa510qo8R1WeEuFbcgIWJZS4JhuqLp+jT4Tp1Q8hlHhJNzCpN/VhA5g==")
            ])
        ])
    }
    return .object([
        "status": .string("OK"), "address": .string("0xaD47D129Dc89CaA0e6B8F88a589960d71845F817"),
        "signatures": .object([
            "field-node": .string("k+lTYWunf+eAkhg6uPIJ3oL8hQlCBDZhgUInqzakNgqTJ0LHy8P/uyh9g3mx5LD3uHTTyJ4D4vMshspf4Hl8cw=="),
            "hl-node-testnet": .string("6ZtmVSF5HzNdI+Ozbgn26vNtuJE6tiSUJgHcQZ01OgVbjJtDJzEqG1mhfu+Bm1PVqwtW/p+lPpFTO1aGpTpfpA=="),
            "node-1": .string("r96MZg6TJRyUGXa7ocQ3Zuew8f/JGe/UP226qdwRxog/nGd44UM/iKisOWgcDDJ0aDlY7TtNShcM5xUu7FL4Vg==")
        ])
    ])
}

@Test(arguments: NetworkEnvironment.allCases)
func unitDepositAddressVerifiesOfficialSignaturesAndRejectsChangedOwnerChainOrAddress(
    environment: NetworkEnvironment
) throws {
    let response = unitResponse(environment)
    let address = try UnitDepositAddress(
        response: response, asset: .eth, owner: unitOwner.uppercased().replacingOccurrences(of: "0X", with: "0x"),
        environment: environment)
    #expect(address.owner == unitOwner && address.asset == .eth)
    #expect(address.address == response["address"].string)
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(
            response: response, asset: .eth, owner: "0x1111111111111111111111111111111111111111",
            environment: environment)
    }
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(response: response, asset: .sol, owner: unitOwner, environment: environment)
    }
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(
            response: response, asset: .eth, owner: unitOwner,
            environment: environment == .mainnet ? .testnet : .mainnet)
    }
    guard case .object(var changed) = response else { return }
    changed["address"] = .string("0x1111111111111111111111111111111111111111")
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(response: .object(changed), asset: .eth, owner: unitOwner, environment: environment)
    }
}

@Test func unitDepositAddressRequiresTwoAuthenticatedGuardiansAndNeverCountsAliasesTwice() throws {
    guard case .object(var response) = unitResponse(.testnet),
          case .object(var signatures) = response["signatures"] else { return }
    signatures.removeValue(forKey: "field-node")
    response["signatures"] = .object(signatures)
    #expect(try UnitDepositAddress(
        response: .object(response), asset: .eth, owner: unitOwner, environment: .testnet).owner == unitOwner)
    signatures.removeValue(forKey: "hl-node-testnet")
    signatures["unit-node"] = signatures["node-1"]
    signatures["unknown"] = signatures["node-1"]
    response["signatures"] = .object(signatures)
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(response: .object(response), asset: .eth, owner: unitOwner, environment: .testnet)
    }
    response["coinType"] = .string("bitcoin")
    #expect(throws: (any Error).self) {
        try UnitDepositAddress(response: .object(response), asset: .eth, owner: unitOwner, environment: .testnet)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"
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
