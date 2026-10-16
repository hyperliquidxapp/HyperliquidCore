import Foundation

extension OrderBook {
    /// Full-size average execution price versus midpoint; unavailable for insufficient visible depth.
    public func estimatedSlippagePercent(side: OrderSide, quantity: Double) -> Double? {
        guard quantity.isFinite, quantity > 0,
              let bid = bids.first?.price, let ask = asks.first?.price,
              bid.isFinite, ask.isFinite, bid > 0, ask >= bid else { return nil }
        let midpoint = (bid + ask) / 2
        guard midpoint.isFinite else { return nil }
        var remaining = quantity
        var value = 0.0
        var previous = side == .buy ? ask : bid
        for level in side == .buy ? asks : bids {
            let price = level.price
            let size = level.size
            guard price.isFinite, size.isFinite, price > 0, size > 0,
                  side == .buy ? price >= previous : price <= previous else { return nil }
            previous = price
            let filled = min(remaining, size)
            value += filled * price
            remaining -= filled
            if remaining <= 0 {
                let average = value / quantity
                let percent = (side == .buy ? average - midpoint : midpoint - average) / midpoint * 100
                return percent.isFinite ? percent : nil
            }
        }
        return nil
    }
}
