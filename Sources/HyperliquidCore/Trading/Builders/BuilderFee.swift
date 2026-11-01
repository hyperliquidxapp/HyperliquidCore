import Foundation

public enum BuilderFeeError: Error, Equatable, Sendable {
    case invalidAddress, invalidRate, invalidApproval, invalidContext, signatureMismatch,
        unsupportedAction, feeChanged
}

/// Fees are expressed in tenths of a basis point: 10 = 0.01%.
public struct BuilderFee: Equatable, Sendable {
    public let address: String
    public let tenthsOfBasisPoint: Int
    public var rate: Decimal { Decimal(tenthsOfBasisPoint) / 100_000 }
    public var percentage: String {
        NSDecimalNumber(decimal: Decimal(tenthsOfBasisPoint) / 1000).stringValue + "%"
    }
    public var wire: WireValue {
        .map([("b", .string(address)), ("f", .uint(UInt64(tenthsOfBasisPoint)))])
    }

    public init(address: String, tenthsOfBasisPoint: Int) throws {
        guard Address.isValid(address),
            address.lowercased() != "0x0000000000000000000000000000000000000000"
        else { throw BuilderFeeError.invalidAddress }
        guard (1...1000).contains(tenthsOfBasisPoint) else { throw BuilderFeeError.invalidRate }
        self.address = address.lowercased()
        self.tenthsOfBasisPoint = tenthsOfBasisPoint
    }

    /// Builder recipients must retain standard account mode and at least 100 USDC in perps account value.
    public static func isEligible(accountValue: String, abstraction: String) throws -> Bool {
        let value = try ReviewDecimal.parse(accountValue)
        return ["default", "disabled"].contains(abstraction) && value >= 100
    }

    public func applicable(to intent: OrderIntent) throws -> BuilderFee? {
        if intent.market.kind == .perp {
            guard tenthsOfBasisPoint <= 100 else { throw BuilderFeeError.invalidRate }
            return self
        }
        return intent.side == .sell ? self : nil
    }

    public func approvedLimit(_ response: JSONValue) throws -> Int {
        guard case .integer(let value) = response, (0...1000).contains(value) else {
            throw BuilderFeeError.invalidApproval
        }
        return Int(value)
    }

    /// Append only to a documented order action, before hashing/signing. Modify/cancel actions are not extended.
    public func appending(toOrderAction action: WireValue) throws -> WireValue {
        guard case .map(let fields) = action, Set(fields.map(\.0)).count == fields.count,
            let type = fields.first(where: { $0.0 == "type" })?.1, case .string("order") = type,
            !fields.contains(where: { $0.0 == "builder" }),
            let orders = fields.first(where: { $0.0 == "orders" })?.1,
            case .array(let wires) = orders, !wires.isEmpty
        else { throw BuilderFeeError.unsupportedAction }
        var chargeable = false
        for wire in wires {
            guard case .map(let order) = wire, Set(order.map(\.0)).count == order.count,
                let asset = order.first(where: { $0.0 == "a" })?.1,
                case .uint(let assetID) = asset,
                let direction = order.first(where: { $0.0 == "b" })?.1,
                case .bool(let buy) = direction
            else { throw BuilderFeeError.unsupportedAction }
            let perp = assetID < 10_000 || assetID >= 100_000
            if perp && tenthsOfBasisPoint > 100 { throw BuilderFeeError.invalidRate }
            chargeable = chargeable || perp || !buy
        }
        return chargeable ? .map(fields + [("builder", wire)]) : action
    }
}

extension ExchangeAction {
    public static func place(_ intent: OrderIntent, cloid: String? = nil, builder: BuilderFee?)
        throws
        -> WireValue
    {
        let action = place(intent, cloid: cloid)
        guard let applicable = try builder?.applicable(to: intent) else { return action }
        return try applicable.appending(toOrderAction: action)
    }
}

extension ProtectionBatch {
    public func action(builder: BuilderFee?) throws -> WireValue {
        guard mode != .modify, let builder else { return action }
        return try builder.appending(toOrderAction: action)
    }
}
