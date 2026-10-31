import Foundation
import Testing
@testable import HyperliquidCore

@Suite struct QuicknodeL4ConfigurationTests {
    private let endpoint = "silent-red-dream.hype-testnet.quiknode.pro:10000"

    @Test func publicEndpointKeepsNetworkIdentityAndCanonicalAuthority() throws {
        let config = try QuicknodeL4Configuration(environment: .testnet, endpoint: endpoint)
        #expect(config.environment == .testnet && config.port == 10000 && config.authority == endpoint)
        #expect(try QuicknodeL4Configuration(environment: .testnet, endpoint: "grpcs://" + endpoint) == config)
        #expect(try QuicknodeL4Configuration(environment: .testnet, endpoint: "silent-red-dream.hype-testnet.quiknode.pro") == config)
        #expect(throws: QuicknodeL4ConfigurationError.environmentMismatch) {
            try QuicknodeL4Configuration(environment: .mainnet, endpoint: endpoint)
        }
    }

    @Test func rejectsCredentialURLsUnexpectedPortsAndHostConfusion() throws {
        for invalid in ["https://" + endpoint + "/token", "grpcs://user:password@" + endpoint,
                        endpoint + "/token", endpoint + "?x-token=secret", endpoint + "#secret",
                        "silent-red-dream.hype-testnet.quiknode.pro:443", " " + endpoint,
                        "x..hype-testnet.quiknode.pro:10000", "-x.hype-testnet.quiknode.pro:10000",
                        "x.hype-testnet.quiknode.pro.evil.example:10000", "localhost:10000", ""] {
            #expect(throws: (any Error).self) { try QuicknodeL4Configuration(environment: .testnet, endpoint: invalid) }
        }
    }

    @Test func credentialsRejectMetadataInjectionAndDoNotPrintSecrets() throws {
        let token = "example-test-token"
        let credential = try QuicknodeL4Credential(token: token)
        #expect(credential.metadataValue == token)
        #expect(!String(describing: credential).contains(token))
        #expect(!String(reflecting: credential).contains(token))
        #expect(Mirror(reflecting: credential).children.allSatisfy { String(describing: $0.value) == "[redacted]" })
        for invalid in ["", "token\r\nx-token:other", "token other", "é", String(repeating: "a", count: 4097)] {
            #expect(throws: QuicknodeL4ConfigurationError.invalidCredential) { try QuicknodeL4Credential(token: invalid) }
        }
    }
}
