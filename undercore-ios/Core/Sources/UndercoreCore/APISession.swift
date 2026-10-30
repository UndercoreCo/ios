import Foundation

/// Cookie persistence and CSRF state. APIClient owns cancellation and cache invalidation on logout.
@MainActor final class APISession {
    private let origin: URL
    private let store: SessionStore
    private let now: () -> Date
    private var credentials: SessionCredentials?
    private var csrfToken: String?
    private var cookieName: String?
    private var lifetime: TimeInterval = 0

    var isValid: Bool { credentials.map { $0.expiresAt > now() } ?? false }
    var isExpired: Bool { credentials != nil && !isValid }
    var isPrepared: Bool { isValid && csrfToken != nil }

    init(origin: URL, store: SessionStore, now: @escaping () -> Date) throws {
        self.origin = origin
        self.store = store
        self.now = now
        if let saved = try store.load(), saved.origin == origin.absoluteString, saved.expiresAt > now() {
            credentials = saved
            cookieName = saved.cookieName
        } else {
            try store.clear()
        }
    }

    func configure(_ bootstrap: Bootstrap) {
        cookieName = bootstrap.sessionCookieName
        lifetime = TimeInterval(min(max(bootstrap.sessionLifetimeSeconds, 60), 30 * 24 * 3600))
    }

    func setCSRFToken(_ token: String) { csrfToken = token }
    func invalidateCSRFToken() { csrfToken = nil }

    func authorize(_ request: inout URLRequest, method: HTTPMethod) throws {
        if let credentials {
            request.setValue("\(credentials.cookieName)=\(credentials.cookieValue)", forHTTPHeaderField: "Cookie")
        }
        guard method != .get else { return }
        guard let csrfToken else { throw ClientError.expiredSession }
        request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-TOKEN")
        request.setValue(origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
    }

    /// Returns false when the server explicitly invalidates the cookie.
    func captureCookie(_ response: HTTPURLResponse) throws -> Bool {
        guard let cookieName, let url = response.url else { return true }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String { result[key] = String(describing: entry.value) }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard let cookie = cookies.first(where: { $0.name == cookieName }) else { return true }
        let timestamp = now()
        guard !cookie.value.isEmpty, cookie.expiresDate.map({ $0 > timestamp }) ?? true else { return false }
        let saved = SessionCredentials(
            origin: origin.absoluteString, cookieName: cookieName, cookieValue: cookie.value,
            expiresAt: cookie.expiresDate ?? timestamp.addingTimeInterval(lifetime > 0 ? lifetime : 60)
        )
        try store.save(saved)
        credentials = saved
        return true
    }

    func clear() throws {
        credentials = nil
        csrfToken = nil
        cookieName = nil
        lifetime = 0
        try store.clear()
    }
}
