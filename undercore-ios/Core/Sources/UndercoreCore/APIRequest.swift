import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
}

/// A complete wire request. Repositories select an operation, not HTTP details.
public struct APIRequest: Sendable {
    public let path: String
    public let method: HTTPMethod
    let body: Data?
    let expectedStatus: Int?
    let allowCached: Bool

    init(_ path: String, method: HTTPMethod = .get, body: Data? = nil,
         expectedStatus: Int? = nil, allowCached: Bool = true) {
        self.path = path
        self.method = method
        self.body = body
        self.expectedStatus = expectedStatus
        self.allowCached = allowCached
    }

    static func json<Body: Encodable>(_ path: String, method: HTTPMethod, body: Body,
                                      expectedStatus: Int? = nil) throws -> Self {
        Self(path, method: method, body: try JSONEncoder().encode(body), expectedStatus: expectedStatus)
    }
}

public enum APIRequests {
    public static func connectDevice(key: UUID, name: String) throws -> APIRequest {
        try .json(APIEndpoints.connectDevice, method: .post,
                  body: ["deviceKey": key.uuidString.lowercased(), "name": String(name.prefix(80))])
    }
    public static func connectionManifest(_ id: String) throws -> APIRequest {
        struct Offer: Encodable { let `protocol` = "amneziawg"; let configuration_version = 1 }
        struct Capabilities: Encodable { let schema_version = 1; let capabilities = [Offer()] }
        return try .json(APIEndpoints.connectionManifest(id), method: .post, body: Capabilities())
    }
    public static let bootstrap = APIRequest(APIEndpoints.bootstrap)
    public static let account = APIRequest(APIEndpoints.account, allowCached: false)
    public static let verificationStatus = APIRequest(APIEndpoints.verificationStatus)
    public static let notificationSummary = APIRequest(APIEndpoints.notificationSummary)
    public static let articles = APIRequest(APIEndpoints.articles)

    public static func registerPushDevice(_ device: PushDeviceRegistration) throws -> APIRequest {
        try .json(APIEndpoints.pushDevice, method: .post, body: device)
    }
    public static func unregisterPushDevice(installationID: String, topic: String) throws -> APIRequest {
        try .json(APIEndpoints.pushDevice, method: .delete, body: ["installationID": installationID, "topic": topic])
    }
    public static func notification(_ id: String) throws -> APIRequest {
        let readPath = try APIEndpoints.notificationRead(id)
        return APIRequest(String(readPath.dropLast("/read".count)), allowCached: false)
    }
    public static func login(email: String, password: String) throws -> APIRequest {
        try .json(APIEndpoints.login, method: .post, body: ["email": email, "password": password])
    }
    public static func register(name: String, email: String, password: String,
                                challenge: (field: String, token: String)?) throws -> APIRequest {
        var body = ["name": name, "email": email, "password": password]
        if let challenge { body[challenge.field] = challenge.token }
        return try .json(APIEndpoints.register, method: .post, body: body)
    }
    public static func verifyEmail(_ code: String) throws -> APIRequest {
        try .json(APIEndpoints.verifyEmail, method: .post, body: ["code": code])
    }
    public static func resendEmail() throws -> APIRequest {
        try .json(APIEndpoints.resendEmail, method: .post, body: ["quickResend": "1"])
    }
    public static func logout() throws -> APIRequest {
        try .json(APIEndpoints.logout, method: .post, body: [String: String]())
    }
    public static func passwordReset(email: String) throws -> APIRequest {
        try .json(APIEndpoints.passwordResetRequest, method: .post, body: ["email": email])
    }
    public static func deleteAccount(password: String) throws -> APIRequest {
        try .json(APIEndpoints.profile, method: .delete, body: ["current_password": password], expectedStatus: 202)
    }
    public static func configurations(page: Int) -> APIRequest {
        APIRequest(APIEndpoints.configurationPage(page))
    }
    public static func package(_ id: String) throws -> APIRequest {
        APIRequest(try APIEndpoints.package(id))
    }
    public static func activate(packageID: String, slot: Int, request: SlotActivationRequest) throws -> APIRequest {
        try .json(APIEndpoints.slot(slot, packageID: packageID), method: .post, body: request)
    }
    public static func configuration(_ id: String) throws -> APIRequest {
        APIRequest(try APIEndpoints.configuration(id))
    }
    public static func removeConfiguration(_ id: String) throws -> APIRequest {
        APIRequest(try APIEndpoints.configuration(id), method: .delete)
    }
    public static func renameConfiguration(_ id: String, name: String) throws -> APIRequest {
        try .json(APIEndpoints.configuration(id), method: .patch, body: ["name": name])
    }
    public static func switchProtocol(_ id: String, request: ProtocolSwitchRequest) throws -> APIRequest {
        try .json(APIEndpoints.configurationProtocol(id), method: .post, body: request)
    }
    public static func downloadConfiguration(_ id: String) throws -> APIRequest {
        APIRequest(try APIEndpoints.configurationDownload(id), allowCached: false)
    }
    public static func notifications(page: Int) -> APIRequest {
        APIRequest(APIEndpoints.notificationPage(page))
    }
    public static func readNotification(_ id: String) throws -> APIRequest {
        try .json(APIEndpoints.notificationRead(id), method: .patch, body: [String: String]())
    }
    public static func readAllNotifications() throws -> APIRequest {
        try .json(APIEndpoints.notificationsReadAll, method: .post, body: [String: String]())
    }
    public static func article(_ id: Int) throws -> APIRequest {
        APIRequest(try APIEndpoints.article(id))
    }
    public static func messenger(_ channel: MessengerChannel) -> APIRequest {
        APIRequest(APIEndpoints.messenger(channel))
    }
    public static func connectMessenger(_ channel: MessengerChannel) throws -> APIRequest {
        try .json(APIEndpoints.messengerConnect(channel), method: .post, body: [String: String]())
    }
    public static func disconnectMessenger(_ channel: MessengerChannel) -> APIRequest {
        APIRequest(APIEndpoints.messenger(channel), method: .delete, expectedStatus: 204)
    }
}
