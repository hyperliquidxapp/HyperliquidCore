import Foundation
import Testing

@testable import HyperliquidCore

private let watched = "0x1111111111111111111111111111111111111111"
private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}
private func packet(_ channel: String, _ data: JSONValue) -> SocketMessage {
    SocketMessage(channel: channel, data: data)
}
private func wrapper(_ values: [String: JSONValue]) -> JSONValue {
    .object(values.merging(["user": .string(watched), "dex": .string("")]) { _, new in new })
}
private func state(
    _ size: String = "1", time: Int64 = 100, usd: String = "100", pnl: String = "0",
    leverage: Int = 2,
    mode: String = "cross", rawUsd: String? = nil
) throws -> JSONValue {
    let rawMargin = rawUsd.map { ",\"rawUsd\":\"\($0)\"" } ?? ""
    return try json(
        """
        {"marginSummary":{"accountValue":"100","totalNtlPos":"20","totalRawUsd":"\(usd)","totalMarginUsed":"10"},"withdrawable":"90","time":\(time),"assetPositions":[{"position":{"coin":"ETH","szi":"\(size)","entryPx":"20","liquidationPx":"10","positionValue":"20","unrealizedPnl":"\(pnl)","returnOnEquity":"0","marginUsed":"10","leverage":{"type":"\(mode)","value":\(leverage)\(rawMargin)}}}]}
        """)
}

@Test func isolatedRawMarginChangesDoNotAnnounceAConfiguredLeverageChange() throws {
    var stream = try AccountStream(address: watched)
    try stream.ingest(
        packet(
            "clearinghouseState",
            wrapper(["clearinghouseState": try state(mode: "isolated", rawUsd: "-10")])))
    #expect(stream.takeEvents().isEmpty)
    try stream.ingest(
        packet(
            "clearinghouseState",
            wrapper([
                "clearinghouseState": try state("1.00", time: 101, mode: "isolated", rawUsd: "-9")
            ])))
    #expect(stream.takeEvents().isEmpty)
    #expect(stream.account?.assetPositions.first?.position.leverage.rawUsd == "-9")
    try stream.ingest(
        packet(
            "clearinghouseState",
            wrapper([
                "clearinghouseState": try state(
                    time: 102, leverage: 3, mode: "isolated", rawUsd: "-9.00")
            ])))
    #expect(stream.takeEvents().map(\.kind) == [.leverage])
}
private func spot(_ total: String = "100") -> JSONValue {
    .object([
        "balances": .array([
            .object([
                "token": .integer(0), "coin": .string("USDC"), "total": .string(total),
                "hold": .string("0")
            ])
        ])
    ])
}
private func order(
    _ oid: Int64 = 1, size: String = "1", price: String = "20", details: Bool = false
) -> JSONValue {
    var values: [String: JSONValue] = [
        "coin": .string("ETH"), "limitPx": .string(price), "sz": .string(size),
        "side": .string("B"),
        "oid": .integer(oid), "timestamp": .integer(100)
    ]
    if details {
        values["orderType"] = .string("Limit")
        values["reduceOnly"] = .bool(true)
        values["tif"] = .string("Alo")
    }
    return .object(values)
}
private func baseline() throws -> AccountStream {
    var stream = try AccountStream(address: watched)
    try stream.ingest(packet("clearinghouseState", wrapper(["clearinghouseState": try state()])))
    try stream.ingest(packet("openOrders", wrapper(["orders": .array([order(details: true)])])))
    try stream.ingest(packet("spotState", wrapper(["spotState": spot()])))
    return stream
}

@Test func accountSnapshotsAreQuietAndBoundToUserAndDex() throws {
    var stream = try baseline()
    #expect(stream.ready)
    #expect(stream.takeEvents().isEmpty)
    let subscriptions = AccountStream.subscriptions(address: watched.uppercased())
    #expect(subscriptions.count == 8)
    #expect(subscriptions.allSatisfy { $0["user"]?.string == watched })
    let foreign = JSONValue.object([
        "user": .string("0x2222222222222222222222222222222222222222"), "dex": .string(""),
        "orders": .array([])
    ])
    #expect(try !stream.ingest(packet("openOrders", foreign)))
    #expect(
        try !stream.ingest(
            packet(
                "openOrders",
                .object(["user": .string(watched), "dex": .string("xyz"), "orders": .array([])]))))
    #expect(stream.orders.count == 1)
    stream.reconnect()
    #expect(!stream.ready)
    #expect(stream.orders.count == 1)
}

@Test func olderRESTCannotOverwriteSocketChangesOrResurrectTerminalOrder() throws {
    var stream = try baseline()
    let revision = stream.revision
    try stream.ingest(
        packet("clearinghouseState", wrapper(["clearinghouseState": try state("2", time: 200)])))
    try stream.ingest(packet("spotState", wrapper(["spotState": spot("80")])))
    let update = JSONValue.object([
        "order": order(), "status": .string("filled"), "statusTimestamp": .integer(200)
    ])
    try stream.ingest(packet("orderUpdates", .array([update])))
    stream.mergeREST(
        account: try state().decode(AccountState.self),
        orders: try JSONValue.array([order(details: true)]).decode([OpenOrder].self),
        fills: [], balances: spot(), startedAt: revision, receivedAt: 300)
    #expect(stream.account?.assetPositions.first?.position.szi == "2")
    #expect(stream.balances["balances"].array.first?["total"].string == "80")
    #expect(stream.orders.isEmpty)
    try stream.ingest(packet("openOrders", wrapper(["orders": .array([order()])])))
    try stream.ingest(
        packet(
            "orderUpdates",
            .array([
                .object([
                    "order": order(), "status": .string("open"), "statusTimestamp": .integer(199)
                ])
            ])))
    #expect(stream.orders.isEmpty)
    #expect(stream.takeEvents().filter { $0.kind == .order }.count == 1)
}

@Test func liveStreamKeepsMissingServerTimeAndRESTOnlyEnrichesOrderMetadata() throws {
    var stream = try baseline()
    guard case .object(var incoming) = try state("3", time: 200) else { return }
    incoming.removeValue(forKey: "time")
    try stream.ingest(
        packet("clearinghouseState", wrapper(["clearinghouseState": .object(incoming)])))
    try stream.ingest(
        packet("openOrders", wrapper(["orders": .array([order(2, size: "0.5", price: "21")])])))
    stream.mergeREST(
        account: try state("1", time: 500).decode(AccountState.self),
        orders: try JSONValue.array([order(2, size: "9", price: "19", details: true), order(3)])
            .decode(
                [OpenOrder].self),
        fills: [], balances: spot("900"), startedAt: stream.revision, receivedAt: 600,
        preferStream: true)
    #expect(stream.account?.time == 100)
    #expect(stream.account?.assetPositions.first?.position.szi == "3")
    #expect(stream.orders.count == 1)
    #expect(stream.orders.first?.sz == "0.5")
    #expect(stream.orders.first?.limitPx == "21")
    #expect(stream.orders.first?.orderType == "Limit")
    #expect(stream.orders.first?.reduceOnly == true)
    #expect(stream.orders.first?.tif == "Alo")
    #expect(stream.balances["balances"].array.first?["total"].string == "100")
}

@Test func positionLeverageAndCashEventsIgnoreEquivalentDecimalsAndPnL() throws {
    var stream = try baseline()
    try stream.ingest(
        packet(
            "clearinghouseState",
            wrapper(["clearinghouseState": try state("1.00", time: 101, pnl: "30")])))
    try stream.ingest(packet("spotState", wrapper(["spotState": spot("100.0000")])))
    #expect(stream.takeEvents().isEmpty)
    try stream.ingest(
        packet(
            "clearinghouseState",
            wrapper(["clearinghouseState": try state("-2", time: 102, usd: "99", leverage: 3)])))
    let events = stream.takeEvents()
    #expect(Set(events.map(\.kind)) == Set([.position, .leverage, .balance]))
    try stream.ingest(
        packet("clearinghouseState", wrapper(["clearinghouseState": try state("9", time: 90)])))
    #expect(stream.account?.assetPositions.first?.position.szi == "-2")
    #expect(stream.takeEvents().isEmpty)
    try stream.ingest(
        packet("spotState", wrapper(["spotState": .object(["balances": .array([])])])))
    #expect(stream.takeEvents().first?.data["total"].string == "0")
}

@Test func positionEventsReportInvalidQuantityChangesWithoutTreatingNumericPrefixesAsEquivalent()
throws {
    var stream = try baseline()
    for (offset, size) in ["1bad", "1worse", "NaN", "invalid", "0"].enumerated() {
        let time = Int64(101 + offset)
        try stream.ingest(
            packet(
                "clearinghouseState", wrapper(["clearinghouseState": try state(size, time: time)])))
        let events = stream.takeEvents().filter { $0.kind == .position }
        #expect(events.count == 1 && events.first?.data["size"].string == size)
        try stream.ingest(
            packet(
                "clearinghouseState", wrapper(["clearinghouseState": try state(size, time: time)])))
        #expect(stream.takeEvents().isEmpty)
    }
    try stream.ingest(
        packet("clearinghouseState", wrapper(["clearinghouseState": try state("-0.00", time: 200)]))
    )
    #expect(stream.takeEvents().isEmpty)
}

@Test func fillSnapshotsAndReplaysAreQuietAndIdentityIncludesBlockTime() throws {
    func fill(_ time: Int64) throws -> JSONValue {
        try json(
            """
            {"coin":"ETH","px":"20","sz":"1","side":"B","time":\(time),"tid":7,"fee":"0","closedPnl":"0"}
            """)
    }
    var stream = try baseline()
    try stream.ingest(
        packet("userFills", wrapper(["fills": .array([try fill(100)]), "isSnapshot": .bool(true)])))
    #expect(stream.takeEvents().isEmpty)
    try stream.ingest(
        packet(
            "userFills",
            wrapper(["fills": .array([try fill(100), try fill(101)]), "isSnapshot": .bool(false)])))
    #expect(stream.takeEvents().count == 1)
    #expect(stream.fills.count == 2)
    try stream.ingest(
        packet(
            "userFills", wrapper(["fills": .array([try fill(101)]), "isSnapshot": .bool(false)])))
    #expect(stream.takeEvents().isEmpty)
}

@Test func fundingAndLedgerSnapshotsMergeWithRESTWithoutDuplicateNotifications() throws {
    var stream = try baseline()
    let funding = try json(
        #"{"time":100,"coin":"ETH","usdc":"0.2","szi":"1","fundingRate":"0.01"}"#)
    let record = try json(#"{"time":100,"hash":"same","delta":{"type":"deposit","usdc":"10"}}"#)
    let other = try json(#"{"time":100,"hash":"same","delta":{"type":"send","amount":"5"}}"#)
    try stream.ingest(
        packet("userFundings", wrapper(["fundings": .array([funding]), "isSnapshot": .bool(true)])))
    try stream.ingest(
        packet(
            "userNonFundingLedgerUpdates",
            wrapper([
                "nonFundingLedgerUpdates": .array([record, other]), "isSnapshot": .bool(true)
            ])))
    #expect(stream.takeEvents().isEmpty)
    stream.mergeHistory(
        funding: [.object(["time": funding["time"], "delta": funding])], ledger: [record],
        orders: [])
    #expect(stream.funding.count == 1)
    #expect(stream.ledger.count == 2)
    #expect(stream.funding.first?["delta"]["coin"].string == "ETH")
    let settlement = try json(
        #"{"time":200,"coin":"ETH","usdc":"0.3","szi":"1","fundingRate":"0.02"}"#)
    try stream.ingest(
        packet(
            "userFundings", wrapper(["fundings": .array([settlement]), "isSnapshot": .bool(false)]))
    )
    #expect(stream.takeEvents().first?.kind == .funding)
    try stream.ingest(
        packet(
            "userFundings", wrapper(["fundings": .array([settlement]), "isSnapshot": .bool(false)]))
    )
    #expect(stream.takeEvents().isEmpty)
}

@Test func restAndReconnectRecoverSessionFillsWithoutReplayingHistory() throws {
    func fill(_ time: Int64) throws -> Fill {
        try json("""
            {"coin":"ETH","px":"20","sz":"1","side":"B","time":\(time),"tid":7,"fee":"0","closedPnl":"0"}
            """).decode(Fill.self)
    }
    var stream = try AccountStream(address: watched, monitoringSince: 200)
    let old = try fill(100)
    let recent = try fill(201)
    stream.mergeREST(
        account: try state().decode(AccountState.self), orders: [], fills: [old, recent],
        balances: spot(), startedAt: stream.revision, receivedAt: 202)
    #expect(stream.takeEvents().filter { $0.kind == .fill }.map(\.id) == [recent.id])
    func fillsPacket(_ values: [Fill], snapshot: Bool) throws -> SocketMessage {
        packet("userFills", wrapper([
            "fills": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(values)),
            "isSnapshot": .bool(snapshot)
        ]))
    }
    try stream.ingest(fillsPacket([recent], snapshot: false))
    #expect(stream.takeEvents().isEmpty)
    stream.reconnect()
    let missed = try fill(300)
    try stream.ingest(fillsPacket([old, recent, missed], snapshot: true))
    #expect(stream.takeEvents().filter { $0.kind == .fill }.map(\.id) == [missed.id])
    try stream.ingest(fillsPacket([missed], snapshot: false))
    stream.mergeREST(
        account: try state().decode(AccountState.self), orders: [], fills: [old, recent, missed],
        balances: spot(), startedAt: stream.revision, receivedAt: 301)
    #expect(stream.takeEvents().isEmpty)
}

@Test func exchangeCancelAndLiquidationAreRetainedWithoutUserFillDuplication() throws {
    var stream = try baseline()
    let event = try json(
        #"{"nonUserCancel":[{"coin":"ETH","oid":1}],"liquidation":{"lid":7,"liquidator":"x","liquidated_user":"0x1111111111111111111111111111111111111111","liquidated_ntl_pos":"1","liquidated_account_value":"2"},"fills":[]}"#
    )
    try stream.ingest(packet("user", event), receivedAt: 200)
    #expect(stream.orders.isEmpty)
    let events = stream.takeEvents()
    #expect(events.filter { $0.kind == .liquidation }.count == 1)
    try stream.ingest(packet("user", event), receivedAt: 200)
    #expect(stream.takeEvents().isEmpty)
    try stream.ingest(
        packet("openOrders", wrapper(["orders": .array([order(), order(2), order(2)])])))
    #expect(stream.orders.count == 1)
    #expect(stream.orders.first?.oid == 2)
}
