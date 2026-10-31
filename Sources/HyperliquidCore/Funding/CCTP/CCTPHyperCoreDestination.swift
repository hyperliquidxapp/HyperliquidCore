import Foundation

/// CCTP mints to the HyperEVM forwarder, which credits the named HyperCore account.
/// This is not a transfer to the user's HyperEVM wallet.
/// https://developers.circle.com/cctp/howtos/transfer-usdc-from-ethereum-to-hypercore
public enum CCTPHyperCoreDestination {
    public static let domain: UInt64 = 19

    public static func forwarder(environment: NetworkEnvironment) -> String {
        environment == .mainnet
            ? "0xb21d281dedb17ae5b501f6aa8256fe38c4e45757"
            : "0x02e39ecb8368b41bf68ff99ff351ac9864e5e2a2"
    }

    public static func hook(recipient: String, account: FundingSource) throws -> Data {
        guard Address.isValid(recipient), let address = Data(hex: recipient) else {
            throw WalletError.invalid("Invalid receiving HyperCore account")
        }
        return Data("cctp-forward".utf8) + Data(repeating: 0, count: 12)
            + Data(WireValue.bigEndian(0, bytes: 4))
            + Data(WireValue.bigEndian(24, bytes: 4)) + address
            + Data(WireValue.bigEndian(account == .perp ? 0 : UInt64(UInt32.max), bytes: 4))
    }
}
