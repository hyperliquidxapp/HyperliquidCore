import Foundation

public struct CandleVolatility: Sendable, Equatable {
    public let candleCount: Int
    public let returnCount: Int
    public let startTime: Int64
    public let endTime: Int64
    public let gapCount: Int
    public let realizedPercent: Double
    public let changePercent: Double
    public static func calculate(_ candles: [Candle], coin: String, now: Int64) throws
    -> CandleVolatility {
        var unique: [Int64: Candle] = [:]
        for candle in candles where candle.s == coin && candle.i == "1m" && candle.T < now {
            guard candle.t >= 0, candle.T >= candle.t, candle.close.isFinite, candle.close > 0
            else {
                throw OrderValidationError.invalid("波动率数据包含无效价格。")
            }
            unique[candle.t] = candle
        }
        let ordered = unique.values.sorted { $0.t < $1.t }
        guard let first = ordered.first, let last = ordered.last, ordered.count >= 2 else {
            throw OrderValidationError.invalid("已完成的一分钟 K 线不足，无法计算波动率。")
        }
        var squaredReturns = 0.0
        var count = 0
        var gaps = 0
        for index in 1..<ordered.count {
            guard ordered[index].t - ordered[index - 1].t == 60_000 else {
                gaps += 1
                continue
            }
            let value = log(ordered[index].close / ordered[index - 1].close)
            guard value.isFinite else { throw OrderValidationError.invalid("无法计算价格收益率。") }
            squaredReturns += value * value
            count += 1
        }
        guard count > 0 else { throw OrderValidationError.invalid("没有连续的一分钟 K 线，无法计算波动率。") }
        return CandleVolatility(
            candleCount: ordered.count, returnCount: count, startTime: first.t, endTime: last.t,
            gapCount: gaps, realizedPercent: sqrt(squaredReturns) * 100,
            changePercent: (last.close / first.close - 1) * 100)
    }
}

public struct FundingObservation: Sendable, Equatable {
    public let count: Int
    public let latest: Double
    public let average: Double
    public let cumulative: Double
    public static func calculate(_ response: JSONValue, coin: String, start: Int64, end: Int64)
    throws
    -> FundingObservation {
        guard case .array(let rows) = response else { throw APIError.malformed("资金费率数据格式无效。") }
        var byTime: [Int64: Double] = [:]
        for row in rows {
            guard row["coin"].string == coin, let time = row["time"].int64,
                  let rate = row["fundingRate"].double,
                  rate.isFinite
            else {
                throw APIError.malformed("资金费率数据与请求的市场不符。")
            }
            if time >= start && time <= end {
                if let existing = byTime[time], existing != rate {
                    throw APIError.malformed("同一期资金费率出现相互冲突的记录。")
                }
                byTime[time] = rate
            }
        }
        let ordered = byTime.sorted { $0.key < $1.key }
        guard let last = ordered.last else { throw APIError.malformed("请求时间范围内没有资金费率记录。") }
        let sum = ordered.reduce(0.0) { $0 + $1.value }
        guard sum.isFinite else { throw APIError.malformed("资金费率合计超出可用范围。") }
        return FundingObservation(
            count: ordered.count, latest: last.value, average: sum / Double(ordered.count),
            cumulative: sum)
    }
}

public enum AgentPositionAnalysis {
    public static func hypotheticalPnL(position: Position, target: Decimal) throws -> Decimal {
        guard target > 0, let entry = position.entryPx else {
            throw OrderValidationError.invalid("目标价格或入场价格不可用。")
        }
        let entryValue = try ReviewDecimal.parse(entry)
        let size = try ReviewDecimal.parse(position.szi)
        guard entryValue > 0, size != 0 else { throw OrderValidationError.invalid("没有可计算的仓位。") }
        let result = (target - entryValue) * size
        guard !result.isNaN else { throw OrderValidationError.invalid("盈亏计算超出可用范围。") }
        return result
    }
}
