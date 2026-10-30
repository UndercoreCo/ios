import Foundation

public enum APILimits {
    public static let maxConfigurationBytes = 65_536
    public static let requestTimeout: TimeInterval = 20
    public static let resourceTimeout: TimeInterval = 30
}

public enum APIEndpoints {
    public static let bootstrap = "/api/mobile/v1/bootstrap"
    public static let challenge = "/api/mobile/v1/challenge"
    public static let login = "/login"
    public static let register = "/register"
    public static let passwordResetRequest = "/forgot-password"
    public static let profile = "/api/internal/profile"
    public static let logout = "/logout"
    public static let account = "/me"
    public static let verifyEmail = "/api/internal/email/verify"
    public static let verificationStatus = "/api/internal/email/verification?quickResend=1"
    public static let resendEmail = "/api/internal/email/verification-notification"
    public static let pushDevice = "/api/mobile/v1/push-device"
    public static let notifications = "/api/internal/notifications"
    public static func notificationRead(_ id: String) throws -> String {
        guard id.range(of: "^ntf_[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil else { throw ClientError.invalidAddress }
        return notifications + "/" + id + "/read"
    }
    public static let configurations = "/api/internal/vpn"
    public static let connectDevice = "/api/internal/vpn/devices/connect"
    public static func connectionManifest(_ id: String) throws -> String {
        try configuration(id) + "/connection-manifest"
    }
    public static let articles = "/api/mobile/v1/articles"
    public static let notificationSummary = notifications + "/summary"
    public static let notificationsReadAll = notifications + "/read-all"

    public static func configurationPage(_ page: Int) -> String {
        query(configurations, [("page", String(max(1, page)))])
    }

    public static func notificationPage(_ page: Int) -> String {
        query(notifications, [
            ("page", String(max(1, page))),
            ("perPage", String(NotificationPage.recentLimit)),
            ("status", "all")
        ])
    }

    public static func article(_ id: Int) throws -> String {
        guard id > 0 else { throw ClientError.invalidAddress }
        return articles + "/\(id)"
    }

    public static func messenger(_ channel: MessengerChannel) -> String {
        profile + "/" + channel.rawValue
    }

    public static func messengerConnect(_ channel: MessengerChannel) -> String {
        messenger(channel) + "/connect"
    }

    public static func configurationDownload(_ id: String) throws -> String {
        try configuration(id) + "/configuration"
    }

    public static func configurationProtocol(_ id: String) throws -> String {
        try configuration(id) + "/protocol"
    }

    private static func query(_ path: String, _ parameters: [(String, String)]) -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.string!
    }
    public static func package(_ id: String) throws -> String {
        guard id.range(of: "^vpk_[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil else { throw ClientError.invalidAddress }
        return configurations + "/packages/" + id
    }
    public static func slot(_ number: Int, packageID: String) throws -> String {
        guard (1...9).contains(number) else { throw ClientError.invalidAddress }
        return try package(packageID) + "/slots/\(number)"
    }
    public static func configuration(_ id: String) throws -> String {
        guard DeepLink.isConfigurationID(id) else { throw ClientError.invalidAddress }
        return configurations + "/configs/" + id
    }
}

public enum DeepLink: Equatable {
    case configuration(String)
    case syntheticTest(String)
    public static func isConfigurationID(_ value: String) -> Bool {
        value.range(of: "^vpn_[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil
    }
    public static func parse(_ url: URL, allowSynthetic: Bool = false) -> DeepLink? {
        guard url.scheme?.lowercased() == "undercore", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, items.count == 1, let value = items.first?.value else { return nil }
        if url.host == "configuration", items.first?.name == "id", isConfigurationID(value) { return .configuration(value) }
        if allowSynthetic, url.host == "test", items.first?.name == "protocol", ["wg", "awg"].contains(value) { return .syntheticTest(value) }
        return nil
    }
}
