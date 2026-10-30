import Foundation
import WireGuardConfiguration

public enum ProfileError: LocalizedError {
    case invalidFile, unsupportedProfile, unsupportedStandaloneProfile
    public var errorDescription: String? {
        switch self {
        case .invalidFile: return "Не удалось прочитать параметры подключения. Попробуйте позже."
        case .unsupportedStandaloneProfile: return "Эта версия приложения пока не поддерживает полученные настройки."
        case .unsupportedProfile: return "Сервер вернул несовместимые параметры VPN. Проверьте подключение или обновите приложение."
        }
    }
}

public enum ProfileConfiguration {
    public static let maximumBytes = 65_536

    public static func parse(_ data: Data, name: String? = nil) throws -> TunnelConfiguration {
        guard !data.isEmpty, data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw ProfileError.invalidFile
        }
        let configuration: TunnelConfiguration
        do {
            configuration = try TunnelConfiguration(fromWgQuickConfig: text, called: name)
        } catch {
            // Upstream errors may contain keys or source lines. Never surface them.
            throw ProfileError.invalidFile
        }
        guard !configuration.interface.addresses.isEmpty, configuration.peers.count == 1,
              configuration.peers[0].endpoint != nil, !configuration.peers[0].allowedIPs.isEmpty else {
            throw ProfileError.unsupportedProfile
        }
        return configuration
    }
}
