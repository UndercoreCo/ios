import Foundation

/// Explicit allow-list for metadata snapshots. It never admits downloads or connection tokens.
enum SnapshotRoute {
    case account, configurations, package, configuration
    case notifications, notificationSummary, notificationRead, notificationsReadAll, messenger

    init?(path: String, method: String) {
        let route = String(path.split(separator: "?", maxSplits: 1).first ?? "")
        switch method {
        case "GET":
            if path == APIEndpoints.account { self = .account }
            else if route == APIEndpoints.configurations { self = .configurations }
            else if Self.isPackage(route) { self = .package }
            else if Self.isConfiguration(route) { self = .configuration }
            else if route == APIEndpoints.notifications { self = .notifications }
            else if path == APIEndpoints.notificationSummary { self = .notificationSummary }
            else if MessengerChannel.allCases.contains(where: { APIEndpoints.messenger($0) == path }) { self = .messenger }
            else { return nil }
        case "POST":
            if [APIEndpoints.login, APIEndpoints.register].contains(path) { self = .account }
            else if Self.isConfiguration(route) { self = .configuration }
            else if route == APIEndpoints.notificationsReadAll { self = .notificationsReadAll }
            else { return nil }
        case "PATCH":
            if Self.isConfiguration(route) { self = .configuration }
            else if route.hasPrefix(APIEndpoints.notifications + "/"), route.hasSuffix("/read") { self = .notificationRead }
            else { return nil }
        default:
            return nil
        }
    }

    /// Detail reads must reach the server: they also confirm completion of pending operations.
    static func canReadOffline(_ path: String) -> Bool {
        path == APIEndpoints.account
            || path.hasPrefix(APIEndpoints.configurations + "?")
            || path.hasPrefix(APIEndpoints.notifications + "?")
            || path == APIEndpoints.notificationSummary
            || MessengerChannel.allCases.contains { APIEndpoints.messenger($0) == path }
    }

    private static func isPackage(_ route: String) -> Bool {
        guard let id = route.split(separator: "/").last else { return false }
        return (try? APIEndpoints.package(String(id))) == route
    }

    private static func isConfiguration(_ route: String) -> Bool {
        let components = route.split(separator: "/")
        let isProtocol = components.last == "protocol"
        guard let id = (isProtocol ? components.dropLast() : components[...]).last else { return false }
        let expected = try? (isProtocol
            ? APIEndpoints.configurationProtocol(String(id))
            : APIEndpoints.configuration(String(id)))
        return expected == route
    }
}
