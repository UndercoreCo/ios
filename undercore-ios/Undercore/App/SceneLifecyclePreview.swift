#if DEBUG && targetEnvironment(simulator)
import UIKit
import UndercoreCore

/// Isolated lifecycle verification uses real repositories/coordinator, synthetic HTTP and memory-only credentials.
/// Persist the opt-in in this simulator so an OS cold launch by URL uses the same fixture.
@MainActor enum SceneLifecyclePreview {
    static var offlineMode: String? { ProcessInfo.processInfo.arguments.first { ["--preview-offline-seed", "--preview-offline-cold", "--preview-offline-notifications", "--preview-offline-profile", "--preview-offline-reconnect"].contains($0) } }
    static let enabled: Bool = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--end-scene-preview") { UserDefaults.standard.removeObject(forKey: "sceneLifecyclePreview") }
        if args.contains("--preview-scene-lifecycle") { UserDefaults.standard.set(true, forKey: "sceneLifecyclePreview") }
        return offlineMode != nil || UserDefaults.standard.bool(forKey: "sceneLifecyclePreview")
    }()
    static func client() throws -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SceneFixtureProtocol.self]
        let origin = URL(string: "https://scene.example.test")!
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineFixture")
        let snapshots = offlineMode != nil ? AccountSnapshotStore(origin: origin, directory: directory) : nil
        if offlineMode == "--preview-offline-seed" { snapshots?.clear() }
        SceneFixtureProtocol.offline = offlineMode != nil && offlineMode != "--preview-offline-seed"
        return try APIClient(baseURL: origin, store: SceneMemorySession(offlineFixture: offlineMode != nil), session: URLSession(configuration: configuration), snapshots: snapshots)
    }
    static func verifyOffline(_ coordinator: AppCoordinator, client: APIClient) {
        guard let mode = offlineMode else { return }
        Task { @MainActor in
            for _ in 0..<100 {
                if coordinator.navigation.topViewController is AppTabBarController,
                   client.cachedDate(for: APIEndpoints.configurationPage(1)) != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let tabs = coordinator.navigation.topViewController as? AppTabBarController else { preconditionFailure("Offline cold launch lost account") }
            try? await Task.sleep(for: .milliseconds(700))
            precondition(client.cachedDate(for: APIEndpoints.configurationPage(1)) != nil)
            precondition(client.cachedDate(for: APIEndpoints.notificationPage(1)) != nil)
            precondition(client.cachedDate(for: MessengerChannel.telegram.path) != nil)
            if mode == "--preview-offline-seed" {
                precondition(!client.isOffline)
                print("OFFLINE CHECK PASS: real repositories seeded account, subscriptions, notifications and bot metadata")
                return
            }
            precondition(client.isOffline)
            tabs.selectSection(section(0, in: tabs))
            try? await Task.sleep(for: .milliseconds(500))
            let configs = (section(0, in: tabs) as! UINavigationController).topViewController!
            precondition(labels(configs.view).contains { $0.contains("Рабочий iPhone") })
            precondition(labels(configs.view).contains { $0.contains("Последнее подключение:") })
            precondition(descendants(configs.view).contains { $0 is OfflineBannerView && !$0.isHidden })
            if mode == "--preview-offline-notifications" {
                tabs.selectSection(section(1, in: tabs))
                try? await Task.sleep(for: .milliseconds(500))
                let notifications = (section(1, in: tabs) as! UINavigationController).topViewController!
                precondition(labels(notifications.view).contains { $0 == "Офлайн-уведомление" })
            } else if mode == "--preview-offline-profile" {
                #if UNDERCORE_VPN
                coordinator.showAccount()
                #else
                tabs.selectSection(section(2, in: tabs))
                #endif
            } else if mode == "--preview-offline-reconnect" {
                SceneFixtureProtocol.offline = false
                coordinator.refreshNotifications()
                for _ in 0..<100 {
                    if !client.isOffline { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                precondition(!client.isOffline, "Verified reconnect did not enable online mode")
            }
            precondition(SceneFixtureProtocol.offlineMutations == 0, "Offline UI sent a mutation")
            print("OFFLINE CHECK PASS: \(mode), restored after process restart; private actions blocked; offline mutations = 0")
        }
    }
    private static func section(_ tag: Int, in tabs: AppTabBarController) -> UIViewController {
        tabs.rootSections.first { $0.tabBarItem.tag == tag }!
    }
    private static func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    private static func labels(_ view: UIView) -> [String] { descendants(view).compactMap { ($0 as? UILabel)?.text } }
    static func inspectLink(_ url: URL, coordinator: AppCoordinator) {
        guard case .configuration = DeepLink.parse(url) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let tabs = coordinator.navigation.topViewController as? AppTabBarController
            let nav = tabs?.rootSections.first { $0.tabBarItem.tag == 0 } as? UINavigationController
            precondition(nav?.topViewController is TransferViewController, "Scene URL did not reach the transfer screen after restoring authentication")
            print("SCENE CHECK PASS: configuration URL reached transfer screen")
        }
    }
}
private final class SceneMemorySession: SessionStore {
    private var credentials: SessionCredentials?
    init(offlineFixture: Bool = false) {
        if offlineFixture { credentials = SessionCredentials(origin: "https://scene.example.test", cookieName: "preview_session", cookieValue: "synthetic", expiresAt: Date().addingTimeInterval(86400)) }
    }
    func load() throws -> SessionCredentials? { credentials }
    func save(_ value: SessionCredentials) throws { credentials = value }
    func clear() throws { credentials = nil }
}
private final class SceneFixtureProtocol: URLProtocol {
    static var offline = false
    static var offlineMutations = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        precondition(url.host == "scene.example.test", "Lifecycle fixture must not contact production")
        if Self.offline {
            if request.httpMethod != "GET" { Self.offlineMutations += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let config = #"{"id":"vpn_00000000000000000000000001","name":"Рабочий iPhone","protocol":"amneziawg","state":"active","connection":{"status":"confirmed","lastHandshakeAt":"2026-10-05T10:00:00Z","checkedAt":"2026-10-05T10:05:00Z"},"canDownload":true,"canRename":true}"#
        let body: String
        switch url.path {
        case APIEndpoints.bootstrap:
            body = #"{"data":{"apiVersion":1,"csrfToken":"preview","sessionCookieName":"preview_session","sessionLifetimeSeconds":1209600,"challenge":{"provider":"none","siteKey":"","tokenField":"smart-token","required":false}}}"#
        case APIEndpoints.account:
            body = #"{"user":{"id":0,"name":"Preview","email":"preview@example.test","isEmailVerified":true}}"#
        case APIEndpoints.configurations:
            body = """
            {"data":{"configs":[],"packages":[{"id":"vpk_00000000000000000000000001","name":"3 устройства","deviceCount":3,"usedSlots":1,"origin":"purchase","expiresAt":"2027-01-01T00:00:00Z","slots":[{"number":1,"occupied":true,"canActivate":false,"config":\(config)},{"number":2,"occupied":false,"canActivate":true,"config":null}]}],"pagination":{"page":1,"lastPage":1}}}
            """
        case APIEndpoints.configurations + "/configs/vpn_00000000000000000000000001":
            body = "{\"data\":\(config)}"
        case APIEndpoints.notifications:
            body = #"{"data":[{"id":"ntf_00000000000000000000000001","kind":"info","title":"Офлайн-уведомление","body":"Сохранённое сообщение доступно без сети","isRead":false,"createdAt":"2026-10-05T10:00:00Z"}],"meta":{"current_page":1,"last_page":1}}"#
        case APIEndpoints.notifications + "/ntf_00000000000000000000000001",
             APIEndpoints.notifications + "/ntf_00000000000000000000000001/read":
            body = #"{"data":{"id":"ntf_00000000000000000000000001","kind":"info","title":"Проверка открытия push","body":"Сообщение загружено через защищённый API","isRead":true,"createdAt":"2026-10-07T08:00:00Z"}}"#
        case APIEndpoints.pushDevice:
            body = #"{"bindingID":"00000000-0000-4000-8000-000000000001"}"#
        case MessengerChannel.telegram.path, MessengerChannel.max.path:
            body = #"{"available":true,"connected":false,"account":null}"#
        case APIEndpoints.notifications + "/summary": body = #"{"data":{"unreadCount":0}}"#
        case "/api/mobile/v1/articles": body = #"{"data":[]}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json", "Set-Cookie":"preview_session=synthetic; Path=/; Secure; HttpOnly"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
