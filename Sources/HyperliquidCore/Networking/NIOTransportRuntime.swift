import NIOCore
import NIOHTTP1
import NIOWebSocket

/// Checks the erased codec conformances used when NIO installs its handlers.
/// This performs no network I/O and can also run in a packaged-app smoke test.
public enum NIOTransportRuntime {
    private static let compatibility: Result<Void, Error> = Result {
        let handlers: [(String, any ChannelHandler, Bool)] = [
            ("HTTP response", ByteToMessageHandler(HTTPResponseDecoder()), true),
            ("HTTP request", ByteToMessageHandler(HTTPRequestDecoder()), false),
            ("WebSocket", ByteToMessageHandler(WebSocketFrameDecoder()), false)
        ]
        for (name, handler, requiresOutbound) in handlers {
            // Keep the same dynamic checks as ChannelHandlerContext, but return
            // an error before pipeline construction can hit its precondition.
            guard handler is any _ChannelInboundHandler,
                  !requiresOutbound || handler is any _ChannelOutboundHandler
            else {
                throw APIError.malformed("NIO \(name) decoder is incompatible with this system runtime")
            }
        }
    }

    public static func validate() throws {
        try compatibility.get()
    }
}
