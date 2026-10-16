import Foundation
import Testing

@testable import HyperliquidCore

private let lifecycleOwner = "0x1111111111111111111111111111111111111111"
private func observation(
    _ status: String, time: Int64, oid: Int64 = 9_007_199_254_740_993, coin: String = "ETH"
) throws
-> OrderObservation {
    try OrderObservation(
        .object([
            "status": .string(status), "statusTimestamp": .integer(time),
            "order": .object(["coin": .string(coin), "oid": .integer(oid)])
        ]))
}

@Test func orderLifecycleDistinguishesEveryPublishedStatusAndUnknownValues() {
    #expect(OrderLifecycle("open") == .open)
    #expect(OrderLifecycle("filled") == .filled)
    #expect(OrderLifecycle("triggered") == .triggered)
    #expect(!OrderLifecycle("triggered").terminal)
    for raw in [
        "canceled", "marginCanceled", "vaultWithdrawalCanceled", "openInterestCapCanceled",
        "selfTradeCanceled",
        "reduceOnlyCanceled", "siblingFilledCanceled", "delistedCanceled", "liquidatedCanceled",
        "scheduledCancel"
    ] {
        guard case .canceled(let reason) = OrderLifecycle(raw) else {
            Issue.record("Expected cancellation: \(raw)")
            continue
        }
        #expect(!reason.isEmpty)
        #expect(OrderLifecycle(raw).terminal)
    }
    for raw in [
        "rejected", "tickRejected", "minTradeNtlRejected", "perpMarginRejected",
        "reduceOnlyRejected",
        "badAloPxRejected",
        "iocCancelRejected", "badTriggerPxRejected", "marketOrderNoLiquidityRejected",
        "positionIncreaseAtOpenInterestCapRejected",
        "positionFlipAtOpenInterestCapRejected", "tooAggressiveAtOpenInterestCapRejected",
        "openInterestIncreaseRejected",
        "insufficientSpotBalanceRejected", "oracleRejected", "perpMaxPositionRejected"
    ] {
        guard case .rejected(let reason) = OrderLifecycle(raw) else {
            Issue.record("Expected rejection: \(raw)")
            continue
        }
        #expect(!reason.isEmpty)
        #expect(OrderLifecycle(raw).terminal)
    }
    #expect(OrderLifecycle("futureCanceledStatus") == .unrecognized("futureCanceledStatus"))
    #expect(!OrderLifecycle("futureCanceledStatus").recognized)
}

@Test func orderLifecycleRejectsForeignAndStaleRecordsWithoutLosingIntegerIdentity() throws {
    let wire = Data(
        #"{"status":"open","statusTimestamp":100,"order":{"coin":"ETH","oid":9007199254740993}}"#
            .utf8)
    let first = try OrderObservation(JSONDecoder().decode(JSONValue.self, from: wire))
    #expect(first.oid == 9_007_199_254_740_993)
    var tracked = TrackedOrder(
        owner: lifecycleOwner.uppercased(), coin: "ETH", oid: first.oid, status: .open)
    let applied1 = tracked.apply(first, owner: lifecycleOwner)
    #expect(applied1)
    #expect(
        !tracked.apply(
            try observation("filled", time: 101),
            owner: "0x2222222222222222222222222222222222222222"))
    #expect(
        !tracked.apply(try observation("filled", time: 101, coin: "BTC"), owner: lifecycleOwner))
    #expect(
        !tracked.apply(
            try observation("filled", time: 101, oid: 9_007_199_254_740_992), owner: lifecycleOwner)
    )
    #expect(!tracked.apply(try observation("filled", time: 99), owner: lifecycleOwner))
    #expect(tracked.status == .open)
    let applied2 = tracked.apply(try observation("filled", time: 101), owner: lifecycleOwner)
    #expect(applied2)
    #expect(!tracked.apply(try observation("open", time: 102), owner: lifecycleOwner))
    #expect(!tracked.apply(try observation("rejected", time: 102), owner: lifecycleOwner))
    #expect(!tracked.apply(try observation("filled", time: 101), owner: lifecycleOwner))
    #expect(tracked.status == .filled)
}

@Test func orderLifecyclePreservesActivationAcrossUnknownStatusAndHandlesTies() throws {
    var tracked = TrackedOrder(
        owner: lifecycleOwner, coin: "ETH", oid: 9_007_199_254_740_993, status: .open)
    let applied3 = tracked.apply(try observation("triggered", time: 100), owner: lifecycleOwner)
    #expect(applied3)
    #expect(!tracked.apply(try observation("open", time: 100), owner: lifecycleOwner))
    #expect(!tracked.apply(try observation("future", time: 100), owner: lifecycleOwner))
    let applied4 = tracked.apply(try observation("future", time: 101), owner: lifecycleOwner)
    #expect(applied4)
    #expect(!tracked.apply(try observation("open", time: 102), owner: lifecycleOwner))
    let applied5 = tracked.apply(try observation("filled", time: 102), owner: lifecycleOwner)
    #expect(applied5)
}

@Test func orderLifecycleQueryAbsenceAndMalformedRecordsStayUnresolved() throws {
    #expect(try OrderObservation.query(.object(["status": .string("unknownOid")])) == nil)
    #expect(throws: APIError.self) {
        try OrderObservation.query(.object(["status": .string("other")]))
    }
    for oid in [JSONValue.number(9_007_199_254_740_992), .integer(-1), .string("123")] {
        #expect(throws: APIError.self) {
            try OrderObservation(
                .object([
                    "status": .string("open"), "statusTimestamp": .integer(100),
                    "order": .object(["coin": .string("ETH"), "oid": oid])
                ]))
        }
    }
    #expect(throws: APIError.self) { try OrderObservation(.object(["status": .string("filled")])) }
}

@Test func exchangeReceiptsRequireOneMatchingActionAndValidFillNumbers() throws {
    func receipt(_ type: String, _ statuses: [JSONValue]) throws -> ExchangeReceipt {
        try .parse(
            .object([
                "status": .string("ok"),
                "response": .object([
                    "type": .string(type), "data": .object(["statuses": .array(statuses)])
                ])
            ]))
    }
    let resting: JSONValue = .object(["resting": .object(["oid": .integer(123)])])
    #expect(try receipt("order", [resting]).singleStatus(for: .order) == .resting(123))
    #expect(try receipt("cancel", [.string("success")]).singleStatus(for: .cancel) == .canceled)
    for value in [
        try receipt("order", [resting, resting]), try receipt("cancel", [resting]),
        try receipt("order", [.string("success")]),
        try ExchangeReceipt.parse(
            .object(["status": .string("ok"), "response": .object(["type": .string("default")])]))
    ] {
        #expect(throws: APIError.self) { try value.singleStatus(for: .order) }
    }
    for raw in ["0", "-1", "NaN", "1junk", "1e3", "999e999", "1.2.3"] {
        for invalidSize in [true, false] {
            let fill: JSONValue = .object([
                "filled": .object([
                    "oid": .integer(123), "totalSz": .string(invalidSize ? raw : "1"),
                    "avgPx": .string(invalidSize ? "100" : raw)
                ])
            ])
            #expect(throws: APIError.self) {
                try receipt("order", [fill]).singleStatus(for: .order)
            }
        }
    }
}
