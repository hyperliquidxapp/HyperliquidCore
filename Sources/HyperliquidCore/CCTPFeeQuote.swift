import Foundation

public struct CCTPFeeQuote: Sendable, Equatable {
    public let environment: NetworkEnvironment
    public let units: UInt64
    public let sourceNetwork: USDCSourceNetwork
    public let minimumFeeBPS: Decimal
    public let startedAt: Double
    public var amount: Decimal { Decimal(units) / 1_000_000 }
    public init(environment: NetworkEnvironment, units: UInt64, startedAt: Double,
                sourceNetwork: USDCSourceNetwork = .arbitrum, minimumFeeBPS: Decimal = 0) {
        self.sourceNetwork = sourceNetwork
        self.minimumFeeBPS = minimumFeeBPS
        self.environment = environment
        self.units = units
        self.startedAt = startedAt
    }
    public static func parse(
        _ value: JSONValue, environment: NetworkEnvironment,
        startedAt: Double, sourceNetwork: USDCSourceNetwork = .arbitrum
    ) throws -> CCTPFeeQuote {
        guard case .array(let rows) = value else {
            throw APIError.malformed("CCTP fee quote is unavailable")
        }
        let finality = CCTPRoute(environment: environment, sourceNetwork: sourceNetwork).finality
        let matching = rows.filter { $0["finalityThreshold"].int64 == Int64(finality.rawValue) }
        guard matching.count == 1, let row = matching.first,
              let bpsValue = row["minimumFee"].double, bpsValue.isFinite, bpsValue >= 0, bpsValue < 10_000,
              let bps = Decimal(string: String(bpsValue), locale: Locale(identifier: "en_US_POSIX")),
              let raw = row["forwardFee"]["high"].int64, raw > 0,
              let units = UInt64(exactly: raw)
        else {
            throw APIError.malformed(
                "CCTP fees changed or are unavailable. Refresh before authorizing.")
        }
        return CCTPFeeQuote(environment: environment, units: units, startedAt: startedAt,
                            sourceNetwork: sourceNetwork, minimumFeeBPS: bps)
    }
    public func totalUnits(for amountUnits: UInt64) throws -> UInt64 {
        guard !minimumFeeBPS.isNaN, minimumFeeBPS >= 0, minimumFeeBPS < 10_000 else {
            throw APIError.malformed("Invalid CCTP protocol fee")
        }
        var protocolFee = Decimal(amountUnits) * minimumFeeBPS / 10_000
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &protocolFee, 0, .up)
        guard let value = UInt64(NSDecimalNumber(decimal: rounded).stringValue),
              !units.addingReportingOverflow(value).overflow else {
            throw APIError.malformed("CCTP fee exceeds the supported amount")
        }
        return units + value
    }
    public func validate(environment: NetworkEnvironment, sourceNetwork: USDCSourceNetwork = .arbitrum,
                         now: Double = ReceiptClock.now) throws {
        guard self.environment == environment, self.sourceNetwork == sourceNetwork,
              !minimumFeeBPS.isNaN, minimumFeeBPS >= 0, minimumFeeBPS < 10_000, startedAt.isFinite, now.isFinite,
              startedAt >= 0, now >= startedAt, now < startedAt + 15, units > 0
        else {
            throw WalletError.invalid("CCTP fee quote expired. Prepare a new deposit preview.")
        }
    }
}

