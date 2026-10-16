import AsyncHTTPClient
import Foundation
import NIOCore

/// One process-wide connection pool; requests never follow a redirect or retry
/// an exchange POST in application code. TLS validation remains enabled.
public struct NIOHTTPTransport: Sendable {
    private static let client = HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: .init(redirectConfiguration: .disallow))
    public init() {}
    public func get(url: URL, accept: String = "application/json") async throws -> Data {
        try await request(url: url, body: nil, accept: accept)
    }
    public func post(url: URL, body: Data) async throws -> Data {
        try await request(url: url, body: body)
    }
    private func request(url: URL, body: Data?, accept: String = "application/json") async throws -> Data {
        guard url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1"),
              url.user == nil
        else {
            throw APIError.malformed("API requests require HTTPS")
        }
        try Task.checkCancellation()
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = body == nil ? .GET : .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Accept", value: accept)
        if let body { request.body = .bytes(ByteBuffer(bytes: body)) }
        let response = try await Self.client.execute(request, timeout: .seconds(20))
        let buffer = try await response.body.collect(upTo: 16 * 1024 * 1024)
        let data = Data(buffer.readableBytesView)
        try Task.checkCancellation()
        guard (200..<300).contains(Int(response.status.code)) else {
            // Preserve UTF-8 replacement decoding; encoded JSON is UTF-8 and error text may be invalid.
            throw APIError.http(
                // swiftlint:disable:next optional_data_string_conversion
                Int(response.status.code), String(decoding: data.prefix(4096), as: UTF8.self))
        }
        return data
    }
}
