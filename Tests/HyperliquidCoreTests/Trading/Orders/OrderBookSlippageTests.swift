import Testing

@testable import HyperliquidCore

@Test func orderBookSlippageUsesWeightedDepthAndRejectsPartialEstimates() {
    let book = OrderBook(coin: "ETH", time: 0, levels: [
        [BookLevel(px: "99", sz: "1", n: 1), BookLevel(px: "98", sz: "3", n: 1)],
        [BookLevel(px: "101", sz: "1", n: 1), BookLevel(px: "102", sz: "3", n: 1)]
    ])
    #expect(book.estimatedSlippagePercent(side: .buy, quantity: 1) == 1)
    #expect(book.estimatedSlippagePercent(side: .buy, quantity: 2) == 1.5)
    #expect(book.estimatedSlippagePercent(side: .sell, quantity: 2) == 1.5)
    #expect(book.estimatedSlippagePercent(side: .buy, quantity: 5) == nil)
    #expect(book.estimatedSlippagePercent(side: .buy, quantity: 0) == nil)
    #expect(book.estimatedSlippagePercent(side: .buy, quantity: .nan) == nil)
    let empty = OrderBook(coin: "ETH", time: 0, levels: [])
    #expect(empty.estimatedSlippagePercent(side: .buy, quantity: 1) == nil)
}
