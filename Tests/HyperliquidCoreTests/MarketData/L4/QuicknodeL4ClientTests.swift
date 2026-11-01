import Foundation
import Testing
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import GRPCNIOTransportHTTP2Posix
import SwiftProtobuf
@testable import HyperliquidCore

@available(macOS 15.0, *)
private struct QuicknodeL4ClientHarness {
    private struct StopConsumer: Error, Equatable {}
    private actor Collector {
        var updates: [L4BookUpdate] = []
        func append(_ value: L4BookUpdate) { updates.append(value) }
    }

    private func message(snapshot: Bool = true) -> Hyperliquid_L4BookUpdatesUpdate {
        var diff = Hyperliquid_L4OrderDiff()
        diff.diffType = .init(rawValue: 1)!
        diff.coin = "ETH"
        diff.oid = .max
        diff.user = "0xfedcfedcfedcfedcfedcfedcfedcfedcfedcfedc"
        diff.side = "B"
        diff.px = "100"
        diff.sz = "0.1"
        var message = Hyperliquid_L4BookUpdatesUpdate()
        message.time = 100
        message.height = 100
        message.snapshot = snapshot
        message.diffs = [diff]
        return message
    }

    private struct Service: RegistrableRPCService {
        let messages: [Hyperliquid_L4BookUpdatesUpdate]
        var failure: RPCError?

        func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
            router.registerHandler(
                forMethod: MethodDescriptor(fullyQualifiedService: "hyperliquid.OrderBookStreaming", method: "StreamL4BookUpdates"),
                deserializer: ProtobufDeserializer<Hyperliquid_L4BookUpdatesRequest>(),
                serializer: ProtobufSerializer<Hyperliquid_L4BookUpdatesUpdate>()
            ) { request, _ in
                let request = try await ServerRequest(stream: request)
                #expect(request.message.coins == ["ETH"])
                #expect(Array(request.metadata[stringValues: "x-token"]) == ["fixture-token"])
                return StreamingServerResponse { writer in
                    for message in messages { try await writer.write(message) }
                    if let failure { throw failure }
                    return [:]
                }
            }
        }
    }

    private func run(service: Service, onUpdate: @escaping @Sendable (L4BookUpdate) async throws -> Void) async throws {
        let transport = InProcessTransport()
        try await withGRPCServer(transport: transport.server, services: [service]) { _ in
            try await withGRPCClient(transport: transport.client) { client in
                do {
                    try await QuicknodeL4Client.consume(client: client, coin: "ETH", credential: .init(token: "fixture-token"),
                                                       maximumMessageBytes: 1024, maximumChanges: 10, onUpdate: onUpdate)
                } catch { throw QuicknodeL4Client.sanitizedError(error) }
            }
        }
    }

    func typedRPCDeliversInitialAndReplacementSnapshotThenDetectsStreamEnd() async throws {
        let collector = Collector()
        var replacement = message()
        replacement.diffs = []
        do {
            try await run(service: Service(messages: [message(), replacement])) { await collector.append($0) }
            Issue.record("A closed stream must request reconnection")
        } catch let error as QuicknodeL4StreamError { #expect(error == .streamEnded) }
        let updates = await collector.updates
        #expect(updates.count == 2 && updates.allSatisfy(\.snapshot))
        #expect(updates.first?.changes.first?.identity.oid == .max && updates.last?.changes.isEmpty == true)
        var reducer = try L4BookReducer(environment: .testnet, coin: "ETH")
        for update in updates { _ = try reducer.apply(update) }
        #expect(reducer.orderCount == 0)
    }

    func statusAfterValidMessagesIsNotMistakenForSuccessfulCompletionOrLoggedVerbatim() async throws {
        let collector = Collector()
        let failure = RPCError(code: .resourceExhausted, message: "provider fixture-token detail", metadata: ["x-token": "fixture-token"])
        do {
            try await run(service: Service(messages: [message()], failure: failure)) { await collector.append($0) }
            Issue.record("Expected trailing gRPC status failure")
        } catch let error as QuicknodeL4StreamError {
            #expect(error == .resourceExhausted && !String(reflecting: error).contains("fixture-token"))
        }
        #expect(await collector.updates.count == 1)
        #expect(QuicknodeL4Client.sanitizedError(RPCError(code: .unauthenticated, message: "fixture-token")) as? QuicknodeL4StreamError == .authenticationFailed)
        #expect(QuicknodeL4Client.sanitizedError(RPCError(code: .permissionDenied, message: "fixture-token")) as? QuicknodeL4StreamError == .permissionDenied)
    }

    func consumerFailureAndCancellationStopTheRPCWithoutBeingReclassified() async throws {
        do {
            try await run(service: Service(messages: [message()])) { _ in throw StopConsumer() }
            Issue.record("Expected consumer stop")
        } catch { #expect(error is StopConsumer) }
        do {
            try await run(service: Service(messages: [message()])) { _ in throw CancellationError() }
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
    }

    func http2LoopbackEnforcesResponseSizeBeforeCallback() async throws {
        var large = message()
        large.diffs = (0..<32).map { index in
            var diff = large.diffs[0]
            diff.oid = .max - UInt64(index)
            return diff
        }
        #expect(try large.serializedData().count > 1024)
        for limit in [4096, 1] {
            let collector = Collector()
            try await withGRPCServer(
                transport: .http2NIOPosix(address: .ipv4(host: "127.0.0.1", port: 0), transportSecurity: .plaintext),
                services: [Service(messages: [large])]
            ) { server in
                let address = try #require(try await server.listeningAddress?.ipv4)
                do {
                    try await withGRPCClient(
                        transport: .http2NIOPosix(target: .ipv4(address: address.host, port: address.port), transportSecurity: .plaintext)
                    ) { client in
                        do {
                            try await QuicknodeL4Client.consume(client: client, coin: "ETH", credential: .init(token: "fixture-token"),
                                                               maximumMessageBytes: limit, maximumChanges: 100) { await collector.append($0) }
                        } catch { throw QuicknodeL4Client.sanitizedError(error) }
                    }
                    Issue.record("A closed or oversized stream must report its state")
                } catch let error as QuicknodeL4StreamError {
                    if limit == 1 {
                        // Transport 2.11.0 reports oversized frame decoding as an internal status.
                        #expect(error == .resourceExhausted || error == .transportFailure)
                    } else { #expect(error == .streamEnded) }
                }
            }
            #expect(await collector.updates.count == (limit == 1 ? 0 : 1))
        }
        do {
            _ = try QuicknodeL4BoundedDeserializer(maximumBytes: 1).deserialize([UInt8(255), 255])
            Issue.record("Size must be checked before attempting to decode malformed protobuf")
        } catch let error as RPCError { #expect(error.code == .resourceExhausted) }
    }

    func wireMappingUsesExactIntegersAndValidatesAllDiffsBeforeFiltering() throws {
        let original = message()
        let bytes = try original.serializedData()
        let decoded = try Hyperliquid_L4BookUpdatesUpdate(serializedBytes: bytes)
        #expect(try QuicknodeL4WireMapping.decode(decoded, coin: "ETH", maximumChanges: 10).changes.first?.identity.oid == .max)
        #expect(throws: L4BookError.invalidPayload) { try QuicknodeL4WireMapping.decode(decoded, coin: "ETH", maximumChanges: 0) }
        var invalid = original
        invalid.time = .max
        #expect(throws: L4BookError.invalidPayload) { try QuicknodeL4WireMapping.decode(invalid, coin: "ETH", maximumChanges: 10) }
        invalid = original
        invalid.diffs[0].diffType = .init(rawValue: 99)!
        invalid.diffs[0].coin = "BTC"
        #expect(throws: L4BookError.invalidPayload) { try QuicknodeL4WireMapping.decode(invalid, coin: "ETH", maximumChanges: 10) }
        var remove = original
        remove.diffs[0].diffType = .init(rawValue: 3)!
        remove.diffs[0].sz = ""
        guard case .remove = try QuicknodeL4WireMapping.decode(remove, coin: "ETH", maximumChanges: 10).changes.first else {
            Issue.record("Removal must not require size"); return
        }
    }
}

@Suite struct QuicknodeL4ClientTests {
    @Test(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0)), "gRPC L4 requires macOS 15"))
    func typedRPCDeliversInitialAndReplacementSnapshotThenDetectsStreamEnd() async throws {
        if #available(macOS 15.0, *) { try await QuicknodeL4ClientHarness().typedRPCDeliversInitialAndReplacementSnapshotThenDetectsStreamEnd() }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0)), "gRPC L4 requires macOS 15"))
    func statusAfterValidMessagesIsNotMistakenForSuccessfulCompletionOrLoggedVerbatim() async throws {
        if #available(macOS 15.0, *) { try await QuicknodeL4ClientHarness().statusAfterValidMessagesIsNotMistakenForSuccessfulCompletionOrLoggedVerbatim() }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0)), "gRPC L4 requires macOS 15"))
    func consumerFailureAndCancellationStopTheRPCWithoutBeingReclassified() async throws {
        if #available(macOS 15.0, *) { try await QuicknodeL4ClientHarness().consumerFailureAndCancellationStopTheRPCWithoutBeingReclassified() }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0)), "gRPC L4 requires macOS 15"))
    func http2LoopbackEnforcesResponseSizeBeforeCallback() async throws {
        if #available(macOS 15.0, *) { try await QuicknodeL4ClientHarness().http2LoopbackEnforcesResponseSizeBeforeCallback() }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0)), "gRPC L4 requires macOS 15"))
    func wireMappingUsesExactIntegersAndValidatesAllDiffsBeforeFiltering() throws {
        if #available(macOS 15.0, *) { try QuicknodeL4ClientHarness().wireMappingUsesExactIntegersAndValidatesAllDiffsBeforeFiltering() }
    }
}
