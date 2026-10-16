import Foundation

/// Documented Arbitrum USDC bridge route. It is separate from CCTP routes.
public struct ArbitrumBridge: Sendable, Equatable {
    public let environment: NetworkEnvironment
    public init(environment: NetworkEnvironment) { self.environment = environment }
    public var chainID: UInt64 { environment == .mainnet ? 42161 : 421614 }
    public var name: String { environment == .mainnet ? "Arbitrum One" : "Arbitrum Sepolia" }
    public var token: String {
        environment == .mainnet
            ? "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
            : "0x1baabb04529d43a73232b713c0fe471f7c7334d5"
    }
    public var bridge: String {
        environment == .mainnet
            ? "0x2df1c51e09aecf9cacb7bc98cb1742757f163df7"
            : "0x08cfc1b6b2dcf36a1480b99353a354aa8ac56f89"
    }
    public var rpcURL: URL {
        URL(
            string: environment == .mainnet
                ? "https://arb1.arbitrum.io/rpc" : "https://sepolia-rollup.arbitrum.io/rpc")!
    }
    public var explorerURL: URL {
        URL(
            string: environment == .mainnet ? "https://arbiscan.io" : "https://sepolia.arbiscan.io")!
    }
    /// Official Arbitrum metadata for a user-approved EIP-3085 network addition.
    public var walletConfiguration: JSONValue {
        .object([
            "chainId": .string("0x" + String(chainID, radix: 16)), "chainName": .string(name),
            "nativeCurrency": .object([
                "name": .string("Ether"), "symbol": .string("ETH"), "decimals": .integer(18)
            ]),
            "rpcUrls": .array([.string(rpcURL.absoluteString)]),
            "blockExplorerUrls": .array([.string(explorerURL.absoluteString)])
        ])
    }
}

public struct WalletTransaction: Sendable, Equatable {
    public let from: String
    public let to: String
    public let data: String
    public let chainID: UInt64
    public init(from: String, to: String, data: String, chainID: UInt64) throws {
        guard Address.isValid(from), Address.isValid(to), chainID > 0, chainID <= UInt64(Int64.max),
              data.hasPrefix("0x"), data.count <= 65_538, let bytes = Data(hex: data),
              bytes.count >= 4
        else {
            throw WalletError.invalid("Invalid reviewed wallet transaction.")
        }
        self.from = from.lowercased()
        self.to = to.lowercased()
        self.data = data.lowercased()
        self.chainID = chainID
    }
    public var json: JSONValue {
        .object([
            "from": .string(from), "to": .string(to), "data": .string(data),
            "value": .string("0x0"), "chainId": .string("0x" + String(chainID, radix: 16))
        ])
    }
    public static func requireHash(_ value: String) throws -> String {
        guard
            value.range(of: "^0x[0-9a-fA-F]{64}$", options: .regularExpression) == value
                .startIndex..<value.endIndex
        else {
            throw WalletError.invalid("Wallet returned no verifiable transaction hash.")
        }
        return value.lowercased()
    }
}

public struct BridgeDepositIntent: Sendable, Identifiable {
    public let id = UUID()
    public let owner: String
    public let amount: String
    public let route: ArbitrumBridge
    public let createdAt: Date
    public let units: UInt64
    public init(owner: String, amount: String, environment: NetworkEnvironment, now: Date = Date())
    throws {
        guard Address.isValid(owner) else {
            throw WalletError.invalid("Connect the depositing wallet first.")
        }
        let normalized = try FundingIntent.normalize(amount, decimals: 6)
        let value = try ReviewDecimal.parse(normalized)
        let scaled = value * 1_000_000
        guard value >= 5, let units = UInt64(NSDecimalNumber(decimal: scaled).stringValue) else {
            throw WalletError.invalid(
                "This bridge requires a deposit of at least 5 USDC within the supported exact amount range."
            )
        }
        self.owner = owner.lowercased()
        self.amount = normalized
        self.route = ArbitrumBridge(environment: environment)
        self.createdAt = now
        self.units = units
    }
    public var transaction: WalletTransaction {
        get throws {
            let recipient = String(repeating: "0", count: 24) + route.bridge.dropFirst(2)
            let raw = String(units, radix: 16)
            let amount = String(repeating: "0", count: 64 - raw.count) + raw
            return try WalletTransaction(
                from: owner, to: route.token, data: "0xa9059cbb" + recipient + amount,
                chainID: route.chainID)
        }
    }
    public func validate(
        snapshot: BridgeDepositSnapshot, connection: WalletConnection, now: Date = Date(),
        maximumAge: TimeInterval = 30
    ) throws {
        let age = now.timeIntervalSince(createdAt)
        guard age >= 0, age < maximumAge, connection.address == owner,
              connection.chainID == route.chainID
        else {
            throw WalletError.invalid(
                "Deposit wallet, network or preview changed. Create a fresh preview.")
        }
        try snapshot.validate(intent: self)
    }
}

public struct BridgeDepositSnapshot: Sendable {
    public let owner: String
    public let route: ArbitrumBridge
    public let transaction: WalletTransaction
    public let availableUSDC: Decimal
    public let nativeWei: Decimal
    public let gasLimit: Decimal
    public let gasPrice: Decimal
    public let startedAt: Double
    public var estimatedGasWei: Decimal { gasLimit * gasPrice }
    public var estimatedGasETH: Decimal { estimatedGasWei / 1_000_000_000_000_000_000 }
    public func validate(intent: BridgeDepositIntent, now: Double = ReceiptClock.now) throws {
        guard now.isFinite, startedAt.isFinite, now >= startedAt, now - startedAt < 15,
              owner == intent.owner, route == intent.route, transaction == (try intent.transaction),
              !availableUSDC.isNaN, availableUSDC >= (try ReviewDecimal.parse(intent.amount)),
              !nativeWei.isNaN, !estimatedGasWei.isNaN, gasLimit > 0, gasPrice > 0,
              nativeWei >= estimatedGasWei
        else {
            throw WalletError.invalid(
                "Refresh the deposit balance and gas estimate. Check USDC and ETH on the selected Arbitrum network."
            )
        }
    }
}

/// Exact decimal decoding of EVM quantities; an overflow refuses the read.
public enum EthereumQuantity {
    public static func parse(_ raw: String?) throws -> Decimal {
        guard let raw, raw.range(of: "^0x[0-9a-fA-F]{1,64}$", options: .regularExpression) != nil
        else {
            throw APIError.malformed("Invalid chain quantity")
        }
        var total = Decimal.zero
        for digit in raw.dropFirst(2) {
            guard let value = digit.hexDigitValue else {
                throw APIError.malformed("Invalid chain quantity")
            }
            var multiplier = Decimal(16)
            var addend = Decimal(value)
            var product = Decimal.zero
            var sum = Decimal.zero
            guard NSDecimalMultiply(&product, &total, &multiplier, .plain) == .noError,
                  NSDecimalAdd(&sum, &product, &addend, .plain) == .noError
            else {
                throw APIError.malformed("Chain quantity exceeds exact decimal precision")
            }
            total = sum
        }
        return total
    }
}

public struct BridgeRPC: Sendable {
    public let route: ArbitrumBridge
    private let transport: NIOHTTPTransport
    public init(environment: NetworkEnvironment, transport: NIOHTTPTransport = .init()) {
        route = ArbitrumBridge(environment: environment)
        self.transport = transport
    }
    private func read(_ method: String, params: [JSONValue]) async throws -> JSONValue {
        let body: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .integer(1), "method": .string(method),
            "params": .array(params)
        ])
        let result = try JSONDecoder().decode(
            JSONValue.self,
            from: await transport.post(url: route.rpcURL, body: JSONEncoder().encode(body)))
        guard result["jsonrpc"].string == "2.0", result["id"].int64 == 1, result["error"] == .null,
              case .object(let fields) = result, fields["result"] != nil
        else {
            throw APIError.malformed(
                result["error"]["message"].string ?? "Invalid chain RPC response")
        }
        return result["result"]
    }
    /// Read the selected deposit token without an amount, fee quote or gas estimate.
    public func usdcBalance(owner: String, token: String) async throws -> Decimal {
        let token = token.lowercased()
        guard Address.isValid(owner),
              [route.token, CCTPArbitrumRoute(environment: route.environment).token].contains(token)
        else {
            throw WalletError.invalid("Invalid depositing wallet or USDC token.")
        }
        let chain = try EthereumQuantity.parse(await read("eth_chainId", params: []).string)
        guard chain == Decimal(route.chainID) else {
            throw APIError.malformed("RPC chain does not match the deposit network")
        }
        let call: JSONValue = .object([
            "to": .string(token),
            "data": .string(
                "0x70a08231" + String(repeating: "0", count: 24) + owner.lowercased().dropFirst(2))
        ])
        let value = try await read("eth_call", params: [call, .string("latest")])
        return try EthereumQuantity.parse(value.string) / 1_000_000
    }
    public func snapshot(intent: BridgeDepositIntent) async throws -> BridgeDepositSnapshot {
        guard intent.route == route else { throw WalletError.invalid("Deposit network mismatch.") }
        let started = ReceiptClock.now
        let chain = try EthereumQuantity.parse(await read("eth_chainId", params: []).string)
        guard chain == Decimal(route.chainID) else {
            throw APIError.malformed("RPC chain does not match the deposit network")
        }
        let transaction = try intent.transaction
        let balanceCall: JSONValue = .object([
            "to": .string(route.token),
            "data": .string(
                "0x70a08231" + String(repeating: "0", count: 24) + intent.owner.dropFirst(2))
        ])
        async let token = read("eth_call", params: [balanceCall, .string("latest")])
        async let native = read(
            "eth_getBalance", params: [.string(intent.owner), .string("latest")])
        async let gas = read("eth_estimateGas", params: [transaction.json])
        async let price = read("eth_gasPrice", params: [])
        let values = try await (token, native, gas, price)
        let snapshot = try BridgeDepositSnapshot(
            owner: intent.owner, route: route, transaction: transaction,
            availableUSDC: EthereumQuantity.parse(values.0.string) / 1_000_000,
            nativeWei: EthereumQuantity.parse(values.1.string),
            gasLimit: EthereumQuantity.parse(values.2.string),
            gasPrice: EthereumQuantity.parse(values.3.string), startedAt: started)
        try snapshot.validate(intent: intent)
        return snapshot
    }
    public func receipt(hash: String, intent: BridgeDepositIntent) async throws -> Bool? {
        guard intent.route == route else {
            throw WalletError.invalid("Deposit receipt network mismatch.")
        }
        let hash = try WalletTransaction.requireHash(hash)
        let value = try await read("eth_getTransactionReceipt", params: [.string(hash)])
        return try BridgeDepositReceipt.parse(value, hash: hash, intent: intent)
    }
}

public enum BridgeDepositReceipt {
    /// A successful token transaction must also contain the intended USDC transfer.
    public static func parse(_ value: JSONValue, hash: String, intent: BridgeDepositIntent) throws
    -> Bool? {
        let hash = try WalletTransaction.requireHash(hash)
        if value == .null { return nil }
        guard value["transactionHash"].string?.lowercased() == hash,
              value["from"].string?.lowercased() == intent.owner,
              value["to"].string?.lowercased() == intent.route.token,
              try EthereumQuantity.parse(value["blockNumber"].string) > 0
        else {
            throw APIError.malformed("Chain receipt does not match this deposit")
        }
        let status = try EthereumQuantity.parse(value["status"].string)
        guard status == 0 || status == 1 else {
            throw APIError.malformed("Unknown chain receipt status")
        }
        if status == 0 { return false }
        guard case .array(let logs) = value["logs"] else {
            throw APIError.malformed("Missing USDC transfer log")
        }
        let event = Keccak256.hash(Data("Transfer(address,address,uint256)".utf8)).hex
        let from = "0x" + String(repeating: "0", count: 24) + intent.owner.dropFirst(2)
        let to = "0x" + String(repeating: "0", count: 24) + intent.route.bridge.dropFirst(2)
        let matches = logs.filter { log in
            let topics = log["topics"].array
            return log["address"].string?.lowercased() == intent.route.token && topics.count == 3
                && topics[0].string?.lowercased() == event && topics[1].string?.lowercased() == from
                && topics[2].string?.lowercased() == to
                && (try? EthereumQuantity.parse(log["data"].string)) == Decimal(intent.units)
        }
        guard matches.count == 1 else {
            throw APIError.malformed("USDC receipt does not contain the exact reviewed deposit")
        }
        return true
    }
}
