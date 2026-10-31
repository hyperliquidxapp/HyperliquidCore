import Foundation

/// JSON and MessagePack share this ordered representation. Field order is part of the Hyperliquid action hash.
public indirect enum WireValue: Sendable {
    case map([(String, WireValue)])
    case array([WireValue])
    case string(String)
    case uint(UInt64)
    case int(Int64)
    case bool(Bool)
    case null
    public func jsonData() throws -> Data {
        switch self {
        case .map(let pairs):
            let fields = try pairs.map { key, value in
                // Preserve UTF-8 replacement decoding; encoded JSON is UTF-8 and error text may be invalid.
                // swiftlint:disable:next optional_data_string_conversion
                String(decoding: try JSONEncoder().encode(key), as: UTF8.self) + ":"
                    // Preserve UTF-8 replacement decoding; encoded JSON is UTF-8 and error text may be invalid.
                    // swiftlint:disable:next optional_data_string_conversion
                    + String(decoding: try value.jsonData(), as: UTF8.self)
            }
            return Data(("{" + fields.joined(separator: ",") + "}").utf8)
        case .array(let values):
            return Data(
                // Preserve UTF-8 replacement decoding; encoded JSON is UTF-8 and error text may be invalid.
                ("["
                    // swiftlint:disable:next optional_data_string_conversion
                    + (try values.map { String(decoding: try $0.jsonData(), as: UTF8.self) })
                    .joined(separator: ",")
                    + "]").utf8)
        case .string(let value): return try JSONEncoder().encode(value)
        case .uint(let value): return Data(String(value).utf8)
        case .int(let value): return Data(String(value).utf8)
        case .bool(let value): return Data((value ? "true" : "false").utf8)
        case .null: return Data("null".utf8)
        }
    }
    public func messagePack() -> Data {
        var output = Data()
        switch self {
        case .map(let fields):
            Self.length(fields.count, fix: 0x80, limit: 16, tag16: 0xde, tag32: 0xdf, into: &output)
            for (key, value) in fields {
                output.append(WireValue.string(key).messagePack())
                output.append(value.messagePack())
            }
        case .array(let values):
            Self.length(values.count, fix: 0x90, limit: 16, tag16: 0xdc, tag32: 0xdd, into: &output)
            for value in values { output.append(value.messagePack()) }
        case .string(let value):
            let bytes = Data(value.utf8)
            let count = bytes.count
            if count < 32 {
                output.append(0xa0 | UInt8(count))
            } else if count <= 255 {
                output.append(0xd9)
                output.append(UInt8(count))
            } else if count <= 65535 {
                output.append(0xda)
                output.append(contentsOf: Self.bigEndian(UInt64(count), bytes: 2))
            } else {
                output.append(0xdb)
                output.append(contentsOf: Self.bigEndian(UInt64(count), bytes: 4))
            }
            output.append(bytes)
        case .uint(let value):
            if value < 128 {
                output.append(UInt8(value))
            } else if value <= 255 {
                output.append(0xcc)
                output.append(UInt8(value))
            } else if value <= 65535 {
                output.append(0xcd)
                output.append(contentsOf: Self.bigEndian(value, bytes: 2))
            } else if value <= UInt64(UInt32.max) {
                output.append(0xce)
                output.append(contentsOf: Self.bigEndian(value, bytes: 4))
            } else {
                output.append(0xcf)
                output.append(contentsOf: Self.bigEndian(value, bytes: 8))
            }
        case .int(let value):
            if value >= 0 {
                output.append(WireValue.uint(UInt64(value)).messagePack())
            } else if value >= -32 {
                output.append(UInt8(truncatingIfNeeded: value))
            } else {
                let width: Int =
                    value >= Int64(Int8.min)
                    ? 1
                    : value >= Int64(Int16.min) ? 2 : value >= Int64(Int32.min) ? 4 : 8
                output.append(width == 1 ? 0xd0 : width == 2 ? 0xd1 : width == 4 ? 0xd2 : 0xd3)
                output.append(contentsOf: Self.bigEndian(UInt64(bitPattern: value), bytes: width))
            }
        case .bool(let value): output.append(value ? 0xc3 : 0xc2)
        case .null: output.append(0xc0)
        }
        return output
    }
    static func bigEndian(_ value: UInt64, bytes: Int) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    private static func length(
        _ count: Int, fix: UInt8, limit: Int, tag16: UInt8, tag32: UInt8, into output: inout Data
    ) {
        if count < limit {
            output.append(fix | UInt8(count))
        } else if count <= 65535 {
            output.append(tag16)
            output.append(contentsOf: bigEndian(UInt64(count), bytes: 2))
        } else {
            output.append(tag32)
            output.append(contentsOf: bigEndian(UInt64(count), bytes: 4))
        }
    }
}

public enum Keccak256 {
    private static let rounds: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808a, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808b, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008a, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000a,
        0x0000_0000_8000_808b, 0x8000_0000_0000_008b, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800a, 0x8000_0000_8000_000a,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008
    ]
    private static let rotations = [
        0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56,
        14
    ]
    public static func hash(_ data: Data) -> Data {
        let rate = 136
        var bytes = [UInt8](data)
        bytes.append(0x01)  // Keccak domain padding; SHA3's 0x06 is incompatible.
        while bytes.count % rate != 0 { bytes.append(0) }
        bytes[bytes.count - 1] |= 0x80
        var state = [UInt64](repeating: 0, count: 25)
        for start in stride(from: 0, to: bytes.count, by: rate) {
            for index in 0..<rate {
                state[index / 8] ^= UInt64(bytes[start + index]) << ((index % 8) * 8)
            }
            permute(&state)
        }
        return Data((0..<32).map { UInt8(truncatingIfNeeded: state[$0 / 8] >> (($0 % 8) * 8)) })
    }
    private static func rotate(_ value: UInt64, _ count: Int) -> UInt64 {
        count == 0 ? value : (value << count) | (value >> (64 - count))
    }
    private static func permute(_ a: inout [UInt64]) {
        for constant in rounds {
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 { c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotate(c[(x + 1) % 5], 1)
                for y in 0..<5 { a[x + 5 * y] ^= d }
            }
            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotate(a[x + 5 * y], rotations[x + 5 * y])
                }
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    a[x + 5 * y] =
                        b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
                }
            }
            a[0] ^= constant
        }
    }
}

extension Data {
    public var hex: String { "0x" + map { String(format: "%02x", $0) }.joined() }
    public init?(hex: String) {
        let input = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard input.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var cursor = input.startIndex
        while cursor < input.endIndex {
            let end = input.index(cursor, offsetBy: 2)
            guard let byte = UInt8(input[cursor..<end], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = end
        }
        self.init(bytes)
    }
}

public struct WalletSignature: Sendable {
    public let r: String
    public let s: String
    public let v: UInt64
    public init(hex: String) throws {
        guard let bytes = Data(hex: hex), bytes.count == 65 else {
            throw APIError.malformed("Wallet returned an invalid signature")
        }
        r = bytes.prefix(32).hex
        s = bytes.dropFirst(32).prefix(32).hex
        let recovery = UInt64(bytes.last!)
        v = recovery < 2 ? recovery + 27 : recovery
        guard v == 27 || v == 28 else {
            throw APIError.malformed("Unsupported signature recovery value")
        }
        guard bytes.prefix(32).contains(where: { $0 != 0 }),
              bytes.dropFirst(32).prefix(32).contains(where: { $0 != 0 })
        else { throw APIError.malformed("Signature scalar must not be zero") }
    }
    public var wire: WireValue { .map([("r", .string(r)), ("s", .string(s)), ("v", .uint(v))]) }
}

public enum ExchangeAction {
    public static func orderWire(
        assetID: Int, buy: Bool, price: String, size: String, reduceOnly: Bool,
        kind: OrderKind, trigger: String? = nil, cloid: String? = nil,
        triggerExecution: TriggerExecution = .limit, timeInForce: TimeInForce = .gtc
    ) -> WireValue {
        let type: WireValue
        if let trigger {
            type = .map([
                (
                    "trigger",
                    .map([
                        ("isMarket", .bool(triggerExecution == .market)),
                        ("triggerPx", .string(trigger)),
                        ("tpsl", .string(kind == .takeProfit ? "tp" : "sl"))
                    ])
                )
            ])
        } else {
            type = .map([
                (
                    "limit",
                    .map([
                        (
                            "tif",
                            .string(
                                kind == .market ? TimeInForce.ioc.rawValue : timeInForce.rawValue)
                        )
                    ])
                )
            ])
        }
        var pairs: [(String, WireValue)] = [
            ("a", .uint(UInt64(assetID))), ("b", .bool(buy)), ("p", .string(price)),
            ("s", .string(size)),
            ("r", .bool(reduceOnly)), ("t", type)
        ]
        if let cloid { pairs.append(("c", .string(cloid))) }
        return .map(pairs)
    }
    public static func place(_ intent: OrderIntent, cloid: String? = nil) -> WireValue {
        let wire = orderWire(
            assetID: intent.market.assetID, buy: intent.side == .buy, price: intent.price,
            size: intent.protectionSizing == .entirePosition ? "0" : intent.size,
            reduceOnly: intent.reduceOnly, kind: intent.kind, trigger: intent.trigger, cloid: cloid,
            triggerExecution: intent.triggerExecution, timeInForce: intent.timeInForce)
        if intent.protectionSizing == .entirePosition {
            return .map([
                ("type", .string("order")), ("orders", .array([wire])),
                ("grouping", .string("positionTpsl"))
            ])
        }
        return orderAction(wires: [wire])
    }
    public static func orderAction(wires: [WireValue]) -> WireValue {
        .map([("type", .string("order")), ("orders", .array(wires)), ("grouping", .string("na"))])
    }
    public static func cancel(assetID: Int, oid: UInt64) -> WireValue {
        .map([
            ("type", .string("cancel")),
            ("cancels", .array([.map([("a", .uint(UInt64(assetID))), ("o", .uint(oid))])]))
        ])
    }
    public static func modify(oid: UInt64, intent: OrderIntent, cloid: String? = nil) -> WireValue {
        .map([
            ("type", .string("batchModify")),
            (
                "modifies",
                .array([
                    .map([
                        ("oid", .uint(oid)),
                        (
                            "order",
                            orderWire(
                                assetID: intent.market.assetID, buy: intent.side == .buy,
                                price: intent.price,
                                size: intent.protectionSizing == .entirePosition
                                    ? "0" : intent.size,
                                reduceOnly: intent.reduceOnly, kind: intent.kind,
                                trigger: intent.trigger, cloid: cloid,
                                triggerExecution: intent.triggerExecution,
                                timeInForce: intent.timeInForce)
                        )
                    ])
                ])
            ),
            // Required for triggers and executable replacements. The review
            // discloses that placement can proceed if the original cancel races.
            ("a", .bool(true))
        ])
    }
    public static func leverage(assetID: Int, value: Int, cross: Bool) -> WireValue {
        .map([
            ("type", .string("updateLeverage")), ("asset", .uint(UInt64(assetID))),
            ("isCross", .bool(cross)),
            ("leverage", .uint(UInt64(value)))
        ])
    }
}

public enum SigningPayload {
    public static func actionHash(
        action: WireValue, nonce: UInt64, vaultAddress: String? = nil, expiresAfter: UInt64? = nil
    ) throws -> Data {
        var bytes = action.messagePack()
        bytes.append(contentsOf: WireValue.bigEndian(nonce, bytes: 8))
        if let vaultAddress {
            guard Address.isValid(vaultAddress), let address = Data(hex: vaultAddress),
                  address.count == 20
            else {
                throw APIError.malformed("Invalid vault address")
            }
            bytes.append(1)
            bytes.append(address)
        } else {
            bytes.append(0)
        }
        if let expiresAfter {
            bytes.append(0)
            bytes.append(contentsOf: WireValue.bigEndian(expiresAfter, bytes: 8))
        }
        return Keccak256.hash(bytes)
    }
    public static func typedData(
        action: WireValue, nonce: UInt64, environment: NetworkEnvironment,
        vaultAddress: String? = nil,
        expiresAfter: UInt64? = nil
    ) throws -> JSONValue {
        let hash = try actionHash(
            action: action, nonce: nonce, vaultAddress: vaultAddress, expiresAfter: expiresAfter)
        func field(_ name: String, _ type: String) -> JSONValue {
            .object(["name": .string(name), "type": .string(type)])
        }
        return .object([
            "domain": .object([
                "name": .string("Exchange"), "version": .string("1"), "chainId": .integer(1337),
                "verifyingContract": .string("0x0000000000000000000000000000000000000000")
            ]),
            "types": .object([
                "EIP712Domain": .array([
                    field("name", "string"), field("version", "string"),
                    field("chainId", "uint256"),
                    field("verifyingContract", "address")
                ]),
                "Agent": .array([field("source", "string"), field("connectionId", "bytes32")])
            ]),
            "primaryType": .string("Agent"),
            "message": .object([
                "source": .string(environment == .mainnet ? "a" : "b"),
                "connectionId": .string(hash.hex)
            ])
        ])
    }
    public static func request(
        action: WireValue, signature: WalletSignature, nonce: UInt64, expiresAfter: UInt64
    )
    throws -> Data {
        try WireValue.map([
            ("action", action), ("nonce", .uint(nonce)), ("signature", signature.wire),
            ("expiresAfter", .uint(expiresAfter))
        ]).jsonData()
    }
}
