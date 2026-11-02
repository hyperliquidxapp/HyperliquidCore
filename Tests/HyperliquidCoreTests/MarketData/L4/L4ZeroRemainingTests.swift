import Foundation
import Testing
@testable import HyperliquidCore

@Suite struct L4ZeroRemainingTests {
    private func order(_ oid: UInt64 = 1, size: String = "1", user: String = "0x1111111111111111111111111111111111111111") throws -> L4Order {
        try .init(identity: .init(oid: oid, user: user, coin: "ETH", side: .bid, price: "100"), size: size)
    }
    private func block(_ height: UInt64, snapshot: Bool = false, _ changes: [L4OrderChange]) throws -> L4BookUpdate {
        try .init(coin: "ETH", height: height, time: Int64(height), snapshot: snapshot, changes: changes)
    }
    private func reducer() throws -> L4BookReducer {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        _ = try reducer.apply(block(10, snapshot: true, [.new(order()), .new(order(2, size: "2"))]))
        return reducer
    }

    @Test func zeroRemainingQuantityRetiresOnlyThatOrderAndKeepsExactLevelTotals() throws {
        var reducer = try reducer()
        let retired = try order()
        let view = try reducer.apply(block(11, [try .update(identity: retired.identity, remainingSize: "0.000")]))
        #expect(view.orderCount == 1 && reducer.order(1) == nil && reducer.order(2)?.size == 2)
        #expect(view.book.bids.first?.sz == "2" && view.book.bids.first?.n == 1)
        let empty = try reducer.apply(block(12, [try .update(identity: order(2).identity, remainingSize: "0")]))
        #expect(empty.orderCount == 0 && empty.book.bids.isEmpty && empty.priceLevelCount == 0)
    }

    @Test func matchingSameBlockFinalRemovalDoesNotSubtractTwice() throws {
        var reducer = try reducer()
        let identity = try order().identity
        let view = try reducer.apply(block(11, [try .update(identity: identity, remainingSize: "0"), .remove(identity)]))
        #expect(view.orderCount == 1 && view.book.bids.first?.sz == "2" && reducer.status == .live)
        #expect(throws: L4BookError.unknownOrder) { try reducer.apply(block(12, [.remove(identity)])) }
    }

    @Test func unknownOrdersNegativeSizesAndMismatchedIdentitiesStillFailClosed() throws {
        #expect(throws: L4BookError.invalidOrder) { try L4Order(identity: order().identity, size: "0") }
        #expect(throws: L4BookError.invalidOrder) { try L4OrderChange.update(identity: order().identity, remainingSize: "-1") }
        var unknown = try reducer()
        #expect(throws: L4BookError.unknownOrder) {
            try unknown.apply(block(11, [try .update(identity: order(99).identity, remainingSize: "0")]))
        }
        var mismatched = try reducer()
        let other = try order(user: "0x2222222222222222222222222222222222222222").identity
        #expect(throws: L4BookError.identityChanged) {
            try mismatched.apply(block(11, [try .update(identity: order().identity, remainingSize: "0"), .remove(other)]))
        }
        var duplicated = try reducer()
        let identity = try order().identity
        #expect(throws: L4BookError.unknownOrder) {
            try duplicated.apply(block(11, [try .update(identity: identity, remainingSize: "0"), .remove(identity), .remove(identity)]))
        }
    }

    @Test func zeroSizeCannotEnterAnAuthoritativeSnapshotAsANewOrder() throws {
        let zero = try L4OrderChange.update(identity: order().identity, remainingSize: "0")
        guard case .update(let value) = zero else { Issue.record("Expected size update"); return }
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        #expect(throws: L4BookError.invalidOrder) { try reducer.apply(block(10, snapshot: true, [.new(value)])) }
    }

    @Test func bothWireCodecsAcceptZeroUpdatesWithoutTurningThemIntoRestingOrders() throws {
        var diff = Hyperliquid_L4OrderDiff()
        diff.diffType = .init(rawValue: 2)!
        diff.coin = "ETH"
        diff.oid = 1
        diff.user = try order().identity.user
        diff.side = "B"
        diff.px = "100"
        diff.sz = "0.0"
        var packet = Hyperliquid_L4BookUpdatesUpdate()
        packet.height = 11
        packet.time = 11
        packet.diffs = [diff]
        let typed = try QuicknodeL4WireMapping.decode(packet, coin: "ETH", maximumChanges: 10)
        let json: JSONValue = .object(["height": .integer(11), "time": .integer(11), "snapshot": .bool(false),
                                       "diffs": .array([.object(["diff_type": .integer(2), "coin": .string("ETH"), "oid": .integer(1),
                                                                "user": .string(diff.user), "side": .string("B"),
                                                                "px": .string("100"), "sz": .string("0.0")])])])
        let decoded = try QuicknodeL4BookCodec.decode(json, coin: "ETH")
        #expect(typed == decoded)
        var reducer = try reducer()
        #expect(try reducer.apply(typed).orderCount == 1)
    }
}
