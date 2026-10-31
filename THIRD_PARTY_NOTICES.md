# Third-party notices

Dependencies are fetched by Swift Package Manager and retain their own licenses and notices. They are not relicensed by this package's MIT license.

| Dependency | Source | License |
| --- | --- | --- |
| swift-secp256k1 | https://github.com/21-DOT-DEV/swift-secp256k1 | MIT; bundled libsecp256k1 has its own MIT notice |
| SwiftNIO | https://github.com/apple/swift-nio | Apache-2.0, plus bundled component notices |
| SwiftNIO SSL | https://github.com/apple/swift-nio-ssl | Apache-2.0, plus BoringSSL notices |
| AsyncHTTPClient | https://github.com/swift-server/async-http-client | Apache-2.0 |
| gRPC Swift 2 | https://github.com/grpc/grpc-swift-2 | Apache-2.0 |
| gRPC Swift NIO transport | https://github.com/grpc/grpc-swift-nio-transport | Apache-2.0 |
| gRPC Swift protobuf | https://github.com/grpc/grpc-swift-protobuf | Apache-2.0 |
| SwiftProtobuf | https://github.com/apple/swift-protobuf | Apache-2.0; bundled protobuf compiler components retain their own notices |

Consult each resolved dependency's LICENSE/NOTICE files for full terms, including transitive dependencies. Exact revisions are recorded in Package.resolved.

Signing test vectors include published examples from the MIT-licensed [Hyperliquid Python SDK](https://github.com/hyperliquid-dex/hyperliquid-python-sdk). The repeating test private key in SigningTests.swift is a publicly documented fixture, not an application credential. The JSON vectors contain synthetic accounts, fixed nonces and expected signatures for protocol compatibility tests.

The L4 protobuf schema is a wire-compatible subset of the published [Quicknode HyperCore example definition](https://github.com/quiknode-labs/hypercore-grpc-examples/blob/main/proto/orderbook.proto). Generated clients are produced by the official gRPC Swift build plugin; generated files preserve the generator headers.
