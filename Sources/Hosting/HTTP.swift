import Foundation

/// Sends an HTTP request. In the app it is URLSession; in tests, a stub with fixtures.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum HTTP {
    /// A session without cache and cookies: we cache API responses ourselves.
    private static let session = URLSession(configuration: .ephemeral)

    public static let urlSession: HTTPTransport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HostingError("Unexpected response from \(request.url?.host() ?? "the server")")
        }
        return (data, http)
    }
}
