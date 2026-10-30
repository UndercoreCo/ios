import UIKit
import UndercoreCore

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var coordinator: AppCoordinator?
    private var privacyCover: UIView?
    private var pendingURLs: [URL] = []

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        #if DEBUG && targetEnvironment(simulator)
        // Process reset flags even when displaying an isolated visual preview.
        let lifecyclePreviewEnabled = SceneLifecyclePreview.enabled
        #endif
        #if DEBUG
        if AppPreview.install(in: window) { return }
        #endif
        do {
            #if DEBUG && targetEnvironment(simulator)
            let client = try lifecyclePreviewEnabled ? SceneLifecyclePreview.client() : APIClient(baseURL: AppConfiguration.apiBaseURL, store: KeychainSessionStore(service: AppConfiguration.keychainService), snapshots: AccountSnapshotStore(origin: AppConfiguration.apiBaseURL))
            #else
            let client = try APIClient(baseURL: AppConfiguration.apiBaseURL, store: KeychainSessionStore(service: AppConfiguration.keychainService), snapshots: AccountSnapshotStore(origin: AppConfiguration.apiBaseURL))
            #endif
            let coordinator = AppCoordinator(client: client, auth: LiveAuthRepository(client: client), configurations: LiveConfigurationRepository(client: client), notifications: LiveNotificationRepository(client: client), transfer: DocumentTransferService())
            self.coordinator = coordinator
            window.rootViewController = coordinator.navigation
            window.makeKeyAndVisible()
            PushNotificationsController.shared.onOpen = { [weak coordinator] id in coordinator?.openPushNotification(id) }
            PushNotificationsController.shared.onArrival = { [weak coordinator] in coordinator?.receivedPushNotification() }
            if let response = connectionOptions.notificationResponse {
                PushNotificationsController.shared.receiveTap(response.notification.request.content.userInfo)
            }
            coordinator.start()
            #if DEBUG && targetEnvironment(simulator)
            SceneLifecyclePreview.verifyOffline(coordinator, client: client)
            #endif
            pendingURLs += connectionOptions.urlContexts.map(\.url)
            #if DEBUG && targetEnvironment(simulator)
            if SceneLifecyclePreview.enabled { print("SCENE CHECK: connected; cold URL count = \(pendingURLs.count)") }
            #endif
        } catch {
            let screen = FormViewController(); screen.loadViewIfNeeded(); screen.addText(error.localizedDescription)
            window.rootViewController = screen; window.makeKeyAndVisible()
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        pendingURLs += URLContexts.map(\.url)
        if scene.activationState == .foregroundActive { openPendingURLs() }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        privacyCover?.removeFromSuperview(); privacyCover = nil
        Task { await PushNotificationsController.shared.refresh() }
        coordinator?.refreshNotifications()
        openPendingURLs()
        #if DEBUG && targetEnvironment(simulator)
        if SceneLifecyclePreview.enabled { print("SCENE CHECK: active; privacy cover removed") }
        #endif
    }

    func sceneWillResignActive(_ scene: UIScene) { coverContent() }
    func sceneDidEnterBackground(_ scene: UIScene) { coverContent() }

    private func openPendingURLs() {
        guard let coordinator else { return }
        let urls = pendingURLs; pendingURLs.removeAll()
        // The coordinator retains configuration links until sign-in/email verification completes.
        for url in urls {
            let accepted = coordinator.open(url)
            #if DEBUG && targetEnvironment(simulator)
            if SceneLifecyclePreview.enabled {
                print("SCENE CHECK: URL accepted = \(accepted)")
                if accepted { SceneLifecyclePreview.inspectLink(url, coordinator: coordinator) }
            }
            #endif
        }
    }

    private func coverContent() {
        guard let window, privacyCover == nil else { return }
        let cover = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        cover.accessibilityIdentifier = "scene.privacy-cover"
        cover.frame = window.bounds; cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(cover); privacyCover = cover
        #if DEBUG && targetEnvironment(simulator)
        if SceneLifecyclePreview.enabled { print("SCENE CHECK: inactive; privacy cover installed") }
        #endif
    }
}
