import Foundation
import UndercoreCore

/// In-memory tunnel material. Intentionally not Codable, logged, or persisted.
public struct VPNConnectionMaterial {
    public let data: Data
    public let revision: Int?
    public let connectionID: String?
    public let expiresAt: Date?
    public func checkValidity(at now: Date = Date()) throws {
        if let expiresAt, expiresAt <= now { throw VPNPreparationError.unavailable }
    }
}

struct ConnectionManifest: Decodable {
    struct Configuration: Decodable {
        let `protocol`: String
        let version: Int
        let format: String
        let data: String
    }
    let schema_version: Int
    let device_id: String
    let connection_id: String
    let node_id: String
    let `protocol`: String
    let state: String
    let expires_at: String
    let revision: Int
    let configuration: Configuration

    func validated(deviceID: String, now: Date) throws -> VPNConnectionMaterial {
        guard schema_version == 1, `protocol` == "amneziawg", configuration.protocol == `protocol`,
              configuration.version == 1, configuration.format == "awg-quick" else {
            throw VPNPreparationError.unsupported
        }
        guard device_id == deviceID, state == "active", (1...2_147_483_647).contains(revision),
              connection_id.range(of: "\\A[A-Za-z0-9_-]{1,100}\\z", options: .regularExpression) != nil,
              node_id.range(of: "\\A[A-Za-z0-9_-]{1,100}\\z", options: .regularExpression) != nil,
              expires_at.range(of: "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z\\z", options: .regularExpression) != nil else {
            throw ClientError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiry = formatter.date(from: expires_at), formatter.string(from: expiry) == expires_at,
              expiry > now else { throw VPNPreparationError.unavailable }
        let data = Data(configuration.data.utf8)
        guard data.count <= ProfileConfiguration.maximumBytes, !data.contains(0) else { throw ClientError.invalidResponse }
        _ = try ProfileConfiguration.parse(data)
        return VPNConnectionMaterial(data: data, revision: revision, connectionID: connection_id, expiresAt: expiry)
    }
}
