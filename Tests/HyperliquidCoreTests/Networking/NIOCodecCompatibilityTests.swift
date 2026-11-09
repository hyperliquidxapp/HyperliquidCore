import NIOCore
import NIOHTTP1
import NIOWebSocket
import Testing

@testable import HyperliquidCore

@Test func nioCodecsRetainErasedPipelineConformancesOnTheHostRuntime() throws {
    // Exercise the actual casts that fail on macOS 14 with NIO 2.104.0.
    // A current host cannot substitute for running this on the oldest OS.
    let response: any ChannelHandler = ByteToMessageHandler(HTTPResponseDecoder())
    let request: any ChannelHandler = ByteToMessageHandler(HTTPRequestDecoder())
    let webSocket: any ChannelHandler = ByteToMessageHandler(WebSocketFrameDecoder())
    for handler in [response, request, webSocket] {
        #expect(handler is any _ChannelInboundHandler)
    }
    #expect(response is any _ChannelOutboundHandler)
    try NIOTransportRuntime.validate()
    // The cached result must also support repeated transport construction.
    try NIOTransportRuntime.validate()
}
