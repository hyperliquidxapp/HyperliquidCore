import Foundation

public struct PositionRiskWarning: Sendable, Equatable {
    public let coin: String
    public let distance: Double
}

/// Missing data preserves prior risk until fresh data establishes recovery.
/// It never classifies an expired snapshot as a safe position.
public struct PositionRiskMonitor: Sendable {
    public private(set) var atRisk = Set<String>()
    public private(set) var unavailable = Set<String>()
    public init() {}
    public mutating func update(positions: [Position], marks: [String: Double], accountFresh: Bool)
    -> [PositionRiskWarning] {
        let exposures = positions.filter(\.hasExposure)
        let coins = Set(exposures.map(\.coin))
        guard accountFresh else {
            unavailable = coins.union(atRisk)
            return []
        }
        var next = Set<String>()
        var missing = Set<String>()
        var warnings: [PositionRiskWarning] = []
        for position in exposures {
            guard position.signedQuantity != nil, let mark = marks[position.coin], mark.isFinite,
                  mark > 0
            else {
                missing.insert(position.coin)
                if atRisk.contains(position.coin) { next.insert(position.coin) }
                continue
            }
            guard position.liquidationPx != nil else { continue }
            guard let distance = position.liquidationDistance(mark: mark) else {
                missing.insert(position.coin)
                if atRisk.contains(position.coin) { next.insert(position.coin) }
                continue
            }
            if distance < 5 {
                next.insert(position.coin)
                if !atRisk.contains(position.coin) {
                    warnings.append(PositionRiskWarning(coin: position.coin, distance: distance))
                }
            }
        }
        atRisk = next
        unavailable = missing
        return warnings
    }
}
