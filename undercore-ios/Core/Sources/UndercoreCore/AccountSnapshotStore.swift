import Foundation
import CryptoKit

/// A private, account-scoped metadata snapshot. Only explicitly decoded DTOs are persisted.
/// Downloads, QR payloads, cookies, CSRF and messenger connection tokens never enter this store.
@MainActor public final class AccountSnapshotStore {
    struct Entry: Codable, Sendable { let data: Data; let savedAt: Date }
    private struct Snapshot: Codable, Sendable {
        let version: Int
        let origin: String
        var account: Account
        var entries: [String: Entry]
    }
    private let url: URL
    private let origin: String
    private var snapshot: Snapshot?
    private var generation = 0
    public init(origin: URL, directory: URL? = nil) {
        self.origin = origin.absoluteString
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineAccount", isDirectory: true)
        let key = SHA256.hash(data: Data(origin.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        url = root.appendingPathComponent(key + ".json")
    }
    public func restore() async {
        let version = generation
        let saved = await ArticleCacheFileIO.read(Snapshot.self, from: url)
        guard version == generation, let saved, saved.version == 1, saved.origin == origin,
              saved.account.isEmailVerified else { return }
        snapshot = saved
    }
    public var account: Account? { snapshot?.account }
    public func date(for path: String) -> Date? { snapshot?.entries[path]?.savedAt }
    public func value<T: Decodable>(_ path: String, as type: T.Type = T.self) -> T? {
        guard let data = snapshot?.entries[path]?.data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    public func clear() {
        generation += 1; snapshot = nil
        ArticleCacheFileIO.remove(url)
    }
    func store(path: String, method: String, data: Data, at date: Date) {
        guard let route = SnapshotRoute(path: path, method: method) else { return }
        if case .account = route {
            storeAccount(data, at: date)
            return
        }
        guard snapshot != nil else { return }
        guard storeMetadata(route, path: path, data: data, at: date) else { return }
        persist()
    }

    private func storeAccount(_ data: Data, at date: Date) {
        guard let response = decode(UserResponse.self, data) else { return }
        guard response.user.isEmailVerified else {
            clear()
            return
        }
        if snapshot?.account.id != response.user.id { clear() }
        if snapshot == nil {
            snapshot = Snapshot(version: 1, origin: origin, account: response.user, entries: [:])
        }
        snapshot?.account = response.user
        put(APIEndpoints.account, response, at: date)
        persist()
    }

    private func storeMetadata(_ route: SnapshotRoute, path: String, data: Data, at date: Date) -> Bool {
        switch route {
        case .account:
            return false // Account responses establish the snapshot before metadata can be saved.
        case .configurations:
            return storeConfigurationPage(data, path: path, at: date)
        case .package:
            return storePackage(data, path: path, at: date)
        case .configuration:
            return storeConfiguration(data, at: date)
        case .notifications:
            return storeNotificationPage(data, path: path, at: date)
        case .notificationSummary:
            return storeDecoded(Envelope<NotificationSummary>.self, data, path: path, at: date)
        case .notificationRead:
            guard let response = decode(Envelope<UserNotification>.self, data) else { return false }
            patchNotifications(at: date) { $0.id == response.data.id ? response.data : $0 }
            return true
        case .notificationsReadAll:
            patchNotifications(at: date) { $0.markingRead() }
            return true
        case .messenger:
            return storeDecoded(MessengerConnection.self, data, path: path, at: date)
        }
    }

    private func storeConfigurationPage(_ data: Data, path: String, at date: Date) -> Bool {
        guard let response = decode(Envelope<VPNPage>.self, data) else { return false }
        // A new first page supersedes pagination from the previous listing.
        if response.data.pagination.page == 1 {
            let retained = snapshot?.entries.filter {
                !$0.key.hasPrefix(APIEndpoints.configurations + "?")
            } ?? [:]
            snapshot?.entries = retained
        }
        put(path, response, at: date)
        return true
    }

    private func storePackage(_ data: Data, path: String, at date: Date) -> Bool {
        guard let response = decode(Envelope<VPNPage.Package>.self, data) else { return false }
        put(path, response, at: date)
        patchPackages(response.data, at: date)
        return true
    }

    private func storeConfiguration(_ data: Data, at date: Date) -> Bool {
        guard let response = decode(Envelope<VPNConfiguration>.self, data) else { return false }
        if let path = try? APIEndpoints.configuration(response.data.id) {
            put(path, response, at: date)
        }
        patchConfiguration(response.data, at: date)
        return true
    }

    private func storeNotificationPage(_ data: Data, path: String, at date: Date) -> Bool {
        guard let page = decode(NotificationPage.self, data), page.meta.page == 1 else { return false }
        let recent = NotificationPage(data: Array(page.data.prefix(NotificationPage.recentLimit)), meta: page.meta)
        put(path, recent, at: date)
        return true
    }

    private func storeDecoded<T: Codable>(_ type: T.Type, _ data: Data, path: String, at date: Date) -> Bool {
        guard let response = decode(type, data) else { return false }
        put(path, response, at: date)
        return true
    }

    private var storedPaths: [String] { snapshot.map { Array($0.entries.keys) } ?? [] }

    private func patchNotifications(at date: Date, transform: (UserNotification) -> UserNotification) {
        for path in storedPaths where path.hasPrefix(APIEndpoints.notifications + "?") {
            guard let page: NotificationPage = value(path) else { continue }
            let updated = NotificationPage(data: page.data.map(transform), meta: page.meta)
            put(path, updated, at: self.date(for: path) ?? date)
        }
        // A full account unread total is fetched again by the repository; do not invent it.
        snapshot?.entries.removeValue(forKey: APIEndpoints.notificationSummary)
    }
    private func patchConfiguration(_ config: VPNConfiguration, at date: Date) {
        patchStoredPackages(at: date) { package in
            var updated = package
            for index in updated.slots.indices where updated.slots[index].config?.id == config.id { updated.slots[index].config = config }
            return updated
        }
    }
    private func patchPackages(_ package: VPNPage.Package, at date: Date) {
        patchStoredPackages(at: date) { $0.id == package.id ? package : $0 }
    }
    private func patchStoredPackages(at date: Date, transform: (VPNPage.Package) -> VPNPage.Package) {
        for key in storedPaths {
            guard key.hasPrefix(APIEndpoints.configurations) else { continue }
            if let page: Envelope<VPNPage> = value(key) {
                var updated = VPNPage(configs: page.data.configs, packages: page.data.packages.map(transform), pagination: page.data.pagination, protocols: page.data.protocols)
                updated.automaticConnectionAvailable = page.data.automaticConnectionAvailable
                // Updating one device does not make the whole listing fresh.
                put(key, Envelope(data: updated), at: self.date(for: key) ?? date)
            } else if let package: Envelope<VPNPage.Package> = value(key) {
                put(key, Envelope(data: transform(package.data)), at: self.date(for: key) ?? date)
            }
        }
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }
    private func put<T: Encodable>(_ key: String, _ value: T, at date: Date) {
        guard let data = try? JSONEncoder().encode(value), data.count <= 1_000_000 else { return }
        snapshot?.entries[key] = Entry(data: data, savedAt: date)
    }
    private func persist() {
        generation += 1
        guard var snapshot else { return }
        if snapshot.entries.count > 100 {
            let keys = snapshot.entries.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(100).map(\.key)
            snapshot.entries = snapshot.entries.filter { keys.contains($0.key) }
            self.snapshot = snapshot
        }
        ArticleCacheFileIO.write(snapshot, to: url)
    }
}

public extension Error {
    var isOfflineTransportError: Bool {
        guard let error = self as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed].contains(error.code)
    }
}
