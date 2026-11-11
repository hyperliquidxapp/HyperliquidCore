import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Exercises the shipped HTTP transport on loopback without wallet or exchange access.
public enum NIOHTTPRuntimeProbe {
    public struct Report: Codable, Sendable {
        public let schemaVersion: Int
        public let passed: Bool
        public let scope: String
        public let completedRequests: Int
        public let cancelledRequests: Int
    }

    public static func run() async throws -> Report {
        let journal = ProbeJournal()
        defer { journal.finish() }
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(ProbeHandler(journal: journal))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }
        guard let port = server.localAddress?.port,
              let echoURL = URL(string: "http://127.0.0.1:\(port)/echo"),
              let holdURL = URL(string: "http://127.0.0.1:\(port)/hold")
        else { throw APIError.malformed("HTTP runtime probe could not bind loopback") }
        let transport = NIOHTTPTransport()
        let payload = Data(#"{"nonce":9007199254740993,"probe":"loopback"}"#.utf8)
        // Match parallel account refreshes, including cross-module async-let frames.
        async let first = transport.post(url: echoURL, body: payload)
        async let second = transport.post(url: echoURL, body: payload)
        async let third = transport.post(url: echoURL, body: payload)
        async let fourth = transport.post(url: echoURL, body: payload)
        async let fifth = transport.post(url: echoURL, body: payload)
        async let sixth = transport.post(url: echoURL, body: payload)
        async let seventh = transport.post(url: echoURL, body: payload)
        async let eighth = transport.post(url: echoURL, body: payload)
        let responses = try await [first, second, third, fourth, fifth, sixth, seventh, eighth]
        guard responses.allSatisfy({ $0 == payload }) else {
            throw APIError.malformed("HTTP runtime probe changed request bytes")
        }

        let pending = Task { try await transport.get(url: holdURL) }
        defer { pending.cancel() }
        let watchdog = DispatchWorkItem {
            journal.finish()
            pending.cancel()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        defer { watchdog.cancel() }
        var observed = false
        for await _ in journal.heldRequests { observed = true; break }
        guard observed else { throw APIError.malformed("HTTP runtime probe did not observe the pending request") }
        pending.cancel()
        do {
            _ = try await pending.value
            throw APIError.malformed("HTTP runtime probe did not cancel the request")
        } catch is CancellationError {
            // A cancellation before result delivery is normalized by the transport.
        } catch let error as HTTPClientError where error == .cancelled {
            // Cancellation after dispatch may be delivered by the NIO future.
        }
        let recovered = try await transport.get(url: echoURL)
        guard recovered == Data("loopback-ready".utf8), journal.count == 10 else {
            throw APIError.malformed("HTTP runtime probe did not recover without duplicate requests")
        }
        return Report(schemaVersion: 1, passed: true, scope: "loopback", completedRequests: 9, cancelledRequests: 1)
    }
}

private final class ProbeJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    let heldRequests: AsyncStream<Void>
    private let output: AsyncStream<Void>.Continuation

    init() { (heldRequests, output) = AsyncStream<Void>.makeStream() }
    func record(held: Bool) {
        lock.withLock { requests += 1 }
        if held { output.yield(()) }
    }
    var count: Int { lock.withLock { requests } }
    func finish() { output.finish() }
}

private final class ProbeHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let journal: ProbeJournal
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(journal: ProbeJournal) { self.journal = journal }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body(var bytes): body.writeBuffer(&bytes)
        case .end:
            guard let head else { return }
            let held = head.uri == "/hold"
            journal.record(held: held)
            if held { return }
            let bytes = head.method == .POST ? body : ByteBuffer(string: "loopback-ready")
            let headers = HTTPHeaders([
                ("Content-Length", String(bytes.readableBytes)), ("Connection", "close")
            ])
            context.write(
                wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(bytes))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
