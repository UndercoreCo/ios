import XCTest
@testable import UndercoreCore

private final class AccountMemoryStore: SessionStore {
    var value: SessionCredentials?
    func load() throws -> SessionCredentials? { value }
    func save(_ credentials: SessionCredentials) throws { value = credentials }
    func clear() throws { value = nil }
}
private final class AccountStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class AccountManagementTests: XCTestCase {
    private static let bootstrap = #"{"data":{"apiVersion":1,"csrfToken":"test-csrf","sessionCookieName":"test_session","sessionLifetimeSeconds":1209600,"challenge":{"provider":"none","siteKey":"","tokenField":"smart-token","required":false}}}"#
    @MainActor private func fixture() throws -> (LiveAccountManagementRepository, URLSession, AccountMemoryStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountStub.self]
        let session = URLSession(configuration: configuration)
        let store = AccountMemoryStore()
        let client = try APIClient(baseURL: URL(string: "https://account.example.test")!, store: store, session: session)
        return (LiveAccountManagementRepository(client: client), session, store)
    }
    private static func bootstrapResponse(_ request: URLRequest) -> (Int, [String: String], String)? {
        guard request.url?.path == APIEndpoints.bootstrap else { return nil }
        return (200, ["Set-Cookie":"test_session=synthetic; Path=/; Secure; HttpOnly"], bootstrap)
    }
    private static func body(_ request: URLRequest) throws -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
    @MainActor func testPasswordResetUsesExistingEndpointCSRFAndOnlyEmail() async throws {
        let (repo, session, _) = try fixture()
        defer { session.invalidateAndCancel(); AccountStub.handler = nil }
        var posts = 0
        AccountStub.handler = { request in
            if let response = Self.bootstrapResponse(request) { return response }
            posts += 1
            XCTAssertEqual(request.url?.path, "/forgot-password")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "test-csrf")
            XCTAssertEqual(try Self.body(request), ["email":"preview@example.test"])
            return (200, [:], #"{"ok":true,"message":"sent"}"#)
        }
        try await repo.requestPasswordReset(email: "preview@example.test")
        XCTAssertEqual(posts, 1)
    }
    @MainActor func testDeletionRequiresAcceptedReceiptAndSendsReauthentication() async throws {
        let (repo, session, store) = try fixture()
        defer { session.invalidateAndCancel(); AccountStub.handler = nil }
        var deletes = 0
        AccountStub.handler = { request in
            if let response = Self.bootstrapResponse(request) { return response }
            deletes += 1
            XCTAssertEqual(request.url?.path, "/api/internal/profile")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "test_session=synthetic")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://account.example.test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "test-csrf")
            XCTAssertEqual(try Self.body(request), ["current_password":"test-password"])
            return (202, [:], #"{"ok":true,"status":"requested"}"#)
        }
        try await repo.requestDeletion(password: "test-password")
        XCTAssertEqual(deletes, 1)
        XCTAssertFalse(String(data: try JSONEncoder().encode(store.value), encoding: .utf8)!.contains("test-password"))
    }
    @MainActor func testDeletionDoesNotTreatMalformedOrUnexpectedSuccessAsAcceptance() async throws {
        let (repo, session, _) = try fixture()
        defer { session.invalidateAndCancel(); AccountStub.handler = nil }
        for (status, body) in [(200, #"{"ok":true,"status":"requested"}"#), (202, #"{"ok":false,"status":"requested"}"#), (202, #"{"ok":true,"status":"failed"}"#), (202, "{}")] {
            AccountStub.handler = { request in Self.bootstrapResponse(request) ?? (status, [:], body) }
            do { try await repo.requestDeletion(password: "test"); XCTFail("False acceptance") }
            catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        }
    }
    @MainActor func testPreparationTimeoutNeverSendsDeletionAndIsNotAmbiguous() async throws {
        let (repo, session, _) = try fixture()
        defer { session.invalidateAndCancel(); AccountStub.handler = nil }
        var deletes = 0
        AccountStub.handler = { request in
            if request.httpMethod == "DELETE" { deletes += 1 }
            throw URLError(.timedOut)
        }
        do { try await repo.requestDeletion(password: "test"); XCTFail("Timeout hidden") }
        catch let error as AccountDeletionPreparationError {
            XCTAssertEqual((error.underlyingError as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(deletes, 0)
    }
    func testRateLimitMessageIsLocalizedAndPreservesRetryAfter() {
        let error = ClientError.server(status: 429, message: "Too Many Attempts.", retryAfter: 42)
        XCTAssertEqual(error.localizedDescription, "Слишком много попыток. Повторите через 42 сек.")
    }

    @MainActor func testDeletionTimeoutNeverAutomaticallyRetries() async throws {
        let (repo, session, _) = try fixture()
        defer { session.invalidateAndCancel(); AccountStub.handler = nil }
        var deletes = 0
        AccountStub.handler = { request in
            if let response = Self.bootstrapResponse(request) { return response }
            deletes += 1
            throw URLError(.timedOut)
        }
        do { try await repo.requestDeletion(password: "test"); XCTFail("Timeout hidden") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(deletes, 1)
    }
    @MainActor func testValidationAndRateLimitsRemainServerErrors() async throws {
        for status in [422, 429, 403] {
            // Independent responses; a 429 now deliberately blocks subsequent requests.
            let (repo, session, _) = try fixture()
            defer { session.invalidateAndCancel(); AccountStub.handler = nil }
            AccountStub.handler = { request in Self.bootstrapResponse(request) ?? (status, ["Retry-After":"60"], #"{"message":"denied"}"#) }
            do { try await repo.requestDeletion(password: "test"); XCTFail("Rejected deletion accepted") }
            catch { XCTAssertEqual(error as? ClientError, .server(status: status, message: "denied", retryAfter: 60)) }
        }
    }
    @MainActor func testExpiredSessionIsClearedOnDeletionUnauthorized() async throws {
        let (repo, session, store) = try fixture()
        defer { session.invalidateAndCancel(); AccountStub.handler = nil }
        AccountStub.handler = { request in Self.bootstrapResponse(request) ?? (401, [:], "{}") }
        do { try await repo.requestDeletion(password: "test"); XCTFail("Unauthorized accepted") }
        catch { XCTAssertEqual(error as? ClientError, .expiredSession) }
        XCTAssertNil(store.value)
    }
}
