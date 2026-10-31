import Foundation
import Testing

@testable import HyperliquidCore

private let archiveOwner = "0x5742261Ef0516AD70C4217cc573fa21485289D3B"
private func archivedFill(_ time: Int64, tid: Int64 = 1, coin: String = "ETH", fee: String = "1")
-> JSONValue {
    .object([
        "coin": .string(coin), "px": .string("2000"), "sz": .string("1"), "side": .string("B"),
        "time": .integer(time), "tid": .integer(tid), "fee": .string(fee),
        "feeToken": .string("USDC"),
        "closedPnl": .string("0")
    ])
}
private func archiveCursor(_ kind: AccountHistoryKind = .fills, limit: Int = 100_000) throws
-> AccountHistoryCursor {
    AccountHistoryCursor(
        kind: kind, window: try AccountHistoryWindow(start: 100, end: 900), recordLimit: limit)
}

@Test func accountHistoryInclusivePagesDeduplicateAndKeepTheirFrozenWindow() throws {
    var cursor = try archiveCursor()
    let initial = try cursor.request(address: archiveOwner)
    #expect(initial["type"] == .string("userFillsByTime"))
    #expect(initial["user"] == .string(archiveOwner.lowercased()))
    #expect(initial["aggregateByTime"] == .bool(false))
    try cursor.append(.array([archivedFill(100), archivedFill(200)]))
    #expect(cursor.coverage == .more && cursor.nextStart == 200)
    let next = try cursor.request(address: archiveOwner)
    #expect(next["startTime"] == .integer(200) && next["endTime"] == .integer(900))
    try cursor.append(
        .array([archivedFill(200, fee: "0.5"), archivedFill(200, coin: "BTC"), archivedFill(300)]))
    #expect(cursor.records.count == 4 && cursor.records.first?.time == 300)
    #expect(cursor.records.first { $0.time == 200 && $0.fill?.coin == "ETH" }?.fill?.fee == "0.5")
    try cursor.append(.array([archivedFill(300)]))
    #expect(cursor.coverage == .exhausted && !cursor.canLoadMore && cursor.records.count == 4)
    #expect(throws: APIError.self) { try cursor.request(address: archiveOwner) }
}

@Test func accountHistoryPreservesExchangeFillDirection() throws {
    for direction in ["Open Long", "Close Long", "Open Short", "Close Short", "Long > Short"] {
        guard case .object(var fields) = archivedFill(100) else { return }
        fields["dir"] = .string(direction)
        var cursor = try archiveCursor()
        try cursor.append(.array([.object(fields)]))
        #expect(cursor.records.first?.fill?.directionLabel == direction)
    }
    let legacy = try archivedFill(100).decode(Fill.self)
    #expect(legacy.dir == nil && legacy.directionLabel == "Buy")
}

@Test func accountHistoryDoesNotSkipAFullTimestampOrDroppedRowsAtCapacity() throws {
    var boundary = try archiveCursor()
    try boundary.append(.array((0..<500).map { archivedFill(100, tid: Int64($0)) }))
    #expect(boundary.coverage == .timestampBoundary && boundary.nextStart == 100)
    #expect(boundary.records.count == 500 && !boundary.canLoadMore)
    var limited = try archiveCursor(limit: 2)
    try limited.append(.array([archivedFill(100), archivedFill(200), archivedFill(300)]))
    #expect(limited.coverage == .capacity && limited.nextStart == 100)
    #expect(limited.records.count == 2 && !limited.canLoadMore)
}

@Test func accountHistoryRejectsMalformedOrUnorderedPagesAtomically() throws {
    let pages: [JSONValue] = [
        .null, .object([:]), .array([archivedFill(100), .object(["time": .integer(200)])]),
        .array([archivedFill(200), archivedFill(100)]), .array([archivedFill(99)]),
        .array([archivedFill(901)])
    ]
    for page in pages {
        var cursor = try archiveCursor()
        #expect(throws: (any Error).self) { try cursor.append(page) }
        #expect(cursor.records.isEmpty && cursor.nextStart == 100 && cursor.coverage == .more)
    }
    #expect(throws: APIError.self) { try archiveCursor().request(address: "invalid") }
    #expect(throws: APIError.self) { try AccountHistoryWindow(start: 2, end: 1) }
    #expect(throws: APIError.self) { try AccountHistoryPeriod.week.window(endingAt: Int64.min) }
    #expect(try AccountHistoryPeriod.available.window(endingAt: 900).start == 0)
}

@Test func accountHistoryNormalizesFundingAndKeepsDistinctLedgerEvents() throws {
    var funding = try archiveCursor(.funding)
    let row: JSONValue = .object([
        "time": .integer(100), "coin": .string("ETH"), "usdc": .string("-1"),
        "fundingRate": .string("0.001")
    ])
    try funding.append(.array([row]))
    #expect(funding.records.first?.data["delta"]["usdc"] == .string("-1"))
    var ledger = try archiveCursor(.ledger)
    let first: JSONValue = .object([
        "time": .integer(100), "hash": .string("same"),
        "delta": .object(["type": .string("deposit"), "usdc": .string("1")])
    ])
    let second: JSONValue = .object([
        "time": .integer(100), "hash": .string("same"),
        "delta": .object(["type": .string("deposit"), "usdc": .string("2")])
    ])
    try ledger.append(.array([first, first, second]))
    #expect(ledger.records.count == 2 && ledger.coverage == .exhausted)
}

@Test func accountHistoryOrdersUseOneSnapshotAndFilterTheSelectedRange() throws {
    var cursor = try archiveCursor(.orders)
    let body = try cursor.request(address: archiveOwner)
    #expect(
        body["type"] == .string("historicalOrders") && body["startTime"] == nil
            && body["endTime"] == nil)
    func order(_ time: Int64, status: String = "filled") -> JSONValue {
        .object([
            "order": .object(["oid": .integer(1)]), "status": .string(status),
            "statusTimestamp": .integer(time)
        ])
    }
    try cursor.append(.array([order(901), order(300), order(200, status: "canceled"), order(99)]))
    #expect(cursor.records.map(\.time) == [300, 200] && cursor.coverage == .exhausted)
    var stream = try AccountStream(address: archiveOwner)
    stream.mergeHistory(funding: [], ledger: [], orders: cursor.records.map(\.data))
    #expect(stream.takeEvents().isEmpty && stream.orders.isEmpty && stream.orderHistory.count == 2)
}
