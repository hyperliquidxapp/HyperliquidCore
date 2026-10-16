import Foundation

public struct MarketCatalogSnapshot: Sendable {
    public let markets: [Market]
    public let contexts: [String: AssetContext]
    public let warning: String?
}

struct HIP3Metadata: Sendable {
    let dexs: JSONValue
    let metas: JSONValue
    let receivedAt: Date
}

extension HyperliquidAPI {
    public func catalogSnapshot(refreshMetadata: Bool = false) async throws -> MarketCatalogSnapshot {
        async let perp = info(["type": .string("metaAndAssetCtxs")])
        async let spot = info(["type": .string("spotMetaAndAssetCtxs")])
        async let hip3 = hip3Metadata(forceRefresh: refreshMetadata)
        let (perpData, spotData, builderData) = try await (perp, spot, hip3)
        try Task.checkCancellation()
        let native = try Self.parseCatalog(perp: perpData, spot: spotData)
        var markets = native.markets
        var warning = builderData.warning
        if let metadata = builderData.metadata {
            do {
                markets += try Self.parseHIP3Markets(dexs: metadata.dexs, metas: metadata.metas, spot: spotData)
            } catch {
                warning = "HIP-3 markets unavailable: \(error.localizedDescription)"
            }
        }
        // HIP-3 prices arrive through allDexsAssetCtxs and the selected market's
        // REST snapshot. Cached metadata must never refresh an old mark's age.
        return MarketCatalogSnapshot(markets: markets, contexts: native.contexts, warning: warning)
    }

    private func hip3Metadata(forceRefresh: Bool) async -> (metadata: HIP3Metadata?, warning: String?) {
        if !forceRefresh, let cachedHIP3Metadata,
           (0..<60).contains(Date().timeIntervalSince(cachedHIP3Metadata.receivedAt)) {
            return (cachedHIP3Metadata, nil)
        }
        let request: Task<HIP3Metadata, Error>
        if let pending = hip3MetadataRequest {
            request = pending
        } else {
            request = Task {
                async let dexs = info(["type": .string("perpDexs")])
                async let metas = info(["type": .string("allPerpMetas")])
                return try await HIP3Metadata(dexs: dexs, metas: metas, receivedAt: Date())
            }
            hip3MetadataRequest = request
        }
        do {
            let metadata = try await request.value
            cachedHIP3Metadata = metadata
            hip3MetadataRequest = nil
            return (metadata, nil)
        } catch {
            hip3MetadataRequest = nil
            let detail = cachedHIP3Metadata == nil ? "unavailable" : "could not refresh; showing saved markets"
            return (cachedHIP3Metadata, "HIP-3 directory \(detail): \(error.localizedDescription)")
        }
    }

    public static func parseHIP3Markets(dexs: JSONValue, metas: JSONValue, spot: JSONValue) throws -> [Market] {
        guard case .array(let dexs) = dexs, case .array(let metas) = metas,
              !dexs.isEmpty, dexs.count == metas.count, dexs.count < 10_000, dexs[0] == .null,
              case .array(let tokens) = spot.array.first?["tokens"]
        else { throw APIError.malformed("HIP-3 metadata does not match the DEX directory") }
        var tokenNames: [Int64: String] = [:]
        for token in tokens {
            if let index = token["index"].int64, let name = token["name"].string {
                guard tokenNames.updateValue(name, forKey: index) == nil else {
                    throw APIError.malformed("Duplicate collateral token index")
                }
            }
        }
        var names = Set<String>()
        var markets: [Market] = []
        for dexIndex in dexs.indices.dropFirst() {
            let dex = dexs[dexIndex]
            let meta = metas[dexIndex]
            guard let name = dex["name"].string, !name.isEmpty, !name.contains(":"),
                  names.insert(name).inserted, case .array(let universe) = meta["universe"],
                  universe.count <= 10_000, let collateral = meta["collateralToken"].int64, collateral >= 0
            else { throw APIError.malformed("Invalid HIP-3 DEX metadata") }
            let quote = tokenNames[collateral] ?? "Token #\(collateral)"
            var coins = Set<String>()
            for (index, asset) in universe.enumerated() {
                guard let coin = asset["name"].string, coin.hasPrefix(name + ":"),
                      coins.insert(coin).inserted else {
                    throw APIError.malformed("HIP-3 coin does not match its DEX")
                }
                if asset["isDelisted"].bool == true { continue }
                let symbol = String(coin.dropFirst(name.count + 1))
                guard !symbol.isEmpty, !symbol.contains(":"),
                      let decimals = asset["szDecimals"].int64, (0...6).contains(decimals),
                      let leverage = asset["maxLeverage"].int64, (1...1000).contains(leverage),
                      asset["marginMode"] == .null || asset["marginMode"].string != nil,
                      asset["onlyIsolated"] == .null || asset["onlyIsolated"].bool != nil
                else { throw APIError.malformed("Invalid HIP-3 market parameters") }
                markets.append(Market(
                                coin: coin, symbol: symbol, assetID: 100_000 + dexIndex * 10_000 + index,
                                sizeDecimals: Int(decimals), maxLeverage: Int(leverage), kind: .perp,
                                onlyIsolated: asset["onlyIsolated"].bool ?? false,
                                marginMode: asset["marginMode"].string,
                                quoteTokenIndex: Int(collateral), collateralSymbol: quote,
                                perpDexIndex: dexIndex))
            }
        }
        return markets
    }

    public func builderContext(market: Market) async throws -> AssetContext {
        guard market.isBuilderPerp, let index = market.contextIndex else {
            throw APIError.malformed("Invalid HIP-3 market identity")
        }
        let response = try await info(["type": .string("metaAndAssetCtxs"), "dex": .string(market.perpDex)])
        guard response.array.count == 2,
              response.array[0]["universe"].array.indices.contains(index),
              response.array[0]["universe"].array[index]["name"].string == market.coin,
              response.array[1].array.indices.contains(index)
        else { throw APIError.malformed("HIP-3 context does not match the selected market") }
        return try response.array[1].array[index].decode(AssetContext.self)
    }
}
