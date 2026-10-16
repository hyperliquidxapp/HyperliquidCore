import Foundation

/// The Agent has a fixed read-only tool surface, with no exchange or wallet API.
public protocol AgentReading: Sendable {
    func catalog() async throws -> (markets: [Market], contexts: [String: AssetContext])
    func account(address: String) async throws -> AccountState
    func orders(address: String) async throws -> [OpenOrder]
    func fills(address: String) async throws -> [Fill]
    func spotBalances(address: String) async throws -> JSONValue
    func accountMode(address: String) async throws -> JSONValue
    func fundingHistory(coin: String, start: Int64, end: Int64) async throws -> JSONValue
    func minuteCandles(coin: String, start: Int64, end: Int64) async throws -> [Candle]
}

public struct AgentReadClient: AgentReading {
    private let api: HyperliquidAPI
    public init(api: HyperliquidAPI) { self.api = api }
    public func catalog() async throws -> (markets: [Market], contexts: [String: AssetContext]) {
        try await api.catalog()
    }
    public func account(address: String) async throws -> AccountState {
        try await api.account(address: address)
    }
    public func orders(address: String) async throws -> [OpenOrder] {
        try await api.orders(address: address)
    }
    public func fills(address: String) async throws -> [Fill] {
        try await api.fills(address: address)
    }
    public func spotBalances(address: String) async throws -> JSONValue {
        try await api.spotBalances(address: address)
    }
    public func accountMode(address: String) async throws -> JSONValue {
        try await api.info(["type": .string("userAbstraction"), "user": .string(address)])
    }
    public func fundingHistory(coin: String, start: Int64, end: Int64) async throws -> JSONValue {
        try await api.info([
            "type": .string("fundingHistory"), "coin": .string(coin), "startTime": .integer(start),
            "endTime": .integer(end)
        ])
    }
    public func minuteCandles(coin: String, start: Int64, end: Int64) async throws -> [Candle] {
        try await api.candles(coin: coin, timeframe: .m1, startTime: start, endTime: end)
    }
}
