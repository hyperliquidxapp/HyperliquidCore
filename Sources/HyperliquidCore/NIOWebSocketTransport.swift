import Foundation
import NIOCore
import NIOFoundationEssentialsCompat
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

enum NIOWebSocketEvent: Sendable {
    case message(Data)
    case ping(ByteBuffer)
    case close(ByteBuffer)
}

/// Preserves frame order and bounds an entire fragmented message, including
/// continuation frames. Control frames may interleave without ending a message.
struct NIOWebSocketMessageAssembler {
    let maximumBytes: Int
    private var opcode: WebSocketOpcode?
    private var bytes = ByteBuffer()
    init(maximumBytes: Int = 1_048_576) { self.maximumBytes = maximumBytes }
    mutating func accept(_ frame: WebSocketFrame) throws -> NIOWebSocketEvent? {
        guard frame.maskKey == nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
            throw APIError.malformed("Invalid server WebSocket frame")
        }
        switch frame.opcode {
        case .ping, .pong, .connectionClose:
            guard frame.fin, frame.data.readableBytes <= 125,
                  frame.opcode != .connectionClose || frame.data.readableBytes != 1
            else { throw APIError.malformed("Invalid WebSocket control frame") }
            if frame.opcode == .connectionClose, frame.data.readableBytes >= 2 {
                let code = frame.data.getInteger(at: frame.data.readerIndex, as: UInt16.self)!
                let validCode =
                    ((1000...1014).contains(code) && ![1004, 1005, 1006].contains(code))
                    || (3000...4999).contains(code)
                let reason = Data(frame.data.readableBytesView.dropFirst(2))
                guard validCode, String(data: reason, encoding: .utf8) != nil else {
                    throw APIError.malformed("Invalid WebSocket close reason")
                }
            }
            if frame.opcode == .ping { return .ping(frame.data) }
            if frame.opcode == .connectionClose { return .close(frame.data) }
            return nil
        case .text, .binary:
            guard opcode == nil else { throw APIError.malformed("Overlapping WebSocket messages") }
            opcode = frame.opcode
        case .continuation:
            guard opcode != nil else {
                throw APIError.malformed("Unexpected WebSocket continuation")
            }
        default: throw APIError.malformed("Unsupported WebSocket opcode")
        }
        guard frame.data.readableBytes <= maximumBytes - bytes.readableBytes else {
            throw APIError.malformed("WebSocket message exceeds the size limit")
        }
        var payload = frame.data
        bytes.writeBuffer(&payload)
        guard frame.fin else { return nil }
        let data = Data(bytes.readableBytesView)
        if opcode == .text, String(data: data, encoding: .utf8) == nil {
            throw APIError.malformed("Invalid WebSocket text encoding")
        }
        opcode = nil
        bytes.clear()
        return .message(data)
    }
}

private func clientFrame(opcode: WebSocketOpcode, data: ByteBuffer) -> WebSocketFrame {
    var random = SystemRandomNumberGenerator()
    return WebSocketFrame(fin: true, opcode: opcode, maskKey: .random(using: &random), data: data)
}

private final class WebSocketConnectionAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: (any Channel)?
    private var cancelled = false
    func attach(_ channel: any Channel) {
        let close = lock.withLock {
            self.channel = channel
            return cancelled
        }
        if close { channel.close(promise: nil) }
    }
    func cancel() {
        let channel = lock.withLock {
            cancelled = true
            return self.channel
        }
        channel?.close(promise: nil)
    }
}

final class WebSocketBufferBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    let maximumBytes: Int
    init(maximumBytes: Int = 8 * 1024 * 1024) { self.maximumBytes = maximumBytes }
    func reserve(_ count: Int) -> Bool {
        lock.withLock {
            guard count >= 0, count <= maximumBytes - bytes else { return false }
            bytes += count
            return true
        }
    }
    func release(_ count: Int) { lock.withLock { bytes = max(0, bytes - max(0, count)) } }
}

/// State is confined to the channel's event loop. Only its Sendable stream
/// continuation crosses into Swift concurrency.
private final class MarketWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    private var assembler = NIOWebSocketMessageAssembler()
    private let output: AsyncThrowingStream<Data, Error>.Continuation
    private let budget: WebSocketBufferBudget
    init(output: AsyncThrowingStream<Data, Error>.Continuation, budget: WebSocketBufferBudget) {
        self.output = output
        self.budget = budget
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        do {
            guard let event = try assembler.accept(unwrapInboundIn(data)) else { return }
            switch event {
            case .message(let message):
                guard budget.reserve(message.count) else {
                    output.finish(
                        throwing: APIError.malformed(
                            "WebSocket buffer exceeds the size limit; reconnecting"))
                    context.close(promise: nil)
                    return
                }
                switch output.yield(message) {
                case .enqueued: break
                case .dropped:
                    budget.release(message.count)
                    output.finish(
                        throwing: APIError.malformed(
                            "WebSocket consumer fell behind; reconnecting for a fresh snapshot"))
                    context.close(promise: nil)
                case .terminated:
                    budget.release(message.count)
                    context.close(promise: nil)
                @unknown default:
                    budget.release(message.count)
                    context.close(promise: nil)
                }
            case .ping(let payload):
                context.writeAndFlush(
                    wrapOutboundOut(clientFrame(opcode: .pong, data: payload)), promise: nil)
            case .close(let payload):
                let channel = context.channel
                let output = output
                context.writeAndFlush(
                    wrapOutboundOut(clientFrame(opcode: .connectionClose, data: payload))
                )
                .whenComplete { _ in
                    output.finish(throwing: APIError.malformed("WebSocket connection closed"))
                    channel.close(promise: nil)
                }
            }
        } catch {
            output.finish(throwing: error)
            context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        output.finish(throwing: APIError.malformed("WebSocket connection ended"))
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        output.finish(throwing: error)
        context.close(promise: nil)
    }
}

public struct NIOWebSocketConnection: Sendable {
    let channel: any Channel
    private let inbound: AsyncThrowingStream<Data, Error>
    private let budget: WebSocketBufferBudget
    private static let tls = Result { try NIOSSLContext(configuration: .makeClientConfiguration()) }

    public static func open(url: URL, headers: [String: String] = [:]) async throws -> Self {
        let attempt = WebSocketConnectionAttempt()
        return try await withTaskCancellationHandler {
            do { return try await open(url: url, headers: headers, attempt: attempt) } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            attempt.cancel()
        }
    }
    private static func open(
        url: URL, headers: [String: String], attempt: WebSocketConnectionAttempt
    ) async throws -> Self {
        guard let host = url.host,
              url.scheme == "wss" || (url.scheme == "ws" && host == "127.0.0.1"), url.user == nil
        else {
            throw APIError.malformed("Invalid WebSocket endpoint")
        }
        try Task.checkCancellation()
        guard headers.allSatisfy({ key, value in
            ["authorization", "user-agent"].contains(key.lowercased())
                && value.utf8.count <= 8192 && !value.contains("\r") && !value.contains("\n")
        }) else { throw APIError.malformed("Unsupported WebSocket headers") }
        let secure = url.scheme == "wss"
        let port = url.port ?? (secure ? 443 : 80)
        let (stream, output) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(256))
        let budget = WebSocketBufferBudget()
        let ssl = secure ? try Self.tls.get() : nil
        let upgrade: EventLoopFuture<any Channel> = try await ClientBootstrap(
            group: MultiThreadedEventLoopGroup.singleton
        )
        .connectTimeout(.seconds(15))
        .connect(host: host, port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                attempt.attach(channel)
                output.onTermination = { _ in channel.close(promise: nil) }
                if let ssl {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSLClientHandler(context: ssl, serverHostname: host))
                }
                let upgrader = NIOTypedWebSocketClientUpgrader<any Channel>(maxFrameSize: 1_048_576) { channel, _ in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            MarketWebSocketHandler(output: output, budget: budget))
                        return channel
                    }
                }
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let path =
                    (components?.percentEncodedPath.isEmpty == false
                        ? components!.percentEncodedPath : "/")
                    + (components?.percentEncodedQuery.map { "?" + $0 } ?? "")
                let request = HTTPRequestHead(
                    version: .http1_1, method: .GET, uri: path,
                    headers: HTTPHeaders(
                        [("Host", url.port == nil ? host : "\(host):\(port)")]
                            + headers.map { ($0.key, $0.value) }))
                let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: request, upgraders: [upgrader],
                    notUpgradingCompletionHandler: { channel in
                        channel.close(promise: nil)
                        return channel.eventLoop.makeFailedFuture(
                            APIError.malformed("WebSocket upgrade was rejected"))
                    })
                let result = try channel.pipeline.syncOperations
                    .configureUpgradableHTTPClientPipeline(
                        configuration: .init(upgradeConfiguration: configuration))
                let timeout = channel.eventLoop.scheduleTask(in: .seconds(15)) {
                    channel.close(promise: nil)
                }
                result.whenComplete { _ in timeout.cancel() }
                return result
            }
        }
        do {
            let channel = try await upgrade.get()
            if Task.isCancelled {
                channel.close(promise: nil)
                throw CancellationError()
            }
            return Self(channel: channel, inbound: stream, budget: budget)
        } catch {
            output.finish(throwing: error)
            throw error
        }
    }
    public func send(text: String) async throws {
        try Task.checkCancellation()
        try await channel.writeAndFlush(clientFrame(opcode: .text, data: ByteBuffer(string: text)))
            .get()
    }
    public func receive() async throws -> Data {
        try Task.checkCancellation()
        var iterator = inbound.makeAsyncIterator()
        guard let message = try await iterator.next() else {
            throw APIError.malformed("WebSocket connection ended")
        }
        budget.release(message.count)
        try Task.checkCancellation()
        guard channel.isActive else {
            throw APIError.malformed("WebSocket connection ended; refresh required")
        }
        return message
    }
    public func close() { channel.close(promise: nil) }
}
