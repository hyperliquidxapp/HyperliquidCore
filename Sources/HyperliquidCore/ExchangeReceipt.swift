import Foundation

public enum ExchangeRejection: LocalizedError, Sendable {
    case rejected(String)
    public var errorDescription: String? {
        switch self {
        case .rejected(let reason): reason
        }
    }
}

public struct ExchangeReceipt: Sendable {
    public enum Status: Sendable, Equatable {
        case resting(UInt64)
        case filled(UInt64, String, String)
        case canceled
        case rejected(String)
    }
    public let statuses: [Status]
    public let responseType: String?
    public enum Action { case order, cancel }
    public func singleStatus(for action: Action) throws -> Status {
        guard responseType == (action == .order ? "order" : "cancel"), statuses.count == 1 else {
            throw APIError.malformed("Expected one matching exchange action status")
        }
        let status = statuses[0]
        switch (action, status) {
        case (_, .rejected), (.order, .resting), (.cancel, .canceled): return status
        case (.order, .filled(_, let size, let price)):
            guard size.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                  price.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
                  let size = Decimal(string: size, locale: Locale(identifier: "en_US_POSIX")),
                  !size.isNaN, size > 0,
                  let price = Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")),
                  !price.isNaN, price > 0
            else {
                throw APIError.malformed("Invalid exchange fill quantity or price")
            }
            return status
        default: throw APIError.malformed("Exchange status does not match the submitted action")
        }
    }
    public static func parse(_ value: JSONValue) throws -> ExchangeReceipt {
        guard value["status"].string == "ok" else {
            throw ExchangeRejection.rejected(
                value["response"].string ?? "Exchange rejected the action")
        }
        let responseType = value["response"]["type"].string
        if responseType == "default" {
            return ExchangeReceipt(statuses: [], responseType: responseType)
        }
        let raw = value["response"]["data"]["statuses"].array
        guard !raw.isEmpty else { throw APIError.malformed("Exchange returned no action status") }
        let statuses: [Status] = try raw.map { status in
            if let error = status["error"].string { return .rejected(error) }
            if status.string == "success" { return .canceled }
            if let oid = status["resting"]["oid"].int64, oid >= 0 { return .resting(UInt64(oid)) }
            if let oid = status["filled"]["oid"].int64, oid >= 0,
               let sz = status["filled"]["totalSz"].string,
               let px = status["filled"]["avgPx"].string {
                return .filled(UInt64(oid), sz, px)
            }
            throw APIError.malformed("Unrecognized exchange action status")
        }
        return ExchangeReceipt(statuses: statuses, responseType: responseType)
    }
}
