import Foundation

public enum AgentTool: Sendable, Equatable {
    case risk
    case scenario(Decimal)
    case funding, openInterest, volatility
    case orders, fills, balances, positions, account, largeTrades
    case reduce(Decimal)
    case protection(OrderKind, Decimal)
    case reverse
    case help
    public var needsPerpetual: Bool {
        switch self {
        case .risk, .scenario, .funding, .openInterest, .reduce, .protection, .reverse: true
        default: false
        }
    }
    public var preparesOrder: Bool {
        switch self {
        case .reduce, .protection, .reverse: true
        default: false
        }
    }
}

public struct AgentQuery: Sendable, Equatable {
    public let tool: AgentTool
    public let market: Market?
    public let explicitMarket: Bool
    public static func parse(_ question: String, markets: [Market], selected: Market?) throws
    -> AgentQuery {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw OrderValidationError.invalid("请输入一个工作台问题。") }
        let namingText = q.replacingOccurrences(of: "/usdc", with: "")
        let named = markets.filter { containsSymbol($0.symbol.lowercased(), in: namingText) }
        let longest = named.map { $0.symbol.count }.max()
        let matches = named.filter { $0.symbol.count == longest }
        var numberText = q
        for symbol in Set(named.map { $0.symbol.lowercased() }) {
            numberText = numberText.replacingOccurrences(
                of: "(?<![a-z0-9_])" + NSRegularExpression.escapedPattern(for: symbol)
                    + "(?![a-z0-9_])", with: " ",
                options: .regularExpression)
        }
        func has(_ words: [String]) -> Bool {
            words.contains { word in
                word.unicodeScalars.allSatisfy({ $0.isASCII })
                    ? containsSymbol(word, in: q) : q.contains(word)
            }
        }
        let tool: AgentTool
        let mutation = has([
            "减仓", "减掉", "减少", "reduce", "close", "平仓", "止损", "stop loss", "止盈", "take profit", "反手",
            "reverse"
        ])
        let conditional = has(["如果", "what if", "假如"])
        let questionOnly = has([
            "怎么", "如何", "how", "为什么", "why", "能否", "可以吗", "should", "show", "查询", "查看", "已有", "现有"
        ])
        let actionKinds = [
            has(["减仓", "减掉", "减少", "reduce", "close", "平仓"]), has(["止损", "stop loss"]),
            has(["止盈", "take profit"]),
            has(["反手", "reverse"])
        ].filter { $0 }.count
        if actionKinds > 1 && !conditional && !questionOnly {
            throw OrderValidationError.invalid("目前请每次准备一个仓位操作，分别检查对应订单意图。")
        }
        if mutation && has(["不要", "别", "不想", "do not", "don't", "never"]) {
            tool = .help
        } else if mutation && (conditional || questionOnly) {
            // Questions and hypothetical instructions are never converted to an action.
            tool = conditional ? .scenario(try target(numberText)) : .help
        } else if has(["止损", "stop loss", "止盈", "take profit"]) {
            tool = .protection(
                has(["止盈", "take profit"]) ? .takeProfit : .stop, try target(numberText))
        } else if has(["反手", "reverse"]) {
            tool = .reverse
        } else if has(["减仓", "减掉", "减少", "reduce", "close", "平仓"]) {
            let percent =
                firstCapture(
                    #"(?<![a-z0-9.,])([+-]?[0-9]+(?:\.[0-9]+)?)\s*(?:%|percent\b)"#, in: numberText)
                ?? firstCapture(#"百分之\s*([+-]?[0-9]+(?:\.[0-9]+)?)"#, in: numberText)
            let amount: Decimal
            if let percent {
                amount = try ReviewDecimal.parse(
                    percent.hasPrefix("+") ? String(percent.dropFirst()) : percent)
            } else if has(["一半", "half"]) {
                amount = 50
            } else if has(["四分之一", "quarter"]) {
                amount = 25
            } else if has(["全部", "all", "close", "平仓"]) {
                guard firstCapture(#"([0-9]+(?:\.[0-9]+)?)"#, in: numberText) == nil else {
                    throw OrderValidationError.invalid("请标明平仓比例，例如 close ETH 25%。")
                }
                amount = 100
            } else {
                guard firstCapture(#"([0-9]+(?:\.[0-9]+)?)"#, in: numberText) == nil else {
                    throw OrderValidationError.invalid("请标明减仓比例，例如：把 ETH 仓位减掉 25%。")
                }
                amount = 25
            }
            guard amount > 0 && amount <= 100 else {
                throw OrderValidationError.invalid("减仓比例必须大于 0% 且不超过 100%。")
            }
            tool = .reduce(amount / 100)
        } else if conditional
                    || has(["盈亏", "pnl"]) && firstCapture(#"([0-9]+(?:\.[0-9]+)?)"#, in: numberText) != nil {
            tool = .scenario(try target(numberText))
        } else if has(["挂单", "未成交订单", "open orders", "orders", "订单"]) {
            tool = .orders
        } else if has(["成交记录", "历史成交", "成交历史", "历史交易", "fills", "trade history", "交易记录"]) {
            tool = .fills
        } else if has(["余额", "balance", "balances"]) {
            tool = .balances
        } else if has(["大单", "large trades", "large", "whales"]) {
            tool = .largeTrades
        } else if has(["funding", "资金费", "费率"]) {
            tool = .funding
        } else if has(["open interest", "oi", "持仓量", "未平仓量"]) {
            tool = .openInterest
        } else if has(["波动", "volatility"]) {
            tool = .volatility
        } else if has(["风险", "risk", "清算", "liquidation"]) {
            tool = .risk
        } else if has(["账户", "account"]) {
            tool = .account
        } else if has(["仓位", "positions", "position"]) {
            tool = .positions
        } else {
            tool = .help
        }

        let explicitSpot = has(["现货", "spot"]) || q.contains("/usdc")
        let explicitPerp = has(["永续", "perp"]) || q.contains("-perp")
        guard !(explicitSpot && explicitPerp) else {
            throw OrderValidationError.invalid("请指定现货或永续中的一个市场。")
        }
        guard Set(named.map(\.symbol)).count <= 1 else {
            throw OrderValidationError.invalid("请一次指定一个市场。")
        }
        let languageWords: Set<String> = Set(
            "usd usdc oi pnl tp sl perp spot funding what if at to my for close reduce risk stop loss take profit order orders balance balances account position positions volatility liquidation large trade trades history fills fill half quarter all percent price prices please set give put make me the a an i of on in by now current currently do not don t never how why can should show reaches hits would happen recently recent rate rates open interest is are was were does have has total amount size limit market latest will one"
                .split(separator: " ").map(String.init))
        let accepted = Set(markets.map { $0.symbol.lowercased() }).union(languageWords)
        let identifierPattern =
            tool.preparesOrder
            ? #"(?<![A-Za-z0-9_])([A-Za-z0-9_]*[A-Za-z][A-Za-z0-9_]*)(?![A-Za-z0-9_])"#
            : #"(?<![A-Za-z0-9_])([A-Z][A-Z0-9]{1,})(?![A-Za-z0-9_])"#
        if let regex = try? NSRegularExpression(pattern: identifierPattern) {
            let tokens = regex.matches(
                in: question, range: NSRange(question.startIndex..., in: question)
            ).compactMap {
                match -> String? in
                guard let range = Range(match.range(at: 1), in: question) else { return nil }
                return String(question[range])
            }
            if let unknown = tokens.first(where: { !accepted.contains($0.lowercased()) }) {
                throw OrderValidationError.invalid("未识别 \(unknown)，请检查市场名称或选择明确的仓位操作。")
            }
        }
        let resolved: Market?
        if !matches.isEmpty {
            let kind: Market.Kind =
                explicitSpot
                ? .spot
                : explicitPerp || tool.needsPerpetual
                ? .perp : (matches.first { $0.coin == selected?.coin }?.kind ?? .perp)
            let candidates = matches.filter { $0.kind == kind }
            guard let candidate = candidates.first else {
                throw OrderValidationError.invalid("没有找到指定类型的市场。")
            }
            if let selectedCandidate = candidates.first(where: { $0.coin == selected?.coin }) {
                resolved = selectedCandidate
            } else {
                guard candidates.count == 1 else {
                    throw OrderValidationError.invalid("该名称对应多个市场，请先在市场切换器中选择具体市场。")
                }
                resolved = candidate
            }
        } else if let selected, tool.needsPerpetual && selected.kind == .spot && !explicitSpot {
            resolved = markets.first { $0.symbol == selected.symbol && $0.kind == .perp }
        } else {
            resolved = selected
        }
        if tool.needsPerpetual, resolved?.kind == .spot {
            throw OrderValidationError.invalid("该查询或仓位操作需要永续市场；现货没有永续仓位或资金费率。")
        }
        return AgentQuery(tool: tool, market: resolved, explicitMarket: !matches.isEmpty)
    }
    private static func containsSymbol(_ symbol: String, in text: String) -> Bool {
        text.range(
            of: "(?<![a-z0-9_])" + NSRegularExpression.escapedPattern(for: symbol)
                + "(?![a-z0-9_])",
            options: .regularExpression) != nil
    }
    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
    private static func target(_ text: String) throws -> Decimal {
        let raw = firstCapture(
            #"(?:到|在|至|价格|(?<![a-z])at\b|(?<![a-z])to\b|(?<![a-z])reaches\b|(?<![a-z])hits\b)\s*\$?\s*([+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(?![0-9,eE])"#,
            in: text)
        guard let raw else {
            throw OrderValidationError.invalid("请指定目标价格，例如：如果 ETH 到 4200，或给 ETH 设置止损在 4180。")
        }
        let clean = raw.replacingOccurrences(of: ",", with: "")
        let value = try ReviewDecimal.parse(
            clean.hasPrefix("+") ? String(clean.dropFirst()) : clean)
        guard value > 0 else { throw OrderValidationError.invalid("目标价格必须大于零。") }
        return value
    }
}
