import Foundation
import Security

public enum WalletAccessState: String, Sendable {
    case watchOnly, walletConnected, authenticated
}

/// Ephemeral ownership proof for this exact connection. It is never a trading authorization.
public struct WalletOwnershipProof: Sendable {
    public let connection: WalletConnection
    public let environment: NetworkEnvironment
    public let validUntil: UInt64
}

/// A fixed EIP-712 challenge, bound to a fresh nonce, App domain, network and connection ID.
public struct WalletOwnershipChallenge: Sendable {
    public let connection: WalletConnection
    public let environment: NetworkEnvironment
    public let nonce: Data
    public let issuedAt: UInt64
    public let expiresAt: UInt64
    public static let appDomain = "hypexapp.xyz"
    private static let schema =
        "WalletOwnership(address wallet,string appDomain,string network,string connectionID,bytes32 nonce,uint64 issuedAt,uint64 expiresAt)"

    public init(
        connection: WalletConnection, environment: NetworkEnvironment, now: UInt64 = TradingSession.timestamp
    ) throws {
        guard now <= UInt64.max - 600_000 else { throw WalletError.invalid("Invalid authentication clock") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WalletError.invalid("Unable to create a wallet ownership challenge")
        }
        self.connection = connection
        self.environment = environment
        nonce = Data(bytes)
        issuedAt = now
        expiresAt = now + 120_000
    }

    public var typedData: JSONValue {
        func field(_ name: String, _ type: String) -> JSONValue {
            .object(["name": .string(name), "type": .string(type)])
        }
        return .object([
            "types": .object([
                "EIP712Domain": .array([
                    field("name", "string"), field("version", "string"), field("chainId", "uint256"),
                    field("verifyingContract", "address")
                ]),
                "WalletOwnership": .array([
                    field("wallet", "address"), field("appDomain", "string"), field("network", "string"),
                    field("connectionID", "string"), field("nonce", "bytes32"),
                    field("issuedAt", "uint64"), field("expiresAt", "uint64")
                ])
            ]),
            "domain": .object([
                "name": .string("HyperliquidX"), "version": .string("1"),
                "chainId": .string(String(connection.chainID)),
                "verifyingContract": .string("0x0000000000000000000000000000000000000000")
            ]),
            "primaryType": .string("WalletOwnership"),
            "message": .object([
                "wallet": .string(connection.address), "appDomain": .string(Self.appDomain),
                "network": .string(environment.rawValue), "connectionID": .string(connection.id.uuidString),
                "nonce": .string(nonce.hex), "issuedAt": .string(String(issuedAt)),
                "expiresAt": .string(String(expiresAt))
            ])
        ])
    }

    public var digest: Data {
        get throws {
            let message = Keccak256.hash(
                EthereumSigning.text(Self.schema) + (try EthereumSigning.addressWord(connection.address))
                    + EthereumSigning.text(Self.appDomain) + EthereumSigning.text(environment.rawValue)
                    + EthereumSigning.text(connection.id.uuidString) + nonce
                    + EthereumSigning.word(issuedAt) + EthereumSigning.word(expiresAt))
            return Keccak256.hash(
                Data([0x19, 0x01])
                    + EthereumSigning.domain(name: "HyperliquidX", chainID: connection.chainID) + message)
        }
    }

    public func verify(
        signature: WalletSignature, current: WalletConnection?, now: UInt64 = TradingSession.timestamp
    ) throws -> WalletOwnershipProof {
        try connection.requireCurrent(current)
        guard now >= issuedAt, now < expiresAt else {
            throw WalletError.invalid("Wallet ownership challenge expired. Verify again.")
        }
        guard try EthereumSigning.recover(signature: signature, digest: digest) == connection.address else {
            throw WalletError.invalid("The signature does not prove ownership of the connected wallet.")
        }
        return WalletOwnershipProof(connection: connection, environment: environment, validUntil: issuedAt + 600_000)
    }
}
