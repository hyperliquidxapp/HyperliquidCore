import Foundation

/// Sanitized field diagnostics. The invalid value, order ID, wallet and provider text are never retained.
public struct QuicknodeL4DecodingFailure: Error, Equatable, Sendable {
    public enum Field: String, Sendable { case oid, user, coin, side, price, size }
    public enum ValueKind: String, Sendable { case empty, zero, negative, other }
    public let field: Field
    public let valueKind: ValueKind
    public let height: UInt64
    public let time: UInt64
    public let snapshot: Bool
    public let diffType: Int
    public let matchesRequestedCoin: Bool

    init(field: Field, value: String, message: Hyperliquid_L4BookUpdatesUpdate,
         diff: Hyperliquid_L4OrderDiff, requestedCoin: String) {
        self.field = field
        if value.isEmpty {
            valueKind = .empty
        } else if value.utf8.count <= 128,
                  value.range(of: "^-?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                  let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN, number <= 0 {
            valueKind = number == 0 ? .zero : .negative
        } else {
            valueKind = .other
        }
        height = message.height
        time = message.time
        snapshot = message.snapshot
        diffType = diff.diffType.rawValue
        matchesRequestedCoin = diff.coin == requestedCoin
    }
}
