import Foundation
import UndercoreCore

enum AppConfiguration {
    static let privacyURL = URL(string: "https://undercore.ru/legal/privacy")!
    static let offerURL = URL(string: "https://undercore.ru/legal/offer")!
    static let supportTelegramURL = URL(string: "https://t.me/undercore_support")!
    static let supportWhatsAppURL = URL(string: "https://wa.me/undercore_support")!
    static let supportEmail = "hi@undercore.ru"
    static let supportEmailURL = URL(string: "mailto:" + supportEmail)!
    static let notificationsWebsiteURL = URL(string: "https://undercore.ru/notifications")!
    static let supportWebsiteURL = URL(string: "https://undercore.ru/support")!
    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Версия \(version) (\(build))"
    }
    static let name = "Undercore"
    static let apiBaseURL: URL = {
        let production = Bundle.main.object(forInfoDictionaryKey: "UndercoreAPIBaseURL") as? String ?? "https://undercore.ru"
        #if DEBUG
        let address = Bundle.main.object(forInfoDictionaryKey: "UndercoreDevelopmentAPIBaseURL") as? String ?? production
        #else
        let address = production
        #endif
        return URL(string: address)!
    }()
    #if UNDERCORE_VPN
    static let keychainService = "ru.undercore.ios.vpn.session." + (apiBaseURL.host ?? "") + "." + String(apiBaseURL.port ?? 443)
    #else
    static let keychainService = "ru.undercore.client.session." + (apiBaseURL.host ?? "") + "." + String(apiBaseURL.port ?? 443)
    #endif
    static let configurationUTI = "com.wireguard.config.quick"
    static let maxConfigurationBytes = APILimits.maxConfigurationBytes
    static let temporaryDirectoryName = "UndercoreConfigurations"
}
