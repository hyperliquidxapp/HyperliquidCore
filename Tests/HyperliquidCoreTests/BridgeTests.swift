import Foundation
import Testing

@testable import HyperliquidCore

@Test func httpParsingHandlesFragmentationAndRejectsSmuggling() throws {
    let header = "POST /connect HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Length: 2\r\n\r\n"
    #expect(try BridgeHTTPRequest.parse(Data(header.utf8)) == nil)
    let parsed = try BridgeHTTPRequest.parse(Data((header + "{}").utf8))
    let request = try #require(parsed)
    #expect(request.path == "/connect")
    #expect(request.body == Data("{}".utf8))
    #expect(throws: WalletError.self) {
        try BridgeHTTPRequest.parse(Data((header + "{}extra").utf8))
    }
    #expect(throws: WalletError.self) {
        try BridgeHTTPRequest.parse(
            Data("POST / HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}".utf8))
    }
    #expect(throws: WalletError.self) {
        try BridgeHTTPRequest.parse(
            Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
    }
    #expect(throws: WalletError.self) {
        try BridgeHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8))
    }
}

@Test func loopbackWalletSessionRequiresCapabilityOriginAndRequestID() async throws {
    let bridge = WalletBridge()
    let launch = try await bridge.start(page: "<!doctype html><title>Test</title>")
    let token = try #require(launch.fragment)
    let origin = "http://127.0.0.1:\(try #require(launch.port))"
    let address = "0x1111111111111111111111111111111111111111"
    func request(
        _ path: String, body: JSONValue? = nil, capability: String? = token,
        source: String? = origin
    )
    async throws -> (JSONValue, Int) {
        var req = URLRequest(url: URL(string: origin + path)!)
        req.timeoutInterval = 3
        if let capability {
            req.setValue("Bearer \(capability)", forHTTPHeaderField: "Authorization")
        }
        if let source { req.setValue(source, forHTTPHeaderField: "Origin") }
        if let body {
            req.httpMethod = "POST"
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = try #require((response as? HTTPURLResponse)?.statusCode)
        return ((try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null, code)
    }
    do {
        let connect: JSONValue = .object([
            "address": .string(address), "name": .string("Mock provider"),
            "chainID": .string("0xa4b1")
        ])
        #expect(try await request("/connect", body: connect, capability: nil).1 == 403)
        #expect(
            try await request("/connect", body: connect, source: "https://evil.example").1 == 403)
        #expect(try await request("/connect", body: connect).1 == 200)
        let typedData = try SigningPayload.typedData(
            action: ExchangeAction.leverage(assetID: 1, value: 2, cross: true), nonce: 1,
            environment: .testnet)
        async let result = bridge.sign(
            typedData: typedData, address: address, summary: "Mock signature transport only")
        var pending = JSONValue.null
        for _ in 0..<100 {
            pending = try await request("/request").0
            if pending["id"].string != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = try #require(pending["id"].string)
        #expect(pending["typedData"] == typedData)
        #expect(pending["chainID"].string == "0xa4b1")
        let signature = "0x" + String(repeating: "01", count: 64) + "1b"
        #expect(
            try await request(
                "/result",
                body: .object([
                    "id": .string("wrong"), "address": .string(address),
                    "signature": .string(signature)
                ])
            ).1 == 409)
        #expect(
            try await request(
                "/result",
                body: .object([
                    "id": .string(id), "address": .string(address), "signature": .string(signature)
                ])
            ).1 == 200)
        #expect(try await result.v == 27)
        #expect(
            try await request(
                "/result",
                body: .object([
                    "id": .string(id), "address": .string(address), "signature": .string(signature)
                ])
            ).1 == 409)
        await #expect(throws: WalletError.self) {
            try await bridge.sign(
                typedData: typedData, address: address, summary: "Wrong chain", expectedChainID: 1)
        }
        let onArbitrum = Task {
            try await bridge.sign(
                typedData: typedData, address: address, summary: "Change chain while signing",
                expectedChainID: 42161)
        }
        var requestOnArbitrum = JSONValue.null
        for _ in 0..<100 {
            requestOnArbitrum = try await request("/request").0
            if requestOnArbitrum["id"].string != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(requestOnArbitrum["chainID"].string == "0xa4b1")
        let oldID = try #require(requestOnArbitrum["id"].string)
        #expect(
            try await request(
                "/connect", body: .object(["address": .string(address), "chainID": .string("0x1")])
            ).1
            == 200)
        await #expect(throws: WalletError.self) { try await onArbitrum.value }
        #expect(
            try await request(
                "/result",
                body: .object([
                    "id": .string(oldID), "address": .string(address),
                    "signature": .string(signature)
                ])
            ).1 == 409)
        #expect(
            try await request(
                "/connect",
                body: .object(["address": .string(address), "chainID": .string("invalid")])
            ).1
            == 400)
        #expect(try await request("/disconnect", body: .object([:])).1 == 200)
        await #expect(throws: WalletError.self) {
            try await bridge.sign(typedData: typedData, address: address, summary: "Disconnected")
        }
        await bridge.stop()
    } catch {
        await bridge.stop()
        throw error
    }
}

@Test func loopbackRejectsOldConnectionsAfterBufferedAccountAndChainRoundTrips() async throws {
    let bridge = WalletBridge()
    let events = await bridge.eventStream()
    var iterator = events.makeAsyncIterator()
    let launch = try await bridge.start(page: "<!doctype html><title>Test</title>")
    let token = try #require(launch.fragment)
    let origin = "http://127.0.0.1:\(try #require(launch.port))"
    let firstAddress = "0x1111111111111111111111111111111111111111"
    let otherAddress = "0x2222222222222222222222222222222222222222"
    func connect(_ address: String, chain: String) async throws {
        var request = URLRequest(url: URL(string: origin + "/connect")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            JSONValue.object(["address": .string(address), "chainID": .string(chain)]))
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
    do {
        try await connect(firstAddress, chain: "0xa4b1")
        let firstEvent = await iterator.next()
        guard case .connected(let first, _) = try #require(firstEvent) else {
            Issue.record("Missing wallet connection")
            await bridge.stop()
            return
        }
        try await bridge.requireConnection(first)
        // A duplicate connect must preserve a still valid authorization.
        try await connect(firstAddress, chain: "0xa4b1")
        let duplicateEvent = await iterator.next()
        guard case .connected(let duplicate, _) = try #require(duplicateEvent) else {
            Issue.record("Missing duplicate connection")
            await bridge.stop()
            return
        }
        #expect(duplicate == first)
        // More events than the UI stream retains: the final snapshot must still
        // invalidate the first connection even though address/chain return to A.
        for _ in 0..<6 {
            try await connect(otherAddress, chain: "0xa4b1")
            try await connect(firstAddress, chain: "0xa4b1")
            try await connect(firstAddress, chain: "0x1")
            try await connect(firstAddress, chain: "0xa4b1")
        }
        var latest: WalletConnection?
        for _ in 0..<10 {
            if case .connected(let value, _) = await iterator.next() { latest = value }
        }
        let returned = try #require(latest)
        #expect(returned.address == first.address)
        #expect(returned.chainID == first.chainID)
        #expect(returned.id != first.id)
        await #expect(throws: WalletError.self) { try await bridge.requireConnection(first) }
        try await bridge.requireConnection(returned)
        let typed = try SigningPayload.typedData(
            action: ExchangeAction.leverage(assetID: 1, value: 2, cross: true), nonce: 1,
            environment: .testnet)
        await #expect(throws: WalletError.self) {
            try await bridge.sign(
                typedData: typed, address: first.address, summary: "Expired connection",
                expectedChainID: first.chainID,
                expectedConnection: first)
        }
        await bridge.stop()
        let restarted = try await bridge.start(page: "<!doctype html><title>Restart</title>")
        #expect(restarted.fragment != launch.fragment)
        let (page, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(try #require(restarted.port))/")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        // Preserve UTF-8 replacement decoding; encoded JSON is UTF-8 and error text may be invalid.
        // swiftlint:disable:next optional_data_string_conversion
        #expect(String(decoding: page, as: UTF8.self).contains("Restart"))
        await #expect(throws: WalletError.self) { try await bridge.requireConnection(returned) }
        await bridge.stop()
    } catch {
        await bridge.stop()
        throw error
    }
}

@Test func receiptsSeparateRejectionFromExecutionAndKeepOrderIDPrecision() throws {
    let resting = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            #"{"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":9007199254740993}}]}}}"#
                .utf8))
    #expect(try ExchangeReceipt.parse(resting).statuses == [.resting(9_007_199_254_740_993)])
    let error = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            #"{"status":"ok","response":{"type":"order","data":{"statuses":[{"error":"Insufficient margin"}]}}}"#
                .utf8))
    #expect(try ExchangeReceipt.parse(error).statuses == [.rejected("Insufficient margin")])
    #expect(throws: ExchangeRejection.self) {
        try ExchangeReceipt.parse(
            .object(["status": .string("err"), "response": .string("Bad signature")]))
    }
    let filled = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            #"{"status":"ok","response":{"type":"order","data":{"statuses":[{"filled":{"oid":123,"totalSz":"1.2","avgPx":"100"}}]}}}"#
                .utf8))
    #expect(try ExchangeReceipt.parse(filled).statuses == [.filled(123, "1.2", "100")])
    let malformed = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            #"{"status":"ok","response":{"type":"order","data":{"statuses":[{"resting":{"oid":1e99}}]}}}"#
                .utf8))
    #expect(throws: APIError.self) { try ExchangeReceipt.parse(malformed) }
}
