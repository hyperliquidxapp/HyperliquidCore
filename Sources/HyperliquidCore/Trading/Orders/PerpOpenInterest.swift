import Foundation

/// A point-in-time validator-market check, not a prediction of future liquidity
/// or exchange acceptance. Resting and conditional orders can be rejected later.
public struct PerpOpenInterestSnapshot: Sendable {
    public let owner: String
    public let environment: NetworkEnvironment
    public let market: Market
    public let atCap: Bool
    public let startedAt: Double
    public let observedAt: Double
    private let intentID: UUID
    private let position: Position?
    public func isFresh(now: Double = ReceiptClock.now) -> Bool {
        startedAt.isFinite && observedAt.isFinite && now.isFinite && startedAt >= 0
            && observedAt >= startedAt && now >= observedAt && now < startedAt + 15
    }

    public static func cappedMarkets(_ response: JSONValue) throws -> Set<String> {
        guard case .array(let values) = response, values.count <= 10_000 else {
            throw APIError.malformed("Market open-interest limits are unavailable")
        }
        var coins = Set<String>()
        for value in values {
            guard let coin = value.string, !coin.isEmpty,
                  coin.trimmingCharacters(in: .whitespacesAndNewlines) == coin,
                  !coin.contains(":"), coins.insert(coin).inserted
            else { throw APIError.malformed("Invalid validator open-interest limits") }
        }
        return coins
    }

    /// Captures the request's owner and network, with no signing or writing API.
    public static func read(
        intent: OrderIntent, address: String, environment: NetworkEnvironment,
        info: @Sendable ([String: JSONValue]) async throws -> JSONValue,
        now: @Sendable () -> Double = { ReceiptClock.now }
    ) async throws -> Self? {
        guard intent.market.kind == .perp else { return nil }
        guard Address.isValid(address), (0..<10_000).contains(intent.market.assetID),
              !intent.market.coin.contains(":")
        else {
            throw OrderValidationError.invalid(
                "Open-interest checks require a validator perpetual market")
        }
        let start = now()
        try Task.checkCancellation()
        let caps = try cappedMarkets(
            await info([
                "type": .string("perpsAtOpenInterestCap"), "dex": .string("")
            ]))
        try Task.checkCancellation()
        let atCap = caps.contains(intent.market.coin)
        var position: Position?
        if atCap {
            let account = try await info([
                "type": .string("clearinghouseState"), "user": .string(address), "dex": .string("")
            ]).decode(AccountState.self)
            try Task.checkCancellation()
            let matches = account.assetPositions.map(\.position).filter {
                $0.coin == intent.market.coin
            }
            guard matches.count <= 1 else {
                throw OrderValidationError.invalid("Duplicate position in open-interest check")
            }
            position = matches.first
            if let position { _ = try ReviewDecimal.parse(position.szi) }
        }
        let observed = now()
        let snapshot = Self(
            owner: address.lowercased(), environment: environment, market: intent.market,
            atCap: atCap, startedAt: start, observedAt: observed, intentID: intent.id,
            position: position)
        try snapshot.validateContext(
            intent: intent, address: address, environment: environment, now: observed)
        return snapshot
    }

    public func validate(
        intent: OrderIntent, address: String, environment: NetworkEnvironment,
        now: Double = ReceiptClock.now
    ) throws {
        try validateContext(intent: intent, address: address, environment: environment, now: now)
        guard atCap else { return }
        try intent.validatePosition(position)
        let current = try ReviewDecimal.parse(position?.szi ?? "0")
        let quantity = try ReviewDecimal.parse(intent.size)
        guard current != 0, quantity > 0, quantity <= abs(current),
              intent.side == (current > 0 ? .sell : .buy)
        else {
            throw OrderValidationError.invalid(
                "Market open interest is at its limit. Reduce an existing position or wait for capacity before opening, increasing or reversing a position."
            )
        }
    }

    private func validateContext(
        intent: OrderIntent, address: String, environment: NetworkEnvironment, now: Double
    ) throws {
        guard intentID == intent.id, market == intent.market, owner == address.lowercased(),
              self.environment == environment, isFresh(now: now)
        else {
            throw OrderValidationError.invalid(
                "Market open-interest check changed or expired. Refresh the preview.")
        }
    }
}

extension HyperliquidAPI {
    public func openInterestSnapshot(intent: OrderIntent, address: String) async throws
    -> PerpOpenInterestSnapshot? {
        try await PerpOpenInterestSnapshot.read(
            intent: intent, address: address, environment: environment,
            info: { try await self.info($0) })
    }
}
