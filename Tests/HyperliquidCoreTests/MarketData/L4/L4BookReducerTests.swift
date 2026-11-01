import Foundation
import Testing
@testable import HyperliquidCore

@Suite struct L4BookReducerTests {
    private let user = "0xFeDcFeDcFeDcFeDcFeDcFeDcFeDcFeDcFeDcFeDc"

    private func order(_ oid: UInt64, _ price: String = "100", _ size: String = "1",
                       side: L4OrderIdentity.Side = .bid, user: String? = nil) throws -> L4Order {
        try L4Order(identity: L4OrderIdentity(oid: oid, user: user ?? self.user, coin: "ETH", side: side, price: price), size: size)
    }

    private func block(_ height: UInt64 = 10, snapshot: Bool = false, time: Int64 = 100,
                       _ changes: [L4OrderChange] = []) throws -> L4BookUpdate {
        try L4BookUpdate(coin: "ETH", height: height, time: time, snapshot: snapshot, changes: changes)
    }

    @Test func retainsCompleteOrderMapBeyondVisibleProjection() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        let bids = try (1...40).map { try order(UInt64($0), String(100 - $0), "0.1") }
        let ask = try order(.max, "101", "0.2", side: .ask)
        let view = try reducer.apply(block(snapshot: true, bids.map(L4OrderChange.new) + [.new(ask)]))
        #expect(view.orderCount == 41 && view.priceLevelCount == 41)
        #expect(view.book.bids.count == 20 && view.maximumLevelsPerSide == 20)
        #expect(reducer.order(.max) == ask && reducer.order(40) == bids.last)
        #expect(try reducer.view(maximumLevelsPerSide: 100).book.bids.count == 40)
        #expect(reducer.environment == .testnet)
    }

    @Test func updatesAreAbsoluteAndDecimalAggregationIsExact() throws {
        var reducer = try L4BookReducer(environment: .mainnet, coin: "ETH")
        let a = try order(1, "100.0", "0.1"), b = try order(2, "100.00", "0.2")
        let initial = try reducer.apply(block(snapshot: true, [.new(a), .new(b)]))
        #expect(initial.book.bids.first?.sz == "0.3" && initial.book.bids.first?.n == 2)
        let resized = try order(1, "100", "0.4")
        let changed = try reducer.apply(block(11, [.update(resized)]))
        #expect(changed.book.bids.first?.sz == "0.6" && changed.book.bids.first?.n == 2)
        let removed = try reducer.apply(block(12, [.remove(b.identity)]))
        #expect(removed.book.bids.first?.sz == "0.4" && removed.orderCount == 1)
        let empty = try reducer.apply(block(13, [.remove(resized.identity)]))
        #expect(empty.book.bids.isEmpty && empty.priceLevelCount == 0 && reducer.order(1) == nil)
        #expect(initial.book.bids.first?.sz == "0.3")
    }

    @Test func replacementSnapshotsAtSameHeightDiscardAllPriorState() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        _ = try reducer.apply(block(snapshot: true, [.new(order(1))]))
        let replacement = try reducer.apply(block(snapshot: true, [.new(order(2, "101"))]))
        #expect(reducer.order(1) == nil && reducer.order(2) != nil && replacement.orderCount == 1)
        let empty = try reducer.apply(block(snapshot: true))
        #expect(empty.orderCount == 0 && empty.book.levels == [[], []] && reducer.status == .live)
    }

    @Test func rejectedBatchInvalidatesAllIndexesAndNeedsFreshSnapshot() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        let old = try reducer.apply(block(snapshot: true, [.new(order(1))]))
        #expect(throws: L4BookError.unknownOrder) {
            try reducer.apply(block(11, [.new(order(2)), .remove(order(9).identity)]))
        }
        #expect(reducer.status == .resynchronizationRequired && reducer.orderCount == 0)
        #expect(reducer.order(1) == nil && reducer.order(2) == nil)
        #expect(throws: L4BookError.snapshotRequired) { try reducer.view() }
        #expect(throws: L4BookError.snapshotRequired) { try reducer.apply(block(12)) }
        #expect(old.orderCount == 1 && old.book.bids.first?.sz == "1")
        #expect(throws: L4BookError.invalidWatermark) { try reducer.apply(block(9, snapshot: true)) }
        #expect(try reducer.apply(block(10, snapshot: true)).orderCount == 0)
    }

    @Test func duplicateNewUnknownUpdateAndSnapshotMutationsAreRejected() throws {
        for kind in 0...3 {
            var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
            let a = try order(1)
            _ = try reducer.apply(block(snapshot: true, [.new(a)]))
            let update: L4BookUpdate
            let error: L4BookError
            switch kind {
            case 0: update = try block(11, [.new(a)]); error = .duplicateOrder
            case 1: update = try block(11, [.update(order(2))]); error = .unknownOrder
            case 2: update = try block(11, snapshot: true, [.update(a)]); error = .invalidOrder
            default: update = try block(11, snapshot: true, [.remove(a.identity)]); error = .invalidOrder
            }
            #expect(throws: error) { try reducer.apply(update) }
            #expect(reducer.status == .resynchronizationRequired && reducer.orderCount == 0)
        }
    }

    @Test func identityCannotSilentlyChangeOnUpdateOrRemove() throws {
        for kind in 0...3 {
            var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
            _ = try reducer.apply(block(snapshot: true, [.new(order(1))]))
            let changed: L4Order
            switch kind {
            case 0: changed = try order(1, "99")
            case 1: changed = try order(1, side: .ask)
            default: changed = try order(1, user: "0x0000000000000000000000000000000000000001")
            }
            let change = kind == 3 ? L4OrderChange.remove(changed.identity) : .update(changed)
            #expect(throws: L4BookError.identityChanged) { try reducer.apply(block(11, [change])) }
        }
    }

    @Test func filteredHeightGapsAreAllowedButReplayAndClockRollbackAreNot() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        _ = try reducer.apply(block(snapshot: true))
        #expect(try reducer.apply(block(100)).height == 100)
        #expect(throws: L4BookError.invalidWatermark) { try reducer.apply(block(100)) }
        #expect(throws: L4BookError.invalidWatermark) { try reducer.apply(block(99, snapshot: true)) }
        #expect(throws: L4BookError.invalidWatermark) { try reducer.apply(block(101, snapshot: true, time: 99)) }
        reducer.resetForNewConnection()
        #expect(reducer.status == .awaitingSnapshot)
        #expect(throws: L4BookError.snapshotRequired) { try reducer.apply(block(1, time: 1)) }
        #expect(try reducer.apply(block(1, snapshot: true, time: 1)).height == 1)
    }

    @Test func crossingAndCapacityLimitsCannotPublishPartialBooks() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH", maximumOrders: 1)
        #expect(throws: L4BookError.capacityExceeded) {
            try reducer.apply(block(snapshot: true, [.new(order(1)), .new(order(2))]))
        }
        #expect(reducer.orderCount == 0)
        var crossing = try L4BookReducer(environment: .testnet, coin: "ETH")
        #expect(throws: L4BookError.crossedBook) {
            try crossing.apply(block(snapshot: true, [.new(order(1, "101")), .new(order(2, "100", side: .ask))]))
        }
        #expect(crossing.orderCount == 0)
        var bounded = try L4BookReducer(environment: .testnet, coin: "ETH", maximumChanges: 1)
        #expect(throws: L4BookError.invalidPayload) {
            try bounded.apply(block(snapshot: true, [.new(order(1)), .new(order(2))]))
        }
        _ = try bounded.apply(block(snapshot: true))
        #expect(throws: L4BookError.capacityExceeded) { try bounded.view(maximumLevelsPerSide: 0) }
        #expect(throws: L4BookError.capacityExceeded) { try bounded.view(maximumLevelsPerSide: 1001) }
    }

    @Test func decimalsRejectRoundingAndCheckedAdditionRejectsLossOfPrecision() throws {
        for raw in ["0", "-1", "NaN", "1e3", " 1", "1.", "0.123456789012345678901234567890123456789"] {
            #expect(throws: L4BookError.invalidOrder) { try order(1, "100", raw) }
        }
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        let huge = "1" + String(repeating: "0", count: 100)
        #expect(throws: L4BookError.arithmeticOverflow) {
            try reducer.apply(block(snapshot: true, [.new(order(1, "100", huge)), .new(order(2, "100", "0.1"))]))
        }
        #expect(reducer.orderCount == 0)
        #expect(throws: L4BookError.invalidPayload) { try L4BookUpdate(coin: " ETH", height: 1, time: 0, snapshot: true, changes: []) }
    }

    @Test func multipleMutationsInOneBatchMaintainLevelMembership() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        _ = try reducer.apply(block(snapshot: true))
        let a = try order(1), b = try order(1, "99", "2")
        let view = try reducer.apply(block(11, [.new(a), .update(order(1, "100", "3")), .remove(a.identity), .new(b)]))
        #expect(view.orderCount == 1 && view.priceLevelCount == 1)
        #expect(view.book.bids.first?.px == "99" && view.book.bids.first?.sz == "2")
        #expect(reducer.ordersSortedByID(side: .bid, price: 100).isEmpty)
        #expect(reducer.ordersSortedByID(side: .bid, price: 99) == [b])
    }

    @Test func sharedPriceSnapshotAndDeterministicInspectionRetainEveryOID() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        let orders = try (1...10_000).reversed().map { try order(UInt64($0), "100", "0.001") }
        let view = try reducer.apply(block(snapshot: true, orders.map(L4OrderChange.new)))
        #expect(view.book.bids.first?.n == 10_000 && view.book.bids.first?.sz == "10")
        #expect(reducer.ordersSortedByID(side: .bid, price: 100).map(\.oid) == Array(1...10_000).map(UInt64.init))
    }

    @Test func seededMutationStreamMatchesIndependentReferenceAggregation() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        _ = try reducer.apply(block(snapshot: true))
        var reference: [UInt64: L4Order] = [:]
        var seed: UInt64 = 42
        func random(_ bound: UInt64) -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return (seed >> 32) % bound
        }
        for height in UInt64(11)...1010 {
            let oid = random(80) + 1
            let change: L4OrderChange
            if let previous = reference[oid] {
                if random(3) == 0 { change = .remove(previous.identity); reference[oid] = nil }
                else {
                    let resized = try L4Order(identity: previous.identity, size: String(random(20) + 1))
                    change = .update(resized); reference[oid] = resized
                }
            } else {
                let side: L4OrderIdentity.Side = random(2) == 0 ? .bid : .ask
                let price = side == .bid ? 100 - random(30) : 101 + random(30)
                let added = try order(oid, String(price), String(random(20) + 1), side: side)
                change = .new(added); reference[oid] = added
            }
            _ = try reducer.apply(block(height, [change]))
            let view = try reducer.view(maximumLevelsPerSide: 100)
            #expect(view.orderCount == reference.count)
            for (index, side) in [L4OrderIdentity.Side.bid, .ask].enumerated() {
                let grouped = Dictionary(grouping: reference.values.filter { $0.identity.side == side }, by: { $0.identity.price })
                let prices = grouped.keys.sorted { side == .bid ? $0 > $1 : $0 < $1 }
                #expect(view.book.levels[index].count == prices.count)
                for (row, price) in zip(view.book.levels[index], prices) {
                    let orders = grouped[price] ?? []
                    #expect(Decimal(string: row.px) == price && row.n == orders.count)
                    #expect(Decimal(string: row.sz) == orders.reduce(Decimal.zero) { $0 + $1.size })
                }
            }
        }
    }
}
