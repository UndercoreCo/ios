import Foundation

/// Account-wide operations use the existing web session and server-side safety checks.
@MainActor public protocol AccountManagementRepository {
    func requestPasswordReset(email: String) async throws
    func requestDeletion(password: String) async throws
}

/// Preparation failed before the destructive request was sent.
public struct AccountDeletionPreparationError: Error {
    public let underlyingError: Error
    public init(underlyingError: Error) { self.underlyingError = underlyingError }
}

@MainActor public final class LiveAccountManagementRepository: AccountManagementRepository {
    private let client: APIClient
    public init(client: APIClient) { self.client = client }

    public func requestPasswordReset(email: String) async throws {
        _ = try await client.bootstrap()
        let result: Acknowledgement = try await client.request(APIRequests.passwordReset(email: email))
        guard result.ok else { throw ClientError.invalidResponse }
    }

    public func requestDeletion(password: String) async throws {
        do { _ = try await client.bootstrap() }
        catch {
            if error is URLError || error is CancellationError || (error as? ClientError) == .invalidResponse {
                throw AccountDeletionPreparationError(underlyingError: error)
            }
            throw error
        }
        let result: DeletionReceipt = try await client.request(APIRequests.deleteAccount(password: password))
        // Acceptance is not completion. The server owns revoke, retries and cleanup.
        guard result.ok, result.status == "requested" else { throw ClientError.invalidResponse }
    }
    private struct Acknowledgement: Decodable { let ok: Bool }
    private struct DeletionReceipt: Decodable { let ok: Bool; let status: String }
}
