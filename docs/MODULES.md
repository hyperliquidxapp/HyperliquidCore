# HyperliquidCore modules

HyperliquidCore contains Hyperliquid protocol, API and domain behavior. Its public product remains a single Swift module: `import HyperliquidCore`. These directories organize ownership; they do not add products or change public APIs.

Application screens, workspace/window state, rendering, user preferences, Keychain policy, generic recording/replay orchestration and institutional operator workflows belong to the consuming application. Hyperliquid-specific data formats, signing, account rules and market/order state belong here. Supporting CCTP and Unit code describes routes into Hyperliquid; this package is not a general multi-exchange SDK.

## Implementation and tests

| Directory | Responsibility | Representative files |
| --- | --- | --- |
| `Types` | Network identity, wire JSON and shared Hyperliquid models; receipt clock | `Models`, `ReceiptClock` |
| `Networking` | Hyperliquid REST/WS API and bounded NIO transports | `HyperliquidAPI`, `NIOHTTPTransport`, `NIOWebSocketTransport` |
| `MarketData` | Market catalogs, market context, Hyperliquid trades and observation windows | `HIP3Catalog`, `MarketContextBook`, `LargeTradeMonitor`, `TradeObservationWindow` |
| `Accounts` | Hyperliquid account subscriptions, state and history | `AccountStream`, `AccountHistory` |
| `Signing` | Exchange signing, wire serialization and credential proof verification | `EthereumSigning`, `SigningPayload`, `PasskeyVerification` |
| `Trading/Sessions` | Hyperliquid API-wallet authorization and protected-session recovery contracts | `TradingSession`, `TradingSessionRecovery` |
| `Trading/Orders` | Intents, modification, lifecycle, receipts, slippage and venue capacity | `OrderIntent`, `OrderModification`, `OrderLifecycle`, `ExchangeReceipt`, `PerpTradingCapacity`, `PerpOpenInterest` |
| `Trading/Risk` | Hyperliquid order/account checks, fees, margin and position risk observations | `OrderReview`, `OrderRisk`, `PositionRiskMonitor` |
| `Trading/Positions` | Position-scoped intents and isolated-margin actions | `PositionIntent`, `IsolatedMargin` |
| `Trading/Protection` | Parent/TP/SL actions and their read contracts | `ProtectionBatch`, `ProtectionReadClient` |
| `Wallet` | Wallet identity, ownership proofs and local bridge protocol | `WalletConnection`, `WalletOwnership`, `WalletBridge` |
| `Funding` | Hyperliquid transfers and deposit route/account contracts | `FundingIntent`, `BalanceTransfer`, `FundingReadClient`, `DepositAsset`, `BridgeDeposit`, `DepositSourceBalance` |
| `Funding/CCTP` | Circle-based Hyperliquid deposit route, allowance, fees and destination rules | `CCTPDeposit`, `CCTPDepositClient`, `CCTPAllowance`, `CCTPNetworkRegistry` |
| `Funding/Unit` | Unit deposit requests and address encoding used by those routes | `UnitDeposit`, `ZcashDepositEncoding` |
| `Analytics` | Hyperliquid account/market analytical queries and read contracts | `AgentQuery`, `AgentAnalytics`, `AgentReadClient` |

All 51 implementation files are under [Sources/HyperliquidCore](../Sources/HyperliquidCore). The 40 existing test files mirror these directories under [Tests/HyperliquidCoreTests](../Tests/HyperliquidCoreTests). Tests spanning multiple areas stay with the workflow they primarily verify.

## Verification fixtures

Published signing/funding JSON vectors remain in [docs/verification](verification). Nested tests locate the package root through [CoreFixturePaths](../Tests/HyperliquidCoreTests/Fixtures/CoreFixturePaths.swift), so moving a test does not change its fixture selection. The helper also works from an editable package or dependency checkout, without relying on the process working directory or `.git` metadata.

The reorganization preserves every implementation file byte-for-byte. Only six fixture path expressions in five test files change, plus the new shared test helper. No package dependency, target, product, signing payload, request body or domain calculation changes.

```sh
swift test --no-parallel
```

Network probes remain opt-in as described in the [README](../README.md). L4-specific protocol models, adapters and order reducers should follow `MarketData` ownership when implemented; this directory reorganization itself does not add L4 functionality.
