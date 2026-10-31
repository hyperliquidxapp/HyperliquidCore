import Foundation

public enum QuicknodeL4ConfigurationError: Error, Equatable, Sendable {
    case invalidEndpoint, environmentMismatch, invalidCredential
}

/// Public connection coordinates only. Credentials never belong in this value or its URL.
public struct QuicknodeL4Configuration: Equatable, Sendable {
    public let environment: NetworkEnvironment
    public let host: String
    public let port: Int
    public var authority: String { "\(host):\(port)" }

    public init(environment: NetworkEnvironment, endpoint: String) throws {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 300,
              endpoint == endpoint.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw QuicknodeL4ConfigurationError.invalidEndpoint
        }
        let url = endpoint.contains("://") ? endpoint : "grpcs://" + endpoint
        guard let parts = URLComponents(string: url), parts.scheme == "grpcs",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty, let host = parts.host?.lowercased(), !host.contains("%"),
              (parts.port ?? 10000) == 10000 else { throw QuicknodeL4ConfigurationError.invalidEndpoint }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw QuicknodeL4ConfigurationError.invalidEndpoint }
        let suffix = environment == .testnet ? ".hype-testnet.quiknode.pro" : ".hype-mainnet.quiknode.pro"
        guard host.hasSuffix(suffix), host.count > suffix.count else {
            throw QuicknodeL4ConfigurationError.environmentMismatch
        }
        self.environment = environment
        self.host = host
        port = 10000
    }
}

/// A read-only market-data token supplied by the caller, typically from local Keychain storage.
/// This is deliberately neither Codable nor part of the connection configuration.
public struct QuicknodeL4Credential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let metadataValue: String
    public var description: String { "QuicknodeL4Credential([redacted])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": "[redacted]"]) }

    public init(token: String) throws {
        guard !token.isEmpty, token.utf8.count <= 4096,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw QuicknodeL4ConfigurationError.invalidCredential
        }
        metadataValue = token
    }
}
