import Foundation
import Testing

@testable import HyperliquidCore

@Test func cctpAllowanceTransactionsMatchIndependentABIForBothNetworksAndDestinations() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtureURL = root.appendingPathComponent("docs/verification/funding/cctp-vectors.json")
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtureURL))
    let owner = try #require(fixture["owner"].string)
    for vector in fixture["vectors"].array {
        let networkName = try #require(vector["network"].string)
        let sourceName = try #require(vector["source"].string)
        let environment = try #require(NetworkEnvironment(rawValue: networkName))
        let source = try #require(FundingSource(rawValue: sourceName))
        let intent = try CCTPDepositIntent(
            owner: owner, amount: "25.125", environment: environment, source: source,
            authorization: .allowance,
            quote: .init(environment: environment, units: 200_000, startedAt: ReceiptClock.now))
        let approval = try intent.approvalTransaction
        let burn = try intent.burnTransaction
        #expect(approval.data == vector["approvalCalldata"].string)
        #expect(burn.data == vector["burnCalldata"].string)
        #expect(approval.from == owner && approval.to == intent.route.token)
        #expect(burn.from == owner && burn.to == vector["tokenMessenger"].string)
        #expect(approval.json["value"].string == "0x0" && burn.json["value"].string == "0x0")
        #expect(approval.chainID == intent.route.chainID && burn.chainID == intent.route.chainID)
        let signature = try WalletSignature(hex: #require(vector["signature"].string))
        #expect(throws: WalletError.self) { try intent.transaction(signature: signature) }
        let snapshot = CCTPDepositSnapshot(
            owner: owner, environment: environment, availableUSDC: 100, nativeWei: 1_000_000_000_000_000,
            gasPrice: 1_000_000, gasLimit: 100_000, transaction: burn,
            quote: .init(environment: environment, units: 200_000, startedAt: ReceiptClock.now),
            startedAt: ReceiptClock.now, allowance: 25)
        #expect(snapshot.needsApproval(for: intent))
        #expect(throws: WalletError.self) { try snapshot.validate(intent: intent, transaction: burn) }
    }
}

@Test func cctpAccountCodeDetectsDelegatedWalletsAndAllowanceComparisonDoesNotRoundUInt256() throws {
    #expect(try CCTPAuthorization.accountCode("0x") == .signature)
    #expect(try CCTPAuthorization.accountCode(
                "0xef0100d6cedde84be40893d153be9d467cd6ad37875b28") == .allowance)
    #expect(try CCTPAuthorization.accountCode("0x6000") == .allowance)
    for malformed in [nil, "", "0xg1", "0x1"] {
        #expect(throws: APIError.self) { try CCTPAuthorization.accountCode(malformed) }
    }
    for units in [UInt64(0), 25_125_000, UInt64.max] {
        let raw = EthereumSigning.word(units).hex
        #expect(try CCTPDepositClient.allowanceAmount(raw) == Decimal(units) / 1_000_000)
    }
    #expect(try CCTPDepositClient.allowanceAmount("0x" + String(repeating: "f", count: 64))
                == Decimal(UInt64.max) / 1_000_000)
    for malformed in [nil, "0x", "0x1", "0x" + String(repeating: "0", count: 65)] {
        #expect(throws: APIError.self) { try CCTPDepositClient.allowanceAmount(malformed) }
    }
}

@Test func cctpApprovalLookupDistinguishesAnUnseenHashFromAnExactPendingOrMinedTransaction() throws {
    let owner = "0x1111111111111111111111111111111111111111"
    let intent = try CCTPDepositIntent(
        owner: owner, amount: "5", environment: .testnet, authorization: .allowance,
        quote: .init(environment: .testnet, units: 200_000, startedAt: ReceiptClock.now))
    let approval = try intent.approvalTransaction
    let hash = "0x" + String(repeating: "ab", count: 32)
    var tx: [String: JSONValue] = [
        "hash": .string(hash), "from": .string(owner), "to": .string(approval.to),
        "input": .string(approval.data), "value": .string("0x0")
    ]
    var receipt: [String: JSONValue] = [
        "transactionHash": .string(hash), "from": .string(owner), "to": .string(approval.to),
        "blockNumber": .string("0x1"), "status": .string("0x1")
    ]
    func result(_ mined: JSONValue, _ transaction: JSONValue) throws -> Bool? {
        try CCTPDepositClient.receiptResult(
            mined: mined, transaction: transaction, hash: hash, owner: owner,
            transactionData: approval.data, to: approval.to)
    }
    #expect(throws: WalletError.self) { try result(.null, .null) }
    #expect(try result(.null, .object(tx)) == nil)
    #expect(try result(.object(receipt), .object(tx)) == true)
    receipt["status"] = .string("0x0")
    #expect(try result(.object(receipt), .object(tx)) == false)
    receipt["status"] = .string("0x2")
    #expect(throws: APIError.self) { try result(.object(receipt), .object(tx)) }
    tx["input"] = .string("0x095ea7b3")
    #expect(throws: APIError.self) { try result(.null, .object(tx)) }
    #expect(throws: APIError.self) { try result(.object(receipt), .object(tx)) }
}

/// Opt-in diagnostic: only public RPC reads and gas simulation; never requests a wallet or sends a transaction.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HL_LIVE_PROBE"] == "1"
                && ProcessInfo.processInfo.environment["HL_CCTP_APPROVAL_OWNER"] != nil))
func cctpReadOnlyFiveUSDCApprovalUsesProductionNIOPreflight() async throws {
    let owner = try #require(ProcessInfo.processInfo.environment["HL_CCTP_APPROVAL_OWNER"])
    let client = CCTPDepositClient(environment: .mainnet)
    let started = Date()
    let authorization = try await client.authorization(owner: owner)
    #expect(authorization == .allowance)
    let quote = try await client.quote()
    let intent = try CCTPDepositIntent(
        owner: owner, amount: "5", environment: .mainnet, authorization: authorization, quote: quote)
    let connection = try WalletConnection(address: owner, chainID: client.route.chainID)
    let reviewed = try await client.snapshot(intent: intent, transaction: nil)
    try reviewed.validate(intent: intent)
    try intent.validate(connection: connection)
    print("5 USDC preview: \(Date().timeIntervalSince(started)) seconds; allowance \(reviewed.allowance ?? -1) USDC.")
    let transaction = try intent.approvalTransaction
    let checked = try await client.snapshot(intent: intent, transaction: nil)
    try checked.validate(intent: intent)
    let simulated = try await client.snapshot(intent: intent, transaction: transaction)
    try simulated.validate(intent: intent, transaction: transaction)
    try intent.validate(connection: connection)
    print("5 USDC approval preflight: \(Date().timeIntervalSince(started)) seconds; gas \(simulated.gasLimit ?? 0). No transaction sent.")
}
