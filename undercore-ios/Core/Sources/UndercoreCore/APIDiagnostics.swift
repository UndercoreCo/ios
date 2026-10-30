import Foundation
import OSLog

/// Allow-listed metadata only: never URLs, IDs, payloads, cookies or error descriptions.
@MainActor public final class APIDiagnostics {
    public enum Kind: String, Codable {
        case offlineEntered, onlineVerified, cacheRead, requestFailed, httpResponse
        case connectRequested, tunnelStartRequested, tunnelStatus, connectionFailed, cancelled
    }
    public enum Category: String, Codable { case session, configuration, download, notifications, tunnel, other }
    public struct Event: Codable {
        public let time: Date
        public let kind: Kind
        public let category: Category
        public let code: Int?
    }
    public private(set) var events: [Event] = []
    private let log = Logger(subsystem: "ru.undercore.ios", category: "connection")
    public init() {}
    public func record(_ kind: Kind, category: Category = .other, code: Int? = nil) {
        events.append(Event(time: Date(), kind: kind, category: category, code: code))
        if events.count > 200 { events.removeFirst(events.count - 200) }
        log.notice("\(kind.rawValue, privacy: .public) category=\(category.rawValue, privacy: .public) code=\(code ?? 0)")
    }
    public func report(isOffline: Bool) throws -> Data {
        struct Report: Encodable { let version: Int; let cachedDataMode: Bool; let events: [Event] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Report(version: 1, cachedDataMode: isOffline, events: events))
    }
    static func category(for request: APIRequest) -> Category {
        if [APIEndpoints.bootstrap, APIEndpoints.account].contains(request.path) { return .session }
        if request.path.hasPrefix(APIEndpoints.notifications) { return .notifications }
        if request.path.hasPrefix(APIEndpoints.configurations) { return .configuration }
        return .other
    }
}
