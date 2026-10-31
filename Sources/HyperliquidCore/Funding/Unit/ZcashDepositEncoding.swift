import CryptoKit
import Foundation

/// ZIP 320 reencodes the same transparent recipient; Unit signs the underlying Base58 address.
public enum ZcashDepositEncoding {
    public static func transparentAddress(fromTEX address: String, environment: NetworkEnvironment) throws -> String {
        let hrp = environment == .mainnet ? "tex" : "textest"
        let prefix = hrp + "1"
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        guard address.hasPrefix(prefix), address.count == prefix.count + 38 else {
            throw APIError.malformed("Invalid Zcash TEX address network or length")
        }
        let words = try address.dropFirst(prefix.count).map { character -> UInt32 in
            guard let index = alphabet.firstIndex(of: character) else {
                throw APIError.malformed("Invalid Zcash TEX address encoding")
            }
            return UInt32(index)
        }
        let bytes = Array(hrp.utf8)
        let expanded = bytes.map { UInt32($0 >> 5) } + [0] + bytes.map { UInt32($0 & 31) }
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var checksum: UInt32 = 1
        for word in expanded + words {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ word
            for (index, generator) in generators.enumerated() where (top >> index) & 1 == 1 {
                checksum ^= generator
            }
        }
        guard checksum == 0x2bc830a3 else { throw APIError.malformed("Invalid Zcash TEX address checksum") }
        var accumulator: UInt32 = 0
        var bits = 0
        var hash: [UInt8] = []
        for word in words.dropLast(6) {
            accumulator = (accumulator << 5) | word
            bits += 5
            while bits >= 8 {
                bits -= 8
                hash.append(UInt8((accumulator >> bits) & 255))
            }
        }
        guard bits == 0, hash.count == 20 else { throw APIError.malformed("Invalid Zcash recipient hash") }
        let lead: [UInt8] = environment == .mainnet ? [0x1c, 0xb8] : [0x1d, 0x25]
        let payload = Data(lead + hash)
        let check = SHA256.hash(data: Data(SHA256.hash(data: payload)))
        return base58(payload + Data(check.prefix(4)))
    }
    private static func base58(_ data: Data) -> String {
        var digits: [UInt8] = [0]
        for byte in data {
            var carry = Int(byte)
            for index in digits.indices {
                carry += Int(digits[index]) * 256
                digits[index] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        return String(digits.reversed().map { alphabet[Int($0)] })
    }
}
