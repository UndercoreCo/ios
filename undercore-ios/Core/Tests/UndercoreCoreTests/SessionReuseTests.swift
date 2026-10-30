import XCTest
@testable import UndercoreCore

@MainActor final class SessionReuseTests: XCTestCase {
    private let origin = URL(string: "https://session.example.test")!
    private let id = "vpn_01AAAAAAAAAAAAAAAAAAAAAAAA"
    private let bootstrap = #"{"data":{"apiVersion":1,"csrfToken":"test-token","sessionCookieName":"session","sessionLifetimeSeconds":86400,"challenge":{"provider":"none","siteKey":"","tokenField":"smart-token","required":false}}}"#
    private let account = #"{"user":{"id":7,"name":"Test","email":"test@example.test","isEmailVerified":true}}"#
    private func client(store: ReuseStore = ReuseStore(), snapshots: AccountSnapshotStore? = nil) throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReuseTransport.self]
        config.httpCookieStorage = nil
        return try APIClient(baseURL: origin, store: store, session: URLSession(configuration: config), snapshots: snapshots)
    }
    private var sessionReplies: [ReuseTransport.Reply] {
        [.init(APIEndpoints.bootstrap, bootstrap), .init(APIEndpoints.account, account)]
    }
    override func tearDown() { ReuseTransport.install([]); super.tearDown() }

    func testRepeatVPNPreparationMakesThreeRequestsInsteadOfFour() async throws {
        let path = try APIEndpoints.configuration(id)
        let metadata = "{\"data\":{\"id\":\"\(id)\",\"protocol\":\"amneziawg\",\"state\":\"active\",\"canDownload\":true,\"canRename\":true}}"
        let download = ReuseTransport.Reply(path + "/configuration", "[Interface]\nPrivateKey = SYNTHETIC\n[Peer]\n",
            headers: ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"uc-1-v1.conf\""])
        let tail: [ReuseTransport.Reply] = [.init(APIEndpoints.account, account), .init(path, metadata), download]
        ReuseTransport.install([.init(APIEndpoints.bootstrap, bootstrap)] + tail + tail)
        let api = try client()
        let repository = LiveConfigurationRepository(client: api)
        for _ in 0..<2 {
            _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
            _ = try await repository.detail(id)
            _ = try await repository.download(id)
        }
        XCTAssertEqual(ReuseTransport.remaining, 0)
    }

    func testWarmSessionReturnsFreshOwnerAndVerificationState() async throws {
        let changed = account.replacingOccurrences(of: "\"id\":7", with: "\"id\":8").replacingOccurrences(of: "true", with: "false")
        ReuseTransport.install(sessionReplies + [.init(APIEndpoints.account, changed)])
        let api = try client()
        _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
        let current = try await api.verifyOnlineSession(reusingPreparedSession: true)
        XCTAssertEqual(current.id, 8)
        XCTAssertFalse(current.isEmailVerified)
        XCTAssertEqual(ReuseTransport.remaining, 0)
    }

    func testWarmSessionNeverUsesOfflineAccountToConfirmConnectivity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AccountSnapshotStore(origin: origin, directory: directory)
        let api = try client(snapshots: cache)
        ReuseTransport.install(sessionReplies)
        _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
        for status in [403, 429, 503] {
            api.setOffline(true)
            ReuseTransport.install([.init(APIEndpoints.account, "{}", status: status)])
            do { _ = try await api.verifyOnlineSession(reusingPreparedSession: true); XCTFail("Failure became cached success") }
            catch { XCTAssertTrue(api.isOffline) }
            XCTAssertEqual(ReuseTransport.remaining, 0)
        }
        await ArticleCacheFileIO.flush()
    }

    func testNormalClientStillForcesBootstrap() async throws {
        ReuseTransport.install(sessionReplies + sessionReplies)
        let api = try client()
        _ = try await api.verifyOnlineSession()
        _ = try await api.verifyOnlineSession()
        XCTAssertEqual(ReuseTransport.remaining, 0)
    }

    func testNewProcessCannotReusePreparedSessionFromKeychain() async throws {
        let store = ReuseStore()
        for _ in 0..<2 {
            ReuseTransport.install(sessionReplies)
            _ = try await client(store: store).verifyOnlineSession(reusingPreparedSession: true)
            XCTAssertEqual(ReuseTransport.remaining, 0)
        }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(store.value), as: UTF8.self).contains("test-token"))
    }

    func testCSRFRejectionInvalidatesBootstrapWithoutReplayingMutation() async throws {
        ReuseTransport.install(sessionReplies + [.init("/mutation", "{}", status: 419)] + sessionReplies)
        let api = try client()
        _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
        do { let _: [String: Bool] = try await api.request("/mutation", method: "POST"); XCTFail("419 accepted") }
        catch let ClientError.server(status, _, _) { XCTAssertEqual(status, 419) }
        _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
        XCTAssertEqual(ReuseTransport.remaining, 0)
    }

    func testFailedForcedBootstrapCannotLeaveOldTokenPrepared() async throws {
        ReuseTransport.install(sessionReplies + [.init(APIEndpoints.bootstrap, "{}", status: 503)] + sessionReplies)
        let api = try client()
        _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
        do { _ = try await api.bootstrap(); XCTFail("Bootstrap failure ignored") } catch {}
        _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
        XCTAssertEqual(ReuseTransport.remaining, 0)
    }

    func testLoginRotatesPreparedStateBeforeNextVerification() async throws {
        ReuseTransport.install(sessionReplies + [.init(APIEndpoints.login, account)] + sessionReplies)
        let api = try client()
        _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
        let _: UserResponse = try await api.request(APIRequests.login(email: "test@example.test", password: "synthetic"))
        _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
        XCTAssertEqual(ReuseTransport.remaining, 0)
    }

    func testLogoutEvenWithStorageFailureRejectsLateVerification() async throws {
        let started = expectation(description: "Account request started")
        ReuseTransport.install(sessionReplies + [.init(APIEndpoints.account, account, delay: 0.1, inspect: { started.fulfill() })])
        let store = ReuseStore()
        let api = try client(store: store)
        _ = try await api.verifyOnlineSession(reusingPreparedSession: true)
        let task = Task { try await api.verifyOnlineSession(reusingPreparedSession: true) }
        await fulfillment(of: [started], timeout: 2)
        store.failClear = true
        XCTAssertThrowsError(try api.clearSession())
        do { _ = try await task.value; XCTFail("Logout lost to late response") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(api.hasValidSession)
        XCTAssertEqual(ReuseTransport.remaining, 0)
    }

    func testExpiredServerCookieCannotPrepareSession() async throws {
        ReuseTransport.install([.init(APIEndpoints.bootstrap, bootstrap, headers: ["Set-Cookie": "session=deleted; Max-Age=0; Path=/"])])
        let api = try client()
        do { _ = try await api.verifyOnlineSession(reusingPreparedSession: true); XCTFail("Expired cookie accepted") } catch {}
        XCTAssertFalse(api.hasValidSession)
        XCTAssertEqual(ReuseTransport.remaining, 0)
    }
}

private final class ReuseStore: SessionStore {
    var value: SessionCredentials? = .init(origin: "https://session.example.test", cookieName: "session", cookieValue: "synthetic", expiresAt: Date().addingTimeInterval(86400))
    var failClear = false
    func load() throws -> SessionCredentials? { value }
    func save(_ value: SessionCredentials) throws { self.value = value }
    func clear() throws { if failClear { throw URLError(.cannotWriteToFile) }; value = nil }
}

private final class ReuseTransport: URLProtocol, @unchecked Sendable {
    struct Reply {
        let path: String
        let body: String
        var status: Int
        var headers: [String: String]
        var delay: TimeInterval
        var inspect: (() -> Void)?
        init(_ path: String, _ body: String, status: Int = 200, headers: [String: String] = [:], delay: TimeInterval = 0, inspect: (() -> Void)? = nil) {
            self.path = path; self.body = body; self.status = status; self.headers = headers; self.delay = delay; self.inspect = inspect
        }
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    static var remaining: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
    static func install(_ value: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()
        guard let reply else { XCTFail("Unexpected request"); client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        XCTAssertEqual(request.url?.path, reply.path)
        reply.inspect?()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        let finish = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: finish) }
        else { finish() }
    }
    override func stopLoading() {}
}
