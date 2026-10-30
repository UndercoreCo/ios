import UIKit
import UserNotifications
import UndercoreCore

/// APNs tokens stay in memory and are obtained again from Apple each launch.
@MainActor final class PushNotificationsController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationsController()
    static let changed = Notification.Name("Undercore.pushStateChanged")
    var onOpen: ((String) -> Void)?
    var onArrival: (() -> Void)?
    private(set) var status: UNAuthorizationStatus = .notDetermined
    private(set) var message: String?
    private weak var client: APIClient?
    private var registrationAllowed = false
    private var ownerID: Int?
    private var token: String?
    private var generation = 0
    private var registration: Task<Void, Never>?
    private var lastRegistration: PushDeviceRegistration?
    private var registeredAt: Date?
    private var pendingOpen: String?
    private var lastTap: (id: String, date: Date)?
    private var bindingID: String? {
        get { UserDefaults.standard.string(forKey: "push.binding") }
        set { UserDefaults.standard.set(newValue, forKey: "push.binding") }
    }
    private var installationID: String {
        if let value = UserDefaults.standard.string(forKey: "push.installation") { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "push.installation")
        return value
    }
    private var topic: String { Bundle.main.bundleIdentifier ?? "" }
    private var environment: String {
        Bundle.main.object(forInfoDictionaryKey: "UndercoreAPNSEnvironment") as? String ?? "production"
    }
    func configure() { UNUserNotificationCenter.current().delegate = self }
    func bind(client: APIClient, ownerID: Int) {
        if self.ownerID != ownerID {
            generation += 1; lastRegistration = nil; registeredAt = nil
        }
        registrationAllowed = true
        self.client = client; self.ownerID = ownerID
        Task { await refresh() }
        if let pendingOpen { self.pendingOpen = nil; onOpen?(pendingOpen) }
    }
    func unbind(preservePendingOpen: Bool = false) {
        registrationAllowed = false
        generation += 1; client = nil; ownerID = nil; lastRegistration = nil; registeredAt = nil
        bindingID = nil
        if !preservePendingOpen { pendingOpen = nil }
        UIApplication.shared.unregisterForRemoteNotifications()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    /// Complete an in-flight registration before the server invalidates its session at logout.
    func prepareLogout() async { registrationAllowed = false; await registration?.value }
    func resumeAfterFailedLogout() { registrationAllowed = true; Task { await refresh() } }
    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        notify()
        guard registrationAllowed, ownerID != nil else { return }
        switch status {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
            synchronize()
        case .denied:
            UIApplication.shared.unregisterForRemoteNotifications()
            removeRegistration()
        default: break
        }
    }
    func requestPermission() async {
        if status == .denied {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { _ = await UIApplication.shared.open(url) }
            return
        }
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { message = "Не удалось запросить разрешение. Попробуйте ещё раз."; notify(); return }
        await refresh()
    }
    func registered(_ data: Data) {
        token = PushNotificationPayload.token(data)
        synchronize()
    }
    func registrationFailed() {
        message = "Не удалось включить push. Попробуйте ещё раз."; notify()
    }
    private func synchronize() {
        guard registrationAllowed, registration == nil, let client, !client.isOffline, let ownerID, let token,
              [.authorized, .provisional, .ephemeral].contains(status) else { return }
        let request = PushDeviceRegistration(installationID: installationID, topic: topic, environment: environment, token: token)
        if lastRegistration == request, let registeredAt, Date().timeIntervalSince(registeredAt) < 3600 { return }
        let current = generation
        registration = Task { [weak self] in
            guard let self else { return }
            defer {
                self.registration = nil; self.notify()
                if self.generation != current, self.registrationAllowed { Task { await self.refresh() } }
            }
            do {
                let response: PushDeviceBinding = try await client.request(APIRequests.registerPushDevice(request))
                guard self.generation == current, self.ownerID == ownerID else { return }
                self.bindingID = response.bindingID; self.lastRegistration = request; self.registeredAt = Date(); self.message = nil
            } catch {
                guard self.generation == current else { return }
                self.message = "Не удалось связать уведомления с аккаунтом. Нажмите, чтобы повторить."
            }
        }
    }
    private func removeRegistration() {
        guard registrationAllowed, registration == nil, let client, !client.isOffline else { return }
        let current = generation
        registration = Task { [weak self] in
            guard let self else { return }
            defer {
                self.registration = nil; self.notify()
                if self.generation != current, self.registrationAllowed { Task { await self.refresh() } }
            }
            do {
                let _: PushRemovalResponse = try await client.request(APIRequests.unregisterPushDevice(installationID: self.installationID, topic: self.topic))
                guard self.generation == current else { return }
                self.lastRegistration = nil; self.bindingID = nil
            } catch { /* Reconcile again on the next foreground transition. */ }
        }
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: nil) }
    func receiveTap(_ payload: [AnyHashable: Any]) {
        guard let id = PushNotificationPayload.notificationID(payload) else { return }
        receiveTap(id: id)
    }
    private func receiveTap(id: String) {
        // Cold launches may deliver the same tap through both scene and notification delegates.
        if let lastTap, lastTap.id == id, Date().timeIntervalSince(lastTap.date) < 2 { return }
        lastTap = (id, Date())
        if ownerID != nil, let onOpen { onOpen(id) } else { pendingOpen = id }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let id = PushNotificationPayload.notificationID(response.notification.request.content.userInfo)
        let opensApp = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        // The async delegate bridge can finish on a cooperative worker after
        // MainActor.run returns. UIKit's scene-restoration completion must run
        // on the main thread, including malformed or dismissed notifications.
        Task { @MainActor in
            defer { completionHandler() }
            guard opensApp, let id else { return }
            self.receiveTap(id: id)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let id = PushNotificationPayload.notificationID(notification.request.content.userInfo)
        let binding = notification.request.content.userInfo["bindingID"] as? String
        Task { @MainActor in
            guard self.ownerID != nil, let binding, binding == self.bindingID, id != nil else {
                completionHandler([])
                return
            }
            self.onArrival?()
            completionHandler([.banner, .list, .sound])
        }
    }
}

private struct PushRemovalResponse: Decodable { let ok: Bool }
