import Foundation

public enum AccountEventKind: String, Sendable {
    case position, leverage, order, fill, funding, balance, ledger, liquidation
}
public struct AccountEvent: Sendable, Identifiable {
    public let id: String
    public let kind: AccountEventKind
    public let time: Int64
    public let data: JSONValue
}
public struct AccountRevision: Sendable {
    public fileprivate(set) var positions = 0
    public fileprivate(set) var orders = 0
    public fileprivate(set) var balances = 0
}

/// Pure account-state reducer. One instance belongs to one address and one socket generation.
/// Snapshots establish a baseline; time-series snapshots never announce old fills as new trades.
public struct AccountStream: Sendable {
    public let address: String
    public private(set) var account: AccountState?
    public private(set) var orders: [OpenOrder] = []
    public private(set) var balances: JSONValue = .null
    public private(set) var fills: [Fill] = []
    public private(set) var funding: [JSONValue] = []
    public private(set) var ledger: [JSONValue] = []
    public private(set) var orderHistory: [JSONValue] = []
    public private(set) var revision = AccountRevision()
    public private(set) var snapshotChannels = Set<String>()
    public var ready: Bool {
        Set(["clearinghouseState", "openOrders", "spotState"]).isSubset(of: snapshotChannels)
    }
    public var needsOrderDetails: Bool {
        orders.contains {
            $0.orderType == nil || $0.reduceOnly == nil
                || ($0.orderType != "Limit"
                        && ($0.isTrigger == nil || $0.triggerPx == nil || $0.isPositionTpsl == nil))
        }
    }
    private var ordersInitialized = false
    private var balancesInitialized = false
    private var events: [AccountEvent] = []
    private var orderVersions: [Int64: (time: Int64, terminal: Bool)] = [:]
    private var liquidationIDs = Set<String>()
    private let monitoringSince: Int64
    public init(
        address: String,
        monitoringSince: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws {
        guard Address.isValid(address) else {
            throw APIError.malformed("Invalid account-stream address")
        }
        self.address = address.lowercased()
        self.monitoringSince = monitoringSince
    }
    public static func subscriptions(address: String) -> [[String: JSONValue]] {
        [
            "clearinghouseState", "openOrders", "spotState", "userFills", "userFundings",
            "userNonFundingLedgerUpdates",
            "orderUpdates", "userEvents"
        ].map { type in
            var result: [String: JSONValue] = [
                "type": .string(type), "user": .string(address.lowercased())
            ]
            if type == "clearinghouseState" || type == "openOrders" { result["dex"] = .string("") }
            return result
        }
    }
    public mutating func reconnect() { snapshotChannels.removeAll() }
    @discardableResult public mutating func ingest(
        _ message: SocketMessage, receivedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> Bool {
        guard let data = message.data else { return false }
        if let user = data["user"].string, user.lowercased() != address { return false }
        switch message.channel {
        case "clearinghouseState":
            guard matchesUser(data), data["dex"].string == "" else { return false }
            guard case .object(var raw) = data["clearinghouseState"] else {
                throw APIError.malformed("Invalid clearinghouse snapshot")
            }
            // Some documented stream schemas omit server time. Preserve the last known server
            // time; receipt freshness is tracked separately and is never fabricated here.
            if raw["time"] == nil { raw["time"] = .integer(account?.time ?? 0) }
            let state = try JSONValue.object(raw).decode(AccountState.self)
            guard state.time >= (account?.time ?? 0) else { return false }
            applyAccount(state, time: receivedAt)
            revision.positions += 1
        case "openOrders":
            guard matchesUser(data), data["dex"].string == "", case .array = data["orders"] else {
                return false
            }
            applyOrders(try data["orders"].decode([OpenOrder].self), time: receivedAt)
            revision.orders += 1
        case "spotState":
            guard matchesUser(data), case .array = data["spotState"]["balances"] else {
                return false
            }
            applyBalances(data["spotState"], time: receivedAt)
            revision.balances += 1
        case "userFills":
            guard matchesUser(data), case .array = data["fills"] else { return false }
            mergeFills(
                try data["fills"].decode([Fill].self), announce: data["isSnapshot"].bool != true)
        case "userFundings":
            guard matchesUser(data), case .array(let values) = data["fundings"] else {
                return false
            }
            mergeFunding(values.map(Self.fundingRecord), announce: data["isSnapshot"].bool != true)
        case "userNonFundingLedgerUpdates":
            guard matchesUser(data), case .array(let values) = data["nonFundingLedgerUpdates"]
            else { return false }
            mergeLedger(values, announce: data["isSnapshot"].bool != true)
        case "orderUpdates":
            guard case .array(let updates) = data else {
                throw APIError.malformed("Invalid order-update batch")
            }
            for update in updates { try applyOrderUpdate(update) }
            revision.orders += 1
        case "user":
            if data["liquidation"]["liquidated_user"].string?.lowercased() == address {
                let value = data["liquidation"]
                let id = Self.recordID(value)
                if liquidationIDs.insert(id).inserted {
                    emit(.liquidation, id: id, time: receivedAt, data: value)
                }
            }
            if case .array(let cancellations) = data["nonUserCancel"] {
                for value in cancellations {
                    guard let oid = value["oid"].int64 else { continue }
                    guard orderVersions[oid]?.terminal != true else { continue }
                    orders.removeAll { $0.oid == oid }
                    orderVersions[oid] = (receivedAt, true)
                    emit(
                        .order, id: "\(oid):nonUserCancel", time: receivedAt,
                        data: .object([
                            "oid": .integer(oid), "coin": value["coin"],
                            "status": .string("Canceled by exchange")
                        ]))
                }
                revision.orders += 1
            }
        default: return false
        }
        snapshotChannels.insert(message.channel)
        return true
    }
    /// REST may enrich details, but a request started before a socket update cannot replace its index.
    public mutating func mergeREST(
        account: AccountState, orders: [OpenOrder], fills: [Fill], balances: JSONValue,
        startedAt revision: AccountRevision, receivedAt: Int64, preferStream: Bool = false
    ) {
        if !preferStream, self.revision.positions == revision.positions,
           account.time >= (self.account?.time ?? 0) {
            applyAccount(account, time: receivedAt)
        }
        if !preferStream, self.revision.orders == revision.orders {
            applyOrders(orders, time: receivedAt)
        } else {
            enrichOrderDetails(orders)
        }
        if !preferStream, self.revision.balances == revision.balances {
            applyBalances(balances, time: receivedAt)
        }
        mergeFills(fills, announce: false)
    }
    public mutating func mergeHistory(
        funding: [JSONValue], ledger: [JSONValue], orders: [JSONValue]
    ) {
        mergeFunding(funding, announce: false)
        mergeLedger(ledger, announce: false)
        orderHistory = Self.mergeRecords(
            orderHistory, orders, key: Self.orderHistoryID, timeKey: "statusTimestamp")
    }
    public mutating func enrichOrderDetails(_ details: [OpenOrder]) {
        orders = orders.map { order in
            Self.enrich(order, from: details.first { $0.oid == order.oid })
        }
    }
    public mutating func takeEvents() -> [AccountEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }
    private func matchesUser(_ data: JSONValue) -> Bool {
        data["user"].string?.lowercased() == address
    }
    private mutating func applyAccount(_ state: AccountState, time: Int64) {
        if let old = account {
            let before = Self.index(old.assetPositions.map(\.position), key: { $0.coin })
            let after = Self.index(state.assetPositions.map(\.position), key: { $0.coin })
            for coin in Set(before.keys).union(after.keys).sorted() {
                let oldSize = before[coin]?.szi ?? "0"
                let newSize = after[coin]?.szi ?? "0"
                let oldQuantity = try? ReviewDecimal.parse(oldSize)
                let newQuantity = try? ReviewDecimal.parse(newSize)
                let sameSize =
                    oldQuantity != nil && newQuantity != nil
                    ? oldQuantity == newQuantity : oldSize == newSize
                if !sameSize {
                    emit(
                        .position, id: "\(coin):\(time):\(newSize)", time: time,
                        data: .object([
                            "coin": .string(coin), "before": .string(oldSize),
                            "size": .string(newSize)
                        ]))
                }
                if let previous = before[coin], let current = after[coin],
                   previous.leverage.type != current.leverage.type
                    || previous.leverage.value != current.leverage.value {
                    emit(
                        .leverage, id: "\(coin):leverage:\(time)", time: time,
                        data: .object([
                            "coin": .string(coin), "value": .integer(Int64(current.leverage.value)),
                            "type": .string(current.leverage.type)
                        ]))
                }
            }
            if let before = old.marginSummary.totalRawUsd,
               let after = state.marginSummary.totalRawUsd,
               Decimal(string: before) != Decimal(string: after) {
                emit(
                    .balance, id: "perpUSDC:\(time):\(after)", time: time,
                    data: .object(["coin": .string("Perp USDC"), "total": .string(after)]))
            }
        }
        account = state
    }
    private mutating func applyOrders(_ values: [OpenOrder], time: Int64) {
        let incoming = Self.index(values, key: { $0.oid }).values.filter {
            orderVersions[$0.oid]?.terminal != true
        }
        let previous = Dictionary(uniqueKeysWithValues: orders.map { ($0.oid, $0) })
        let enriched = incoming.map { Self.enrich($0, from: previous[$0.oid]) }
        if ordersInitialized {
            for order in enriched where previous[order.oid] == nil {
                emit(
                    .order, id: "\(order.oid):open", time: order.timestamp,
                    data: Self.orderEvent(order, status: "open")
                )
            }
            for order in orders where !enriched.contains(where: { $0.oid == order.oid }) {
                emit(
                    .order, id: "\(order.oid):removed:\(time)", time: time,
                    data: Self.orderEvent(order, status: "No longer open"))
            }
        }
        orders = enriched.sorted {
            $0.timestamp == $1.timestamp ? $0.oid > $1.oid : $0.timestamp > $1.timestamp
        }
        ordersInitialized = true
    }
    private static func index<T, K: Hashable>(_ values: [T], key: (T) -> K) -> [K: T] {
        values.reduce(into: [:]) { $0[key($1)] = $1 }
    }
    private static func enrich(_ order: OpenOrder, from detail: OpenOrder?) -> OpenOrder {
        guard let detail, detail.coin == order.coin, detail.side == order.side else { return order }
        let triggerDetailsMatch =
            order.timestamp == detail.timestamp
            && (try? ReviewDecimal.parse(order.sz)) == (try? ReviewDecimal.parse(detail.sz))
            && (try? ReviewDecimal.parse(order.limitPx))
            == (try? ReviewDecimal.parse(detail.limitPx))
        // Extra trigger fields from a delayed read must not overwrite changed
        // stream data. Plain limit metadata does not contain a trigger price.
        let detailIsTrigger =
            detail.isTrigger == true || detail.orderType?.contains("Stop") == true
            || detail.orderType?.contains("Take Profit") == true
        let sameKind = order.orderType == nil || order.orderType == detail.orderType
        let usable = sameKind && (!detailIsTrigger || triggerDetailsMatch)
        let isLimit = (order.orderType ?? (usable ? detail.orderType : nil)) == "Limit"
        return OpenOrder(
            coin: order.coin, limitPx: order.limitPx, sz: order.sz, side: order.side,
            oid: order.oid,
            timestamp: order.timestamp,
            orderType: order.orderType ?? (usable ? detail.orderType : nil),
            reduceOnly: order.reduceOnly ?? (sameKind ? detail.reduceOnly : nil),
            tif: order.tif ?? (usable && isLimit ? detail.tif : nil),
            isTrigger: order.isTrigger ?? (usable ? detail.isTrigger : nil),
            triggerPx: order.triggerPx ?? (usable ? detail.triggerPx : nil),
            isPositionTpsl: order.isPositionTpsl ?? (usable ? detail.isPositionTpsl : nil),
            children: order.children ?? (usable ? detail.children : nil))
    }
    private mutating func applyOrderUpdate(_ raw: JSONValue) throws {
        guard let timestamp = raw["statusTimestamp"].int64, let status = raw["status"].string else {
            throw APIError.malformed("Invalid order status")
        }
        let incoming = try raw["order"].decode(OpenOrder.self)
        if let version = orderVersions[incoming.oid],
           timestamp < version.time || (version.terminal && status == "open") {
            return
        }
        let unchanged =
            orderVersions[incoming.oid]?.time == timestamp
            && orderHistory.contains { Self.orderHistoryID($0) == Self.orderHistoryID(raw) }
        let terminal =
            status == "filled" || status == "triggered" || status.lowercased().contains("cancel")
            || status.lowercased().contains("reject")
        orderVersions[incoming.oid] = (timestamp, terminal)
        if status == "open" {
            let order = Self.enrich(incoming, from: orders.first { $0.oid == incoming.oid })
            orders.removeAll { $0.oid == incoming.oid }
            orders.append(order)
            orders.sort { $0.timestamp > $1.timestamp }
        } else if terminal {
            orders.removeAll { $0.oid == incoming.oid }
        }
        orderHistory = Self.mergeRecords(
            orderHistory, [raw], key: Self.orderHistoryID, timeKey: "statusTimestamp")
        if !unchanged {
            emit(
                .order, id: Self.orderHistoryID(raw), time: timestamp,
                data: Self.orderEvent(incoming, status: status))
        }
        if orderVersions.count > 5000 {
            orderVersions = Dictionary(
                uniqueKeysWithValues: orderVersions.sorted { $0.value.time > $1.value.time }.prefix(
                    2500
                ).map {
                    ($0.key, $0.value)
                })
        }
    }
    private mutating func applyBalances(_ value: JSONValue, time: Int64) {
        if balancesInitialized {
            let before = Dictionary(
                balances["balances"].array.compactMap { item in
                    item["token"].int64.map { ($0, item) }
                },
                uniquingKeysWith: { _, last in last })
            let after = Dictionary(
                value["balances"].array.compactMap { item in item["token"].int64.map { ($0, item) }
                },
                uniquingKeysWith: { _, last in last })
            for token in Set(before.keys).union(after.keys).sorted() {
                let old = before[token]?["total"].string ?? "0"
                let new = after[token]?["total"].string ?? "0"
                if Decimal(string: old) != Decimal(string: new) {
                    emit(
                        .balance, id: "\(token):\(time):\(new)", time: time,
                        data: .object([
                            "coin": after[token]?["coin"] ?? before[token]?["coin"]
                                ?? .string("Asset"),
                            "total": .string(new)
                        ]))
                }
            }
        }
        balances = value
        balancesInitialized = true
    }
    private mutating func mergeFills(_ incoming: [Fill], announce: Bool) {
        var existing = Set(fills.map(\.id))
        // REST can arrive before userFills, and reconnect snapshots can contain trades
        // missed while offline. Announce new executions during this watch session
        // regardless of transport, while keeping pre-session history quiet.
        for fill in incoming where existing.insert(fill.id).inserted {
            if announce || fill.time >= monitoringSince {
                emit(
                    .fill, id: fill.id, time: fill.time,
                    data: .object([
                        "coin": .string(fill.coin), "side": .string(fill.side),
                        "size": .string(fill.sz),
                        "price": .string(fill.px)
                    ]))
            }
        }
        var result = Dictionary(uniqueKeysWithValues: fills.map { ($0.id, $0) })
        for fill in incoming { result[fill.id] = fill }
        fills = Array(
            result.values.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time > $1.time }.prefix(
                2000))
    }
    private mutating func mergeFunding(_ incoming: [JSONValue], announce: Bool) {
        var existing = Set(funding.map(Self.fundingID))
        if announce {
            for item in incoming where existing.insert(Self.fundingID(item)).inserted {
                emit(
                    .funding, id: Self.fundingID(item), time: item["time"].int64 ?? 0,
                    data: item["delta"])
            }
        }
        funding = Self.mergeRecords(funding, incoming, key: Self.fundingID, timeKey: "time")
    }
    private mutating func mergeLedger(_ incoming: [JSONValue], announce: Bool) {
        var existing = Set(ledger.map(Self.recordID))
        if announce {
            for item in incoming where existing.insert(Self.recordID(item)).inserted {
                emit(
                    item["delta"]["type"].string == "liquidation" ? .liquidation : .ledger,
                    id: Self.recordID(item),
                    time: item["time"].int64 ?? 0, data: item["delta"])
            }
        }
        ledger = Self.mergeRecords(ledger, incoming, key: Self.recordID, timeKey: "time")
    }
    private static func fundingRecord(_ value: JSONValue) -> JSONValue {
        value["delta"] != .null ? value : .object(["time": value["time"], "delta": value])
    }
    public static func fundingID(_ value: JSONValue) -> String {
        "\(value["time"].int64 ?? 0):\(value["delta"]["coin"].string ?? "")"
    }
    public static func orderHistoryID(_ value: JSONValue) -> String {
        "\(value["order"]["oid"].int64 ?? 0):\(value["statusTimestamp"].int64 ?? 0):\(value["status"].string ?? "")"
    }
    public static func recordID(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Keccak256.hash((try? encoder.encode(value)) ?? Data()).hex
    }
    private static func mergeRecords(
        _ existing: [JSONValue], _ incoming: [JSONValue], key: (JSONValue) -> String,
        timeKey: String
    ) -> [JSONValue] {
        var result: [String: JSONValue] = [:]
        for value in existing + incoming { result[key(value)] = value }
        return Array(
            result.values.sorted {
                $0[timeKey].int64 == $1[timeKey].int64
                    ? key($0) < key($1) : ($0[timeKey].int64 ?? 0) > ($1[timeKey].int64 ?? 0)
            }.prefix(2000))
    }
    private static func orderEvent(_ order: OpenOrder, status: String) -> JSONValue {
        .object([
            "coin": .string(order.coin), "oid": .integer(order.oid), "status": .string(status)
        ])
    }
    private mutating func emit(_ kind: AccountEventKind, id: String, time: Int64, data: JSONValue) {
        if !events.contains(where: { $0.id == id && $0.kind == kind }) {
            events.append(AccountEvent(id: id, kind: kind, time: time, data: data))
        }
    }
}
