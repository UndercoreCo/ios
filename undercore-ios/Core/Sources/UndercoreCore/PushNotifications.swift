import Foundation

public struct PushDeviceRegistration: Encodable, Equatable, Sendable {
    public let installationID: String
    public let topic: String
    public let environment: String
    public let token: String
    public init(installationID: String, topic: String, environment: String, token: String) {
        self.installationID = installationID; self.topic = topic; self.environment = environment; self.token = token
    }
}
public struct PushDeviceBinding: Decodable { public let bindingID: String }
public enum PushNotificationPayload {
    public static func notificationID(_ payload: [AnyHashable: Any]) -> String? {
        guard let id = payload["notificationID"] as? String,
              id.range(of: "^ntf_[0-9A-HJKMNP-TV-Z]{26}$", options: .regularExpression) != nil else { return nil }
        return id
    }
    public static func token(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
