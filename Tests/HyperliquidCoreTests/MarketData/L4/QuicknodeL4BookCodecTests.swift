import Foundation
import Testing
@testable import HyperliquidCore

@Suite struct QuicknodeL4BookCodecTests {
    private func diff(_ kind: JSONValue = .string("L4_ORDER_DIFF_TYPE_NEW"), coin: String = "ETH", oid: JSONValue = .string("18446744073709551615")) -> JSONValue {
        .object(["diff_type": kind, "coin": .string(coin), "oid": oid,
                 "user": .string("0xFeDcFeDcFeDcFeDcFeDcFeDcFeDcFeDcFeDcFeDc"),
                 "side": .string("B"), "px": .string("100"), "sz": .string("0.1")])
    }

    private func payload(_ diffs: [JSONValue], height: JSONValue = .string("18446744073709551615"), snapshot: JSONValue = .bool(true)) -> JSONValue {
        .object(["time": .string("100"), "height": height, "snapshot": snapshot, "diffs": .array(diffs)])
    }

    @Test func acceptsExactUInt64AndBothEnumRepresentations() throws {
        for kind in [JSONValue.string("L4_ORDER_DIFF_TYPE_NEW"), .integer(1)] {
            let update = try QuicknodeL4BookCodec.decode(payload([diff(kind)]), coin: "ETH")
            #expect(update.height == .max && update.snapshot)
            #expect(update.changes.first?.identity.oid == .max)
        }
        guard case .object(var fields) = diff(.integer(2)) else { return }
        fields["diffType"] = fields.removeValue(forKey: "diff_type")
        let update = try QuicknodeL4BookCodec.decode(payload([.object(fields)]), coin: "ETH")
        guard case .update(let order) = try #require(update.changes.first) else {
            Issue.record("Expected an absolute size update"); return
        }
        #expect(order.size == Decimal(string: "0.1"))
    }

    @Test func removesNeedNoSizeAndFilteredEmptyBatchesKeepWatermarks() throws {
        guard case .object(var fields) = diff(.integer(3)) else { return }
        fields.removeValue(forKey: "sz")
        let removed = try QuicknodeL4BookCodec.decode(payload([.object(fields)], snapshot: .bool(false)), coin: "ETH")
        guard case .remove(let identity) = try #require(removed.changes.first) else {
            Issue.record("Expected removal without a fabricated size"); return
        }
        #expect(identity.oid == .max && !removed.snapshot)
        let filtered = try QuicknodeL4BookCodec.decode(payload([diff(coin: "BTC")]), coin: "ETH")
        #expect(filtered.changes.isEmpty && filtered.height == .max && filtered.snapshot)
        #expect(try QuicknodeL4BookCodec.decode(payload([], snapshot: .null), coin: "ETH").snapshot == false)
    }

    @Test func rejectsLossyNumbersConflictingAliasesAndUnboundedBatches() throws {
        for oid in [JSONValue.number(9_007_199_254_740_992), .string("18446744073709551616"), .string("+1"), .integer(-1)] {
            #expect(throws: L4BookError.invalidPayload) { try QuicknodeL4BookCodec.decode(payload([diff(oid: oid)]), coin: "ETH") }
        }
        guard case .object(var fields) = diff() else { return }
        fields["diffType"] = .integer(3)
        #expect(throws: L4BookError.invalidPayload) { try QuicknodeL4BookCodec.decode(payload([.object(fields)]), coin: "ETH") }
        #expect(throws: L4BookError.invalidPayload) { try QuicknodeL4BookCodec.decode(payload([diff()]), coin: "ETH", maximumChanges: 0) }
        #expect(throws: L4BookError.invalidPayload) { try QuicknodeL4BookCodec.decode(payload([], snapshot: .string("true")), coin: "ETH") }
        #expect(throws: L4BookError.invalidPayload) { try QuicknodeL4BookCodec.decode(payload([], height: .number(1)), coin: "ETH") }
    }

    @Test func validatesForeignEventsBeforeFilteringAndRejectsInvalidIdentities() throws {
        #expect(throws: L4BookError.invalidPayload) {
            try QuicknodeL4BookCodec.decode(payload([diff(.integer(9), coin: "BTC")]), coin: "ETH")
        }
        for field in ["side", "user", "px", "coin"] {
            guard case .object(var fields) = diff() else { continue }
            fields[field] = .string(field == "coin" ? "" : "?")
            #expect(throws: (any Error).self) { try QuicknodeL4BookCodec.decode(payload([.object(fields)]), coin: "ETH") }
        }
    }
}
