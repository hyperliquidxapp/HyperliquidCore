import Foundation

public enum APIError: LocalizedError, Sendable {
    case http(Int, String)
    case malformed(String)
    public var errorDescription: String? {
        switch self {
        case .http(let code, let message): "HTTP \(code): \(message)"
        case .malformed(let message): message
        }
    }
}

public actor HyperliquidAPI {
    public nonisolated let environment: NetworkEnvironment
    private let transport: NIOHTTPTransport
    var cachedHIP3Metadata: HIP3Metadata?
    var hip3MetadataRequest: Task<HIP3Metadata, Error>?
    public init(environment: NetworkEnvironment = .mainnet, transport: NIOHTTPTransport = .init()) {
        self.environment = environment
        self.transport = transport
    }
    public func info(_ body: [String: JSONValue]) async throws -> JSONValue {
        let data = try await transport.post(
            url: environment.apiURL.appendingPathComponent("info"), body: JSONEncoder().encode(body)
        )
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    public func catalog() async throws -> (markets: [Market], contexts: [String: AssetContext]) {
        let snapshot = try await catalogSnapshot()
        return (snapshot.markets, snapshot.contexts)
    }
    public static func parseCatalog(perp: JSONValue, spot: JSONValue) throws -> (
        markets: [Market], contexts: [String: AssetContext]
    ) {
        guard perp.array.count == 2, spot.array.count == 2 else {
            throw APIError.malformed("Invalid market metadata")
        }
        var markets: [Market] = []
        var contexts: [String: AssetContext] = [:]
        let universe = perp.array[0]["universe"].array
        for (index, raw) in universe.enumerated() {
            guard raw["isDelisted"].bool != true, let symbol = raw["name"].string,
                  let decimals = raw["szDecimals"].double, let leverage = raw["maxLeverage"].double
            else { continue }
            guard raw["marginMode"] == .null || raw["marginMode"].string != nil,
                  raw["onlyIsolated"] == .null || raw["onlyIsolated"].bool != nil
            else { throw APIError.malformed("Invalid market margin mode") }
            let market = Market(
                coin: symbol, symbol: symbol, assetID: index, sizeDecimals: Int(decimals),
                maxLeverage: Int(leverage),
                kind: .perp, onlyIsolated: raw["onlyIsolated"].bool ?? false,
                marginMode: raw["marginMode"].string)
            markets.append(market)
            if index < perp.array[1].array.count {
                contexts[symbol] = try perp.array[1].array[index].decode(AssetContext.self)
            }
        }
        let tokens = Dictionary(
            uniqueKeysWithValues: spot.array[0]["tokens"].array.compactMap {
                token -> (Int, JSONValue)? in
                guard let index = token["index"].double else { return nil }
                return (Int(index), token)
            })
        let spotUniverse = spot.array[0]["universe"].array
        let quoteAssets = Set(spotUniverse.compactMap { $0["tokens"].array.last?.int64 })
        let spotContexts = spot.array[1].array
        var spotContextsByCoin: [String: JSONValue] = [:]
        for context in spotContexts {
            if let coin = context["coin"].string { spotContextsByCoin[coin] = context }
        }
        for (offset, raw) in spotUniverse.enumerated() {
            let pair = raw["tokens"].array
            guard pair.count == 2, let baseIndex = pair[0].double, let quoteIndex = pair[1].double,
                  let base = tokens[Int(baseIndex)], Int(quoteIndex) == 0,
                  tokens[0]?["name"].string == "USDC",
                  let index = raw["index"].double, let symbol = base["name"].string,
                  let decimals = base["szDecimals"].double
            else { continue }
            let coin = Int(index) == 0 ? (raw["name"].string ?? "PURR/USDC") : "@\(Int(index))"
            markets.append(
                Market(
                    coin: coin, symbol: symbol, assetID: 10_000 + Int(index),
                    sizeDecimals: Int(decimals),
                    maxLeverage: 1, kind: .spot, baseTokenIndex: Int(baseIndex),
                    quoteTokenIndex: Int(quoteIndex),
                    isStablePair: quoteAssets.contains(Int64(baseIndex))))
            if let rawContext = spotContextsByCoin[coin] {
                contexts[coin] = try rawContext.decode(AssetContext.self)
            } else if spotUniverse.count == spotContexts.count, offset < spotContexts.count,
                      spotContexts[offset]["coin"].string == nil {
                // Older documented responses omitted coin and were aligned to the universe.
                contexts[coin] = try spotContexts[offset].decode(AssetContext.self)
            }
        }
        return (markets, contexts)
    }
    public func candles(
        coin: String, timeframe: Timeframe, startTime: Int64? = nil, endTime: Int64? = nil
    ) async throws
    -> [Candle] {
        let end = endTime ?? Int64(Date().timeIntervalSince1970 * 1000)
        let start = startTime ?? end - timeframe.milliseconds * 500
        guard start >= 0, end >= start else {
            throw APIError.malformed("Invalid candle time range")
        }
        let response = try await info([
            "type": .string("candleSnapshot"),
            "req": .object([
                "coin": .string(coin), "interval": .string(timeframe.rawValue),
                "startTime": .integer(start), "endTime": .integer(end)
            ])
        ])
        let candles = try response.decode([Candle].self)
        guard candles.allSatisfy({ $0.s == coin && $0.i == timeframe.rawValue }) else {
            throw APIError.malformed("Candle snapshot does not match the requested market")
        }
        return candles.sorted { $0.t < $1.t }
    }
    public func book(coin: String) async throws -> OrderBook {
        try await info(["type": .string("l2Book"), "coin": .string(coin)]).decode(OrderBook.self)
    }
    public func account(address: String) async throws -> AccountState {
        try await info(["type": .string("clearinghouseState"), "user": .string(address)]).decode(
            AccountState.self)
    }
    public func userFees(address: String) async throws -> UserFeeRates {
        try UserFeeRates(
            response: await info(["type": .string("userFees"), "user": .string(address)]))
    }
    public func marginTable(market: Market) async throws -> MarginTable {
        try MarginTable.parse(meta: await info(["type": .string("meta")]), market: market)
    }
    public func orderRisk(
        intent: OrderIntent, address: String, asset: ActiveAssetData, fees: OrderFeeEstimate
    )
    async throws -> OrderRiskEstimate {
        async let account = self.account(address: address)
        async let table = marginTable(market: intent.market)
        async let mode = info(["type": .string("userAbstraction"), "user": .string(address)])
        let (snapshot, tiers, abstraction) = try await (account, table, mode)
        guard let mode = abstraction.string else {
            throw APIError.malformed("Account mode is unavailable")
        }
        return try OrderRiskEstimate.preview(
            intent: intent, address: address, account: snapshot, asset: asset, table: tiers,
            abstraction: mode,
            fees: fees)
    }
    public func activeAssetData(address: String, market: Market) async throws -> ActiveAssetData {
        guard market.kind == .perp else {
            throw APIError.malformed("Asset trading limits are available for perpetuals")
        }
        let value = try await info([
            "type": .string("activeAssetData"), "user": .string(address),
            "coin": .string(market.coin)
        ]).decode(ActiveAssetData.self)
        try value.validate(address: address, market: market)
        return value
    }
    public func spotBalances(address: String) async throws -> JSONValue {
        try await info(["type": .string("spotClearinghouseState"), "user": .string(address)])
    }
    public func orders(address: String) async throws -> [OpenOrder] {
        try await info(["type": .string("frontendOpenOrders"), "user": .string(address)]).decode(
            [OpenOrder].self)
    }
    public func fills(address: String) async throws -> [Fill] {
        try await info(["type": .string("userFills"), "user": .string(address)]).decode([Fill].self)
    }
    public func exchange(body: Data) async throws -> JSONValue {
        let data = try await transport.post(
            url: environment.apiURL.appendingPathComponent("exchange"), body: body)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public struct SocketMessage: Decodable, Sendable {
    public let channel: String
    public let data: JSONValue?
}

/// One cancellable connection owns its subscriptions and heartbeat. Reconnect is the service's responsibility.
public actor HyperliquidSocket {
    private var socket: NIOWebSocketConnection?
    private var heartbeat: Task<Void, Never>?
    private var connecting: Task<NIOWebSocketConnection, Error>?
    private var generation = UUID()
    private var receiving = false
    public init() {}
    public func connect(environment: NetworkEnvironment, subscriptions: [[String: JSONValue]])
    async throws {
        disconnect()
        let token = generation
        let task = Task { try await NIOWebSocketConnection.open(url: environment.socketURL) }
        connecting = task
        defer { if token == generation { connecting = nil } }
        let connection = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard token == generation, !Task.isCancelled else {
            connection.close()
            throw CancellationError()
        }
        socket = connection
        do {
            for subscription in subscriptions {
                let data = try JSONEncoder().encode(
                    JSONValue.object([
                        "method": .string("subscribe"), "subscription": .object(subscription)
                    ]))
                // Preserve UTF-8 replacement decoding; encoded JSON is UTF-8 and error text may be invalid.
                // swiftlint:disable:next optional_data_string_conversion
                try await connection.send(text: String(decoding: data, as: UTF8.self))
                guard token == generation else { throw CancellationError() }
            }
        } catch {
            connection.close()
            if token == generation { socket = nil }
            throw error
        }
        heartbeat = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(25))
                    try Task.checkCancellation()
                    try await connection.send(text: "{\"method\":\"ping\"}")
                } catch {
                    connection.close()
                    break
                }
            }
        }
    }
    public func receive() async throws -> SocketMessage {
        guard let socket, !receiving else {
            throw APIError.malformed("WebSocket is not connected or already has a receiver")
        }
        let token = generation
        receiving = true
        defer { if token == generation { receiving = false } }
        let data = try await socket.receive()
        guard token == generation else { throw CancellationError() }
        return try JSONDecoder().decode(SocketMessage.self, from: data)
    }
    public func disconnect() {
        connecting?.cancel()
        connecting = nil
        heartbeat?.cancel()
        heartbeat = nil
        generation = UUID()
        receiving = false
        socket?.close()
        socket = nil
    }
}
