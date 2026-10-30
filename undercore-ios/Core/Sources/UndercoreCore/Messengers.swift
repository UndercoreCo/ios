import Foundation

public enum MessengerChannel: String, CaseIterable, Hashable {
    case telegram, max
    public var title: String { self == .telegram ? "Telegram" : "MAX" }
    public var host: String { self == .telegram ? "t.me" : "max.ru" }
    public var path: String { APIEndpoints.messenger(self) }
}
public struct MessengerConnection: Codable {
    public struct Account: Codable {
        public let username: String?
        public let displayName: String?
        public let connectedAt: String?
    }
    public let available: Bool
    public let connected: Bool
    public let account: Account?
    public var accountLabel: String? {
        if let name = account?.username, !name.isEmpty { return "@" + name.trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
        return account?.displayName
    }
}
public struct MessengerConnectionLink: Decodable {
    public let url: String
    public let expiresAt: String
    /// Keep one-time tokens in memory only and open only the expected messenger origin.
    public func validatedURL(for channel: MessengerChannel, now: Date = Date()) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiry = formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt), expiry > now,
              let parts = URLComponents(string: url), parts.scheme == "https", parts.host == channel.host,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.percentEncodedPath.range(of: "^/[A-Za-z0-9_-]{1,128}\\z", options: .regularExpression) != nil,
              let items = parts.queryItems, items.count == 1, items[0].name == "start",
              let token = items[0].value, token.range(of: "^[A-Za-z0-9]{48}\\z", options: .regularExpression) != nil,
              let result = parts.url else { throw ClientError.invalidResponse }
        return result
    }
}
@MainActor public protocol MessengerRepository {
    func status(_ channel: MessengerChannel) async throws -> MessengerConnection
    func connect(_ channel: MessengerChannel) async throws -> URL
    func disconnect(_ channel: MessengerChannel) async throws
}
@MainActor public final class LiveMessengerRepository: MessengerRepository {
    private let client: APIClient
    public init(client: APIClient) { self.client = client }
    public func status(_ channel: MessengerChannel) async throws -> MessengerConnection {
        try await client.request(APIRequests.messenger(channel))
    }
    public func connect(_ channel: MessengerChannel) async throws -> URL {
        let link: MessengerConnectionLink = try await client.request(APIRequests.connectMessenger(channel))
        return try link.validatedURL(for: channel)
    }
    public func disconnect(_ channel: MessengerChannel) async throws {
        try await client.requestEmpty(APIRequests.disconnectMessenger(channel))
    }
}
