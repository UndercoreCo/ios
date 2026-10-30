import XCTest
@testable import UndercoreCore

private final class OfflineSession: SessionStore {
    var value: SessionCredentials?
    init(origin: URL) { value = SessionCredentials(origin: origin.absoluteString, cookieName: "session", cookieValue: "test-session", expiresAt: Date().addingTimeInterval(86400)) }
    func load() throws -> SessionCredentials? { value }
    func save(_ value: SessionCredentials) throws { self.value = value }
    func clear() throws { value = nil }
}
private final class OfflineTransport: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor final class OfflineAccountTests: XCTestCase {
    let origin = URL(string: "https://offline.example.test")!
    let pagePath = APIEndpoints.configurations + "?page=1"
    let accountJSON = #"{"user":{"id":12,"name":"Test","email":"test@example.test","isEmailVerified":true,"secret":"never-cache"}}"#
    let pageJSON = #"{"data":{"configs":[],"packages":[{"id":"vpk_01AAAAAAAAAAAAAAAAAAAAAAAA","name":"3 устройства","deviceCount":3,"usedSlots":0,"origin":"paid","expiresAt":"2027-01-01T00:00:00Z","slots":[]}],"pagination":{"page":1,"lastPage":1},"privateKey":"never-cache"}}"#
    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OfflineTransport.self]
        return URLSession(configuration: config)
    }
    func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func seed(_ cache: AccountSnapshotStore) {
        cache.store(path: APIEndpoints.account, method: "GET", data: Data(accountJSON.utf8), at: Date())
        cache.store(path: pagePath, method: "GET", data: Data(pageJSON.utf8), at: Date())
    }
    func testColdRestartRestoresSameAccountAndMetadataWithoutSendingMutations() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = AccountSnapshotStore(origin: origin, directory: root); seed(saved)
        await ArticleCacheFileIO.flush()
        let restored = AccountSnapshotStore(origin: origin, directory: root)
        let transport = session(); defer { transport.invalidateAndCancel() }
        var requests = 0
        OfflineTransport.handler = { _ in requests += 1; throw URLError(.notConnectedToInternet) }
        let client = try APIClient(baseURL: origin, store: OfflineSession(origin: origin), session: transport, snapshots: restored)
        let user = await client.restoreOfflineAccount()
        XCTAssertEqual(user?.id, 12); XCTAssertTrue(client.isOffline)
        let page: Envelope<VPNPage> = try await client.request(pagePath)
        XCTAssertEqual(page.data.packages.count, 1)
        do { let _: UserResponse = try await client.request("/mutation", method: "POST"); XCTFail() } catch { XCTAssertTrue(error.isOfflineTransportError) }
        do { _ = try await client.download("/configuration"); XCTFail() } catch { XCTAssertTrue(error.isOfflineTransportError) }
        XCTAssertEqual(requests, 0, "Offline mutations and private exports must not reach the network")
    }
    func testTransportFailureUsesSnapshotButHTTPFailuresDoNot() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        let transport = session(); defer { transport.invalidateAndCancel() }
        let client = try APIClient(baseURL: origin, store: OfflineSession(origin: origin), session: transport, snapshots: cache)
        for status in [429, 500] {
            OfflineTransport.handler = { _ in (status, #"{"message":"Test error"}"#) }
            do { let _: Envelope<VPNPage> = try await client.request(pagePath); XCTFail("HTTP failure disguised as cached success") }
            catch let ClientError.server(actual, _, _) { XCTAssertEqual(actual, status) }
            XCTAssertFalse(client.isOffline)
        }
        OfflineTransport.handler = { _ in throw URLError(.notConnectedToInternet) }
        let result: Envelope<VPNPage> = try await client.request(pagePath)
        XCTAssertEqual(result.data.packages.count, 1); XCTAssertTrue(client.isOffline)
        await ArticleCacheFileIO.flush()
    }
    func testUnauthorizedClearsDiskAndCannotRestore() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        let transport = session(); defer { transport.invalidateAndCancel() }
        let client = try APIClient(baseURL: origin, store: OfflineSession(origin: origin), session: transport, snapshots: cache)
        OfflineTransport.handler = { _ in (401, "{}") }
        do { let _: Envelope<VPNPage> = try await client.request(pagePath); XCTFail() } catch { XCTAssertEqual(error as? ClientError, .expiredSession) }
        await ArticleCacheFileIO.flush()
        let restored = AccountSnapshotStore(origin: origin, directory: root); await restored.restore()
        XCTAssertNil(restored.account)
        let user = await client.restoreOfflineAccount(); XCTAssertNil(user)
    }
    func testDifferentAccountAndOriginNeverInheritData() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        cache.store(path: APIEndpoints.account, method: "GET", data: Data(accountJSON.replacingOccurrences(of: "\"id\":12", with: "\"id\":13").utf8), at: Date())
        let oldPage: Envelope<VPNPage>? = cache.value(pagePath); XCTAssertNil(oldPage)
        await ArticleCacheFileIO.flush()
        let other = AccountSnapshotStore(origin: URL(string: "https://other.example.test")!, directory: root); await other.restore()
        XCTAssertNil(other.account)
    }
    func testWhitelistStripsUnknownSecretsAndIgnoresExportsAndTokens() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        for path in ["/api/mobile/v1/bootstrap", "/api/internal/vpn/configs/vpn_01AAAAAAAAAAAAAAAAAAAAAAAA/configuration", "/api/internal/profile/telegram/connect"] {
            cache.store(path: path, method: "GET", data: Data(#"{"privateKey":"never-cache"}"#.utf8), at: Date())
        }
        await ArticleCacheFileIO.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let entries = try XCTUnwrap(json["entries"] as? [String: [String: Any]])
        XCTAssertEqual(entries.count, 2)
        for entry in entries.values {
            let raw = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(entry["data"] as? String)))
            XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("never-cache"))
        }
    }
    func testLogoutWinsOverQueuedWritesAndExpiredSessionCannotRestore() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache); cache.clear()
        await ArticleCacheFileIO.flush()
        let restored = AccountSnapshotStore(origin: origin, directory: root); await restored.restore(); XCTAssertNil(restored.account)
        seed(cache); await ArticleCacheFileIO.flush()
        let credentials = OfflineSession(origin: origin)
        credentials.value = SessionCredentials(origin: origin.absoluteString, cookieName: "session", cookieValue: "old", expiresAt: .distantPast)
        let client = try APIClient(baseURL: origin, store: credentials, snapshots: cache)
        let user = await client.restoreOfflineAccount(); XCTAssertNil(user)
        await ArticleCacheFileIO.flush()
    }
    func testReconnectionMustVerifyAccountWithoutCachedSuccess() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        let transport = session(); defer { transport.invalidateAndCancel() }
        let client = try APIClient(baseURL: origin, store: OfflineSession(origin: origin), session: transport, snapshots: cache)
        client.setOffline(true)
        OfflineTransport.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await LiveAuthRepository(client: client).currentAccount(); XCTFail("Reconnection accepted a cached account") }
        catch { XCTAssertTrue(error.isOfflineTransportError) }
        XCTAssertTrue(client.isOffline)
        OfflineTransport.handler = { _ in (200, self.accountJSON) }
        let user = try await LiveAuthRepository(client: client).currentAccount()
        XCTAssertEqual(user.id, 12)
        // The coordinator additionally requires a fresh CSRF bootstrap before changing this state.
        XCTAssertTrue(client.isOffline)
        await ArticleCacheFileIO.flush()
    }
    func testExplicitRetryRecoversAfterTimeoutWithoutPathChange() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        let transport = session(); defer { transport.invalidateAndCancel() }
        let client = try APIClient(baseURL: origin, store: OfflineSession(origin: origin), session: transport, snapshots: cache)
        OfflineTransport.handler = { _ in throw URLError(.timedOut) }
        let _: Envelope<VPNPage> = try await client.request(APIRequests.configurations(page: 1))
        XCTAssertTrue(client.isOffline)
        var paths: [String] = []
        OfflineTransport.handler = { request in
            paths.append(request.url!.path)
            if request.url!.path == APIEndpoints.bootstrap { return (200, self.retryBootstrap) }
            return (200, self.accountJSON)
        }
        let account = try await client.verifyOnlineSession()
        XCTAssertEqual(account.id, 12)
        XCTAssertFalse(client.isOffline)
        XCTAssertEqual(paths, [APIEndpoints.bootstrap, APIEndpoints.account])
        XCTAssertTrue(client.diagnostics.events.contains { $0.kind == .requestFailed && $0.code == URLError.timedOut.rawValue })
        await ArticleCacheFileIO.flush()
    }

    private var retryBootstrap: String {
        #"{"data":{"apiVersion":1,"csrfToken":"test","sessionCookieName":"session","sessionLifetimeSeconds":86400,"challenge":{"provider":"none","siteKey":"","tokenField":"smart-token","required":false}}}"#
    }

    func testFailedAccountRetryNeverEnablesOfflineActions() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        let transport = session(); defer { transport.invalidateAndCancel() }
        let client = try APIClient(baseURL: origin, store: OfflineSession(origin: origin), session: transport, snapshots: cache)
        for status in [500, 429] {
            client.setOffline(true)
            OfflineTransport.handler = { request in
                request.url!.path == APIEndpoints.bootstrap ? (200, self.retryBootstrap) : (status, "{}")
            }
            do { _ = try await client.verifyOnlineSession(); XCTFail("Failed verification enabled actions") }
            catch { XCTAssertTrue(client.isOffline) }
        }
        await ArticleCacheFileIO.flush()
    }

    func testDiagnosticsAreBoundedAndContainNoRequestOrAccountData() async throws {
        let transport = session(); defer { transport.invalidateAndCancel() }
        let client = try APIClient(baseURL: origin, store: OfflineSession(origin: origin), session: transport)
        OfflineTransport.handler = { _ in (200, self.accountJSON) }
        let _: UserResponse = try await client.request(APIRequests.account)
        for _ in 0..<210 { client.diagnostics.record(.tunnelStatus, category: .tunnel, code: 3) }
        XCTAssertEqual(client.diagnostics.events.count, 200)
        let json = String(decoding: try client.diagnostics.report(isOffline: false), as: UTF8.self)
        for secret in ["offline.example.test", "test@example.test", "test-session", "never-cache", "PrivateKey"] {
            XCTAssertFalse(json.contains(secret))
        }
    }

    func testVerifiedLoginSeedsCacheAndNotificationsRemainBounded() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root)
        cache.store(path: APIEndpoints.login, method: "POST", data: Data(accountJSON.utf8), at: Date())
        XCTAssertEqual(cache.account?.id, 12)
        let messages = (0..<60).map { ["id": "ntf_\($0)", "title": "Test", "body": "Message", "kind": "info", "isRead": false] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["data": messages, "meta": ["current_page": 1, "last_page": 2]])
        let path = APIEndpoints.notifications + "?page=1&perPage=30&status=all"
        cache.store(path: path, method: "GET", data: data, at: Date())
        let page: NotificationPage? = cache.value(path)
        XCTAssertEqual(page?.data.count, 30)
        await ArticleCacheFileIO.flush()
    }
    func testUnavailableDeviceDetailNeverBecomesCachedOperationConfirmation() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        let path = try APIEndpoints.configuration("vpn_01AAAAAAAAAAAAAAAAAAAAAAAA")
        let json = #"{"data":{"id":"vpn_01AAAAAAAAAAAAAAAAAAAAAAAA","protocol":"amneziawg","state":"active","canDownload":true,"canRename":true}}"#
        cache.store(path: path, method: "GET", data: Data(json.utf8), at: Date())
        let transport = session(); defer { transport.invalidateAndCancel() }
        let client = try APIClient(baseURL: origin, store: OfflineSession(origin: origin), session: transport, snapshots: cache)
        OfflineTransport.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await LiveConfigurationRepository(client: client).detail("vpn_01AAAAAAAAAAAAAAAAAAAAAAAA"); XCTFail("Cached device confirmed a live operation") }
        catch { XCTAssertTrue(error.isOfflineTransportError) }
        await ArticleCacheFileIO.flush()
    }
    func testFirstConfigurationPageReplacesOldPaginationWithoutDroppingOtherMetadata() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        let secondPath = APIEndpoints.configurationPage(2)
        cache.store(path: secondPath, method: "GET", data: Data(pageJSON.replacingOccurrences(of: "\"page\":1", with: "\"page\":2").utf8), at: Date())
        cache.store(path: APIEndpoints.notificationSummary, method: "GET", data: Data(#"{"data":{"unreadCount":4}}"#.utf8), at: Date())
        let second: Envelope<VPNPage>? = cache.value(secondPath)
        XCTAssertNotNil(second)
        cache.store(path: pagePath, method: "GET", data: Data(pageJSON.utf8), at: Date())
        let removed: Envelope<VPNPage>? = cache.value(secondPath)
        let summary: Envelope<NotificationSummary>? = cache.value(APIEndpoints.notificationSummary)
        XCTAssertNil(removed)
        XCTAssertEqual(summary?.data.unreadCount, 4)
        await ArticleCacheFileIO.flush()
    }

    func testReadNotificationsPatchListAndInvalidateSummaryWithoutRefreshingListTimestamp() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        let path = APIEndpoints.notificationPage(1)
        let id = "ntf_01AAAAAAAAAAAAAAAAAAAAAAAA"
        let first = UserNotification(id: id, kind: "info", title: "One", body: "Test", isRead: false, createdAt: nil)
        let second = UserNotification(id: "ntf_01BBBBBBBBBBBBBBBBBBBBBBBB", kind: "info", title: "Two", body: "Test", isRead: false, createdAt: nil)
        let page = NotificationPage(data: [first, second], meta: .init(page: 1, lastPage: 1))
        let date = Date(timeIntervalSince1970: 1000)
        cache.store(path: path, method: "GET", data: try JSONEncoder().encode(page), at: date)
        cache.store(path: APIEndpoints.notificationSummary, method: "GET", data: Data(#"{"data":{"unreadCount":2}}"#.utf8), at: date)
        cache.store(path: try APIEndpoints.notificationRead(id), method: "PATCH", data: try JSONEncoder().encode(Envelope(data: first.markingRead())), at: Date())
        let read: NotificationPage? = cache.value(path)
        XCTAssertEqual(read?.data.map(\.isRead), [true, false])
        XCTAssertEqual(cache.date(for: path), date)
        let summary: Envelope<NotificationSummary>? = cache.value(APIEndpoints.notificationSummary)
        XCTAssertNil(summary)
        cache.store(path: APIEndpoints.notificationsReadAll, method: "POST", data: Data(), at: Date())
        let allRead: NotificationPage? = cache.value(path)
        XCTAssertEqual(allRead?.data.map(\.isRead), [true, true])
        XCTAssertEqual(cache.date(for: path), date)
        await ArticleCacheFileIO.flush()
    }

    func testPackageAndDeviceUpdatesPatchCachedPagesWithoutMakingListingFresh() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountSnapshotStore(origin: origin, directory: root); seed(cache)
        let originalDate = cache.date(for: pagePath)
        let packageID = "vpk_01AAAAAAAAAAAAAAAAAAAAAAAA"
        let configID = "vpn_01AAAAAAAAAAAAAAAAAAAAAAAA"
        let config = #"{"id":"vpn_01AAAAAAAAAAAAAAAAAAAAAAAA","name":"Before","protocol":"amneziawg","state":"active","canDownload":true,"canRename":true}"#
        let package = #"{"data":{"id":"vpk_01AAAAAAAAAAAAAAAAAAAAAAAA","name":"3 устройства","deviceCount":3,"usedSlots":1,"origin":"paid","expiresAt":"2027-01-01T00:00:00Z","slots":[{"number":1,"occupied":true,"canActivate":false,"config":CONFIG}]}}"#.replacingOccurrences(of: "CONFIG", with: config)
        cache.store(path: try APIEndpoints.package(packageID), method: "GET", data: Data(package.utf8), at: Date())
        let updated: Envelope<VPNPage>? = cache.value(pagePath)
        XCTAssertEqual(updated?.data.packages.first?.slots.first?.config?.name, "Before")
        let renamed = #"{"data":CONFIG}"#.replacingOccurrences(of: "CONFIG", with: config.replacingOccurrences(of: "Before", with: "After"))
        cache.store(path: try APIEndpoints.configuration(configID), method: "PATCH", data: Data(renamed.utf8), at: Date())
        let page: Envelope<VPNPage>? = cache.value(pagePath)
        let detail: Envelope<VPNPage.Package>? = cache.value(try APIEndpoints.package(packageID))
        XCTAssertEqual(page?.data.packages.first?.slots.first?.config?.name, "After")
        XCTAssertEqual(detail?.data.slots.first?.config?.name, "After")
        XCTAssertEqual(cache.date(for: pagePath), originalDate)
        await ArticleCacheFileIO.flush()
    }

    func testLastConnectionDecodesOldAPIAndDoesNotInventOnlineState() throws {
        let old = #"{"id":"vpn_01AAAAAAAAAAAAAAAAAAAAAAAA","protocol":"amneziawg","state":"active","canDownload":true,"canRename":true}"#
        XCTAssertNil(try JSONDecoder().decode(VPNConfiguration.self, from: Data(old.utf8)).connection)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(old.utf8)) as? [String: Any])
        json["connection"] = ["status":"confirmed", "lastHandshakeAt":"2026-10-05T10:00:00Z", "checkedAt":"2026-10-05T10:05:00Z"]
        let item = try JSONDecoder().decode(VPNConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(item.connection?.lastHandshakeAt, "2026-10-05T10:00:00Z")
    }
}
