import Foundation

public protocol CCTPDepositReadClient: Sendable {
    func authorization(owner: String) async throws -> CCTPAuthorization
    func quote() async throws -> CCTPFeeQuote
    func snapshot(intent: CCTPDepositIntent, transaction: WalletTransaction?) async throws
    -> CCTPDepositSnapshot
    func progress(hash: String, owner: String, transactionData: String) async throws -> String
    func approvalReceipt(hash: String, owner: String, transactionData: String) async throws -> Bool?
}

public struct CCTPDepositClient: CCTPDepositReadClient {
    public let route: CCTPRoute
    private let transport = NIOHTTPTransport()
    public init(environment: NetworkEnvironment, sourceNetwork: USDCSourceNetwork = .arbitrum) {
        route = CCTPRoute(environment: environment, sourceNetwork: sourceNetwork)
    }
    public func quote() async throws -> CCTPFeeQuote {
        let started = ReceiptClock.now
        let url = route.circleURL.appendingPathComponent("v2/burn/USDC/fees/\(route.sourceDomain)/\(CCTPHyperCoreDestination.domain)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "forward", value: "true"), .init(name: "hyperCoreDeposit", value: "true")
        ]
        let value = try JSONDecoder().decode(
            JSONValue.self, from: await transport.get(url: components.url!))
        let result = try CCTPFeeQuote.parse(
            value, environment: route.environment, startedAt: started, sourceNetwork: route.sourceNetwork)
        try result.validate(environment: route.environment, sourceNetwork: route.sourceNetwork)
        return result
    }
    func rpc(_ method: String, params: [JSONValue]) async throws -> JSONValue {
        let body: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .integer(1),
            "method": .string(method), "params": .array(params)
        ])
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: await transport.post(url: route.rpcURL, body: JSONEncoder().encode(body)))
        guard value["jsonrpc"].string == "2.0", value["id"].int64 == 1, value["error"] == .null,
              case .object(let fields) = value, fields["result"] != nil
        else {
            throw APIError.malformed(
                value["error"]["message"].string ?? "Invalid CCTP chain RPC response")
        }
        return value["result"]
    }
    public func snapshot(intent: CCTPDepositIntent, transaction: WalletTransaction?) async throws
    -> CCTPDepositSnapshot {
        guard intent.route == route else {
            throw WalletError.invalid("CCTP deposit network changed")
        }
        let started = ReceiptClock.now
        let chain = try EthereumQuantity.parse(await rpc("eth_chainId", params: []).string)
        guard chain == Decimal(route.chainID) else {
            throw APIError.malformed("CCTP RPC chain mismatch")
        }
        guard try await authorization(owner: intent.owner) == intent.authorization else {
            throw WalletError.invalid("Wallet account type changed. Prepare a fresh deposit preview.")
        }
        let allowance = intent.authorization == .allowance ? try await allowance(owner: intent.owner) : nil
        if let transaction, intent.authorization == .allowance {
            let approval = try intent.approvalTransaction
            let burn = try intent.burnTransaction
            guard transaction == approval || transaction == burn
            else { throw WalletError.invalid("The CCTP transaction differs from the reviewed deposit") }
            if transaction == burn,
               (allowance ?? -1) < Decimal(intent.units) / 1_000_000 {
                throw WalletError.invalid("Confirm the USDC approval on the source network before depositing")
            }
        }
        async let quote = self.quote()
        async let balance = rpc(
            "eth_call",
            params: [
                .object([
                    "to": .string(route.token),
                    "data": .string(
                        "0x70a08231" + String(repeating: "0", count: 24) + intent.owner.dropFirst(2)
                    )
                ]), .string("latest")
            ])
        async let native = rpc(
            "eth_getBalance", params: [.string(intent.owner), .string("latest")])
        async let price = rpc("eth_gasPrice", params: [])
        async let tokenMetadata = rpc(
            "eth_call",
            params: [
                .object(["to": .string(route.token), "data": .string(intent.authorization == .signature ? "0x3644e515" : "0x313ce567")]),
                .string("latest")
            ])
        async let code = rpc(
            "eth_getCode", params: [
                .string(intent.authorization == .signature ? route.depositContract : route.tokenMessenger),
                .string("latest")
            ])
        let (fee, funds, eth, gasPrice, domain, contract) = try await (
            quote, balance, native, price, tokenMetadata, code
        )
        let validToken = intent.authorization == .signature
            ? domain.string?.lowercased() == (try route.domainSeparator).hex
            : (try EthereumQuantity.parse(domain.string)) == 6
        guard validToken,
              let raw = contract.string, let bytes = Data(hex: raw), !bytes.isEmpty,
              bytes.contains(where: { $0 != 0 })
        else {
            throw APIError.malformed(
                "CCTP token domain or deposit contract does not match the documented route")
        }
        let gas: Decimal?
        if let transaction {
            gas = try EthereumQuantity.parse(
                await rpc("eth_estimateGas", params: [transaction.json]).string)
        } else {
            gas = nil
        }
        let result = try CCTPDepositSnapshot(
            owner: intent.owner, environment: route.environment,
            availableUSDC: EthereumQuantity.parse(funds.string) / 1_000_000,
            nativeWei: EthereumQuantity.parse(eth.string),
            gasPrice: EthereumQuantity.parse(gasPrice.string),
            gasLimit: gas, transaction: transaction, quote: fee, startedAt: started, allowance: allowance)
        try result.validate(intent: intent, transaction: transaction)
        return result
    }
    public func progress(hash: String, owner: String, transactionData: String) async throws
    -> String {
        let hash = try WalletTransaction.requireHash(hash)
        guard let data = Data(hex: transactionData), data.count >= 4 else {
            throw APIError.malformed("Missing original CCTP transaction")
        }
        let destination = data.prefix(4) == CCTPDepositIntent.burnSelector
            ? route.tokenMessenger : route.depositContract
        let receipt = try await verifiedReceipt(
            hash: hash, owner: owner, transactionData: transactionData, to: destination)
        guard let receipt else {
            return "CCTP deposit is pending on \(route.network.name). Check again before depositing more."
        }
        if !receipt {
            return
                "CCTP transaction failed on \(route.network.name). USDC was not deposited; gas may have been charged."
        }
        var url = URLComponents(
            url: route.circleURL.appendingPathComponent("v2/messages/\(route.sourceDomain)"),
            resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "transactionHash", value: hash)]
        let messages = try JSONDecoder().decode(
            JSONValue.self, from: await transport.get(url: url.url!))
        guard case .array(let rows) = messages["messages"] else {
            throw APIError.malformed(
                "CCTP message status is unavailable; the \(route.network.name) transaction is mined")
        }
        if !rows.isEmpty && rows.allSatisfy({ $0["status"].string == "complete" }) {
            return
                "\(route.network.name) burn is mined and Circle reports the CCTP message ready. Forwarding and Hyperliquid credit must still be checked in the original account."
        }
        return
            "\(route.network.name) burn is mined. CCTP attestation, forwarding and Hyperliquid credit are pending."
    }
}

