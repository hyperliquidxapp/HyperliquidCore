import Foundation

public enum L4BookQueryError: Error, Equatable, Sendable {
    case invalidLimit, invalidPrice, invalidCursor, staleCursor
}

/// Local pagination identity, not an exchange sequence or a queue-priority position.
public struct L4OrderPageCursor: Equatable, Sendable {
    public let environment: NetworkEnvironment
    public let coin: String
    public let side: L4OrderIdentity.Side
    public let price: Decimal
    public let levelRevision: UUID
    public let afterOID: UInt64
}

/// A bounded inspection of one unchanged price level, sorted numerically by OID, never FIFO.
public struct L4OrderPage: Sendable {
    public let environment: NetworkEnvironment
    public let coin: String
    public let side: L4OrderIdentity.Side
    public let price: Decimal
    public let height: UInt64
    public let time: Int64
    public let levelRevision: UUID?
    public let totalOrderCount: Int
    public let totalSize: Decimal
    public let orders: [L4Order]
    public let nextCursor: L4OrderPageCursor?
}
