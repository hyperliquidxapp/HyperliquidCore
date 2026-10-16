# HyperliquidCore

Swift protocol and domain library extracted from HyperliquidX. This is a community project, not an official Hyperliquid SDK.

## Requirements

Xcode 26.3 or later (Swift 6.2+) to build; macOS 14 or later to run. Other platforms are not currently validated; the implementation uses Apple Security, CryptoKit, Network and Darwin APIs.

## Scope

- REST and WebSocket transports, market catalogs (including HIP-3), candles and order books.
- Account streams, history, order validation, slippage and position risk calculations.
- Ethereum signing, temporary trading sessions, wallet connection models and a local browser-wallet bridge.
- Transfers and deposit routing, including CCTP and Unit-related models and clients.

The package contains no app screens, chart rendering, layout models, Touch ID workflow, Reown dependency, or bundled wallet web page. Applications provide their own UI and wallet integration. APIs are initially experimental; releases before 1.0 may change them.

## Swift Package Manager

Add the package and product to your manifest:

```swift
.package(url: "https://github.com/hyperliquidxapp/HyperliquidCore.git", exact: "0.1.0")
// In your target dependencies:
.product(name: "HyperliquidCore", package: "HyperliquidCore")
```

The initial release is `0.1.0`.

```swift
import HyperliquidCore

let api = HyperliquidAPI(environment: .testnet)
let (markets, contexts) = try await api.catalog()
let book = try await api.book(coin: "BTC")
print(markets.count, contexts.count, book)
```

Signing and exchange submission are separate from public market reads. Wallet authorization, secret storage and user confirmation belong to the consuming application. Network deployments and supported funding routes can change; validate them before submitting transactions.

## Development

```sh
swift build
swift test
```

The default suite uses deterministic fixtures and loopback networking. Public network probes are opt-in with `HL_LIVE_PROBE=1`; account probes additionally require `HL_TESTNET_ACCOUNT`. CCTP deployment probes use `HL_CCTP_NETWORK_PROBE=1`. Do not use real private keys in test fixtures.

Fixture JSON under `docs/verification/` is required by the signing and funding tests. Keep it when copying or checking out this package.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
