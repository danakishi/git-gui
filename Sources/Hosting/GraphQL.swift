import Foundation

/// Hosting provider GraphQL API client: sends a request with a token and turns errors into user-facing text.
struct GraphQLClient: Sendable {
    /// Service name used in error messages: "GitHub", "gitlab.example.com".
    let service: String
    let endpoint: URL
    let token: String
    let transport: HTTPTransport

    func query<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitGui", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Request(query: query, variables: variables))
        request.timeoutInterval = 30

        let body: Data
        let response: HTTPURLResponse
        do {
            (body, response) = try await transport(request)
        } catch let e as HostingError {
            throw e
        } catch {
            throw HostingError("\(service) is unavailable: \(error.localizedDescription)")
        }
        switch response.statusCode {
        case 200: break
        case 401:
            throw HostingError("\(service) rejected the token: it is invalid or revoked")
        case 403, 429:
            throw HostingError(rateLimitMessage(response) ?? "\(service) denied access (\(response.statusCode))")
        default:
            throw HostingError("\(service) responded with \(response.statusCode)")
        }

        let decoded: Response<T>
        do {
            decoded = try JSONDecoder().decode(Response<T>.self, from: body)
        } catch {
            throw HostingError("Couldn't parse the response from \(service): \(error)")
        }
        // If there is no data at all, show the error. Partial errors (for example,
        // NOT_FOUND for a single object) don't affect the rest of the response.
        if let data = decoded.data { return data }
        let errors = decoded.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            throw HostingError("Rate limit for \(service) exceeded")
        }
        let messages = errors.map(\.message)
        throw HostingError("\(service) error: " + (messages.isEmpty ? "empty response" : messages.joined(separator: "; ")))
    }

    /// GitHub sends `x-ratelimit-*`, GitLab sends `RateLimit-*`; header names are case-insensitive.
    private func rateLimitMessage(_ response: HTTPURLResponse) -> String? {
        let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining")
            ?? response.value(forHTTPHeaderField: "ratelimit-remaining")
        guard remaining == "0" || response.statusCode == 429 else { return nil }
        let reset = (response.value(forHTTPHeaderField: "x-ratelimit-reset")
            ?? response.value(forHTTPHeaderField: "ratelimit-reset")).flatMap(TimeInterval.init)
        if let reset {
            let time = Date(timeIntervalSince1970: reset).formatted(date: .omitted, time: .shortened)
            return "Rate limit for \(service) exceeded until \(time)"
        }
        return "Rate limit for \(service) exceeded"
    }

    private struct Request: Encodable {
        let query: String
        let variables: [String: String]
    }

    private struct Response<D: Decodable>: Decodable {
        let data: D?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        let message: String
        let type: String?
    }
}

/// Key for fields with computed names (`c0`, `c1`…) that we set via aliases.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    /// A commit alias: `c` followed by a number.
    var isCommitAlias: Bool {
        stringValue.hasPrefix("c") && stringValue.count > 1 && stringValue.dropFirst().allSatisfy(\.isNumber)
    }

    var commitIndex: Int? { isCommitAlias ? Int(stringValue.dropFirst()) : nil }
}
