import Foundation

/// Coordinates HTTP, session safety and metadata caching. Wire contracts live in APIRequests.
@MainActor public final class APIClient {
    public var baseURL: URL { transport.baseURL }
    private let transport: APITransport
    private let session: APISession
    private let snapshots: AccountSnapshotStore?
    private let now: () -> Date
    private var sessionGeneration = 0
    private var rateLimiter = APIRateLimiter()

    public let diagnostics = APIDiagnostics()
    public private(set) var isOffline = false
    public var onOfflineChange: (() -> Void)?
    public var hasValidSession: Bool { session.isValid }

    public init(baseURL: URL, store: SessionStore, session: URLSession? = nil,
                now: @escaping () -> Date = Date.init, snapshots: AccountSnapshotStore? = nil) throws {
        transport = try APITransport(baseURL: baseURL, session: session)
        self.session = try APISession(origin: baseURL, store: store, now: now)
        self.snapshots = snapshots
        self.now = now
        if !hasValidSession { snapshots?.clear() }
    }

    public func url(for path: String) throws -> URL { try transport.url(for: path) }
    public func cachedDate(for path: String) -> Date? { snapshots?.date(for: path) }

    public func setOffline(_ value: Bool) {
        guard isOffline != value else { return }
        isOffline = value
        diagnostics.record(value ? .offlineEntered : .onlineVerified)
        onOfflineChange?()
    }

    public func prepareOfflineCache() async {
        guard hasValidSession else { return }
        await snapshots?.restore()
    }

    public func restoreOfflineAccount() async -> Account? {
        guard hasValidSession, let snapshots else { return nil }
        let generation = sessionGeneration
        await snapshots.restore()
        guard generation == sessionGeneration, hasValidSession, let account = snapshots.account else { return nil }
        setOffline(true)
        return account
    }

    @discardableResult public func bootstrap() async throws -> Bootstrap {
        session.invalidateCSRFToken()
        let (data, response) = try await perform(APIRequests.bootstrap)
        let envelope: Envelope<Bootstrap> = try decode(data)
        let bootstrap = envelope.data
        guard bootstrap.apiVersion == 1, !bootstrap.csrfToken.isEmpty, bootstrap.csrfToken.count <= 1024,
              !bootstrap.csrfToken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              bootstrap.sessionCookieName.range(of: "\\A[A-Za-z0-9_-]{1,128}\\z", options: .regularExpression) != nil else {
            throw ClientError.invalidResponse
        }
        session.configure(bootstrap)
        try captureCookie(response)
        session.setCSRFToken(bootstrap.csrfToken)
        return bootstrap
    }

    /// Account verification always reaches the server. VPN starts may reuse only
    /// the bootstrap of this in-memory session, never an account or permission snapshot.
    public func verifyOnlineSession(reusingPreparedSession: Bool = false) async throws -> Account {
        let generation = sessionGeneration
        if !reusingPreparedSession || !session.isPrepared { _ = try await bootstrap() }
        let response: UserResponse = try await request(APIRequests.account)
        try checkGeneration(generation)
        try Task.checkCancellation()
        setOffline(false)
        return response.user
    }

    public func request<T: Decodable>(_ request: APIRequest) async throws -> T {
        if isOffline, let cached: T = cachedValue(for: request) { return cached }
        do {
            let (data, response) = try await perform(request)
            if let expected = request.expectedStatus, response.statusCode != expected {
                throw ClientError.invalidResponse
            }
            let result: T = try decode(data)
            snapshots?.store(path: request.path, method: request.method.rawValue, data: data, at: now())
            return result
        } catch {
            // HTTP failures and invalid responses never silently become cached successes.
            if error.isOfflineTransportError, let cached: T = cachedValue(for: request) { return cached }
            throw error
        }
    }

    public func requestEmpty(_ request: APIRequest) async throws {
        let (data, response) = try await perform(request)
        guard response.statusCode == (request.expectedStatus ?? 204), data.isEmpty else {
            throw ClientError.invalidResponse
        }
    }

    public func download(_ request: APIRequest) async throws -> ConfigurationDownload {
        if isOffline { throw URLError(.notConnectedToInternet) }
        let (data, response) = try await perform(request)
        guard response.mimeType == "application/octet-stream", data.count <= APILimits.maxConfigurationBytes,
              let text = String(data: data, encoding: .utf8), text.contains("[Interface]"), text.contains("[Peer]"),
              text.contains("PrivateKey ="), !text.contains("<html") else { throw ClientError.invalidResponse }
        let filename = try ConfigurationDownload.filename(from: response.value(forHTTPHeaderField: "Content-Disposition"))
        return try ConfigurationDownload(data: data, filename: filename)
    }

    /// Secret manifest bytes bypass the metadata snapshot store entirely.
    public func connectionManifest(_ id: String) async throws -> Data {
        let (data, response) = try await perform(APIRequests.connectionManifest(id))
        guard response.mimeType == "application/json", data.count <= 524_288,
              response.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true else {
            throw ClientError.invalidResponse
        }
        return data
    }

    public func clearSession() throws {
        sessionGeneration += 1
        snapshots?.clear()
        rateLimiter.clear()
        defer { setOffline(false) }
        try session.clear()
    }

    private func cachedValue<T: Decodable>(for request: APIRequest) -> T? {
        guard request.allowCached, request.method == .get, hasValidSession,
              SnapshotRoute.canReadOffline(request.path) else { return nil }
        let value: T? = snapshots?.value(request.path)
        if value != nil { diagnostics.record(.cacheRead, category: APIDiagnostics.category(for: request)) }
        return value
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw ClientError.invalidResponse }
        return value
    }

    private func perform(_ operation: APIRequest) async throws -> (Data, HTTPURLResponse) {
        let request = try makeURLRequest(operation)
        let key = rateLimiter.key(for: operation, url: request.url!)
        try rateLimiter.check(key, at: now())
        let generation = sessionGeneration
        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.send(request)
        } catch {
            try checkGeneration(generation)
            diagnostics.record(.requestFailed, category: APIDiagnostics.category(for: operation), code: (error as? URLError)?.errorCode)
            if error.isOfflineTransportError, snapshots?.account != nil { setOffline(true) }
            throw error
        }
        try checkGeneration(generation)
        diagnostics.record(.httpResponse, category: APIDiagnostics.category(for: operation), code: result.1.statusCode)
        try handleResponse(result.1, data: result.0, operation: operation, retryKey: key)
        try checkGeneration(generation)
        return result
    }

    private func makeURLRequest(_ operation: APIRequest) throws -> URLRequest {
        if operation.method != .get, isOffline { throw URLError(.notConnectedToInternet) }
        var request = URLRequest(url: try url(for: operation.path))
        request.httpMethod = operation.method.rawValue
        request.timeoutInterval = APILimits.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        if session.isExpired {
            try clearSession()
            throw ClientError.expiredSession
        }
        try session.authorize(&request, method: operation.method)
        if let body = operation.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func handleResponse(_ response: HTTPURLResponse, data: Data,
                                operation: APIRequest, retryKey: String) throws {
        if response.statusCode == 401 {
            try clearSession()
            throw ClientError.expiredSession
        }
        if response.statusCode == 403 { snapshots?.clear() }
        try captureCookie(response)
        if response.statusCode == 419 { session.invalidateCSRFToken() }
        guard (200..<300).contains(response.statusCode) else {
            if operation.path == APIEndpoints.bootstrap, response.statusCode == 404 {
                throw ClientError.serviceNotEnabled
            }
            let failure = APIResponseFailure(data: data, response: response)
            rateLimiter.record(failure, key: retryKey, at: now())
            throw failure.error
        }
        if operation.path == APIEndpoints.login || operation.path == APIEndpoints.register {
            session.invalidateCSRFToken()
            snapshots?.clear()
            rateLimiter.clear()
        }
    }

    private func captureCookie(_ response: HTTPURLResponse) throws {
        if try !session.captureCookie(response) { try clearSession() }
    }

    private func checkGeneration(_ generation: Int) throws {
        guard generation == sessionGeneration else { throw CancellationError() }
    }
}
