import Foundation
import Testing
@testable import HyperliquidCore

@Suite struct QuicknodeL4DecodingFailureTests {
    private func message() -> Hyperliquid_L4BookUpdatesUpdate {
        var diff = Hyperliquid_L4OrderDiff()
        diff.diffType = .init(rawValue: 2)!
        diff.oid = 123
        diff.coin = "ETH"
        diff.user = "0x1111111111111111111111111111111111111111"
        diff.side = "B"
        diff.px = "100"
        diff.sz = "-1"
        var message = Hyperliquid_L4BookUpdatesUpdate()
        message.height = 42
        message.time = 999
        message.diffs = [diff]
        return message
    }

    @Test func negativeRemainingQuantityReportsOnlySafeFieldMetadata() throws {
        let message = message()
        do {
            _ = try QuicknodeL4WireMapping.decode(message, coin: "ETH", maximumChanges: 10)
            Issue.record("Expected invalid size diagnostics")
        } catch let failure as QuicknodeL4DecodingFailure {
            #expect(failure.field == .size && failure.valueKind == .negative)
            #expect(failure.height == 42 && failure.time == 999 && !failure.snapshot)
            #expect(failure.diffType == 2 && failure.matchesRequestedCoin)
            if #available(macOS 15.0, *) {
                #expect(QuicknodeL4Client.sanitizedError(failure) as? QuicknodeL4DecodingFailure == failure)
            }
            #expect(!String(reflecting: failure).contains(message.diffs[0].user))
        }
    }

    @Test func malformedUserValueIsNeverRetainedInTheError() throws {
        var message = message()
        let privateValue = "do-not-retain-provider-value"
        message.diffs[0].user = privateValue
        do {
            _ = try QuicknodeL4WireMapping.decode(message, coin: "ETH", maximumChanges: 10)
            Issue.record("Expected invalid identity diagnostics")
        } catch let failure as QuicknodeL4DecodingFailure {
            #expect(failure.field == .user && failure.valueKind == .other)
            #expect(!String(reflecting: failure).contains(privateValue))
        }
    }
}
