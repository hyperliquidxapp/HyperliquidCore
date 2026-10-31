// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "L4ProtocolCodegen",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0")
    ],
    targets: [
        .target(
            name: "L4Protocol",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Protocol",
            plugins: [.plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")]
        )
    ]
)
