import Foundation

public struct UserNotification: Codable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let title: String
    public let body: String
    public let isRead: Bool
    public let createdAt: String?
    public func markingRead() -> Self {
        Self(id: id, kind: kind, title: title, body: body, isRead: true, createdAt: createdAt)
    }
}
public struct NotificationPage: Codable {
    public static let recentLimit = 30
    public struct Pagination: Codable {
        public let page: Int
        public let lastPage: Int
        enum CodingKeys: String, CodingKey { case page = "current_page", lastPage = "last_page" }
    }
    public let data: [UserNotification]
    public let meta: Pagination
}
public struct NotificationSummary: Codable { public let unreadCount: Int }
public struct NotificationReadResult: Decodable { public let unreadCount: Int; public let updatedCount: Int }

@MainActor public protocol NotificationRepository {
    func page(_ page: Int) async throws -> NotificationPage
    func summary() async throws -> NotificationSummary
    func markRead(_ id: String) async throws -> UserNotification
    func markAllRead() async throws -> NotificationReadResult
}
@MainActor public final class LiveNotificationRepository: NotificationRepository {
    private let client: APIClient
    public init(client: APIClient) { self.client = client }
    public func page(_ page: Int) async throws -> NotificationPage {
        try await client.request(APIRequests.notifications(page: page))
    }
    public func summary() async throws -> NotificationSummary {
        let response: Envelope<NotificationSummary> = try await client.request(APIRequests.notificationSummary)
        return response.data
    }
    public func markRead(_ id: String) async throws -> UserNotification {
        let response: Envelope<UserNotification> = try await client.request(APIRequests.readNotification(id))
        return response.data
    }
    public func markAllRead() async throws -> NotificationReadResult {
        let response: Envelope<NotificationReadResult> = try await client.request(APIRequests.readAllNotifications())
        return response.data
    }
}
