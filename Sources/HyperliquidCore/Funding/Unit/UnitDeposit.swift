import CryptoKit
import Foundation

/// An address is exposed only after two distinct Unit guardians authenticate its owner and route.
public struct UnitDepositAddress: Sendable, Equatable {
    public let asset: DepositAsset
    public let owner: String
    public let environment: NetworkEnvironment
    public let address: String

    public init(
        response: JSONValue, asset: DepositAsset, owner: String, environment: NetworkEnvironment
    ) throws {
        guard Address.isValid(owner), asset != .usdc,
              DepositAsset.available(environment: environment).contains(asset),
              response["status"].string == "OK", let address = response["address"].string,
              Self.validAddress(address, asset: asset, environment: environment)
        else { throw APIError.malformed("Invalid asset deposit address") }
        let owner = owner.lowercased()
        let coinType = response["coinType"].string ?? response["coin_type"].string
        let expectedCoin = asset.usesEVMWallet ? "ethereum" : asset.chain
        guard coinType == nil || coinType == expectedCoin else {
            throw APIError.malformed("Deposit address signing network mismatch")
        }
        // The API omits coinType on some current responses and canonicalizes EVM owners to EIP-55.
        // Both representations below are computed from the requested account, never from the server.
        let owners = Set([owner, Self.checksummedOwner(owner)])
        var signingAddresses = [address]
        if asset == .zec, address.hasPrefix(environment == .mainnet ? "tex1" : "textest1") {
            signingAddresses.append(
                try ZcashDepositEncoding.transparentAddress(fromTEX: address, environment: environment))
        }
        var verified = Set<String>()
        for guardian in Self.guardians(environment: environment) {
            guard let encoded = response["signatures"][guardian.name].string,
                  let raw = Data(base64Encoded: encoded), raw.count == 64,
                  let bytes = Data(hex: guardian.key),
                  let key = try? P256.Signing.PublicKey(x963Representation: bytes),
                  let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw)
            else { continue }
            let payloads = owners.flatMap { account -> [String] in
                signingAddresses.flatMap { recipient -> [String] in
                    let modern = "\(guardian.name):user-\(expectedCoin)-hyperliquid-\(account)-\(recipient)"
                    let legacy = "\(guardian.name):\(account)-hyperliquid-\(asset.unitSymbol)-\(recipient)-\(asset.chain)-deposit"
                    return coinType == "ethereum" ? [modern] : [legacy, modern]
                }
            }
            if payloads.contains(where: { key.isValidSignature(signature, for: Data($0.utf8)) }) {
                verified.insert(guardian.key)
            }
        }
        guard verified.count >= 2 else {
            throw APIError.malformed("Deposit address could not be verified. Refresh to try again.")
        }
        self.asset = asset
        self.owner = owner
        self.environment = environment
        self.address = address
    }

    private static func checksummedOwner(_ owner: String) -> String {
        let body = owner.dropFirst(2).lowercased()
        let hash = Keccak256.hash(Data(body.utf8)).hex.dropFirst(2)
        return "0x" + zip(body, hash).map { character, digit in
            (digit.hexDigitValue ?? 0) >= 8 ? String(character).uppercased() : String(character)
        }.joined()
    }

    private static func validAddress(
        _ value: String, asset: DepositAsset, environment: NetworkEnvironment
    ) -> Bool {
        if asset.usesEVMWallet { return Address.isValid(value) }
        switch asset.chain {
        case "bitcoin":
            let prefix = environment == .mainnet ? "bc1" : "tb1"
            return value.hasPrefix(prefix) && (14...90).contains(value.count)
                && value.allSatisfy { "023456789acdefghjklmnpqrstuvwxyz1b".contains($0) }
        case "solana":
            return (32...44).contains(value.count)
                && value.allSatisfy { "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) }
        case "zcash":
            let exchangePrefix = environment == .mainnet ? "tex1" : "textest1"
            if value.hasPrefix(exchangePrefix) {
                let body = value.dropFirst(exchangePrefix.count)
                return body.count == 38
                    && body.allSatisfy { "023456789acdefghjklmnpqrstuvwxyz".contains($0) }
            }
            return value.hasPrefix(environment == .mainnet ? "t" : "tm")
                && value.count == 35
                && value.allSatisfy { "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) }
        default: return false
        }
    }

    private static func guardians(environment: NetworkEnvironment) -> [(name: String, key: String)] {
        if environment == .mainnet {
            return [
                ("unit-node",
                 "04dc6f89f921dc816aa69b687be1fcc3cc1d48912629abc2c9964e807422e1047e0435cb5ba0fa53cb9a57a9c610b4e872a0a2caedda78c4f85ebafcca93524061"),
                ("hl-node",
                 "048633ea6ab7e40cdacf37d1340057e84bb9810de0687af78d031e9b07b65ad4ab379180ab55075f5c2ebb96dab30d2c2fab49d5635845327b6a3c27d20ba4755b"),
                ("field-node",
                 "04ae2ab20787f816ea5d13f36c4c4f7e196e29e867086f3ce818abb73077a237f841b33ada5be71b83f4af29f333dedc5411ca4016bd52ab657db2896ef374ce99")
            ]
        }
        let unitKey =
            "04bab844e8620c4a1ec304df6284cd6fdffcde79b3330a7bffb1e4cecfee72d02a7c1f3a4415b253dc8d6ca2146db170e1617605cc8a4160f539890b8a24712152"
        return [
            ("node-1", unitKey), ("unit-node", unitKey),
            ("hl-node-testnet",
             "04502d20a0d8d8aaea9395eb46d50ad2d8278c1b3a3bcdc200d531253612be23f5f2e9709bf3a3a50d1447281fa81aca0bf2ac2a6a3cb8a12978381d73c24bb2d9"),
            ("field-node",
             "04e674a796ff01d6b74f4ee4079640729797538cdb4926ec333ce1bd18414ef7f22c1a142fd76dca120614045273f30338cd07d79bc99872c76151756aaec0f8e8")
        ]
    }
}

public protocol UnitDepositReadClient: Sendable {
    func depositAddress(asset: DepositAsset, owner: String) async throws -> UnitDepositAddress
    func balance(asset: DepositAsset, owner: String) async throws -> Decimal
}

public struct UnitDepositClient: UnitDepositReadClient {
    public let environment: NetworkEnvironment
    private let transport: NIOHTTPTransport
    public init(environment: NetworkEnvironment, transport: NIOHTTPTransport = .init()) {
        self.environment = environment
        self.transport = transport
    }
    public func depositAddress(asset: DepositAsset, owner: String) async throws -> UnitDepositAddress {
        guard Address.isValid(owner), asset != .usdc,
              DepositAsset.available(environment: environment).contains(asset)
        else { throw WalletError.invalid("Select an available deposit token and connect your wallet.") }
        let base = environment == .mainnet ? "https://api.hyperunit.xyz" : "https://api.hyperunit-testnet.xyz"
        let url = URL(string: base)!.appendingPathComponent(
            "gen/\(asset.chain)/hyperliquid/\(asset.unitSymbol)/\(owner.lowercased())")
        let response = try JSONDecoder().decode(JSONValue.self, from: await transport.get(url: url))
        return try UnitDepositAddress(
            response: response, asset: asset, owner: owner, environment: environment)
    }
    public func balance(asset: DepositAsset, owner: String) async throws -> Decimal {
        guard DepositAsset.available(environment: environment).contains(asset) else {
            throw WalletError.invalid("This token is unavailable on the selected network.")
        }
        if asset.chain == "solana" { return try await solanaBalance(asset: asset, owner: owner) }
        if asset == .btc { return try await bitcoinBalance(owner: owner) }
        guard Address.isValid(owner) else { throw WalletError.invalid("Invalid source wallet.") }
        let network = try DepositEVMNetwork(asset: asset, environment: environment)
        let chain = try EthereumQuantity.parse(
            await read("eth_chainId", params: [], url: network.rpcURL).string)
        guard chain == Decimal(network.chainID) else {
            throw APIError.malformed("RPC chain does not match the selected deposit token")
        }
        let value: JSONValue
        if let contract = network.contract {
            let call: JSONValue = .object([
                "to": .string(contract),
                "data": .string("0x70a08231" + String(repeating: "0", count: 24) + owner.lowercased().dropFirst(2))
            ])
            value = try await read("eth_call", params: [call, .string("latest")], url: network.rpcURL)
        } else {
            value = try await read(
                "eth_getBalance", params: [.string(owner.lowercased()), .string("latest")], url: network.rpcURL)
        }
        return try EthereumQuantity.parse(value.string) / 1_000_000_000_000_000_000
    }
    private func solanaBalance(asset: DepositAsset, owner: String) async throws -> Decimal {
        guard (32...44).contains(owner.count),
              owner.allSatisfy({ "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) })
        else { throw WalletError.invalid("Enter a valid Solana source wallet address.") }
        let url = URL(string: environment == .mainnet
            ? "https://api.mainnet-beta.solana.com" : "https://api.devnet.solana.com")!
        if let mint = asset.solanaMint {
            let result = try await read("getTokenAccountsByOwner", params: [
                .string(owner), .object(["mint": .string(mint.address)]),
                .object(["encoding": .string("jsonParsed"), "commitment": .string("confirmed")])
            ], url: url)
            return try DepositSourceBalance.solanaTokens(result, asset: asset, owner: owner)
        }
        let result = try await read("getBalance", params: [
            .string(owner), .object(["commitment": .string("confirmed")])
        ], url: url)
        guard let units = result["value"].int64, units >= 0 else {
            throw APIError.malformed("Invalid SOL balance")
        }
        return Decimal(units) / 1_000_000_000
    }
    private func bitcoinBalance(owner: String) async throws -> Decimal {
        let prefix = environment == .mainnet ? "bc1" : "tb1"
        let bech32 = owner.hasPrefix(prefix) && (14...90).contains(owner.count)
            && owner.allSatisfy { "023456789acdefghjklmnpqrstuvwxyz1b".contains($0) }
        let legacyPrefixes = environment == .mainnet ? "13" : "mn2"
        let legacy = owner.first.map { legacyPrefixes.contains($0) } == true
            && (26...35).contains(owner.count)
            && owner.allSatisfy { "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) }
        guard bech32 || legacy else {
            throw WalletError.invalid("Enter a Bitcoin source address for the selected network.")
        }
        let base = environment == .mainnet ? "https://blockstream.info/api" : "https://blockstream.info/signet/api"
        let url = URL(string: base)!.appendingPathComponent("address/" + owner)
        let response = try JSONDecoder().decode(JSONValue.self, from: await transport.get(url: url))
        return try DepositSourceBalance.bitcoin(response, owner: owner)
    }
    private func read(_ method: String, params: [JSONValue], url: URL) async throws -> JSONValue {
        let body: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .integer(1), "method": .string(method), "params": .array(params)
        ])
        let result = try JSONDecoder().decode(
            JSONValue.self, from: await transport.post(url: url, body: JSONEncoder().encode(body)))
        guard result["jsonrpc"].string == "2.0", result["id"].int64 == 1, result["error"] == .null,
              case .object(let fields) = result, fields["result"] != nil
        else { throw APIError.malformed(result["error"]["message"].string ?? "Invalid chain RPC response") }
        return result["result"]
    }
}
