import Foundation
import GRPCCore
import GRPCProtobuf
import GRPCNIOTransportHTTP2Posix

public enum QuicknodeL4StreamError: Error, Equatable, Sendable {
    case invalidLimits, streamEnded, authenticationFailed, permissionDenied, resourceExhausted, transportFailure
}

/// One read-only, server-filtered coin stream. The caller owns cancellation and reconnect policy.
/// Each callback completes before the next batch is consumed; there is no unbounded task-per-update queue.
@available(macOS 15.0, *)
public struct QuicknodeL4Client: Sendable {
    public let configuration: QuicknodeL4Configuration

    public init(configuration: QuicknodeL4Configuration) { self.configuration = configuration }

    public func stream(
        coin: String, credential: QuicknodeL4Credential,
        maximumMessageBytes: Int = 64 * 1024 * 1024, maximumChanges: Int = 1_000_000,
        onUpdate: @escaping @Sendable (L4BookUpdate) async throws -> Void
    ) async throws {
        guard (1...128 * 1024 * 1024).contains(maximumMessageBytes), (1...2_000_000).contains(maximumChanges) else {
            throw QuicknodeL4StreamError.invalidLimits
        }
        // Validate the market before opening any network connection.
        _ = try L4BookUpdate(coin: coin, height: 0, time: 0, snapshot: true, changes: [])
        do {
            try await withGRPCClient(
                transport: .http2NIOPosix(
                    target: .dns(host: configuration.host, port: configuration.port),
                    transportSecurity: .tls
                )
            ) { client in
                try await Self.consume(client: client, coin: coin, credential: credential,
                                       maximumMessageBytes: maximumMessageBytes, maximumChanges: maximumChanges,
                                       onUpdate: onUpdate)
            }
        } catch { throw Self.sanitizedError(error) }
    }

    private struct ConsumerError: Error { let underlying: any Error }

    static func sanitizedError(_ error: any Error) -> any Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        if let error = error as? ConsumerError { return error.underlying }
        if error is L4BookError || error is QuicknodeL4StreamError { return error }
        if let error = error as? RPCError {
            // Keep provider status text, causes and metadata out of ordinary App diagnostics.
            switch error.code {
            case .unauthenticated: return QuicknodeL4StreamError.authenticationFailed
            case .permissionDenied: return QuicknodeL4StreamError.permissionDenied
            case .resourceExhausted: return QuicknodeL4StreamError.resourceExhausted
            default: return QuicknodeL4StreamError.transportFailure
            }
        }
        return QuicknodeL4StreamError.transportFailure
    }

    static func consume<Transport: ClientTransport>(
        client: GRPCClient<Transport>, coin: String, credential: QuicknodeL4Credential,
        maximumMessageBytes: Int, maximumChanges: Int,
        onUpdate: @escaping @Sendable (L4BookUpdate) async throws -> Void
    ) async throws {
        var request = Hyperliquid_L4BookUpdatesRequest()
        request.coins = [coin]
        var options = CallOptions.defaults
        // HTTP/2 transport 2.11.0 uses maxRequestMessageBytes for its inbound frame limit.
        // Set both bounds; the deserializer independently checks the response before protobuf allocation.
        options.maxRequestMessageBytes = max(1024, maximumMessageBytes)
        options.maxResponseMessageBytes = maximumMessageBytes
        options.waitForReady = false
        let service = Hyperliquid_OrderBookStreaming.Client(wrapping: client)
        let rpcRequest = ClientRequest(message: request, metadata: ["x-token": .string(credential.metadataValue)])
        try await service.streamL4BookUpdates(
            request: rpcRequest, serializer: ProtobufSerializer<Hyperliquid_L4BookUpdatesRequest>(),
            deserializer: QuicknodeL4BoundedDeserializer(maximumBytes: maximumMessageBytes), options: options
        ) { response in
            for try await message in response.messages {
                try Task.checkCancellation()
                let update = try QuicknodeL4WireMapping.decode(message, coin: coin, maximumChanges: maximumChanges)
                do { try await onUpdate(update) } catch { throw ConsumerError(underlying: error) }
            }
        }
        throw QuicknodeL4StreamError.streamEnded
    }
}

@available(macOS 15.0, *)
struct QuicknodeL4BoundedDeserializer: MessageDeserializer {
    let maximumBytes: Int

    func deserialize<Bytes: GRPCContiguousBytes>(_ bytes: Bytes) throws -> Hyperliquid_L4BookUpdatesUpdate {
        guard bytes.count <= maximumBytes else { throw RPCError(code: .resourceExhausted, message: "L4 message exceeds configured size") }
        return try ProtobufDeserializer<Hyperliquid_L4BookUpdatesUpdate>().deserialize(bytes)
    }
}
