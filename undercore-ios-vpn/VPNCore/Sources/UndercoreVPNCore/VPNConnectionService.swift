import Foundation
import UndercoreCore

public enum VPNPreparationError: Error, LocalizedError {
    case unavailable, unsupported, provisioning, unverified
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Подключение недоступно. Проверьте подписку и устройство в разделе «Конфигурации»."
        case .unsupported: return "Для этого подключения требуется обновление приложения."
        case .provisioning: return "Подключение ещё создаётся. Попробуйте немного позже — новое место занято не будет."
        case .unverified: return "Подтвердите email, чтобы подключиться."
        }
    }
}

public struct PreparedVPNConnection {
    public let configuration: VPNConfiguration
    public let material: VPNConnectionMaterial
}

/// Authenticated preparation independent of UIKit and NetworkExtension.
@MainActor public final class VPNConnectionService {
    private let client: APIClient
    private let repository: ConfigurationRepository
    private let devices: VPNDeviceStore
    private let now: () -> Date
    private let sleep: () async throws -> Void
    public init(client: APIClient, repository: ConfigurationRepository, devices: VPNDeviceStore,
                now: @escaping () -> Date = Date.init,
                sleep: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) {
        self.client = client; self.repository = repository; self.devices = devices
        self.now = now; self.sleep = sleep
    }

    /// nil selects the device registered by this installation, not another device's configuration.
    public func prepare(selectedID: String?, ownerID: Int, name: String,
                        check: () throws -> Void) async throws -> PreparedVPNConnection {
        do { return try await request(selectedID: selectedID, ownerID: ownerID, name: name, check: check) }
        catch ClientError.server(status: 419, message: _, retryAfter: _) {
            try check(); try Task.checkCancellation()
            // APIClient discarded the rejected token. Recheck the account before any replay.
            // A second rejection escapes; network failures and other HTTP codes never replay.
            return try await request(selectedID: selectedID, ownerID: ownerID, name: name, check: check)
        }
    }

    private func request(selectedID: String?, ownerID: Int, name: String,
                         check: () throws -> Void) async throws -> PreparedVPNConnection {
        try check(); try Task.checkCancellation()
        let account = try await client.verifyOnlineSession(reusingPreparedSession: true)
        try check(); try Task.checkCancellation()
        guard account.id == ownerID else { throw ClientError.expiredSession }
        guard account.isEmailVerified else { throw VPNPreparationError.unverified }
        let id: String
        if let selectedID { id = selectedID }
        else {
            let record = try devices.registration(owner: ownerID)
            if let saved = record.configurationID { id = saved }
            else {
                let response: Envelope<VPNConfiguration> = try await client.request(APIRequests.connectDevice(key: record.key, name: name))
                try check(); try Task.checkCancellation()
                guard DeepLink.isConfigurationID(response.data.id), response.data.connectionManifestVersion == 1 else {
                    throw VPNPreparationError.unsupported
                }
                id = response.data.id
                try devices.bind(id, owner: ownerID)
            }
        }
        var current = try await repository.detail(id)
        try check(); try Task.checkCancellation()
        guard current.id == id else { throw ClientError.invalidResponse }
        // Poll reads, not slot-creation mutations. Same device identity survives cancellation/relaunch.
        for _ in 0..<15 where selectedID == nil && current.state == "provisioning" {
            try await sleep()
            try check(); try Task.checkCancellation()
            current = try await repository.detail(id)
            try check(); try Task.checkCancellation()
            guard current.id == id else { throw ClientError.invalidResponse }
        }
        guard current.id == id else { throw ClientError.invalidResponse }
        if current.state == "provisioning" { throw VPNPreparationError.provisioning }
        guard current.canDownload, !current.isDeleting, !current.isSwitchingProtocol,
              ["wireguard", "amneziawg"].contains(current.protocolName) else { throw VPNPreparationError.unavailable }
        let material: VPNConnectionMaterial
        if let version = current.connectionManifestVersion {
            guard version == 1 else { throw VPNPreparationError.unsupported }
            let data = try await client.connectionManifest(id)
            try check(); try Task.checkCancellation()
            guard let response = try? JSONDecoder().decode(Envelope<ConnectionManifest>.self, from: data) else {
                throw ClientError.invalidResponse
            }
            material = try response.data.validated(deviceID: id, now: now())
        } else {
            // Only explicitly selected legacy devices may use the old export. Never fallback on failure.
            guard selectedID != nil else { throw VPNPreparationError.unsupported }
            let download = try await repository.download(id)
            try check(); try Task.checkCancellation()
            _ = try ProfileConfiguration.parse(download.data)
            material = VPNConnectionMaterial(data: download.data, revision: nil, connectionID: nil, expiresAt: nil)
        }
        return PreparedVPNConnection(configuration: current, material: material)
    }
}
