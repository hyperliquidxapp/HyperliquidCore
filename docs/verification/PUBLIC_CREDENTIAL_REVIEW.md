# Public repository credential review — 2026-11-01

Reviewed SDK revision: `99bc413b4230cbc6e0e9fe81b92ceacfccf44221`.

The GitHub repository was already **public** when checked. No real private key, mnemonic, API credential, credential-bearing provider URL or private-key container was identified by the checks below. This is a bounded credential/disclosure review, not a formal security audit or a guarantee that every possible secret format is detectable.

## Scope and evidence

- Gitleaks **8.30.1**, official macOS arm64 release verified against its published SHA-256 checksum, scanned a clean archive of tracked HEAD content and Git history across all reachable refs. All scanner reports/logs were redacted; repository content was not uploaded to an external scanning service.
- The Git history inventory contained **20 reachable commits and 169 unique text blobs**. A supplemental scan read every reachable blob for private-key containers, credentials embedded in URLs, Quicknode URL tokens, mnemonic literals and named wallet-key literals.
- Neither of the two earlier account-specific public wallet addresses occurs in current SDK sources, tests or documentation.
- SDK regression: **240 tests in 6 suites passed** after fixture cleanup, 0.648 s (build 6.43 s). No user wallet signing or fund transfer was performed.
- GitHub's secret-scanning alerts API returned **Secret scanning is disabled on this repository**. This was not counted as an independent clean scan.

The official scanner binary SHA-256 was `b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5`.

## Reviewed scanner findings

Gitleaks reported eight findings in current files and the same eight original additions in history, all under `generic-api-key`:

| Content | Count | Classification |
| --- | --- | --- |
| Expected public signing-wallet address in SigningTests | 1 | Address derived from the published synthetic signing key |
| USDC contract addresses asserted in CCTP tests | 3 | Public 20-byte contract addresses |
| TokenMessenger addresses in CCTP JSON vectors | 4 | Public 20-byte contract addresses |

All eight matched literals are `0x` followed by 40 hexadecimal digits. None is a private key or API credential. They remain in the tests because they verify public protocol data.

The supplemental scan found five named fixed wallet-key literals. Each exactly matched the existing public synthetic signing fixture described in [THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md). It found no other named wallet-key literal, mnemonic literal, credential-bearing URL or private-key container. Other hashes, signatures, public guardian keys and transaction calldata in protocol fixtures are expected public cryptographic test data.

## Configuration and historical disclosure

Builder address and product fee policy belong in the consuming App. SDK Builder APIs take these values as arguments and contain no HyperliquidX fee destination default. New Builder signing vectors use a synthetic destination.

Older account/L4/session fixtures now use synthetic accounts. Unit fixture responses were regenerated for a synthetic owner through the public Unit API and frozen with genuine guardian signatures. The production guardian keys, two-party quorum, signing payload checks and network binding were not weakened.

Previously published commits still contain the earlier public wallet addresses and associated historical fixtures. Those are public account identifiers, with possible account-linkage implications, rather than signing credentials. This review did **not** rewrite published Git history, delete branches or force push. Current-source cleanup does not erase earlier public copies.

Ignored/untracked files, local Keychain contents, local wallets, build caches, unreachable Git objects and GitHub-hosted artifacts were outside the tracked-content review. No real wallet Keychain entry or private key was read.

## Public-source conclusion

The checked content provides no credential-leak blocker to keeping this SDK public or merging the reviewed changes. The package has an MIT license and [third-party notices](../../THIRD_PARTY_NOTICES.md). Enable GitHub secret scanning and push protection when available to add ongoing detection; these settings were left unchanged during this review.

A separately authorized history-disclosure cleanup would be required if removing the earlier public account identifiers from published history is a release requirement.

