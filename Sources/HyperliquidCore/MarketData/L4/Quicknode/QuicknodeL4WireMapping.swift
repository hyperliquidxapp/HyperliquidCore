import Foundation

enum QuicknodeL4WireMapping {
    static func decode(_ message: Hyperliquid_L4BookUpdatesUpdate, coin: String, maximumChanges: Int) throws -> L4BookUpdate {
        guard message.time <= UInt64(Int64.max), message.diffs.count <= maximumChanges else {
            throw L4BookError.invalidPayload
        }
        var changes: [L4OrderChange] = []
        changes.reserveCapacity(message.diffs.count)
        for diff in message.diffs {
            func invalid(_ field: QuicknodeL4DecodingFailure.Field, _ value: String) -> QuicknodeL4DecodingFailure {
                .init(field: field, value: value, message: message, diff: diff, requestedCoin: coin)
            }
            guard let side = L4OrderIdentity.Side(rawValue: diff.side) else { throw invalid(.side, diff.side) }
            guard diff.oid > 0 else { throw invalid(.oid, "0") }
            guard Address.isValid(diff.user) else { throw invalid(.user, diff.user) }
            guard !diff.coin.isEmpty, diff.coin.utf8.count <= 128,
                  diff.coin == diff.coin.trimmingCharacters(in: .whitespacesAndNewlines) else { throw invalid(.coin, diff.coin) }
            let identity: L4OrderIdentity
            do { identity = try L4OrderIdentity(oid: diff.oid, user: diff.user, coin: diff.coin, side: side, price: diff.px) }
            catch { throw invalid(.price, diff.px) }
            func sizedOrder() throws -> L4Order {
                do { return try L4Order(identity: identity, size: diff.sz) }
                catch { throw invalid(.size, diff.sz) }
            }
            let change: L4OrderChange
            switch diff.diffType.rawValue {
            case 1: change = .new(try sizedOrder())
            case 2:
                do { change = try .update(identity: identity, remainingSize: diff.sz) }
                catch { throw invalid(.size, diff.sz) }
            case 3: change = .remove(identity)
            default: throw L4BookError.invalidPayload
            }
            if identity.coin == coin { changes.append(change) }
        }
        return try L4BookUpdate(coin: coin, height: message.height, time: Int64(message.time), snapshot: message.snapshot, changes: changes)
    }
}
