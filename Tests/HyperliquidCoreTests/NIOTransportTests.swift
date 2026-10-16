import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing

@testable import HyperliquidCore

@Test func nioWebSocketAssemblesFragmentsAcrossControlFramesAndPreservesBinaryMessages() throws {
    var assembler = NIOWebSocketMessageAssembler(maximumBytes: 16)
    let first = try assembler.accept(
        WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(string: "{\"x\":")))
    #expect(first == nil)
    let ping = try assembler.accept(
        WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer(string: "echo")))
    if case .ping(let bytes) = ping {
        #expect(String(buffer: bytes) == "echo")
    } else {
        Issue.record("Missing ping")
    }
    let text = try assembler.accept(
        WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer(string: "1}")))
    if case .message(let bytes) = text {
        #expect(bytes == Data("{\"x\":1}".utf8))
    } else {
        Issue.record("Missing assembled text")
    }
    let binary = try assembler.accept(
        WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer(bytes: [0, 1, 255])))
    if case .message(let bytes) = binary {
        #expect(bytes == Data([0, 1, 255]))
    } else {
        Issue.record("Missing binary message")
    }
}

@Test func nioWebSocketRejectsMalformedFramesAndBoundsTheWholeFragmentedMessage() throws {
    let invalid = [
        WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer()),
        WebSocketFrame(fin: false, opcode: .ping, data: ByteBuffer()),
        WebSocketFrame(
            fin: true, opcode: .ping, data: ByteBuffer(bytes: [UInt8](repeating: 0, count: 126))),
        WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer(bytes: [0])),
        WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer(bytes: [3, 237])),
        WebSocketFrame(
            fin: true, opcode: .connectionClose, data: ByteBuffer(bytes: [3, 232, 255])),
        WebSocketFrame(fin: true, rsv1: true, opcode: .text, data: ByteBuffer()),
        WebSocketFrame(fin: true, opcode: .text, maskKey: [1, 2, 3, 4], data: ByteBuffer()),
        WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(bytes: [0xff]))
    ]
    for frame in invalid {
        var assembler = NIOWebSocketMessageAssembler()
        #expect(throws: APIError.self) { try assembler.accept(frame) }
    }
    var assembler = NIOWebSocketMessageAssembler(maximumBytes: 4)
    _ = try assembler.accept(
        WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(string: "123")))
    #expect(throws: APIError.self) {
        try assembler.accept(
            WebSocketFrame(fin: true, opcode: .continuation, data: ByteBuffer(string: "45")))
    }
    var overlapping = NIOWebSocketMessageAssembler()
    _ = try overlapping.accept(
        WebSocketFrame(fin: false, opcode: .text, data: ByteBuffer(string: "a")))
    #expect(throws: APIError.self) {
        try overlapping.accept(WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer()))
    }
}

private final class HTTPFixtureJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(String, Data)] = []
    let events: AsyncStream<String>
    private let output: AsyncStream<String>.Continuation
    init() { (events, output) = AsyncStream<String>.makeStream() }
    func append(_ path: String, _ data: Data) {
        lock.withLock { requests.append((path, data)) }
        output.yield(path)
    }
    var snapshot: [(String, Data)] { lock.withLock { requests } }
    func finish() { output.finish() }
}

private final class HTTPFixtureHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let journal: HTTPFixtureJournal
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    init(journal: HTTPFixtureJournal) { self.journal = journal }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body(var bytes): body.writeBuffer(&bytes)
        case .end:
            guard let head else { return }
            journal.append(head.uri, Data(body.readableBytesView))
            let status: HTTPResponseStatus =
                head.uri == "/redirect" ? .found : head.uri == "/fail" ? .serviceUnavailable : .ok
            let bytes: ByteBuffer =
                head.method == .GET && body.readableBytes == 0
                ? ByteBuffer(string: "read-only quote")
                : head.method == .POST
                && head.headers.first(name: "content-type") == "application/json"
                ? body : ByteBuffer(string: "invalid request")
            var headers = HTTPHeaders([
                ("Content-Length", String(bytes.readableBytes)), ("Connection", "close")
            ])
            if head.uri == "/redirect" { headers.add(name: "Location", value: "/unexpected") }
            context.write(
                wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))),
                promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(bytes))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

@Test func nioHTTPPreservesExactPostBytesAndRejectsRedirectsAndErrorsWithoutRepeatingRequests()
async throws {
    let journal = HTTPFixtureJournal()
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                try channel.pipeline.syncOperations.addHandler(HTTPFixtureHandler(journal: journal))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
    defer { server.close(promise: nil) }
    let port = try #require(server.localAddress?.port)
    let transport = NIOHTTPTransport()
    let body = Data(#"{"nonce":9007199254740993,"signature":"fixture-only"}"#.utf8)
    let result = try await transport.post(
        url: URL(string: "http://127.0.0.1:\(port)/echo")!, body: body)
    #expect(result == body)
    for (path, status) in [("redirect", 302), ("fail", 503)] {
        do {
            _ = try await transport.post(
                url: URL(string: "http://127.0.0.1:\(port)/\(path)")!, body: body)
            Issue.record("Expected HTTP status failure")
        } catch APIError.http(let code, let message) {
            #expect(code == status && message.contains("fixture-only"))
        }
    }
    #expect(journal.snapshot.map { $0.0 } == ["/echo", "/redirect", "/fail"])
    #expect(journal.snapshot.allSatisfy { $0.1 == body })
    let quote = try await transport.get(
        url: URL(string: "http://127.0.0.1:\(port)/quote?forward=true&hyperCoreDeposit=true")!)
    #expect(quote == Data("read-only quote".utf8))
    #expect(
        journal.snapshot.last?.0 == "/quote?forward=true&hyperCoreDeposit=true"
            && journal.snapshot.last?.1.isEmpty == true)
    do {
        _ = try await NIOWebSocketConnection.open(
            url: URL(string: "ws://127.0.0.1:\(port)/upgrade-rejected")!)
        Issue.record("Expected rejected WebSocket upgrade")
    } catch { #expect(error.localizedDescription.contains("rejected")) }
    do {
        _ = try await transport.post(url: URL(string: "http://example.com/info")!, body: body)
        Issue.record("Expected insecure endpoint rejection")
    } catch { #expect(error.localizedDescription.contains("HTTPS")) }
}

@Test func nioWebSocketBoundsPendingBytesAndReleasesConsumedCapacity() {
    let budget = WebSocketBufferBudget(maximumBytes: 8)
    #expect(budget.reserve(5) && budget.reserve(3))
    #expect(!budget.reserve(1) && !budget.reserve(-1))
    budget.release(5)
    #expect(budget.reserve(5) && !budget.reserve(1))
    budget.release(100)
    #expect(budget.reserve(8))
}

private final class WebSocketEchoFixture: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let journal: HTTPFixtureJournal
    init(journal: HTTPFixtureJournal) { self.journal = journal }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        let bytes = frame.unmaskedData
        if frame.opcode == .text {
            journal.append(
                frame.maskKey == nil ? "unmasked" : "masked", Data(bytes.readableBytesView))
            let text = String(buffer: bytes)
            let middle = text.utf8.count / 2
            let raw = Array(text.utf8)
            context.write(
                wrapOutboundOut(
                    WebSocketFrame(
                        fin: false, opcode: .text, data: ByteBuffer(bytes: raw.prefix(middle)))),
                promise: nil)
            context.write(
                wrapOutboundOut(
                    WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer(string: "probe"))),
                promise: nil)
            context.writeAndFlush(
                wrapOutboundOut(
                    WebSocketFrame(
                        fin: true, opcode: .continuation,
                        data: ByteBuffer(bytes: raw.suffix(raw.count - middle)))),
                promise: nil)
        } else if frame.opcode == .pong {
            journal.append(
                frame.maskKey == nil ? "unmasked-pong" : "pong", Data(bytes.readableBytesView))
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        journal.finish()
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

@Test func nioWebSocketLoopbackUpgradesMasksOutboundFramesAndHandlesFragmentedEchoAndPing()
async throws {
    let journal = HTTPFixtureJournal()
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let upgrader = NIOTypedWebSocketServerUpgrader<any Channel>(
                    shouldUpgrade: { channel, request in
                        journal.append("upgrade", Data((request.uri + "|"
                                                            + (request.headers.first(name: "Authorization") ?? "") + "|"
                                                            + (request.headers.first(name: "User-Agent") ?? "")).utf8))
                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                WebSocketEchoFixture(journal: journal))
                            return channel
                        }
                    })
                let configuration = NIOTypedHTTPServerUpgradeConfiguration(
                    upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        channel.eventLoop.makeFailedFuture(
                            APIError.malformed("Unexpected HTTP request"))
                    })
                let upgraded = try channel.pipeline.syncOperations
                    .configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: configuration))
                upgraded.whenFailure { _ in channel.close(promise: nil) }
            }
        }.bind(host: "127.0.0.1", port: 0).get()
    defer { server.close(promise: nil) }
    let port = try #require(server.localAddress?.port)
    let connection = try await NIOWebSocketConnection.open(
        url: URL(string: "ws://127.0.0.1:\(port)/stream?fixture=1")!,
        headers: ["Authorization": "Bearer offline-fixture", "User-Agent": "WalletConnect/fixture"])
    defer { connection.close() }
    let deadline = Task {
        try await Task.sleep(for: .seconds(3))
        connection.close()
    }
    defer { deadline.cancel() }
    let message = #"{"channel":"fixture","data":{"price":"123.45"}}"#
    try await connection.send(text: message)
    let received = try await connection.receive()
    #expect(received == Data(message.utf8))
    var events = journal.events.makeAsyncIterator()
    while let event = await events.next() { if event == "pong" { break } }
    #expect(journal.snapshot.map { $0.0 } == ["upgrade", "masked", "pong"])
    #expect(journal.snapshot.first?.1 == Data(
                "/stream?fixture=1|Bearer offline-fixture|WalletConnect/fixture".utf8))
    #expect(journal.snapshot.last?.1 == Data("probe".utf8))
    let waiting = Task { try await connection.receive() }
    await Task.yield()
    waiting.cancel()
    connection.close()
    do {
        _ = try await waiting.value
        Issue.record("Expected cancelled receive")
    } catch {}
    try await connection.channel.closeFuture.get()
}
