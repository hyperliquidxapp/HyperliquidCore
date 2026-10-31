# Hyperliquid L4 book

`MarketData/L4` contains Hyperliquid-specific order state and Quicknode's read-only wire adapter. Application configuration persistence, credential storage, quality state, recording and reconnect policy belong to the consuming application.

## Coverage

`L4BookReducer` retains an exact OID map and per-price membership/quantity indexes. It projects a bounded number of aggregated price levels for display while retaining orders beyond that projection. Sizes and price keys use checked `Decimal` arithmetic. Updates carry absolute remaining size. The book changes only through the authoritative order-diff stream; trades and order-status observations must not subtract quantity again.

Each order includes OID, pseudonymous wallet address, coin, side, price and current size. A wallet address identifies an on-chain participant; it does not establish a real-world person or institution. `ordersSortedByID` supports deterministic inspection, with no FIFO or queue-priority claim.

The selected RPC is `hyperliquid.OrderBookStreaming/StreamL4BookUpdates`: typed NEW/UPDATE/REMOVE state changes. `StreamL4Book` offers fuller order and lifecycle detail and is a separate integration; this implementation does not subscribe to it. Trigger and TP/SL orders have a separate provider stream and are outside resting-book depth.

Every `snapshot: true` batch replaces the complete state, including a mid-stream snapshot at the current height. Non-snapshot heights must increase; jumps are allowed because filtered streams need not emit every chain block. Increasing height alone cannot prove that a provider delivered all changes. A fault clears the reducer's actionable state and requires a fresh snapshot. The accepted height/time watermark survives faults within a connection. Only `resetForNewConnection()` clears that watermark. The application may keep an earlier immutable view visible with stale provenance.

## Client

The reducer and configuration models support macOS 14. The official gRPC Swift 2 transport requires macOS 15. Public APIs that open gRPC connections are availability-gated; the package deployment target remains macOS 14.

```swift
let configuration = try QuicknodeL4Configuration(
    environment: .testnet,
    endpoint: "your-endpoint.hype-testnet.quiknode.pro:10000"
)
// Obtain this read-only credential through the application's secret store.
let credential = try QuicknodeL4Credential(token: tokenFromSecretStore)
if #available(macOS 15.0, *) {
    try await QuicknodeL4Client(configuration: configuration).stream(
        coin: "ETH", credential: credential
    ) { update in
        try await engine.apply(update)
    }
}
```

`engine` above is an application-owned actor containing `L4BookReducer`. The callback is awaited before consuming the next batch. The caller cancels the enclosing task to close the connection and restarts with a fresh reducer baseline. A normally closed subscription throws `streamEnded`; provider errors are reduced to typed categories without provider text or metadata. Errors thrown by the consumer callback propagate to the caller. This client does not automatically retry or share subscriptions.

The client subscribes to one coin on the server, uses TLS with standard certificate validation, and sends `x-token` metadata. Hostnames are validated against the configured Quicknode network; URLs containing credentials, paths, queries or fragments are rejected. Credentials are not Codable and their normal descriptions/mirrors redact the value. The SDK does not save tokens, invoke Keychain, or access trading credentials.

Default limits are 64 MiB per protobuf response, 1,000,000 changes per batch and 500,000 retained orders per reducer. Explicit upper bounds are 128 MiB, 2,000,000 changes and 2,000,000 orders. Limits are independent: receiving a response successfully does not bypass reducer capacity. A larger market exceeding the configured limits requires reconfiguration and a new baseline. Source timestamps, authenticated coverage, HIP-3 support, ordering and long-running recovery still require provider-specific live validation.

## Reproducible protocol code

The [protocol subset](../Sources/HyperliquidCore/MarketData/L4/Quicknode/Protocol/quicknode_l4.proto) keeps Quicknode's published package, RPC name, fields and enum values. The official SwiftPM build plugin generates internal message/client types into the build directory. No generated checkout files are edited or used as deliverables. Runtime and generator versions are pinned in `Package.swift` and `Package.resolved`.

```sh
swift test --no-parallel
```

The suite covers reducer/reference equivalence, whole-state resets, checked arithmetic, malformed batches, capacity, network/credential validation, typed in-process RPC delivery, trailing error status, consumer cancellation and an actual HTTP/2 loopback message-size check. These are local contract tests, not evidence that an authenticated provider endpoint is delivering complete production state.

## Primary contracts

- [Quicknode typed L4 updates](https://www.quicknode.com/docs/hyperliquid/datasets/l4-book-updates)
- [Quicknode protobuf definitions](https://github.com/quiknode-labs/hypercore-grpc-examples/blob/main/proto/orderbook.proto)
- [Quicknode gRPC connection and authentication](https://www.quicknode.com/docs/hyperliquid/grpc-api)
- [gRPC Swift 2](https://github.com/grpc/grpc-swift-2)
- [gRPC HTTP/2 transport](https://github.com/grpc/grpc-swift-nio-transport)
- [gRPC Swift protobuf generation](https://github.com/grpc/grpc-swift-protobuf)
