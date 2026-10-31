import Foundation
import Testing

@testable import HyperliquidCore

private func riskPosition(size: String = "1", liquidation: String? = "96") throws -> Position {
    let data: JSONValue = .object([
        "coin": .string("ETH"), "szi": .string(size), "entryPx": .string("100"),
        "liquidationPx": liquidation.map(JSONValue.string) ?? .null,
        "positionValue": .string("100"),
        "unrealizedPnl": .string("0"), "returnOnEquity": .string("0"), "marginUsed": .string("10"),
        "leverage": .object(["type": .string("cross"), "value": .integer(10)])
    ])
    return try data.decode(Position.self)
}

@Test func riskWarningsPersistAcrossMissingDataAndRearmOnlyAfterVerifiedRecovery() throws {
    var monitor = PositionRiskMonitor()
    let position = try riskPosition()
    let warnings = monitor.update(positions: [position], marks: ["ETH": 100], accountFresh: true)
    #expect(warnings.count == 1 && warnings.first?.distance == 4)
    #expect(monitor.update(positions: [position], marks: ["ETH": 100], accountFresh: true).isEmpty)
    #expect(monitor.update(positions: [position], marks: [:], accountFresh: true).isEmpty)
    #expect(monitor.atRisk == ["ETH"] && monitor.unavailable == ["ETH"])
    #expect(monitor.update(positions: [], marks: ["ETH": 120], accountFresh: false).isEmpty)
    #expect(monitor.atRisk == ["ETH"] && monitor.unavailable == ["ETH"])
    #expect(monitor.update(positions: [position], marks: ["ETH": 120], accountFresh: true).isEmpty)
    #expect(monitor.atRisk.isEmpty && monitor.unavailable.isEmpty)
    #expect(
        monitor.update(positions: [position], marks: ["ETH": 100], accountFresh: true).count == 1)
    #expect(monitor.update(positions: [], marks: [:], accountFresh: true).isEmpty)
    #expect(monitor.atRisk.isEmpty)
}

@Test func riskMonitorHandlesShortsCrossedLiquidationThresholdAndAbsentPrices() throws {
    var monitor = PositionRiskMonitor()
    let short = try riskPosition(size: "-1", liquidation: "105")
    #expect(monitor.update(positions: [short], marks: ["ETH": 100], accountFresh: true).isEmpty)
    #expect(monitor.atRisk.isEmpty)  // The spec says below 5%, not at 5%.
    #expect(
        monitor.update(positions: [short], marks: ["ETH": 110], accountFresh: true).first?.distance
            ?? 0 < 0)
    #expect(
        monitor.update(
            positions: [try riskPosition(liquidation: nil)], marks: ["ETH": 100], accountFresh: true
        ).isEmpty
    )
    #expect(monitor.atRisk.isEmpty && monitor.unavailable.isEmpty)
    _ = monitor.update(
        positions: [try riskPosition(liquidation: "nan")], marks: ["ETH": 100], accountFresh: true)
    #expect(monitor.unavailable == ["ETH"])
}

@Test func liquidationDistanceRejectsNonfiniteAndInvalidPositionInputs() throws {
    let position = try riskPosition()
    for mark in [Double.nan, .infinity, -.infinity, 0, -1] {
        #expect(position.liquidationDistance(mark: mark) == nil)
    }
    for size in ["0", "nan", "inf"] {
        #expect(try riskPosition(size: size).liquidationDistance(mark: 100) == nil)
    }
    for liquidation in ["nan", "inf", "0", "-1", "invalid"] {
        #expect(try riskPosition(liquidation: liquidation).liquidationDistance(mark: 100) == nil)
    }
    #expect(try riskPosition(liquidation: "1e308").liquidationDistance(mark: 1e-300) == nil)
}

@Test func invalidPositionQuantitiesStayVisibleAndCannotEstablishRiskRecovery() throws {
    var monitor = PositionRiskMonitor()
    let risky = try riskPosition()
    #expect(monitor.update(positions: [risky], marks: ["ETH": 100], accountFresh: true).count == 1)
    for raw in [
        "bad", "1bad", "NaN", "inf", "1e2", "", " 1", "0bad", "1\n",
        String(repeating: "9", count: 200),
        "0." + String(repeating: "0", count: 150) + "1"
    ] {
        let position = try riskPosition(size: raw)
        #expect(position.signedQuantity == nil && position.hasExposure)
        #expect(position.liquidationDistance(mark: 120) == nil)
        #expect(
            monitor.update(positions: [position], marks: ["ETH": 120], accountFresh: true).isEmpty)
        #expect(monitor.atRisk == ["ETH"] && monitor.unavailable == ["ETH"])
    }
    for raw in ["0", "-0", "0.0000"] {
        let closed = try riskPosition(size: raw)
        #expect(closed.signedQuantity == 0 && !closed.hasExposure)
        #expect(monitor.update(positions: [closed], marks: [:], accountFresh: true).isEmpty)
        #expect(monitor.atRisk.isEmpty && monitor.unavailable.isEmpty)
    }
    for raw in ["0.0000000000000000000000000000000000000001", "-9007199254740993"] {
        let position = try riskPosition(size: raw)
        #expect(position.hasExposure && position.signedQuantity != nil)
    }
    var firstObservation = PositionRiskMonitor()
    _ = firstObservation.update(
        positions: [try riskPosition(size: "bad")], marks: ["ETH": 120], accountFresh: true)
    #expect(firstObservation.atRisk.isEmpty && firstObservation.unavailable == ["ETH"])
}
