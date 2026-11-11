# HyperliquidCore

Swift protocol and domain library extracted from HyperliquidX. This is a community project, not an official Hyperliquid SDK.

## Requirements

Build and test with Xcode 27.1 (27A9275), Apple Swift 6.4 (swiftlang-6.4.0.34.1) and macOS SDK 27.0 (26A425), pinned in `build-toolchain.json` to match the consuming application's local, preview and release builds. macOS 14 or later is supported at runtime. The optional gRPC L4 client requires macOS 15 or later; reducers and existing REST/WS APIs retain macOS 14 support. Other platforms are not currently validated; the implementation uses Apple Security, CryptoKit, Network and Darwin APIs.

## Scope

- REST and WebSocket transports, market catalogs (including HIP-3), candles and order books.
- Full per-order L4 reconstruction and a configurable Quicknode typed gRPC client; see [L4 coverage and contracts](docs/L4_BOOK.md).
- Account streams, history, order validation, slippage and position risk calculations.
- Ethereum signing, temporary trading sessions, wallet connection models and a local browser-wallet bridge.
- Transfers and deposit routing, including CCTP and Unit-related models and clients.

The package contains no app screens, chart rendering, layout models, Touch ID workflow, Reown dependency, or bundled wallet web page. Applications provide their own UI and wallet integration. APIs are initially experimental; releases before 1.0 may change them.

## Module organization

Implementation and tests are grouped by Hyperliquid domain: types, networking, market data, accounts, trading, signing, wallet, funding and analytics. See [module ownership and fixture paths](docs/MODULES.md). Public imports remain `import HyperliquidCore`.

## Swift Package Manager

Add the package and product to your manifest:

```swift
.package(url: "https://github.com/hyperliquidxapp/HyperliquidCore.git", exact: "0.1.1")
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
python3 scripts/build-toolchain.py swift build --force-resolved-versions
python3 scripts/build-toolchain.py swift test --force-resolved-versions
```

The default suite uses deterministic fixtures and loopback networking. Public network probes are opt-in with `HL_LIVE_PROBE=1`; account probes additionally require `HL_TESTNET_ACCOUNT`. CCTP deployment probes use `HL_CCTP_NETWORK_PROBE=1`. Do not use real private keys in test fixtures.

Select the pinned Xcode with `DEVELOPER_DIR` or `xcode-select`. The wrapper checks exact Xcode, Swift and SDK versions/builds and executes commands using that Xcode's tools. CI uses the same check on the `xcode-27` runner. Keep the application and SDK pins/checkers synchronized during deliberate upgrades; the host OS can differ, and macOS 14 runtime validation remains separate.

`NIOTransportRuntime.validate()` checks the erased HTTP/WebSocket decoder conformances without network access. Transports check its cached result before opening pipelines. NIO is pinned to 2.103.0 to avoid the older-runtime codec regression in [NIO #3764](https://github.com/apple/swift-nio/issues/3764); gRPC NIO transport 2.10.0 preserves that dependency compatibility. A test on a newer OS does not replace validation on macOS 14.

`try await NIOHTTPRuntimeProbe.run()` exercises the real transport against loopback: eight parallel POSTs preserving exact bytes, an observed in-flight cancellation and successful recovery. HTTP requests use the bounded future/delegate API, avoiding AsyncHTTPClient's crashing `executeCancellable` async wrapper on the reported macOS 14 runtime. TLS validation, the 20-second deadline, 16 MiB response limit, redirect rejection and no application-level retry remain in force.

Fixture JSON under `docs/verification/` is required by the signing and funding tests. Keep it when copying or checking out this package.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
