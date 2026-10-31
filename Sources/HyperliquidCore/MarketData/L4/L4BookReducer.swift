import Foundation

/// Maintains every resting OID, aggregated level membership, and sorted price indexes for one connection.
/// Order statuses and trades must not also decrement this authoritative book state.
public struct L4BookReducer {
    public enum Status: Equatable, Sendable { case awaitingSnapshot, live, resynchronizationRequired }
    private struct PriceKey: Hashable {
        let side: L4OrderIdentity.Side
        let price: Decimal
    }
    private struct Level {
        let rawPrice: String
        var size: Decimal = 0
        var members: Set<UInt64> = []
    }
    private final class StagedLevel {
        var value: Level
        init(_ value: Level) { self.value = value }
    }
    private enum Change { case present(L4Order), removed }

    public let environment: NetworkEnvironment
    public let coin: String
    public let maximumOrders: Int
    public let maximumChanges: Int
    public private(set) var status: Status = .awaitingSnapshot
    public private(set) var orderCount = 0
    private var orders: [UInt64: L4Order] = [:]
    private var levels: [PriceKey: Level] = [:]
    private var bids: [Decimal] = []
    private var asks: [Decimal] = []
    private var height: UInt64?
    private var time: Int64?

    public init(environment: NetworkEnvironment, coin: String, maximumOrders: Int = 500_000, maximumChanges: Int = 1_000_000) throws {
        guard !coin.isEmpty, coin.utf8.count <= 128, coin == coin.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw L4BookError.invalidPayload
        }
        self.environment = environment
        self.coin = coin
        self.maximumOrders = min(2_000_000, max(1, maximumOrders))
        self.maximumChanges = min(2_000_000, max(1, maximumChanges))
    }

    public func order(_ oid: UInt64) -> L4Order? { orders[oid] }

    /// Numeric OID order is for deterministic inspection. It is not FIFO or a queue-priority estimate.
    public func ordersSortedByID(side: L4OrderIdentity.Side, price: Decimal) -> [L4Order] {
        (levels[PriceKey(side: side, price: price)]?.members ?? []).sorted().compactMap { orders[$0] }
    }

    public mutating func invalidate() {
        clearOrders()
        status = .resynchronizationRequired
        // An accepted chain watermark survives faults in this connection.
    }

    public mutating func resetForNewConnection() {
        clearOrders()
        height = nil
        time = nil
        status = .awaitingSnapshot
    }

    public mutating func apply(_ update: L4BookUpdate) throws -> L4BookView {
        do { return try applyBlock(update) } catch {
            invalidate()
            throw error
        }
    }

    public func view(maximumLevelsPerSide: Int = 20) throws -> L4BookView {
        guard status == .live, let height, let time else { throw L4BookError.snapshotRequired }
        let book = try projection(bids: bids, asks: asks, time: time, maximumLevels: maximumLevelsPerSide) { levels[$0] }
        return L4BookView(book: book, height: height, orderCount: orderCount,
                          priceLevelCount: bids.count + asks.count, maximumLevelsPerSide: maximumLevelsPerSide)
    }

    private mutating func applyBlock(_ update: L4BookUpdate) throws -> L4BookView {
        guard update.coin == coin, update.changes.count <= maximumChanges else { throw L4BookError.invalidPayload }
        if let height {
            guard update.snapshot ? update.height >= height : update.height > height else { throw L4BookError.invalidWatermark }
        }
        if let time, update.time < time { throw L4BookError.invalidWatermark }
        guard update.snapshot || status == .live else { throw L4BookError.snapshotRequired }
        let reset = update.snapshot
        var orderChanges: [UInt64: Change] = [:]
        var levelChanges: [PriceKey: StagedLevel] = [:]
        var count = reset ? 0 : orderCount
        func existing(_ oid: UInt64) -> L4Order? {
            if let change = orderChanges[oid] {
                if case .present(let order) = change { return order }
                return nil
            }
            return reset ? nil : orders[oid]
        }
        for change in update.changes {
            let identity = change.identity
            let key = PriceKey(side: identity.side, price: identity.price)
            let previous = existing(identity.oid)
            let staged = levelChanges[key] ?? StagedLevel((reset ? nil : levels[key]) ?? Level(rawPrice: identity.rawPrice))
            levelChanges[key] = staged
            switch change {
            case .new(let order):
                guard previous == nil else { throw L4BookError.duplicateOrder }
                guard count < maximumOrders else { throw L4BookError.capacityExceeded }
                count += 1
                guard staged.value.members.insert(order.oid).inserted else { throw L4BookError.duplicateOrder }
                staged.value.size = try L4Decimal.add(staged.value.size, order.size)
                orderChanges[order.oid] = .present(order)
            case .update(let order):
                guard !reset else { throw L4BookError.invalidOrder }
                guard let previous else { throw L4BookError.unknownOrder }
                guard previous.identity.matches(identity) else { throw L4BookError.identityChanged }
                staged.value.size = try L4Decimal.add(try L4Decimal.subtract(staged.value.size, previous.size), order.size)
                orderChanges[order.oid] = .present(order)
            case .remove:
                guard !reset else { throw L4BookError.invalidOrder }
                guard let previous else { throw L4BookError.unknownOrder }
                guard previous.identity.matches(identity) else { throw L4BookError.identityChanged }
                guard staged.value.members.remove(identity.oid) != nil else { throw L4BookError.unknownOrder }
                staged.value.size = try L4Decimal.subtract(staged.value.size, previous.size)
                count -= 1
                orderChanges[identity.oid] = .removed
            }
            guard staged.value.members.isEmpty ? staged.value.size == 0 : staged.value.size > 0 else { throw L4BookError.invalidOrder }
        }
        var nextBids = reset ? [] : bids
        var nextAsks = reset ? [] : asks
        if reset {
            nextBids = levelChanges.keys.filter { $0.side == .bid }.map(\.price).sorted(by: >)
            nextAsks = levelChanges.keys.filter { $0.side == .ask }.map(\.price).sorted()
        } else {
            for (key, staged) in levelChanges {
                let hasMembers = !staged.value.members.isEmpty
                guard (levels[key] != nil) != hasMembers else { continue }
                if key.side == .bid { Self.updatePrices(&nextBids, price: key.price, insert: hasMembers, descending: true) }
                else { Self.updatePrices(&nextAsks, price: key.price, insert: hasMembers, descending: false) }
            }
        }
        let book = try projection(bids: nextBids, asks: nextAsks, time: update.time, maximumLevels: 20) {
            levelChanges[$0]?.value ?? (reset ? nil : levels[$0])
        }
        // All validation and checked arithmetic finish before committing either index.
        if reset { orders.removeAll(keepingCapacity: true); levels.removeAll(keepingCapacity: true) }
        for (oid, change) in orderChanges {
            switch change {
            case .present(let order): orders[oid] = order
            case .removed: orders.removeValue(forKey: oid)
            }
        }
        for (key, staged) in levelChanges {
            if staged.value.members.isEmpty { levels.removeValue(forKey: key) } else { levels[key] = staged.value }
        }
        bids = nextBids
        asks = nextAsks
        orderCount = count
        height = update.height
        time = update.time
        status = .live
        return L4BookView(book: book, height: update.height, orderCount: count,
                          priceLevelCount: bids.count + asks.count, maximumLevelsPerSide: 20)
    }

    private func projection(bids: [Decimal], asks: [Decimal], time: Int64, maximumLevels: Int,
                            level: (PriceKey) -> Level?) throws -> OrderBook {
        guard (1...1000).contains(maximumLevels) else { throw L4BookError.capacityExceeded }
        if let bid = bids.first, let ask = asks.first, bid > ask { throw L4BookError.crossedBook }
        func rows(_ prices: [Decimal], side: L4OrderIdentity.Side) throws -> [BookLevel] {
            var total: Decimal = 0
            return try prices.prefix(maximumLevels).map { price in
                guard let value = level(PriceKey(side: side, price: price)), !value.members.isEmpty, value.size > 0 else {
                    throw L4BookError.invalidOrder
                }
                total = try L4Decimal.add(total, value.size)
                return BookLevel(px: value.rawPrice, sz: NSDecimalNumber(decimal: value.size).stringValue, n: value.members.count)
            }
        }
        return try OrderBook(coin: coin, time: time, levels: [rows(bids, side: .bid), rows(asks, side: .ask)])
    }

    private mutating func clearOrders() {
        orders.removeAll()
        levels.removeAll()
        bids.removeAll()
        asks.removeAll()
        orderCount = 0
    }

    private static func updatePrices(_ prices: inout [Decimal], price: Decimal, insert: Bool, descending: Bool) {
        var low = 0, high = prices.count
        while low < high {
            let middle = (low + high) / 2
            if descending ? prices[middle] > price : prices[middle] < price { low = middle + 1 } else { high = middle }
        }
        if insert { prices.insert(price, at: low) }
        else if prices.indices.contains(low), prices[low] == price { prices.remove(at: low) }
    }
}
