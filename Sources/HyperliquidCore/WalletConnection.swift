import Foundation

/// One uninterrupted wallet connection. Returning to the same account or chain
/// after a change creates a new ID, so an earlier authorization stays invalid.
public struct WalletConnection: Sendable, Equatable {
    public let id: UUID
    public let address: String
    public let chainID: UInt64

    public init(address: String, chainID: UInt64, id: UUID = UUID()) throws {
        guard Address.isValid(address), chainID > 0, chainID <= UInt64(Int64.max) else {
            throw WalletError.invalid("Invalid wallet connection")
        }
        self.id = id
        self.address = address.lowercased()
        self.chainID = chainID
    }

    public func requireCurrent(_ current: WalletConnection?) throws {
        guard current == self else {
            throw WalletError.invalid(
                "Wallet connection changed. Create a new preview and approve again.")
        }
    }
}
