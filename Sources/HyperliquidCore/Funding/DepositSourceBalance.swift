import Foundation

/// Source balances keep exact units and omit pending Bitcoin credits and frozen SPL accounts.
public enum DepositSourceBalance {
    public static func bitcoin(_ value: JSONValue, owner: String) throws -> Decimal {
        guard value["address"].string == owner,
              let funded = value["chain_stats"]["funded_txo_sum"].int64,
              let spent = value["chain_stats"]["spent_txo_sum"].int64,
              let pendingSpent = value["mempool_stats"]["spent_txo_sum"].int64,
              funded >= 0, spent >= 0, pendingSpent >= 0, funded >= spent
        else { throw APIError.malformed("Invalid Bitcoin source balance") }
        return max(0, Decimal(funded) - Decimal(spent) - Decimal(pendingSpent)) / 100_000_000
    }
    public static func solanaTokens(_ value: JSONValue, asset: DepositAsset, owner: String) throws -> Decimal {
        guard let mint = asset.solanaMint, case .array(let accounts) = value["value"] else {
            throw APIError.malformed("Missing selected Solana token balances")
        }
        var total = Decimal.zero
        var addresses = Set<String>()
        for account in accounts {
            let parsed = account["account"]["data"]["parsed"]
            let info = parsed["info"]
            let token = info["tokenAmount"]
            guard let address = account["pubkey"].string, addresses.insert(address).inserted,
                  parsed["type"].string == "account", info["mint"].string == mint.address,
                  info["owner"].string == owner, token["decimals"].int64 == Int64(mint.decimals),
                  let raw = token["amount"].string, !raw.isEmpty,
                  raw.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let rawUnits = UInt64(raw),
                  info["state"].string == "initialized" || info["state"].string == "frozen"
            else { throw APIError.malformed("Solana balance does not match the selected token or wallet") }
            if info["state"].string == "frozen" { continue }
            var units = Decimal(rawUnits)
            var sum = Decimal.zero
            guard NSDecimalAdd(&sum, &total, &units, .plain) == .noError else {
                throw APIError.malformed("Solana balance exceeds exact decimal precision")
            }
            total = sum
        }
        return total / pow(Decimal(10), mint.decimals)
    }
}
