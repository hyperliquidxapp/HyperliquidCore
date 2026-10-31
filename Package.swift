// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HyperliquidCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HyperliquidCore", targets: ["HyperliquidCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.23.2"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.36.2"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.11.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0")
    ],
    targets: [
        .target(
            name: "HyperliquidCore",
            dependencies: [
                .product(name: "libsecp256k1", package: "swift-secp256k1"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationEssentialsCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            plugins: [.plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")]),
        .testTarget(name: "HyperliquidCoreTests", dependencies: ["HyperliquidCore"])
    ]
)
