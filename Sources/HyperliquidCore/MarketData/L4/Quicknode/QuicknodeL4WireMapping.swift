import Foundation

enum QuicknodeL4WireMapping {
    static func decode(_ message: Hyperliquid_L4BookUpdatesUpdate, coin: String, maximumChanges: Int) throws -> L4BookUpdate {
        guard message.time <= UInt64(Int64.max), message.diffs.count <= maximumChanges else {
            throw L4BookError.invalidPayload
        }
        var changes: [L4OrderChange] = []
        changes.reserveCapacity(message.diffs.count)
        for diff in message.diffs {
            guard let side = L4OrderIdentity.Side(rawValue: diff.side) else { throw L4BookError.invalidPayload }
            let identity = try L4OrderIdentity(oid: diff.oid, user: diff.user, coin: diff.coin, side: side, price: diff.px)
            let change: L4OrderChange
            switch diff.diffType.rawValue {
            case 1: change = .new(try L4Order(identity: identity, size: diff.sz))
            case 2: change = .update(try L4Order(identity: identity, size: diff.sz))
            case 3: change = .remove(identity)
            default: throw L4BookError.invalidPayload
            }
            if identity.coin == coin { changes.append(change) }
        }
        return try L4BookUpdate(coin: coin, height: message.height, time: Int64(message.time), snapshot: message.snapshot, changes: changes)
    }
}
