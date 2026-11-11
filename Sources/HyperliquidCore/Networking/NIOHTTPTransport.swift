import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// One process-wide connection pool; requests never follow a redirect or retry
/// an exchange POST in application code. TLS validation remains enabled.
public struct NIOHTTPTransport: Sendable {
    private static let client: HTTPClient = {
        var configuration = HTTPClient.Configuration(redirectConfiguration: .disallow)
        // Request tracing is not used by the SDK. Skip withSpan/TaskLocal entirely,
        // including Swift's affected macOS 14 backdeployment path.
        configuration.tracing.tracer = nil
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }()
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
        try NIOTransportRuntime.validate()
        let request = try HTTPClient.Request(
            url: url.absoluteString, method: body == nil ? .GET : .POST,
            headers: HTTPHeaders([("Content-Type", "application/json"), ("Accept", accept)]),
            body: body.map { .byteBuffer(ByteBuffer(bytes: $0)) })
        try Task.checkCancellation()
        let operation = Self.client.execute(
            request: request,
            delegate: ResponseAccumulator(request: request, maxBodySize: 16 * 1024 * 1024),
            deadline: .now() + .seconds(20))
        // The callback API avoids AHC's executeCancellable async frame, which
        // aborts in the supplied macOS 14 report. A NIO future completes once;
        // this gives the unsafe continuation exactly one completion as well.
        let response = try await withTaskCancellationHandler {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<HTTPClient.Response, Error>) in
                operation.futureResult.whenComplete { continuation.resume(with: $0) }
            }
        } onCancel: {
            operation.cancel()
        }
        let data = response.body.map { Data($0.readableBytesView) } ?? Data()
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
