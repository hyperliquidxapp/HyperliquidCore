import Foundation

public enum L4BookError: Error, Equatable, Sendable {
    case snapshotRequired, invalidOrder, duplicateOrder, unknownOrder, identityChanged
    case invalidWatermark, capacityExceeded, arithmeticOverflow, crossedBook, invalidPayload
}

public struct L4OrderIdentity: Equatable, Sendable {
    public enum Side: String, Codable, Sendable { case bid = "B", ask = "A" }
    public let oid: UInt64
    public let user: String
    public let coin: String
    public let side: Side
    public let rawPrice: String
    public let price: Decimal

    public init(oid: UInt64, user: String, coin: String, side: Side, price: String) throws {
        guard oid > 0, Address.isValid(user), !coin.isEmpty, coin.utf8.count <= 128,
              coin == coin.trimmingCharacters(in: .whitespacesAndNewlines) else { throw L4BookError.invalidOrder }
        self.oid = oid
        self.user = user.lowercased()
        self.coin = coin
        self.side = side
        rawPrice = price
        self.price = try L4Decimal.positive(price)
    }

    func matches(_ other: Self) -> Bool {
        oid == other.oid && user == other.user && coin == other.coin && side == other.side && price == other.price
    }
}

public struct L4Order: Equatable, Sendable {
    public let identity: L4OrderIdentity
    public let rawSize: String
    public let size: Decimal
    public var oid: UInt64 { identity.oid }

    public init(identity: L4OrderIdentity, size: String) throws {
        self.identity = identity
        rawSize = size
        self.size = try L4Decimal.positive(size)
    }

    fileprivate init(identity: L4OrderIdentity, remainingSize: String) throws {
        self.identity = identity
        rawSize = remainingSize
        size = try L4Decimal.nonnegative(remainingSize)
    }
}

public enum L4OrderChange: Equatable, Sendable {
    case new(L4Order), update(L4Order), remove(L4OrderIdentity)

    /// Absolute remaining quantity. Zero retires an existing order, never a resting zero-size order.
    public static func update(identity: L4OrderIdentity, remainingSize: String) throws -> Self {
        .update(try L4Order(identity: identity, remainingSize: remainingSize))
    }

    public var identity: L4OrderIdentity {
        switch self {
        case .new(let order), .update(let order): order.identity
        case .remove(let identity): identity
        }
    }
}

/// A complete provider batch, scoped to one coin. Height is a watermark, not a contiguous sequence guarantee.
public struct L4BookUpdate: Equatable, Sendable {
    public let coin: String
    public let height: UInt64
    public let time: Int64
    public let snapshot: Bool
    public let changes: [L4OrderChange]

    public init(coin: String, height: UInt64, time: Int64, snapshot: Bool, changes: [L4OrderChange]) throws {
        guard !coin.isEmpty, coin.utf8.count <= 128, coin == coin.trimmingCharacters(in: .whitespacesAndNewlines),
              time >= 0, changes.allSatisfy({ $0.identity.coin == coin }) else {
            throw L4BookError.invalidPayload
        }
        self.coin = coin
        self.height = height
        self.time = time
        self.snapshot = snapshot
        self.changes = changes
    }
}

/// Bounded aggregated projection of the complete OID map, without a claim of price-time queue ordering.
public struct L4BookView: Sendable {
    public let book: OrderBook
    public let height: UInt64
    public let orderCount: Int
    public let priceLevelCount: Int
    public let maximumLevelsPerSide: Int
}

enum L4Decimal {
    static func positive(_ raw: String) throws -> Decimal {
        let value = try nonnegative(raw)
        guard value > 0 else { throw L4BookError.invalidOrder }
        return value
    }

    static func nonnegative(_ raw: String) throws -> Decimal {
        guard raw.utf8.count <= 128 else { throw L4BookError.invalidOrder }
        let significant = raw.filter { $0 != "." }.drop(while: { $0 == "0" }).reversed().drop(while: { $0 == "0" })
        guard significant.count <= 38, let value = try? ReviewDecimal.parse(raw), value >= 0 else {
            throw L4BookError.invalidOrder
        }
        return value
    }

    static func add(_ a: Decimal, _ b: Decimal) throws -> Decimal {
        var a = a, b = b, result = Decimal()
        guard NSDecimalAdd(&result, &a, &b, .plain) == .noError else { throw L4BookError.arithmeticOverflow }
        return result
    }

    static func subtract(_ a: Decimal, _ b: Decimal) throws -> Decimal {
        var a = a, b = b, result = Decimal()
        guard NSDecimalSubtract(&result, &a, &b, .plain) == .noError, result >= 0 else { throw L4BookError.arithmeticOverflow }
        return result
    }
}
