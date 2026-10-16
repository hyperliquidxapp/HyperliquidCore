import Foundation
import Network
import Security

public enum WalletEvent: Sendable {
    case connected(WalletConnection, String)
    case disconnected
    case failed(String)
}
public enum WalletError: LocalizedError, Sendable {
    case invalid(String)
    case rejected(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let value): value
        case .rejected(let value): value
        }
    }
}

public struct BridgeHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public static func parse(_ buffer: Data) throws -> BridgeHTTPRequest? {
        guard buffer.count <= 131_072 else { throw WalletError.invalid("Request too large") }
        guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 16_384 { throw WalletError.invalid("Headers too large") }
            return nil
        }
        guard boundary.lowerBound <= 16_384,
              let head = String(data: buffer[..<boundary.lowerBound], encoding: .utf8)
        else { throw WalletError.invalid("Invalid headers") }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" else {
            throw WalletError.invalid("Invalid request line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw WalletError.invalid("Invalid header")
            }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw WalletError.invalid("Duplicate header") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else {
            throw WalletError.invalid("Chunked requests are not accepted")
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0, parsed <= 114_688 else {
                throw WalletError.invalid("Invalid content length")
            }
            length = parsed
        } else {
            length = 0
        }
        let end = boundary.upperBound + length
        guard buffer.count >= end else { return nil }
        guard buffer.count == end else { throw WalletError.invalid("Pipelining is not accepted") }
        return BridgeHTTPRequest(
            method: String(first[0]), path: String(first[1]), headers: headers,
            body: Data(buffer[boundary.upperBound..<end]))
    }
}

/// Ephemeral loopback bridge for EIP-1193 browser wallets. Keys stay in the wallet extension.
/// The bearer capability lives only in a URL fragment and browser memory; it is never persisted.
public actor WalletBridge {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var origin: String?
    private var secret = ""
    private var page = ""
    private var account: String?
    private var chainID: UInt64?
    private var walletName = "Browser wallet"
    private var connectionID = UUID()
    private var listenerID = UUID()
    private var events: AsyncStream<WalletEvent>.Continuation?
    private var pending: Pending?
    private var openConnections = 0
    private var lastBrowserContact: Date?
    private var watchdog: Task<Void, Never>?
    private struct Pending {
        let id: UUID
        let address: String
        let typedData: JSONValue
        let transaction: WalletTransaction?
        let summary: String
        let connection: WalletConnection
        let automaticallyReview: Bool
        let network: EVMDepositNetwork?
        let continuation: CheckedContinuation<JSONValue, Error>
    }
    public init() {}
    public func eventStream() -> AsyncStream<WalletEvent> {
        let (stream, continuation) = AsyncStream<WalletEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(10))
        events?.finish()
        events = continuation
        return stream
    }
    public func start(page: String) async throws -> URL {
        if let origin { return URL(string: origin + "/#" + secret)! }
        guard listener == nil else {
            throw WalletError.invalid("Wallet bridge is already starting")
        }
        self.page = page
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw WalletError.invalid("Unable to create a wallet session")
        }
        secret = Data(random).hex
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let listenerID = UUID()
        self.listenerID = listenerID
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.stateChanged(state, listenerID: listenerID) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.start(queue: DispatchQueue(label: "land.hyperliquidx.wallet"))
        }
    }
    private func stateChanged(_ state: NWListener.State, listenerID: UUID) {
        guard self.listenerID == listenerID else { return }
        switch state {
        case .ready:
            guard let port = listener?.port else {
                ready?.resume(throwing: WalletError.invalid("No wallet bridge port"))
                ready = nil
                return
            }
            origin = "http://127.0.0.1:\(port.rawValue)"
            watchdog?.cancel()
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { break }
                    await self?.checkLiveness()
                }
            }
            ready?.resume(returning: URL(string: origin! + "/#" + secret)!)
            ready = nil
        case .failed(let error):
            ready?.resume(throwing: error)
            ready = nil
            events?.yield(.failed(error.localizedDescription))
            stop()
        case .cancelled:
            ready?.resume(throwing: CancellationError())
            ready = nil
        default: break
        }
    }
    public func stop() {
        listenerID = UUID()
        connectionID = UUID()
        watchdog?.cancel()
        watchdog = nil
        lastBrowserContact = nil
        listener?.cancel()
        listener = nil
        origin = nil
        secret = ""
        account = nil
        chainID = nil
        pending?.continuation.resume(throwing: WalletError.invalid("Wallet disconnected"))
        pending = nil
        events?.yield(.disconnected)
        ready?.resume(throwing: CancellationError())
        ready = nil
    }
    public func requireConnection(_ expected: WalletConnection) throws {
        checkLiveness()
        try expected.requireCurrent(currentConnection)
    }
    private var currentConnection: WalletConnection? {
        guard let account, let chainID else { return nil }
        return try? WalletConnection(address: account, chainID: chainID, id: connectionID)
    }
    public func sign(
        typedData: JSONValue, address: String, summary: String, expectedChainID: UInt64? = nil,
        expectedConnection: WalletConnection? = nil, automaticallyReview: Bool = false
    ) async throws -> WalletSignature {
        let value = try await approve(
            typedData: typedData, transaction: nil, address: address, summary: summary,
            expectedChainID: expectedChainID, expectedConnection: expectedConnection,
            automaticallyReview: automaticallyReview)
        guard let signature = value.string else {
            throw WalletError.invalid("Wallet returned no signature")
        }
        return try WalletSignature(hex: signature)
    }
    public func sendTransaction(
        _ transaction: WalletTransaction, connection: WalletConnection, summary: String,
        automaticallyReview: Bool = false
    ) async throws -> String {
        guard transaction.from == connection.address, transaction.chainID == connection.chainID
        else {
            throw WalletError.invalid("Transaction does not match the reviewed wallet and chain.")
        }
        let result = try await approve(
            typedData: .null, transaction: transaction, address: transaction.from, summary: summary,
            expectedChainID: transaction.chainID, expectedConnection: connection,
            automaticallyReview: automaticallyReview)
        guard let hash = result.string else {
            throw WalletError.invalid("Wallet returned no transaction hash")
        }
        return try WalletTransaction.requireHash(hash)
    }
    /// Switches only to a documented deposit network and returns a new connection identity.
    /// This request never signs typed data or broadcasts a transaction.
    public func switchDepositNetwork(
        _ network: EVMDepositNetwork, connection: WalletConnection
    ) async throws -> WalletConnection {
        try requireConnection(connection)
        if connection.chainID == network.chainID { return connection }
        let identity = try await approve(
            typedData: .null, transaction: nil, address: connection.address,
            summary: "Switch to \(network.name) to prepare your USDC deposit.\nWallet: \(connection.address)\nConfirm the network change in your wallet. Deposit authorization and the transaction are reviewed separately.",
            expectedChainID: connection.chainID, expectedConnection: connection,
            automaticallyReview: true, network: network)
        checkLiveness()
        guard let updated = currentConnection, identity.string == updated.id.uuidString,
              updated.address == connection.address, updated.chainID == network.chainID,
              updated.id != connection.id
        else { throw WalletError.invalid("Wallet changed while completing the network switch.") }
        return updated
    }
    private func approve(
        typedData: JSONValue, transaction: WalletTransaction?, address: String, summary: String,
        expectedChainID: UInt64?, expectedConnection: WalletConnection?, automaticallyReview: Bool,
        network: EVMDepositNetwork? = nil
    ) async throws -> JSONValue {
        checkLiveness()
        guard let connection = currentConnection, connection.address == address.lowercased(),
              Address.isValid(address),
              origin != nil
        else { throw WalletError.invalid("Connect the signing wallet first") }
        try expectedConnection?.requireCurrent(connection)
        guard pending == nil else {
            throw WalletError.invalid("A wallet request is already awaiting approval")
        }
        if let expectedChainID, chainID != expectedChainID {
            throw WalletError.invalid("Wallet chain changed")
        }
        let id = UUID()
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            await self?.cancelRequest(id: id, reason: "Wallet approval timed out")
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = Pending(
                    id: id, address: address.lowercased(), typedData: typedData,
                    transaction: transaction, summary: summary,
                    connection: connection, automaticallyReview: automaticallyReview,
                    network: network,
                    continuation: continuation)
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelRequest(id: id, reason: "Wallet request canceled") }
        }
    }
    private func cancelRequest(id: UUID, reason: String) {
        guard pending?.id == id else { return }
        pending?.continuation.resume(throwing: WalletError.invalid(reason))
        pending = nil
    }
    private func checkLiveness() {
        if account != nil, let lastBrowserContact, Date().timeIntervalSince(lastBrowserContact) > 30 {
            account = nil
            chainID = nil
            pending?.continuation.resume(throwing: WalletError.invalid("Wallet page disconnected"))
            pending = nil
            events?.yield(.disconnected)
        }
    }
    private func handle(_ connection: NWConnection) async {
        guard openConnections < 16 else {
            connection.cancel()
            return
        }
        openConnections += 1
        connection.start(queue: DispatchQueue(label: "land.hyperliquidx.wallet.request"))
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { connection.cancel() }
        }
        defer {
            timeout.cancel()
            connection.cancel()
            openConnections -= 1
        }
        do {
            var buffer = Data()
            var request: BridgeHTTPRequest?
            while request == nil {
                let (chunk, ended) = try await Self.receive(connection)
                buffer.append(chunk)
                request = try BridgeHTTPRequest.parse(buffer)
                if ended && request == nil { throw WalletError.invalid("Incomplete request") }
            }
            let response = try route(request!)
            try await Self.send(response, on: connection)
        } catch {
            try? await Self.send(
                Self.response(
                    status: 400, type: "text/plain",
                    body: Data("Invalid wallet bridge request".utf8)),
                on: connection)
        }
    }
    private func route(_ request: BridgeHTTPRequest) throws -> Data {
        guard let origin, let url = URL(string: origin),
              request.headers["host"] == "127.0.0.1:\(url.port!)"
        else {
            return Self.response(status: 403)
        }
        if request.method == "GET", request.path == "/" {
            return Self.response(
                status: 200, type: "text/html; charset=utf-8", body: Data(page.utf8))
        }
        guard request.headers["authorization"] == "Bearer \(secret)" else {
            return Self.response(status: 403)
        }
        if let source = request.headers["origin"], source != origin {
            return Self.response(status: 403)
        }
        if request.method == "GET", request.path == "/request" {
            lastBrowserContact = Date()
            let value: JSONValue
            if let pending {
                value = .object([
                    "id": .string(pending.id.uuidString), "address": .string(pending.address),
                    "typedData": pending.typedData, "summary": .string(pending.summary),
                    "automaticallyReview": .bool(pending.automaticallyReview),
                    "kind": .string(
                        pending.network != nil
                            ? "switchChain" : pending.transaction == nil ? "signTypedData" : "sendTransaction"),
                    "transaction": pending.transaction?.json ?? .null,
                    "network": pending.network?.walletConfiguration ?? .null,
                    "chainID": .string("0x" + String(pending.connection.chainID, radix: 16))
                ])
            } else {
                value = .null
            }
            return Self.response(status: 200, body: try JSONEncoder().encode(value))
        }
        guard request.method == "POST", request.headers["origin"] == origin,
              request.headers["content-type"]?.hasPrefix("application/json") == true
        else { return Self.response(status: 403) }
        let body = try JSONDecoder().decode(JSONValue.self, from: request.body)
        switch request.path {
        case "/connect":
            guard let address = body["address"].string, Address.isValid(address),
                  let rawChain = body["chainID"].string,
                  rawChain.hasPrefix("0x"), let chain = UInt64(rawChain.dropFirst(2), radix: 16),
                  chain > 0,
                  chain <= UInt64(Int64.max)
            else { return Self.response(status: 400) }
            if account != address.lowercased() || chainID != chain {
                connectionID = UUID()
                pending?.continuation.resume(
                    throwing: WalletError.invalid("Wallet account or chain changed"))
                pending = nil
            }
            account = address.lowercased()
            chainID = chain
            walletName = String((body["name"].string ?? "Browser wallet").prefix(80))
            lastBrowserContact = Date()
            events?.yield(
                .connected(
                    try WalletConnection(address: address, chainID: chain, id: connectionID),
                    walletName))
        case "/disconnect":
            account = nil
            chainID = nil
            pending?.continuation.resume(throwing: WalletError.invalid("Wallet disconnected"))
            pending = nil
            events?.yield(.disconnected)
        case "/result":
            guard let pending, body["id"].string == pending.id.uuidString,
                  body["address"].string?.lowercased() == pending.address, account == pending.address,
                  pending.connection == currentConnection
            else { return Self.response(status: 409) }
            self.pending = nil
            if let error = body["error"].string {
                let message = String(error.prefix(500))
                pending.continuation.resume(
                    throwing: body["errorCode"].int64 == 4001
                        ? WalletError.rejected(message) : WalletError.invalid(message))
            } else if let network = pending.network {
                guard let raw = body["chainID"].string, raw.hasPrefix("0x"),
                      UInt64(raw.dropFirst(2), radix: 16) == network.chainID
                else {
                    account = nil
                    chainID = nil
                    connectionID = UUID()
                    events?.yield(.disconnected)
                    pending.continuation.resume(
                        throwing: WalletError.invalid("Wallet did not confirm the requested deposit network."))
                    break
                }
                chainID = network.chainID
                connectionID = UUID()
                let updated = try WalletConnection(
                    address: pending.address, chainID: network.chainID, id: connectionID)
                events?.yield(.connected(updated, walletName))
                pending.continuation.resume(returning: .string(updated.id.uuidString))
            } else if pending.transaction != nil, let hash = body["transactionHash"].string {
                do {
                    pending.continuation.resume(
                        returning: .string(try WalletTransaction.requireHash(hash)))
                } catch { pending.continuation.resume(throwing: error) }
            } else if pending.transaction == nil, let signature = body["signature"].string {
                do {
                    _ = try WalletSignature(hex: signature)
                    pending.continuation.resume(returning: .string(signature))
                } catch {
                    pending.continuation.resume(throwing: error)
                }
            } else {
                pending.continuation.resume(
                    throwing: WalletError.invalid(
                        "Wallet returned no result for the approved request"))
            }
        default: return Self.response(status: 404)
        }
        return Self.response(status: 200, body: Data("{}".utf8))
    }
    private static func receive(_ connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) {
                data, _, ended, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), ended))
                }
            }
        }
    }
    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }
    private static func response(
        status: Int, type: String = "application/json", body: Data = Data()
    ) -> Data {
        let reason = status == 200 ? "OK" : "Rejected"
        let header =
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'\r\n\r\n"
        return Data(header.utf8) + body
    }
}
