import Foundation
import Testing
@testable import HyperliquidCore

@Suite struct L4BookQueryTests {
    private func order(_ oid: UInt64, price: String = "100", size: String = "1",
                       side: L4OrderIdentity.Side = .bid) throws -> L4Order {
        try .init(identity: .init(oid: oid, user: "0x0000000000000000000000000000000000000001",
                                  coin: "ETH", side: side, price: price), size: size)
    }

    private func block(_ height: UInt64 = 10, snapshot: Bool = false,
                       _ changes: [L4OrderChange] = []) throws -> L4BookUpdate {
        try .init(coin: "ETH", height: height, time: Int64(height * 100), snapshot: snapshot, changes: changes)
    }

    @Test func boundedPagesVisitAllOidsExactlyOnceAndRetainWalletAttribution() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        let ids = Array(1...2003).map(UInt64.init) + [UInt64.max]
        let changes = try ids.reversed().map { try L4OrderChange.new(order($0)) }
        _ = try reducer.apply(block(snapshot: true, changes + [.new(order(3000, price: "101", side: .ask))]))
        var cursor: L4OrderPageCursor?
        var observed: [UInt64] = []
        repeat {
            let page = try reducer.orderPage(side: .bid, price: 100, after: cursor, limit: 37)
            #expect(page.orders.count <= 37 && page.totalOrderCount == ids.count && page.totalSize == Decimal(ids.count))
            #expect(page.height == 10 && page.time == 1000 && page.environment == .testnet && page.coin == "ETH")
            #expect(page.orders.allSatisfy { $0.identity.user == "0x0000000000000000000000000000000000000001" })
            observed += page.orders.map(\.oid)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(observed == ids && Set(observed).count == ids.count)
        #expect(reducer.status == .live && reducer.orderCount == ids.count + 1)
    }

    @Test func unchangedLevelCanContinueAcrossOtherPriceUpdates() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        _ = try reducer.apply(block(snapshot: true, [.new(order(1)), .new(order(2)), .new(order(3, price: "99"))]))
        let first = try reducer.orderPage(side: .bid, price: 100, limit: 1)
        let cursor = try #require(first.nextCursor)
        _ = try reducer.apply(block(11, [.update(order(3, price: "99", size: "5"))]))
        let next = try reducer.orderPage(side: .bid, price: 100, after: cursor, limit: 1)
        #expect(next.orders.map(\.oid) == [2] && next.nextCursor == nil)
        #expect(next.levelRevision == first.levelRevision && next.height == 11 && next.time == 1100)
    }

    @Test(arguments: [0, 1, 2, 3]) func touchedDeletedOrReplacedLevelsRejectPriorPagination(mutation: Int) throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        let initial = try [L4OrderChange.new(order(1)), .new(order(2))]
        _ = try reducer.apply(block(snapshot: true, initial))
        let cursor = try #require(reducer.orderPage(side: .bid, price: 100, limit: 1).nextCursor)
        switch mutation {
        case 0: _ = try reducer.apply(block(11, [.update(order(2, size: "2"))]))
        case 1: _ = try reducer.apply(block(11, [.remove(order(1).identity), .remove(order(2).identity)]))
        case 2: _ = try reducer.apply(block(snapshot: true, initial))
        default:
            reducer.resetForNewConnection()
            _ = try reducer.apply(block(1, snapshot: true, initial))
        }
        #expect(throws: L4BookQueryError.staleCursor) { try reducer.orderPage(side: .bid, price: 100, after: cursor) }
        #expect(reducer.status == .live)
    }

    @Test func queryScopeCannotRedirectACursorEvenWhenTwoLevelsShareABatchRevision() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        _ = try reducer.apply(block(snapshot: true, [.new(order(1)), .new(order(2)),
                                                     .new(order(3, price: "101", side: .ask)), .new(order(4, price: "101", side: .ask))]))
        let cursor = try #require(reducer.orderPage(side: .bid, price: 100, limit: 1).nextCursor)
        #expect(throws: L4BookQueryError.invalidCursor) { try reducer.orderPage(side: .ask, price: 101, after: cursor) }
        let bad = L4OrderPageCursor(environment: .mainnet, coin: cursor.coin, side: cursor.side, price: cursor.price,
                                    levelRevision: cursor.levelRevision, afterOID: cursor.afterOID)
        #expect(throws: L4BookQueryError.invalidCursor) { try reducer.orderPage(side: .bid, price: 100, after: bad) }
        var other = try L4BookReducer(environment: .testnet, coin: "ETH")
        _ = try other.apply(block(snapshot: true, [.new(order(1)), .new(order(2))]))
        #expect(throws: L4BookQueryError.staleCursor) { try other.orderPage(side: .bid, price: 100, after: cursor) }
    }

    @Test func invalidQueriesDoNotInvalidateTheBookAndEmptyLevelIsExplicit() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        #expect(throws: L4BookError.snapshotRequired) { try reducer.orderPage(side: .bid, price: 100) }
        _ = try reducer.apply(block(snapshot: true, [.new(order(1))]))
        for limit in [0, -1, 501, Int.max] {
            #expect(throws: L4BookQueryError.invalidLimit) { try reducer.orderPage(side: .bid, price: 100, limit: limit) }
        }
        for price in [Decimal.zero, -1, .nan] {
            #expect(throws: L4BookQueryError.invalidPrice) { try reducer.orderPage(side: .bid, price: price) }
        }
        let empty = try reducer.orderPage(side: .ask, price: 101)
        #expect(empty.orders.isEmpty && empty.totalOrderCount == 0 && empty.totalSize == 0)
        #expect(empty.nextCursor == nil && empty.levelRevision == nil && reducer.orderCount == 1 && reducer.status == .live)
        reducer.invalidate()
        #expect(throws: L4BookError.snapshotRequired) { try reducer.orderPage(side: .bid, price: 100) }
    }

    @Test func boundedSelectionMatchesSortingForDifferentPagesAndLimits() throws {
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        var seed: UInt64 = 44
        var ids: Set<UInt64> = [UInt64.max]
        for _ in 0..<5000 { seed = seed &* 6_364_136_223_846_793_005 &+ 1; if seed > 0 { ids.insert(seed) } }
        _ = try reducer.apply(block(snapshot: true, try ids.map { try .new(order($0)) }))
        for limit in [1, 7, 100, 500] {
            let first = try reducer.orderPage(side: .bid, price: try #require(Decimal(string: "100.000")), limit: limit)
            #expect(first.orders.map(\.oid) == Array(ids.sorted().prefix(limit)))
            let cursor = try #require(first.nextCursor)
            let second = try reducer.orderPage(side: .bid, price: 100, after: cursor, limit: limit)
            #expect(second.orders.map(\.oid) == Array(ids.sorted().dropFirst(limit).prefix(limit)))
        }
    }
}
