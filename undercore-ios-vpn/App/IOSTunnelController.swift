import Foundation
import NetworkExtension
import UndercoreCore
import UndercoreVPNCore

/// iOS owns the tunnel lifetime. This object owns only UI state and explicit user starts.
@MainActor final class IOSTunnelController {
    static let providerID = "ru.undercore.ios.vpn.tunnel"
    private var manager: NETunnelProviderManager?
    private let healthDiagnostics = IOSTunnelDiagnostics()
    private var attempt = VPNAttempt()
    private var observer: NSObjectProtocol?
    private var ownerKnown = false
    private weak var diagnostics: APIDiagnostics?
    private(set) var isBusy = false
    private(set) var message: String?
    var onChange: (() -> Void)?
    var onSessionExpired: (() -> Void)?

    init() {
        healthDiagnostics.onChange = { [weak self] in self?.onChange?() }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, let connection = notification.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.diagnostics?.record(.tunnelStatus, category: .tunnel, code: connection.status.rawValue)
                self.healthDiagnostics.attach(connection as? NETunnelProviderSession)
                self.onChange?()
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    var status: NEVPNStatus { manager?.connection.status ?? .disconnected }
    var isActive: Bool { [.connecting, .connected, .reasserting, .disconnecting].contains(status) }
    var configurationID: String? {
        (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["configurationID"] as? String
    }
    var isAutomaticConnection: Bool {
        (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["automatic"] as? Bool ?? false
    }
    var statusText: String {
        if isBusy && !isActive { return "Подготавливаем подключение…" }
        switch status {
        case .connecting: return "Подключаем VPN…"
        case .connected: return "VPN включён"
        case .reasserting: return "Восстанавливаем соединение…"
        case .disconnecting: return "Отключаем VPN…"
        default: return "VPN выключен"
        }
    }
    var internetVerified: Bool { status == .connected && healthDiagnostics.health == .ok }
    var healthText: String { healthDiagnostics.detail }
    func diagnosticReport(client: APIClient) async throws -> Data {
        try await healthDiagnostics.report(client: client)
    }
    func bindOwner(_ id: Int?) {
        ownerKnown = true
        attempt.changeOwner(id)
        Task {
            do {
                try await reload()
                guard self.attempt.ownerID == id else { return }
                let savedOwner = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["ownerID"] as? Int
                if id == nil || savedOwner != id { disconnect() }
            } catch { message = "Не удалось прочитать состояние VPN."; onChange?() }
        }
    }
    func refresh() async {
        do { try await reload() }
        catch { message = "Не удалось прочитать состояние VPN." }
        onChange?()
    }
    private func reload() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerID }
        healthDiagnostics.attach(manager?.connection as? NETunnelProviderSession)
        onChange?()
    }
    func connect(selectedID: String?, deviceName: String, ownerID: Int,
                 repository: ConfigurationRepository, client: APIClient) async {
        guard !isBusy, !isActive, ownerKnown, attempt.ownerID == ownerID else { return }
        diagnostics = client.diagnostics
        diagnostics?.record(.connectRequested, category: .tunnel)
        isBusy = true; message = nil; onChange?()
        let token = attempt.begin()
        defer { isBusy = false; onChange?() }
        do {
            let preparation = VPNConnectionService(client: client, repository: repository,
                devices: VPNDeviceStore(origin: client.baseURL))
            let prepared = try await preparation.prepare(selectedID: selectedID, ownerID: ownerID, name: deviceName) {
                try self.check(token, ownerID: ownerID)
            }
            let current = prepared.configuration
            try await reload()
            try check(token, ownerID: ownerID)
            guard !isActive else { throw CancellationError() }
            let manager = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerID
            proto.serverAddress = "Undercore VPN"
            // Only public metadata is persisted in NetworkExtension preferences.
            proto.providerConfiguration = ["ownerID": ownerID, "configurationID": current.id, "automatic": selectedID == nil]
            proto.disconnectOnSleep = false
            manager.protocolConfiguration = proto
            manager.localizedDescription = "Undercore VPN"
            manager.isOnDemandEnabled = false
            manager.isEnabled = true
            self.manager = manager
            try await manager.saveToPreferences()
            try check(token, ownerID: ownerID)
            try await manager.loadFromPreferences()
            try check(token, ownerID: ownerID)
            guard let session = manager.connection as? NETunnelProviderSession else { throw ClientError.invalidResponse }
            // The configuration crosses only the system's app-to-extension IPC, never disk.
            diagnostics?.record(.tunnelStartRequested, category: .tunnel)
            try prepared.material.checkValidity()
            try session.startTunnel(options: ["configuration": prepared.material.data as NSData, "runID": UUID().uuidString as NSString])
        } catch is CancellationError {
            diagnostics?.record(.cancelled, category: .tunnel)
            // A cancelled download or a changed account must not resurrect the tunnel.
        } catch ClientError.expiredSession {
            guard attempt.accepts(token, ownerID: ownerID) else { return }
            diagnostics?.record(.connectionFailed, category: .session, code: 401)
            disconnect(); message = "Войдите в аккаунт снова."; onSessionExpired?()
        } catch let error as VPNPreparationError {
            guard attempt.accepts(token, ownerID: ownerID) else { return }
            diagnostics?.record(.connectionFailed, category: .tunnel)
            message = error.localizedDescription
        } catch let error as ProfileError {
            guard attempt.accepts(token, ownerID: ownerID) else { return }
            diagnostics?.record(.connectionFailed, category: .tunnel)
            message = error.localizedDescription
        } catch let error as ClientError {
            guard attempt.accepts(token, ownerID: ownerID) else { return }
            diagnostics?.record(.connectionFailed, category: .tunnel)
            message = error.localizedDescription
        } catch let error as URLError {
            guard attempt.accepts(token, ownerID: ownerID) else { return }
            diagnostics?.record(.connectionFailed, category: .session, code: error.errorCode)
            message = "Не удалось связаться с Undercore. Попробуйте подключиться ещё раз."
        } catch {
            guard attempt.accepts(token, ownerID: ownerID) else { return }
            diagnostics?.record(.connectionFailed, category: .tunnel, code: (error as NSError).code)
            message = "Не удалось включить VPN. Проверьте интернет и разрешение на добавление VPN в iOS."
        }
    }
    private func check(_ token: UUID, ownerID: Int) throws {
        guard attempt.accepts(token, ownerID: ownerID), !Task.isCancelled else { throw CancellationError() }
    }
    func disconnect() {
        attempt.cancel()
        healthDiagnostics.attach(nil)
        manager?.connection.stopVPNTunnel()
        message = nil; onChange?()
    }
}
