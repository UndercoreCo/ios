import Foundation

@MainActor public protocol AuthRepository {
    func prepare() async throws -> Bootstrap
    func currentAccount() async throws -> Account
    func login(email: String, password: String) async throws -> Account
    func register(name: String, email: String, password: String, challenge: (field: String, token: String)?) async throws -> Account
    func verifyEmail(code: String) async throws -> Account
    func verificationStatus() async throws -> EmailVerificationStatus
    func resendEmail() async throws -> EmailVerificationStatus
    func logout() async throws
}
@MainActor public final class LiveAuthRepository: AuthRepository {
    private let client: APIClient
    public init(client: APIClient) { self.client = client }
    public func prepare() async throws -> Bootstrap { try await client.bootstrap() }
    public func currentAccount() async throws -> Account { let response: UserResponse = try await client.request(APIRequests.account); return response.user }
    public func login(email: String, password: String) async throws -> Account {
        let response: UserResponse = try await client.request(APIRequests.login(email: email, password: password))
        try await client.bootstrap()
        return response.user
    }
    public func register(name: String, email: String, password: String, challenge: (field: String, token: String)?) async throws -> Account {
        let response: UserResponse = try await client.request(APIRequests.register(name: name, email: email, password: password, challenge: challenge))
        try await client.bootstrap()
        return response.user
    }
    public func verifyEmail(code: String) async throws -> Account {
        let _: Acknowledgement = try await client.request(APIRequests.verifyEmail(code))
        return try await currentAccount()
    }
    public func verificationStatus() async throws -> EmailVerificationStatus {
        let response: Envelope<EmailVerificationStatus> = try await client.request(APIRequests.verificationStatus)
        return response.data
    }
    public func resendEmail() async throws -> EmailVerificationStatus {
        let response: Envelope<EmailVerificationStatus> = try await client.request(APIRequests.resendEmail())
        return response.data
    }
    public func logout() async throws {
        if client.isOffline { try client.clearSession(); return }
        let _: Acknowledgement = try await client.request(APIRequests.logout())
        try client.clearSession()
    }
    private struct Acknowledgement: Decodable { let ok: Bool }
}
@MainActor public protocol ConfigurationRepository {
    func package(_ id: String) async throws -> VPNPage.Package
    func activate(packageID: String, slot: Int, request: SlotActivationRequest) async throws -> VPNConfiguration
    func remove(_ id: String) async throws -> DeviceRemovalReceipt
    func page(_ number: Int) async throws -> VPNPage
    func detail(_ id: String) async throws -> VPNConfiguration
    func download(_ id: String) async throws -> ConfigurationDownload
    func rename(_ id: String, name: String) async throws -> VPNConfiguration
    func switchProtocol(_ id: String, request: ProtocolSwitchRequest) async throws -> VPNConfiguration
}
@MainActor public final class LiveConfigurationRepository: ConfigurationRepository {
    private let client: APIClient
    public init(client: APIClient) { self.client = client }
    public func package(_ id: String) async throws -> VPNPage.Package {
        let result: Envelope<VPNPage.Package> = try await client.request(APIRequests.package(id))
        guard result.data.id == id else { throw ClientError.invalidResponse }
        return result.data
    }
    public func activate(packageID: String, slot: Int, request: SlotActivationRequest) async throws -> VPNConfiguration {
        let result: Envelope<VPNConfiguration> = try await client.request(APIRequests.activate(packageID: packageID, slot: slot, request: request))
        return result.data
    }
    public func remove(_ id: String) async throws -> DeviceRemovalReceipt {
        let result: Envelope<DeviceRemovalReceipt> = try await client.request(APIRequests.removeConfiguration(id))
        guard result.data.id == id else { throw ClientError.invalidResponse }
        return result.data
    }
    public func page(_ number: Int) async throws -> VPNPage {
        let result: Envelope<VPNPage> = try await client.request(APIRequests.configurations(page: number))
        return result.data
    }
    public func detail(_ id: String) async throws -> VPNConfiguration {
        let result: Envelope<VPNConfiguration> = try await client.request(APIRequests.configuration(id))
        return result.data
    }
    public func download(_ id: String) async throws -> ConfigurationDownload { try await client.download(APIRequests.downloadConfiguration(id)) }
    public func switchProtocol(_ id: String, request: ProtocolSwitchRequest) async throws -> VPNConfiguration {
        let result: Envelope<VPNConfiguration> = try await client.request(APIRequests.switchProtocol(id, request: request))
        return result.data
    }
    public func rename(_ id: String, name: String) async throws -> VPNConfiguration {
        let result: Envelope<VPNConfiguration> = try await client.request(APIRequests.renameConfiguration(id, name: name))
        return result.data
    }
}

public struct EmailVerificationStatus: Decodable, Equatable {
    public let retryAfterSeconds: Int
    public let isEmailVerified: Bool
    public init(retryAfterSeconds: Int, isEmailVerified: Bool) {
        self.retryAfterSeconds = retryAfterSeconds; self.isEmailVerified = isEmailVerified
    }
}
