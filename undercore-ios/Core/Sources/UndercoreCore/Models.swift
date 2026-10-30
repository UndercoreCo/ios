import Foundation

public struct Envelope<T: Decodable>: Decodable { public let data: T }
extension Envelope: Encodable where T: Encodable {}

public struct UserResponse: Codable, Sendable { public let user: Account }
public struct Account: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let email: String
    public let isEmailVerified: Bool
}
public struct RegistrationChallenge: Decodable {
    public let provider: String
    public let siteKey: String
    public let tokenField: String
    public let required: Bool
}
public struct Bootstrap: Decodable {
    public let apiVersion: Int
    public let csrfToken: String
    public let sessionCookieName: String
    public let sessionLifetimeSeconds: Int
    public let challenge: RegistrationChallenge
}
public struct VPNConfiguration: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let protocolName: String
    public let state: String
    public let expiresAt: String?
    public let canDownload: Bool
    public let canRename: Bool
    public let protocolRevision: Int?
    public let canSwitchProtocol: Bool?
    public let protocolSwitch: VPNProtocolSwitch?
    public let canDelete: Bool?
    public let deletion: VPNDeletion?
    public let connection: VPNConnection?
    public let connectionManifestVersion: Int?
    public var isDeleting: Bool { deletion != nil }
    public var isSwitchingProtocol: Bool { protocolSwitch?.pending == true }
    public func switchOptions(from options: [VPNProtocolOption]) -> [VPNProtocolOption] {
        guard canSwitchProtocol == true, let protocolRevision, protocolRevision >= 0, !isSwitchingProtocol, !isDeleting else { return [] }
        return options.filter { $0.available && $0.id != protocolName && ["wireguard", "amneziawg"].contains($0.id) }
    }
    public var displayName: String { name ?? "VPN-конфигурация" }
    public var applicationName: String { protocolName == "wireguard" ? "WireGuard" : "AmneziaWG" }
    enum CodingKeys: String, CodingKey { case id, name, state, expiresAt, canDownload, canRename, protocolRevision, canSwitchProtocol, protocolSwitch, canDelete, deletion, connection, connectionManifestVersion; case protocolName = "protocol" }
}
public struct VPNPage: Codable {
    public struct Pagination: Codable { public let page: Int; public let lastPage: Int }
    public struct Package: Codable, Equatable, Identifiable {
        public struct Slot: Codable, Equatable {
            public let number: Int
            public let occupied: Bool
            public let canActivate: Bool
            public var config: VPNConfiguration?
        }
        public let id: String
        public let name: String
        public let deviceCount: Int
        public let usedSlots: Int
        public let origin: String
        public let expiresAt: String?
        public let expired: Bool?
        public let autoRenewal: AutoRenewal?
        public var slots: [Slot]
        public struct AutoRenewal: Codable, Equatable { public let enabled: Bool }
    }
    public let configs: [VPNConfiguration]
    public let packages: [Package]
    public let pagination: Pagination
    public let protocols: [VPNProtocolOption]?
    public var automaticConnectionAvailable: Bool? = nil
    public var configurations: [VPNConfiguration] { configs + packages.flatMap { $0.slots.compactMap(\.config) } }
}

public enum ClientError: Error, LocalizedError, Equatable {
    case invalidAddress, invalidResponse, insecureStorage, expiredSession, serviceNotEnabled
    case server(status: Int, message: String, retryAfter: Int?)
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Некорректный адрес сервиса."
        case .invalidResponse: return "Не удалось прочитать ответ сервера. Попробуйте позже."
        case .insecureStorage: return "Не удалось безопасно сохранить вход. Разблокируйте устройство и попробуйте снова."
        case .expiredSession: return "Войдите в аккаунт снова."
        case .serviceNotEnabled: return "Мобильный вход пока недоступен на этом сервере."
        case let .server(status, message, retryAfter):
            let text = status == 429 ? "Слишком много попыток." : message
            return retryAfter.map { "\(text) Повторите через \($0) сек." } ?? text
        }
    }
}

/// Server-issued attachment name; never derive names from the secret file contents on clients.
public struct ConfigurationDownload {
    public let data: Data
    public let filename: String
    public init(data: Data, filename: String) throws {
        guard Self.isValidFilename(filename) else { throw ClientError.invalidResponse }
        self.data = data; self.filename = filename
    }
    public static func isValidFilename(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_=+.-]{1,15}\\.conf\\z", options: .regularExpression) != nil
            && !name.hasPrefix(".")
    }
    public static func filename(from disposition: String?) throws -> String {
        guard let disposition,
              let range = disposition.range(of: "(?:^|;)\\s*filename=\"[^\"]+\"(?:;|$)", options: [.regularExpression, .caseInsensitive]),
              let name = disposition[range].split(separator: "\"").dropFirst().first.map(String.init),
              isValidFilename(name) else { throw ClientError.invalidResponse }
        return name
    }
}

public struct VPNProtocolOption: Codable, Equatable {
    public let id: String
    public let label: String
    public let available: Bool
}
public struct VPNProtocolSwitch: Codable, Equatable {
    public let pending: Bool
    public let target: String
}
public struct ProtocolSwitchRequest: Encodable {
    public let protocolName: String
    public let revision: Int
    public let requestKey: String
    enum CodingKeys: String, CodingKey { case protocolName = "protocol", revision, requestKey }
    public init(protocolName: String, revision: Int, requestKey: UUID = UUID()) throws {
        guard ["wireguard", "amneziawg"].contains(protocolName), revision >= 0 else { throw ClientError.invalidResponse }
        self.protocolName = protocolName; self.revision = revision; self.requestKey = requestKey.uuidString.lowercased()
    }
}

public struct VPNDeletion: Codable, Equatable {
    public enum Status: String, Codable { case pending, completed }
    public let status: Status
}
public struct DeviceRemovalReceipt: Decodable {
    public let id: String
    public let status: VPNDeletion.Status
}
public struct SlotActivationRequest: Codable, Equatable {
    public let protocolName: String
    public let requestKey: String
    enum CodingKeys: String, CodingKey { case protocolName = "protocol", requestKey }
    public init(protocolName: String, requestKey: UUID = UUID()) throws {
        guard ["wireguard", "amneziawg"].contains(protocolName) else { throw ClientError.invalidResponse }
        self.protocolName = protocolName; self.requestKey = requestKey.uuidString.lowercased()
    }
}

/// Historical observation, never a live online/offline indicator.
public struct VPNConnection: Codable, Equatable {
    public let status: String
    public let lastHandshakeAt: String?
    public let checkedAt: String?
}
