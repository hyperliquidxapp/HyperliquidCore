import Foundation

/// Validates the JSON representation of Quicknode StreamL4BookUpdates (for fixtures and gateways).
public enum QuicknodeL4BookCodec {
    public static func decode(_ value: JSONValue, coin: String, maximumChanges: Int = 1_000_000) throws -> L4BookUpdate {
        guard let height = unsigned(value["height"]), let time = unsigned(value["time"]), time <= UInt64(Int64.max),
              case .array(let events) = value["diffs"], events.count <= max(0, min(2_000_000, maximumChanges)),
              value["snapshot"] == .null || value["snapshot"].bool != nil else { throw L4BookError.invalidPayload }
        var changes: [L4OrderChange] = []
        for event in events {
            let change = try decodeChange(event)
            if change.identity.coin == coin { changes.append(change) }
        }
        return try L4BookUpdate(coin: coin, height: height, time: Int64(time), snapshot: value["snapshot"].bool ?? false, changes: changes)
    }

    private static func decodeChange(_ raw: JSONValue) throws -> L4OrderChange {
        guard let oid = unsigned(raw["oid"]), let user = raw["user"].string, let coin = raw["coin"].string,
              let sideText = raw["side"].string, let side = L4OrderIdentity.Side(rawValue: sideText),
              let price = raw["px"].string,
              raw["diff_type"] == .null || raw["diffType"] == .null || raw["diff_type"] == raw["diffType"] else {
            throw L4BookError.invalidPayload
        }
        let identity = try L4OrderIdentity(oid: oid, user: user, coin: coin, side: side, price: price)
        let kind = raw["diff_type"] == .null ? raw["diffType"] : raw["diff_type"]
        switch kind {
        case .string("L4_ORDER_DIFF_TYPE_NEW"), .integer(1):
            guard let size = raw["sz"].string else { throw L4BookError.invalidPayload }
            return .new(try L4Order(identity: identity, size: size))
        case .string("L4_ORDER_DIFF_TYPE_UPDATE"), .integer(2):
            guard let size = raw["sz"].string else { throw L4BookError.invalidPayload }
            return .update(try L4Order(identity: identity, size: size))
        case .string("L4_ORDER_DIFF_TYPE_REMOVE"), .integer(3): return .remove(identity)
        default: throw L4BookError.invalidPayload
        }
    }

    private static func unsigned(_ value: JSONValue) -> UInt64? {
        switch value {
        case .integer(let integer): return UInt64(exactly: integer)
        case .string(let text):
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt64(text)
        default: return nil
        }
    }
}
