import CryptoKit
import Darwin
import Foundation
import Security
import libsecp256k1

/// EIP-712 encoding for the two fixed signing schemas used by this client.
/// This is intentionally not a permissive, arbitrary typed-data interpreter.
public enum EthereumSigning {
    static func text(_ value: String) -> Data { Keccak256.hash(Data(value.utf8)) }
    static func word(_ value: UInt64) -> Data {
        Data(repeating: 0, count: 24) + Data(WireValue.bigEndian(value, bytes: 8))
    }
    static func addressWord(_ address: String) throws -> Data {
        guard Address.isValid(address), let data = Data(hex: address) else {
            throw WalletError.invalid("Invalid signing address")
        }
        return Data(repeating: 0, count: 12) + data
    }
    static func domain(name: String, chainID: UInt64) -> Data {
        Keccak256.hash(
            text(
                "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
            )
            + text(name) + text("1") + word(chainID) + Data(repeating: 0, count: 32))
    }
    public static func actionDigest(
        action: WireValue, nonce: UInt64, environment: NetworkEnvironment,
        vaultAddress: String? = nil, expiresAfter: UInt64? = nil
    ) throws -> Data {
        let connection = try SigningPayload.actionHash(
            action: action, nonce: nonce, vaultAddress: vaultAddress, expiresAfter: expiresAfter)
        let message = Keccak256.hash(
            text("Agent(string source,bytes32 connectionId)")
                + text(environment == .mainnet ? "a" : "b") + connection)
        return Keccak256.hash(
            Data([0x19, 0x01]) + domain(name: "Exchange", chainID: 1337) + message)
    }
    public static func recover(signature: WalletSignature, digest: Data) throws -> String {
        Keccak256.hash(try recoverPublicKey(signature: signature, digest: digest)).suffix(20).hex
    }
    /// Uncompressed secp256k1 public key without its format byte, as required by Reown's CryptoProvider.
    public static func recoverPublicKey(signature: WalletSignature, digest: Data) throws -> Data {
        guard digest.count == 32, let r = Data(hex: signature.r), let s = Data(hex: signature.s),
              r.count == 32,
              s.count == 32,
              let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE))
        else { throw WalletError.invalid("Invalid signature digest") }
        defer { secp256k1_context_destroy(context) }
        var parsed = secp256k1_ecdsa_recoverable_signature()
        var publicKey = secp256k1_pubkey()
        let compact = [UInt8](r + s)
        let hash = [UInt8](digest)
        guard
            secp256k1_ecdsa_recoverable_signature_parse_compact(
                context, &parsed, compact, Int32(signature.v - 27))
                == 1,
            secp256k1_ecdsa_recover(context, &publicKey, &parsed, hash) == 1
        else { throw WalletError.invalid("Unable to verify wallet signature") }
        var bytes = [UInt8](repeating: 0, count: 65)
        var count = bytes.count
        guard secp256k1_ec_pubkey_serialize(
                context, &bytes, &count, &publicKey, UInt32(SECP256K1_EC_UNCOMPRESSED)) == 1, count == 65 else {
            throw WalletError.invalid("Unable to recover wallet public key")
        }
        return Data(bytes.dropFirst())
    }
    static func publicAddress(context: OpaquePointer, publicKey: inout secp256k1_pubkey) throws
    -> String {
        var bytes = [UInt8](repeating: 0, count: 65)
        var count = 65
        guard
            secp256k1_ec_pubkey_serialize(
                context, &bytes, &count, &publicKey, UInt32(SECP256K1_EC_UNCOMPRESSED)) == 1,
            count == 65
        else { throw WalletError.invalid("Unable to derive session address") }
        return Keccak256.hash(Data(bytes.dropFirst())).suffix(20).hex
    }
}

/// Owned only by TradingSession's actor. Secret bytes are never exported in plaintext or logged.
/// Optional recovery exports only passkey-encrypted ciphertext.
/// The allocation is explicitly cleared on end/deinit; mlock prevents paging while available.
final class EphemeralSigningKey {
    private let bytes: UnsafeMutablePointer<UInt8>
    private let context: OpaquePointer
    let address: String
    init(testKey: Data? = nil, restoring: UnsafeRawBufferPointer? = nil) throws {
        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            throw WalletError.invalid("Unable to initialize signing")
        }
        self.context = context
        bytes = .allocate(capacity: 32)
        bytes.initialize(repeating: 0, count: 32)
        _ = mlock(bytes, 32)
        do {
            if let restoring {
                guard testKey == nil, restoring.count == 32,
                      let source = restoring.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw WalletError.invalid("Invalid recovered session key")
                }
                bytes.update(from: source, count: 32)
            } else if let testKey {
                guard testKey.count == 32 else {
                    throw WalletError.invalid("Invalid session key length")
                }
                testKey.copyBytes(to: bytes, count: 32)
            } else {
                repeat {
                    guard SecRandomCopyBytes(kSecRandomDefault, 32, bytes) == errSecSuccess else {
                        throw WalletError.invalid("Unable to generate session key")
                    }
                } while secp256k1_ec_seckey_verify(context, bytes) != 1
            }
            guard secp256k1_ec_seckey_verify(context, bytes) == 1 else {
                throw WalletError.invalid("Invalid session key")
            }
            var seed = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, 32, &seed) == errSecSuccess,
                  secp256k1_context_randomize(context, seed) == 1
            else { throw WalletError.invalid("Unable to randomize signing context") }
            var publicKey = secp256k1_pubkey()
            guard secp256k1_ec_pubkey_create(context, &publicKey, bytes) == 1 else {
                throw WalletError.invalid("Unable to derive session key")
            }
            address = try EthereumSigning.publicAddress(context: context, publicKey: &publicKey)
        } catch {
            _ = memset_s(bytes, 32, 0, 32)
            _ = munlock(bytes, 32)
            bytes.deallocate()
            secp256k1_context_destroy(context)
            throw error
        }
    }
    deinit {
        _ = memset_s(bytes, 32, 0, 32)
        _ = munlock(bytes, 32)
        bytes.deallocate()
        secp256k1_context_destroy(context)
    }
    func sign(digest: Data) throws -> WalletSignature {
        guard digest.count == 32 else { throw WalletError.invalid("Invalid signing digest") }
        var signature = secp256k1_ecdsa_recoverable_signature()
        var recovery: Int32 = 0
        var output = [UInt8](repeating: 0, count: 64)
        guard
            secp256k1_ecdsa_sign_recoverable(context, &signature, [UInt8](digest), bytes, nil, nil)
                == 1,
            secp256k1_ecdsa_recoverable_signature_serialize_compact(
                context, &output, &recovery, &signature) == 1,
            recovery == 0 || recovery == 1
        else { throw WalletError.invalid("Unable to sign action") }
        return try WalletSignature(hex: (Data(output) + Data([UInt8(recovery + 27)])).hex)
    }
    func seal(using key: SymmetricKey, nonce: UInt64, authenticating binding: Data) throws -> Data {
        var plaintext = Data(bytes: bytes, count: 32)
        plaintext.append(contentsOf: WireValue.bigEndian(nonce, bytes: 8))
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard let ciphertext = try AES.GCM.seal(
                plaintext, using: key, authenticating: binding).combined else {
            throw WalletError.invalid("Unable to protect the trading session")
        }
        return ciphertext
    }
}
