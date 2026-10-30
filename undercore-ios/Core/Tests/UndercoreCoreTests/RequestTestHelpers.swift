import Foundation
@testable import UndercoreCore

// Transport tests deliberately construct malformed and non-catalogue routes.
// Production code uses APIRequests exclusively.
extension APIClient {
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil,
                               expectedStatus: Int? = nil, allowCached: Bool = true) async throws -> T {
        let operation = APIRequest(path, method: HTTPMethod(rawValue: method)!,
                                   body: try body.map { try JSONEncoder().encode($0) },
                                   expectedStatus: expectedStatus, allowCached: allowCached)
        return try await request(operation)
    }
    func download(_ path: String) async throws -> ConfigurationDownload {
        try await download(APIRequest(path, allowCached: false))
    }
}
