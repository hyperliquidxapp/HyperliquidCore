import Foundation
import Testing

@testable import HyperliquidCore

private let builderAddress = "0x2222222222222222222222222222222222222222"
private let builderOwner = "0x14791697260e4c9a71f18484c9f997b308e59325"

private func builderIntent(spot: Bool = false, side: OrderSide = .buy, kind: OrderKind = .limit)
    throws -> OrderIntent
{
    let market =
        spot
        ? Market(
            coin: "@1", symbol: "TOKEN", assetID: 10_001, sizeDecimals: 4, maxLeverage: 1,
            kind: .spot,
            baseTokenIndex: 1, quoteTokenIndex: 0)
        : Market(
            coin: "ETH", symbol: "ETH", assetID: 1, sizeDecimals: 4, maxLeverage: 25, kind: .perp)
    return try OrderPlanner.preview(
        market: market, side: side, kind: kind, size: "100", isUSD: false,
        price: "100", trigger: nil, mark: 100, leverage: 1, reduceOnly: false)
}

private func builderFees() throws -> UserFeeRates {
    try .init(
        response: .object([
            "userAddRate": .string("0.00015"), "userCrossRate": .string("0.00045"),
            "userSpotAddRate": .string("0.0004"), "userSpotCrossRate": .string("0.0007"),
            "activeReferralDiscount": .string("0.1"),
        ]))
}

@Suite struct BuilderFeeTests {
    @Test func recipientsRequireStandardModeAndSufficientPerpsValue() throws {
        for mode in ["default", "disabled"] {
            #expect(try BuilderFee.isEligible(accountValue: "100", abstraction: mode))
            #expect(try !BuilderFee.isEligible(accountValue: "99.99", abstraction: mode))
        }
        for mode in ["unifiedAccount", "portfolioMargin", "dexAbstraction", "future", ""] {
            #expect(try !BuilderFee.isEligible(accountValue: "1000", abstraction: mode))
        }
        #expect(throws: OrderValidationError.self) {
            try BuilderFee.isEligible(accountValue: "NaN", abstraction: "default")
        }
    }

    @Test func ratesLimitsAndApprovalReadsAreExact() throws {
        let fee = try BuilderFee(address: builderAddress, tenthsOfBasisPoint: 10)
        #expect(fee.rate == Decimal(string: "0.0001") && fee.percentage == "0.01%")
        #expect(fee.address == builderAddress.lowercased())
        #expect(try fee.approvedLimit(.integer(10)) == 10)
        #expect(throws: BuilderFeeError.invalidApproval) { try fee.approvedLimit(.string("10")) }
        #expect(throws: BuilderFeeError.invalidApproval) { try fee.approvedLimit(.integer(-1)) }
        #expect(throws: BuilderFeeError.invalidRate) {
            try BuilderFee(address: builderAddress, tenthsOfBasisPoint: 0)
        }
        #expect(throws: BuilderFeeError.invalidAddress) {
            try BuilderFee(
                address: "0x" + String(repeating: "0", count: 40), tenthsOfBasisPoint: 10)
        }
        let maximum = try BuilderFee(address: builderAddress, tenthsOfBasisPoint: 1000)
        #expect(throws: BuilderFeeError.invalidRate) { try maximum.applicable(to: builderIntent()) }
        #expect(try maximum.applicable(to: builderIntent(spot: true, side: .sell)) == maximum)
    }

    @Test(arguments: [NetworkEnvironment.mainnet, .testnet])
    func approvalMatchesIndependentPythonVectors(_ environment: NetworkEnvironment) throws {
        let approval = try BuilderFeeApproval(
            owner: builderOwner, builder: builderAddress, feeLimit: 10,
            chainID: 42161, nonce: 1_700_000_000_000, environment: environment)
        let digest =
            environment == .mainnet
            ? "73cbce803f075cfafa27e1ad8b39a3b8daee8455df4cb237e01d443b74ed9212"
            : "be0bb003a27b1b3ba46e9fc2179ae3ec1108686a08f7aec75ae77b6fdd7a5914"
        let signature =
            environment == .mainnet
            ? "4d02e1a2b04908fe90556e4d18d889e5243c3b86e50aa91b90c0efca3ec7649c2c388321ebc991612c588d78dbf3fc91732a286c7efb0ee8d6ea542d4ab5127a1b"
            : "4772ccdf0bfdaf6a1b4f16ae1815ace65815f2edaafbd2c1f7bbe8bbc8d648476b83b5d3b1ee597de64ac1b2649dd2350c313f07c2694d3ff2a3b1f1a138a4a71b"
        #expect(try approval.digest.hex == "0x" + digest)
        let request = try JSONDecoder().decode(
            JSONValue.self, from: approval.request(signature: .init(hex: "0x" + signature)))
        #expect(request["action"]["type"].string == "approveBuilderFee")
        #expect(request["action"]["nonce"] == request["nonce"])
        #expect(request["action"]["maxFeeRate"].string == "0.01%")
        #expect(request["expiresAfter"] == .null && request["vaultAddress"] == .null)
        #expect(
            approval.typedData["primaryType"].string == "HyperliquidTransaction:ApproveBuilderFee")
    }

    @Test func approvalRejectsAnAgentSignatureAndSupportsZeroFeeRevocation() throws {
        let approval = try BuilderFeeApproval(
            owner: builderOwner, builder: builderAddress, feeLimit: 10,
            chainID: 42161, nonce: 1_700_000_000_000, environment: .testnet)
        let agent = try EphemeralSigningKey()
        #expect(throws: BuilderFeeError.signatureMismatch) {
            try approval.request(signature: agent.sign(digest: approval.digest))
        }
        let revoke = try BuilderFeeApproval(
            owner: builderOwner, builder: builderAddress, feeLimit: 0,
            chainID: 42161, nonce: 1_700_000_000_001, environment: .testnet)
        #expect(revoke.maxFeeRate == "0%")
        #expect(try revoke.digest != approval.digest)
        #expect(throws: BuilderFeeError.invalidContext) {
            try BuilderFeeApproval(
                owner: builderOwner, builder: builderAddress, feeLimit: 10, chainID: UInt64.max,
                nonce: 1,
                environment: .mainnet)
        }
    }

    @Test func builderIsCoveredByTheOrderHashAndCannotExtendUndocumentedActions() throws {
        let fee = try BuilderFee(address: builderAddress, tenthsOfBasisPoint: 10)
        let intent = try builderIntent()
        let original = ExchangeAction.place(intent)
        let action = try ExchangeAction.place(intent, builder: fee)
        let json = try JSONDecoder().decode(JSONValue.self, from: action.jsonData())
        #expect(
            json["builder"]["b"].string == builderAddress.lowercased()
                && json["builder"]["f"].int64 == 10
        )
        #expect(
            try SigningPayload.actionHash(action: original, nonce: 1)
                != SigningPayload.actionHash(action: action, nonce: 1))
        #expect(throws: BuilderFeeError.unsupportedAction) {
            try fee.appending(toOrderAction: ExchangeAction.cancel(assetID: 1, oid: 1))
        }
        #expect(throws: BuilderFeeError.unsupportedAction) {
            try fee.appending(toOrderAction: ExchangeAction.modify(oid: 1, intent: intent))
        }
        #expect(throws: BuilderFeeError.unsupportedAction) {
            try fee.appending(toOrderAction: action)
        }
    }

    @Test func spotBuyAndSellHaveDifferentBuilderFeeApplicability() throws {
        let fee = try BuilderFee(address: builderAddress, tenthsOfBasisPoint: 10)
        let buy = try builderIntent(spot: true)
        let sell = try builderIntent(spot: true, side: .sell)
        let buyAction = try ExchangeAction.place(buy, builder: fee)
        let sellAction = try ExchangeAction.place(sell, builder: fee)
        #expect(
            try JSONDecoder().decode(JSONValue.self, from: buyAction.jsonData())["builder"] == .null
        )
        #expect(
            try JSONDecoder().decode(JSONValue.self, from: sellAction.jsonData())["builder"]["f"]
                .int64
                == 10)
        #expect(try builderFees().estimate(for: buy, builder: fee).builderAmount == 0)
        #expect(try builderFees().estimate(for: sell, builder: fee).builderAmount == 1)
    }

    @Test func builderFeeIsNotReferralDiscountedAndCannotChangeAfterReview() throws {
        let fee = try BuilderFee(address: builderAddress, tenthsOfBasisPoint: 10)
        let intent = try builderIntent(kind: .market)
        let rates = try builderFees()
        let base = try rates.estimate(for: intent)
        let charged = try rates.estimate(for: intent, builder: fee)
        #expect(charged.builderAmount == 1)
        #expect(charged.lower == base.lower + 1 && charged.upper == base.upper + 1)
        #expect(charged.maximumRate == base.maximumRate + Decimal(string: "0.0001")!)
        #expect(throws: BuilderFeeError.feeChanged) { try base.validate(current: charged) }
        let other = try BuilderFee(
            address: "0x1111111111111111111111111111111111111111", tenthsOfBasisPoint: 10)
        #expect(throws: BuilderFeeError.feeChanged) {
            try charged.validate(current: rates.estimate(for: intent, builder: other))
        }
    }
}
