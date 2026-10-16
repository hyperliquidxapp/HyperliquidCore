import Foundation

public enum PositionIntentPurpose: String, Sendable {
    case close = "Close position"
    case protect = "Protect position"
    case reverse = "Reverse position"
}

/// A reviewed position action belongs to the exact position on which it was prepared.
/// The client checks this again after signing, before posting the immutable order.
public struct PositionIntentGuard: Sendable {
    public let coin: String
    public let signedSize: String
    public let purpose: PositionIntentPurpose
    public init(position: Position, purpose: PositionIntentPurpose) {
        coin = position.coin
        signedSize = position.szi
        self.purpose = purpose
    }
    public func validate(current: Position?, intent: OrderIntent) throws {
        guard let current, current.coin == coin, let quantity = current.signedQuantity,
              let expected = try? ReviewDecimal.parse(signedSize), quantity == expected
        else {
            throw OrderValidationError.invalid(
                "Position changed. Prepare and preview this position action again.")
        }
        try validateDraft(intent)
    }
    public func validateDraft(_ intent: OrderIntent) throws {
        guard intent.market.kind == .perp, intent.market.coin == coin,
              let signed = try? ReviewDecimal.parse(signedSize), signed != 0,
              let quantity = try? ReviewDecimal.parse(intent.size), quantity > 0,
              intent.side == (signed > 0 ? .sell : .buy)
        else {
            throw OrderValidationError.invalid(
                "Position action must trade the opposite side of the current position")
        }
        let absolute = abs(signed)
        if intent.protectionSizing == .entirePosition {
            guard purpose == .protect, intent.kind.conditional, intent.reduceOnly,
                  quantity == absolute
            else {
                throw OrderValidationError.invalid(
                    "Entire-position protection must preview the whole current position. Prepare the position action again."
                )
            }
        }
        if purpose == .reverse {
            guard !intent.reduceOnly, intent.kind == .market, quantity > absolute else {
                throw OrderValidationError.invalid(
                    "Reverse requires a market order larger than the current position, without reduce-only"
                )
            }
        } else {
            guard intent.reduceOnly, quantity <= absolute,
                  purpose != .protect || intent.kind.conditional
            else {
                throw OrderValidationError.invalid(
                    "Closing and protection orders must be reduce-only and no larger than the current position"
                )
            }
        }
    }
}

public struct PositionOrderDraft: Sendable {
    public let side: OrderSide
    public let size: String
    public let kind: OrderKind
    public let reduceOnly: Bool
    public let leverage: Int
    public let guardValue: PositionIntentGuard
    public static func prepare(
        position: Position, market: Market, purpose: PositionIntentPurpose,
        fraction: Decimal = 1, kind: OrderKind = .market
    ) throws -> PositionOrderDraft {
        guard position.coin == market.coin, market.kind == .perp,
              let signed = position.signedQuantity, signed != 0, fraction > 0, fraction <= 1,
              purpose != .protect || kind.conditional,
              purpose != .reverse || fraction == 1
        else {
            throw OrderValidationError.invalid(
                "Select a live position and a closing fraction between 0 and 100%")
        }
        let quantity = abs(signed) * (purpose == .reverse ? 2 : fraction)
        let size = try OrderPlanner.normalizeSize(
            NSDecimalNumber(decimal: quantity).stringValue, decimals: market.sizeDecimals)
        let guardValue = PositionIntentGuard(position: position, purpose: purpose)
        return PositionOrderDraft(
            side: signed > 0 ? .sell : .buy, size: size, kind: purpose == .reverse ? .market : kind,
            reduceOnly: purpose != .reverse, leverage: position.leverage.value,
            guardValue: guardValue)
    }
}
