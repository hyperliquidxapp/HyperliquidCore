import Foundation
import Testing

@testable import HyperliquidCore

@Test func loopbackWalletDepositRequestRequiresApprovedTransactionAndMatchingHashResult()
async throws {
    let bridge = WalletBridge()
    let stream = await bridge.eventStream()
    let launch = try await bridge.start(page: "<title>Offline deposit transport fixture</title>")
    let capability = try #require(launch.fragment)
    let port = try #require(launch.port)
    let origin = "http://127.0.0.1:\(port)"
    let owner = "0x1111111111111111111111111111111111111111"
    func request(_ path: String, body: JSONValue? = nil) async throws -> (JSONValue, Int) {
        var request = URLRequest(url: URL(string: origin + path)!)
        request.timeoutInterval = 3
        request.setValue("Bearer " + capability, forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = try #require((response as? HTTPURLResponse)?.statusCode)
        return ((try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null, code)
    }
    func pending() async throws -> JSONValue {
        for _ in 0..<100 {
            let result = try await request("/request").0
            if result["id"].string != nil { return result }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WalletError.invalid("Mock transaction request did not become available")
    }
    do {
        #expect(
            try await request(
                "/connect",
                body: .object(["address": .string(owner), "chainID": .string("0x66eee")])
            ).1 == 200)
        var events = stream.makeAsyncIterator()
        let event = await events.next()
        let connected = try #require(event)
        guard case .connected(let connection, _) = connected else {
            throw WalletError.invalid("Mock connection unavailable")
        }
        let intent = try BridgeDepositIntent(owner: owner, amount: "5.125", environment: .testnet)
        let transaction = try intent.transaction
        let first = Task {
            try await bridge.sendTransaction(
                transaction, connection: connection, summary: "Offline fixture only")
        }
        let original = try await pending()
        let id = try #require(original["id"].string)
        #expect(
            original["kind"].string == "sendTransaction"
                && original["transaction"] == transaction.json)
        #expect(original["typedData"] == .null && original["chainID"].string == "0x66eee")
        #expect(original["automaticallyReview"].bool == false)
        #expect(
            try await request(
                "/result",
                body: .object([
                    "id": .string("wrong"), "address": .string(owner),
                    "transactionHash": .string("0x" + String(repeating: "a", count: 64))
                ])
            ).1 == 409)
        // A signature cannot be mistaken for a deposit transaction hash.
        #expect(
            try await request(
                "/result",
                body: .object([
                    "id": .string(id), "address": .string(owner),
                    "signature": .string("0x" + String(repeating: "01", count: 64) + "1b")
                ])
            ).1 == 200)
        await #expect(throws: WalletError.self) { try await first.value }
        let next = Task {
            try await bridge.sendTransaction(
                transaction, connection: connection, summary: "Offline fixture only",
                automaticallyReview: true)
        }
        let valid = try await pending()
        #expect(valid["automaticallyReview"].bool == true)
        let nextID = try #require(valid["id"].string)
        let hash = "0x" + String(repeating: "a", count: 64)
        #expect(
            try await request(
                "/result",
                body: .object([
                    "id": .string(nextID), "address": .string(owner),
                    "transactionHash": .string(hash)
                ])
            ).1 == 200)
        #expect(try await next.value == hash)
        #expect(
            try await request(
                "/result",
                body: .object([
                    "id": .string(nextID), "address": .string(owner),
                    "transactionHash": .string(hash)
                ])
            ).1 == 409)
        let rejected = Task {
            try await bridge.sendTransaction(
                transaction, connection: connection, summary: "Offline rejection fixture")
        }
        let rejection = try await pending()
        #expect(
            try await request(
                "/result",
                body: .object([
                    "id": rejection["id"], "address": .string(owner),
                    "error": .string("Rejected by user"), "errorCode": .integer(4001)
                ])
            ).1 == 200)
        do {
            _ = try await rejected.value
            Issue.record("User rejection was accepted")
        } catch WalletError.rejected {} catch {
            Issue.record("User rejection lost its explicit rejection state")
        }
        let wrongChain = try WalletConnection(address: owner, chainID: 42161)
        await #expect(throws: WalletError.self) {
            try await bridge.sendTransaction(
                transaction, connection: wrongChain, summary: "Wrong chain")
        }
        await bridge.stop()
    } catch {
        await bridge.stop()
        throw error
    }
}

@Test func bridgeDepositReceiptRequiresExactAssetSenderReceiverAmountAndMinedStatus() throws {
    let owner = "0x1111111111111111111111111111111111111111"
    let intent = try BridgeDepositIntent(owner: owner, amount: "5.125", environment: .testnet)
    let hash = "0x" + String(repeating: "a", count: 64)
    let from = "0x" + String(repeating: "0", count: 24) + owner.dropFirst(2)
    let to = "0x" + String(repeating: "0", count: 24) + intent.route.bridge.dropFirst(2)
    let log: JSONValue = .object([
        "address": .string(intent.route.token), "data": .string("0x4e3388"),
        "topics": .array([
            .string(Keccak256.hash(Data("Transfer(address,address,uint256)".utf8)).hex),
            .string(from), .string(to)
        ])
    ])
    let fields: [String: JSONValue] = [
        "transactionHash": .string(hash), "from": .string(owner), "to": .string(intent.route.token),
        "blockNumber": .string("0x123"), "status": .string("0x1"), "logs": .array([log])
    ]
    #expect(try BridgeDepositReceipt.parse(.null, hash: hash, intent: intent) == nil)
    #expect(try BridgeDepositReceipt.parse(.object(fields), hash: hash, intent: intent) == true)
    var failed = fields
    failed["status"] = .string("0x0")
    failed["logs"] = .array([])
    #expect(try BridgeDepositReceipt.parse(.object(failed), hash: hash, intent: intent) == false)
    for (key, value) in [
        ("transactionHash", JSONValue.string("0x" + String(repeating: "b", count: 64))),
        ("from", .string(intent.route.bridge)), ("to", .string(intent.route.bridge)),
        ("blockNumber", .string("0x0")),
        ("status", .string("0x2")), ("logs", .array([])), ("logs", .array([log, log]))
    ] {
        var invalid = fields
        invalid[key] = value
        #expect(throws: APIError.self) {
            try BridgeDepositReceipt.parse(.object(invalid), hash: hash, intent: intent)
        }
    }
}
