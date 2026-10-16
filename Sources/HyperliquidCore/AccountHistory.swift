import Foundation

public enum AccountHistoryKind: String, CaseIterable, Hashable, Sendable {
    case fills, funding, ledger, orders
    public var requestType: String {
        switch self {
        case .fills: "userFillsByTime"
        case .funding: "userFunding"
        case .ledger: "userNonFundingLedgerUpdates"
        case .orders: "historicalOrders"
        }
    }
    public var exchangeScope: String? {
        switch self {
        case .fills: "The exchange provides only its latest 10,000 fills."
        case .orders: "The exchange provides only its latest 2,000 historical orders."
        case .funding, .ledger: nil
        }
    }
}

public enum AccountHistoryPeriod: String, CaseIterable, Sendable {
    case week = "Past 7 days"
    case month = "Past 30 days"
    case quarter = "Past 90 days"
    case available = "All available"
    public func window(endingAt end: Int64) throws -> AccountHistoryWindow {
        guard end >= 0 else { throw APIError.malformed("Invalid account history end time") }
        let days: Int64? =
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 90
            case .available: nil
            }
        return try AccountHistoryWindow(
            start: days.map { max(0, end - $0 * 86_400_000) } ?? 0, end: end)
    }
}
public struct AccountHistoryWindow: Sendable, Equatable {
    public let start: Int64
    public let end: Int64
    public init(start: Int64, end: Int64) throws {
        guard start >= 0, end >= start else {
            throw APIError.malformed("Invalid account history time range")
        }
        self.start = start
        self.end = end
    }
}
public struct AccountHistoryRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let time: Int64
    public let data: JSONValue
    public let fill: Fill?
}
public enum AccountHistoryCoverage: Sendable, Equatable {
    case more, exhausted, timestampBoundary, capacity
}

/// An archive query has its own frozen end time and identity. It never merges
/// old records into the live event stream or trades against a historical row.
public struct AccountHistoryCursor: Sendable {
    public let kind: AccountHistoryKind
    public let window: AccountHistoryWindow
    public let recordLimit: Int
    public private(set) var nextStart: Int64
    public private(set) var coverage: AccountHistoryCoverage = .more
    public private(set) var records: [AccountHistoryRecord] = []
    private var indexed: [String: AccountHistoryRecord] = [:]
    public var canLoadMore: Bool { coverage == .more }

    public init(kind: AccountHistoryKind, window: AccountHistoryWindow, recordLimit: Int = 100_000) {
        self.kind = kind
        self.window = window
        nextStart = window.start
        self.recordLimit = min(max(recordLimit, 1), 100_000)
    }
    public func request(address: String) throws -> [String: JSONValue] {
        guard Address.isValid(address), canLoadMore else {
            throw APIError.malformed("Account history cannot continue")
        }
        var body: [String: JSONValue] = [
            "type": .string(kind.requestType), "user": .string(address.lowercased())
        ]
        if kind != .orders {
            body["startTime"] = .integer(nextStart)
            body["endTime"] = .integer(window.end)
        }
        if kind == .fills { body["aggregateByTime"] = .bool(false) }
        return body
    }

    /// Inclusive boundary re-reads deduplicate by record identity. Never add a
    /// millisecond to escape a full timestamp: that would silently lose rows.
    public mutating func append(_ response: JSONValue) throws {
        try Task.checkCancellation()
        guard canLoadMore, case .array(let raw) = response else {
            throw APIError.malformed("Expected an account history array")
        }
        var parsed: [AccountHistoryRecord] = []
        for value in raw {
            try Task.checkCancellation()
            let record = try Self.record(value, kind: kind)
            if kind == .orders {
                if (window.start...window.end).contains(record.time) { parsed.append(record) }
            } else {
                guard (nextStart...window.end).contains(record.time) else {
                    throw APIError.malformed("History response is outside the requested time range")
                }
                parsed.append(record)
            }
        }
        // The paginated endpoints advance chronologically; taking a maximum
        // from an out-of-order page could skip unseen earlier records.
        if kind != .orders {
            guard zip(parsed, parsed.dropFirst()).allSatisfy({ $0.time <= $1.time }) else {
                throw APIError.malformed("History page is not in chronological order")
            }
        }
        var next = indexed
        var capacityReached = false
        for record in parsed {
            if next[record.id] == nil, next.count == recordLimit {
                capacityReached = true
                break
            }
            next[record.id] = record
        }
        try Task.checkCancellation()
        indexed = next
        records = next.values.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time > $1.time }
        if capacityReached {
            coverage = .capacity
        } else if kind == .orders || raw.isEmpty {
            coverage = .exhausted
        } else if let last = parsed.last {
            if last.time == nextStart {
                // Conservatively account for the general 500-row/block cap.
                coverage = raw.count < 500 ? .exhausted : .timestampBoundary
            } else {
                nextStart = last.time
            }
        }
    }

    private static func record(_ raw: JSONValue, kind: AccountHistoryKind) throws
    -> AccountHistoryRecord {
        let data =
            kind == .funding && raw["delta"] == .null
            ? JSONValue.object(["time": raw["time"], "delta": raw]) : raw
        let key = kind == .orders ? "statusTimestamp" : "time"
        guard case .object = data, let time = data[key].int64, time >= 0 else {
            throw APIError.malformed("History record is missing its timestamp")
        }
        let id: String
        var decodedFill: Fill?
        switch kind {
        case .fills:
            let fill = try data.decode(Fill.self)
            guard !fill.coin.isEmpty, fill.tid >= 0, fill.side == "B" || fill.side == "A" else {
                throw APIError.malformed("Invalid fill history identity")
            }
            id = fill.id
            decodedFill = fill
        case .funding:
            guard let coin = data["delta"]["coin"].string, !coin.isEmpty else {
                throw APIError.malformed("Funding history is missing its market")
            }
            id = AccountStream.fundingID(data)
        case .ledger:
            guard let type = data["delta"]["type"].string, !type.isEmpty else {
                throw APIError.malformed("Ledger history is missing its event type")
            }
            id = AccountStream.recordID(data)
        case .orders:
            guard let oid = data["order"]["oid"].int64, oid >= 0,
                  let status = data["status"].string, !status.isEmpty
            else {
                throw APIError.malformed("Order history is missing its identity or status")
            }
            id = AccountStream.orderHistoryID(data)
        }
        return AccountHistoryRecord(id: id, time: time, data: data, fill: decodedFill)
    }
}
