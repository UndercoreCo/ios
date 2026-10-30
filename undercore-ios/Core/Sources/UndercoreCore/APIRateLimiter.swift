import Foundation
import CryptoKit

struct APIRateLimiter {
    private var deadlines: [String: Date] = [:]

    func key(for request: APIRequest, url: URL) -> String {
        var key = request.method.rawValue + " " + url.path
        // Identity-specific limits must not block another account entered on the same phone.
        if let body = request.body,
           let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let email = json["email"] as? String {
            let identity = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            key += " " + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return key
    }

    mutating func check(_ key: String, at date: Date) throws {
        deadlines = deadlines.filter { $0.value > date }
        guard let deadline = deadlines[key] else { return }
        throw ClientError.server(status: 429, message: "Слишком много попыток.",
                                 retryAfter: Int(ceil(deadline.timeIntervalSince(date))))
    }

    mutating func record(_ failure: APIResponseFailure, key: String, at date: Date) {
        guard failure.status == 429, let seconds = failure.retryAfter, seconds > 0 else { return }
        let deadline = date.addingTimeInterval(TimeInterval(seconds))
        deadlines[key] = max(deadlines[key] ?? deadline, deadline)
    }

    mutating func clear() { deadlines.removeAll() }
}

struct APIResponseFailure {
    let status: Int
    let message: String
    let retryAfter: Int?

    init(data: Data, response: HTTPURLResponse) {
        status = response.statusCode
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let fields = (json?["errors"] as? [String: [String]])?
            .sorted { $0.key < $1.key }.compactMap { $0.value.first }
        let description = fields?.first ?? (json?["message"] as? String)
            ?? "Не удалось выполнить запрос. Попробуйте позже."
        message = String(description.prefix(500))
        let parameters = (json?["error"] as? [String: Any])?["parameters"] as? [String: Any]
        retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            ?? parameters?["retryAfterSeconds"] as? Int
    }

    var error: ClientError { .server(status: status, message: message, retryAfter: retryAfter) }
}
