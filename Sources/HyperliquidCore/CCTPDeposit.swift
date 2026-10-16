import Foundation
import Security

public struct CCTPDepositIntent: Sendable, Identifiable {
    public let id = UUID()
    public let owner: String
    public let amount: String
    public let units: UInt64
    public let route: CCTPRoute
    public let source: FundingSource
    public let authorization: CCTPAuthorization
    public let feeUnits: UInt64
    public let authorizationNonce: Data
    public let validBefore: UInt64
    public let createdAt: Date
    fileprivate var amountDecimal: Decimal { Decimal(units) / 1_000_000 }
    public var fee: Decimal { Decimal(feeUnits) / 1_000_000 }
    public var received: Decimal { Decimal(units - feeUnits) / 1_000_000 }
    public init(
        owner: String, amount: String, environment: NetworkEnvironment,
        source: FundingSource = .perp, sourceNetwork: USDCSourceNetwork = .arbitrum,
        authorization: CCTPAuthorization = .signature,
        quote: CCTPFeeQuote, nonce: Data? = nil, now: Date = Date()
    ) throws {
        guard Address.isValid(owner) else {
            throw WalletError.invalid("Connect the depositing wallet first")
        }
        try quote.validate(environment: environment, sourceNetwork: sourceNetwork)
        guard CCTPRoute(environment: environment, sourceNetwork: sourceNetwork).supportsSignatureDeposit || authorization == .allowance else {
            throw WalletError.invalid("This source network requires a USDC allowance and burn transaction")
        }
        let normalized = try FundingIntent.normalize(amount, decimals: 6)
        let value = try ReviewDecimal.parse(normalized)
        guard value >= 5,
              let units = UInt64(NSDecimalNumber(decimal: value * 1_000_000).stringValue),
              units > (try quote.totalUnits(for: units))
        else {
            throw WalletError.invalid("Enter at least 5 USDC, exceeding the quoted CCTP fee.")
        }
        var random = [UInt8](repeating: 0, count: 32)
        if nonce == nil {
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess
            else {
                throw WalletError.invalid("Unable to create a deposit authorization nonce")
            }
        }
        let authNonce = nonce ?? Data(random)
        guard authNonce.count == 32 else {
            throw WalletError.invalid("Invalid deposit authorization nonce")
        }
        let timestamp = now.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0, timestamp < Double(Int64.max) - 300 else {
            throw WalletError.invalid("Invalid deposit authorization date")
        }
        hook = try CCTPHyperCoreDestination.hook(recipient: owner, account: source)
        self.owner = owner.lowercased()
        self.amount = normalized
        self.units = units
        route = CCTPRoute(environment: environment, sourceNetwork: sourceNetwork)
        self.source = source
        self.authorization = authorization
        feeUnits = try quote.totalUnits(for: units)
        authorizationNonce = authNonce
        validBefore = UInt64(timestamp) + 300
        createdAt = now
    }
    public let hook: Data
    public var typedData: JSONValue {
        let fields: [(String, String)] = [
            ("from", "address"), ("to", "address"), ("value", "uint256"),
            ("validAfter", "uint256"), ("validBefore", "uint256"), ("nonce", "bytes32")
        ]
        func field(_ name: String, _ type: String) -> JSONValue {
            .object(["name": .string(name), "type": .string(type)])
        }
        return .object([
            "domain": .object([
                "name": .string(route.tokenDomainName), "version": .string("2"),
                "chainId": .integer(Int64(route.chainID)),
                "verifyingContract": .string(route.token)
            ]),
            "types": .object([
                "EIP712Domain": .array([
                    field("name", "string"), field("version", "string"),
                    field("chainId", "uint256"), field("verifyingContract", "address")
                ]),
                "ReceiveWithAuthorization": .array(fields.map { field($0.0, $0.1) })
            ]), "primaryType": .string("ReceiveWithAuthorization"),
            "message": .object([
                "from": .string(owner), "to": .string(route.depositContract),
                "value": .string(String(units)), "validAfter": .string("0"),
                "validBefore": .string(String(validBefore)),
                "nonce": .string(authorizationNonce.hex)
            ])
        ])
    }
    public var digest: Data {
        get throws {
            let message = Keccak256.hash(
                EthereumSigning.text(
                    "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                )
                + (try EthereumSigning.addressWord(owner))
                + (try EthereumSigning.addressWord(route.depositContract))
                + EthereumSigning.word(units) + EthereumSigning.word(0)
                + EthereumSigning.word(validBefore) + authorizationNonce)
            return Keccak256.hash(Data([0x19, 0x01]) + (try route.domainSeparator) + message)
        }
    }
    public func transaction(signature: WalletSignature) throws -> WalletTransaction {
        guard authorization == .signature else {
            throw WalletError.invalid("This deposit uses an ERC-20 allowance, not a USDC signature")
        }
        guard try EthereumSigning.recover(signature: signature, digest: digest) == owner,
              let r = Data(hex: signature.r), let s = Data(hex: signature.s)
        else {
            throw WalletError.invalid("Deposit authorization does not match the sending wallet")
        }
        let selector = Keccak256.hash(
            Data(
                "batchDepositForBurnWithAuth((uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32),(uint256,uint32,bytes32,bytes32,uint256,uint32,bytes))"
                    .utf8)
        ).prefix(4)
        // First tuple is static (7 words). Second tuple is dynamic and begins after the 8-word head.
        let head =
            EthereumSigning.word(units) + EthereumSigning.word(0)
            + EthereumSigning.word(validBefore)
            + authorizationNonce + EthereumSigning.word(signature.v) + r + s
            + EthereumSigning.word(8 * 32)
        let destination = try EthereumSigning.addressWord(route.forwarder)
        let tail =
            EthereumSigning.word(units) + EthereumSigning.word(CCTPHyperCoreDestination.domain) + destination + destination
            + EthereumSigning.word(feeUnits) + EthereumSigning.word(route.finality.rawValue)
            + EthereumSigning.word(7 * 32)
            + EthereumSigning.word(UInt64(hook.count)) + hook
            + Data(repeating: 0, count: 64 - hook.count)
        return try WalletTransaction(
            from: owner, to: route.depositContract, data: (selector + head + tail).hex,
            chainID: route.chainID)
    }
    public func validate(
        connection: WalletConnection, maximumAge: TimeInterval = 30, now: Date = Date()
    ) throws {
        let age = now.timeIntervalSince(createdAt)
        guard connection.address == owner, connection.chainID == route.chainID,
              age.isFinite, maximumAge.isFinite, age >= 0, age < maximumAge,
              now.timeIntervalSince1970 < Double(validBefore)
        else {
            throw WalletError.invalid(
                "Deposit account, chain or preview changed. Prepare a fresh CCTP review.")
        }
    }
}

public struct CCTPDepositSnapshot: Sendable {
    public let owner: String
    public let environment: NetworkEnvironment
    public let availableUSDC: Decimal
    public let nativeWei: Decimal
    public let gasPrice: Decimal
    public let gasLimit: Decimal?
    public let transaction: WalletTransaction?
    public let quote: CCTPFeeQuote
    public let startedAt: Double
    public let allowance: Decimal?
    public init(
        owner: String, environment: NetworkEnvironment, availableUSDC: Decimal, nativeWei: Decimal,
        gasPrice: Decimal, gasLimit: Decimal?, transaction: WalletTransaction?, quote: CCTPFeeQuote,
        startedAt: Double, allowance: Decimal? = nil
    ) {
        self.owner = owner
        self.environment = environment
        self.availableUSDC = availableUSDC
        self.nativeWei = nativeWei
        self.gasPrice = gasPrice
        self.gasLimit = gasLimit
        self.transaction = transaction
        self.quote = quote
        self.startedAt = startedAt
        self.allowance = allowance
    }
    public func validate(
        intent: CCTPDepositIntent, transaction: WalletTransaction? = nil,
        now: Double = ReceiptClock.now
    ) throws {
        try quote.validate(environment: intent.route.environment, sourceNetwork: intent.route.sourceNetwork, now: now)
        guard (transaction == nil) == (gasLimit == nil) else {
            throw WalletError.invalid("Refresh the gas estimate for the reviewed CCTP transaction")
        }
        if intent.authorization == .allowance {
            guard let allowance, !allowance.isNaN, allowance >= 0 else {
                throw WalletError.invalid("Refresh the USDC spending allowance before continuing")
            }
            if transaction == (try intent.burnTransaction), needsApproval(for: intent) {
                throw WalletError.invalid("Confirm the USDC approval on the source network before depositing")
            }
        }
        guard owner == intent.owner, environment == intent.route.environment,
              (try quote.totalUnits(for: intent.units)) <= intent.feeUnits,
              startedAt.isFinite, now.isFinite, startedAt >= 0, now >= startedAt,
              now < startedAt + 15,
              !availableUSDC.isNaN, availableUSDC >= Decimal(intent.units) / 1_000_000,
              !nativeWei.isNaN, nativeWei > 0, !gasPrice.isNaN, gasPrice > 0,
              self.transaction == transaction
        else {
            throw WalletError.invalid("CCTP balances or fees changed. Refresh the deposit preview.")
        }
        if let gasLimit {
            guard transaction != nil, !gasLimit.isNaN, gasLimit > 0, !(gasLimit * gasPrice).isNaN,
                  nativeWei >= gasLimit * gasPrice + (intent.route.network.gasUsesUSDC ? intent.amountDecimal * 1_000_000_000_000_000_000 : 0)
            else {
                throw WalletError.invalid(
                    "Insufficient \(intent.route.network.nativeCurrencySymbol) for the CCTP transaction's current gas estimate")
            }
        } else if transaction != nil {
            throw APIError.malformed("Missing signed CCTP gas estimate")
        }
    }
}
