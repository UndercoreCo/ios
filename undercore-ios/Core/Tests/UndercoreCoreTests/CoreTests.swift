import XCTest
@testable import UndercoreCore

private final class MemoryStore: SessionStore {
    var value: SessionCredentials?
    var cleared = false
    func load() throws -> SessionCredentials? { value }
    func save(_ credentials: SessionCredentials) throws { value = credentials }
    func clear() throws { value = nil; cleared = true }
}
private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class CoreTests: XCTestCase {
    private let id = "vpn_01AAAAAAAAAAAAAAAAAAAAAAAA"
    @MainActor func testRateLimitWaitsWithoutRetryAndKeepsOtherActionsAvailable() async throws {
        let session = makeSession()
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        var time = Date()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session, now: { time })
        StubProtocol.handler = { _ in (200, [:], Self.bootstrapData) }
        try await client.bootstrap()
        var calls = 0
        StubProtocol.handler = { _ in
            calls += 1
            return (429, ["Retry-After": "60"], Data("{}".utf8))
        }
        let path = "/api/internal/profile/telegram/connect"
        do {
            let _: [String: Bool] = try await client.request(path, method: "POST")
            XCTFail("Expected rate limit")
        } catch let ClientError.server(status, _, retry) {
            XCTAssertEqual(status, 429); XCTAssertEqual(retry, 60)
        }
        time.addTimeInterval(10)
        do {
            let _: [String: Bool] = try await client.request(path + "?ignored=1", method: "POST")
            XCTFail("Expected local cooldown")
        } catch let ClientError.server(status, _, retry) {
            XCTAssertEqual(status, 429); XCTAssertEqual(retry, 50)
        }
        XCTAssertEqual(calls, 1, "No automatic or manual request during Retry-After")
        StubProtocol.handler = { _ in calls += 1; return (200, [:], Data("{}".utf8)) }
        let _: [String: Bool] = try await client.request("/api/internal/profile/max/connect", method: "POST")
        let _: [String: Bool] = try await client.request(path, method: "GET")
        XCTAssertEqual(calls, 3, "Other messenger and reads are independent")
        time.addTimeInterval(50)
        let _: [String: Bool] = try await client.request(path, method: "POST")
        XCTAssertEqual(calls, 4)
    }

    @MainActor func testCooldownDoesNotBlockAnotherLoginIdentity() async throws {
        let session = makeSession()
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        StubProtocol.handler = { _ in (200, [:], Self.bootstrapData) }
        try await client.bootstrap()
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; return (429, ["Retry-After": "60"], Data("{}".utf8)) }
        for email in ["a@example.test", " A@EXAMPLE.TEST ", "b@example.test"] {
            do {
                let _: [String: Bool] = try await client.request(APIEndpoints.login, method: "POST", body: ["email": email])
                XCTFail("Expected rate limit")
            } catch let ClientError.server(status, _, _) { XCTAssertEqual(status, 429) }
        }
        XCTAssertEqual(calls, 2, "Email normalization groups retries, another account reaches the server")
    }

    @MainActor func testRateLimitJSONFallbackAndSessionReset() async throws {
        let session = makeSession()
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        var calls = 0
        StubProtocol.handler = { _ in
            calls += 1
            return (429, [:], Data(#"{"error":{"parameters":{"retryAfterSeconds":120}}}"#.utf8))
        }
        for _ in 0..<2 {
            do {
                let _: [String: Bool] = try await client.request("/limited")
                XCTFail("Expected rate limit")
            } catch let ClientError.server(status, _, retry) {
                XCTAssertEqual(status, 429); XCTAssertEqual(retry, 120)
            }
        }
        XCTAssertEqual(calls, 1)
        try client.clearSession()
        StubProtocol.handler = { _ in calls += 1; return (200, [:], Data("{}".utf8)) }
        let _: [String: Bool] = try await client.request("/limited")
        XCTAssertEqual(calls, 2, "The previous account's cooldown is cleared")
    }

    func testDeepLinksOnlyAcceptPublicIDsAndExplicitDebugTests() throws {
        XCTAssertEqual(DeepLink.parse(URL(string: "undercore://configuration?id=\(id)")!), .configuration(id))
        for text in ["undercore://configuration?id=1", "undercore://configuration?id=\(id)&url=https://evil.test", "undercore://configuration?id=\(id)&id=\(id)", "undercore://configuration?id=\(id)#secret", "https://example.test?id=\(id)", "undercore://configuration/other?id=\(id)"] {
            XCTAssertNil(DeepLink.parse(URL(string: text)!))
        }
        XCTAssertNil(DeepLink.parse(URL(string: "undercore://test?protocol=wg")!))
        XCTAssertEqual(DeepLink.parse(URL(string: "undercore://test?protocol=awg")!, allowSynthetic: true), .syntheticTest("awg"))
    }
    func testPackageConfigurationsAreIncluded() throws {
        let config = "{\"id\":\"\(id)\",\"name\":null,\"protocol\":\"wireguard\",\"state\":\"active\",\"expiresAt\":null,\"canDownload\":true,\"canRename\":true}"
        let data = Data("{\"configs\":[],\"packages\":[{\"id\":\"vpk_01AAAAAAAAAAAAAAAAAAAAAAAA\",\"name\":\"Package\",\"deviceCount\":3,\"usedSlots\":1,\"origin\":\"purchase\",\"slots\":[{\"number\":1,\"occupied\":false,\"canActivate\":true,\"config\":null},{\"number\":2,\"occupied\":true,\"canActivate\":false,\"config\":\(config)}]}],\"pagination\":{\"page\":1,\"lastPage\":1}}".utf8)
        let page = try JSONDecoder().decode(VPNPage.self, from: data)
        XCTAssertEqual(page.configurations.map(\.id), [id])
    }
    func testPackageCapacitiesAndUnavailableOccupiedSlots() throws {
        for count in [1, 3, 6, 9] {
            for origin in ["purchase", "trial", "gift"] {
                let json: [String: Any] = ["id": "vpk_01AAAAAAAAAAAAAAAAAAAAAAAA", "name": "Package", "deviceCount": count,
                    "usedSlots": 1, "origin": origin, "expiresAt": "2025-01-01T00:00:00Z",
                    "slots": (1...count).map { ["number": $0, "occupied": $0 == 1, "canActivate": false, "config": NSNull()] as [String: Any] }]
                let package = try JSONDecoder().decode(VPNPage.Package.self, from: JSONSerialization.data(withJSONObject: json))
                XCTAssertEqual(package.slots.count, count)
                XCTAssertTrue(package.slots[0].occupied, "An archived/hidden config still occupies its slot")
                XCTAssertNil(package.slots[0].config)
                XCTAssertTrue(package.slots.allSatisfy { !$0.canActivate })
            }
        }
    }
    func testPackageSlotPathsAndActivationPayload() throws {
        let packageID = "vpk_01AAAAAAAAAAAAAAAAAAAAAAAA"
        XCTAssertEqual(try APIEndpoints.slot(9, packageID: packageID), "/api/internal/vpn/packages/\(packageID)/slots/9")
        for invalid in ["1", "../profile", "vpk_01AAAAAAAAAAAAAAAAAAAAAAA/", "\(packageID)?other=true"] {
            XCTAssertThrowsError(try APIEndpoints.package(invalid))
        }
        for slot in [0, -1, 10] { XCTAssertThrowsError(try APIEndpoints.slot(slot, packageID: packageID)) }
        XCTAssertThrowsError(try SlotActivationRequest(protocolName: "unsupported"))
        let request = try SlotActivationRequest(protocolName: "amneziawg")
        let bytes = try JSONEncoder().encode(request)
        let payload = try JSONDecoder().decode([String: String].self, from: bytes)
        XCTAssertEqual(Set(payload.keys), ["protocol", "requestKey"])
        XCTAssertNotNil(UUID(uuidString: request.requestKey))
        XCTAssertEqual(try JSONDecoder().decode(SlotActivationRequest.self, from: bytes), request)
    }
    @MainActor func testDeviceRemovalReceiptsAndNoAutomaticRetry() async throws {
        let session = makeSession()
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        StubProtocol.handler = { _ in (200, ["Set-Cookie": "wg_session=synthetic; Path=/; Secure"], Self.bootstrapData) }
        try await client.bootstrap()
        let repo = LiveConfigurationRepository(client: client)
        for (status, value) in [(202, "pending"), (200, "completed")] {
            StubProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.url?.path, "/api/internal/vpn/configs/\(self.id)")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "synthetic-csrf")
                return (status, [:], Data("{\"data\":{\"id\":\"\(self.id)\",\"status\":\"\(value)\"}}".utf8))
            }
            let receipt = try await repo.remove(id)
            XCTAssertEqual(receipt.status.rawValue, value)
        }
        for body in ["{}", "{\"data\":{\"id\":\"wrong\",\"status\":\"completed\"}}", "{\"data\":{\"id\":\"\(id)\",\"status\":\"unknown\"}}"] {
            StubProtocol.handler = { _ in (202, [:], Data(body.utf8)) }
            do { _ = try await repo.remove(id); XCTFail("Invalid deletion accepted") }
            catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        }
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; throw URLError(.timedOut) }
        do { _ = try await repo.remove(id); XCTFail("Expected timeout") } catch { }
        XCTAssertEqual(calls, 1)
        for status in [403, 409, 429, 503] {
            StubProtocol.handler = { _ in calls += 1; return (status, [:], Data("{\"message\":\"Rejected\"}".utf8)) }
            do { _ = try await repo.remove(id); XCTFail("Rejected removal accepted") }
            catch { XCTAssertEqual(error as? ClientError, .server(status: status, message: "Rejected", retryAfter: nil)) }
        }
        XCTAssertEqual(calls, 5)
    }
    @MainActor func testSlotActivationUsesCSRFAndStableRequestWithoutRetry() async throws {
        let session = makeSession()
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        StubProtocol.handler = { _ in (200, [:], Self.bootstrapData) }
        try await client.bootstrap()
        let repo = LiveConfigurationRepository(client: client)
        let operation = try SlotActivationRequest(protocolName: "wireguard")
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/internal/vpn/packages/vpk_01AAAAAAAAAAAAAAAAAAAAAAAA/slots/1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "synthetic-csrf")
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertEqual(try JSONDecoder().decode(SlotActivationRequest.self, from: bytes), operation)
            throw URLError(.timedOut)
        }
        for expected in 1...2 {
            do { _ = try await repo.activate(packageID: "vpk_01AAAAAAAAAAAAAAAAAAAAAAAA", slot: 1, request: operation); XCTFail("Expected timeout") } catch { }
            XCTAssertEqual(calls, expected)
        }
    }
    @MainActor func testClientRejectsInsecureOriginAndForeignPaths() throws {
        XCTAssertThrowsError(try APIClient(baseURL: URL(string: "http://example.test")!, store: MemoryStore()))
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore())
        XCTAssertThrowsError(try client.url(for: "https://evil.test"))
        XCTAssertThrowsError(try client.url(for: "//evil.test/path"))
        XCTAssertThrowsError(try APIEndpoints.configuration("../../../me"))
    }
    @MainActor func testExpiredOrDifferentOriginSessionIsDiscarded() throws {
        let store = MemoryStore()
        store.value = SessionCredentials(origin: "https://other.test", cookieName: "session", cookieValue: "synthetic", expiresAt: Date().addingTimeInterval(120))
        _ = try APIClient(baseURL: URL(string: "https://example.test")!, store: store)
        XCTAssertNil(store.value)
        store.value = SessionCredentials(origin: "https://example.test", cookieName: "session", cookieValue: "synthetic", expiresAt: Date().addingTimeInterval(-1))
        _ = try APIClient(baseURL: URL(string: "https://example.test")!, store: store)
        XCTAssertNil(store.value)
    }
    @MainActor func testBootstrapStoresCookieAndPostUsesCSRFWithoutPasswordPersistence() async throws {
        let store = MemoryStore()
        let session = makeSession()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: store, session: session)
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            if calls == 1 { return (200, ["Set-Cookie": "wg_session=synthetic-cookie; Path=/; Secure; HttpOnly"], Self.bootstrapData) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "wg_session=synthetic-cookie")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "synthetic-csrf")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, [:], Data("{\"user\":{\"id\":1,\"name\":\"Test\",\"email\":\"test@example.test\",\"isEmailVerified\":true}}".utf8))
        }
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        try await client.bootstrap()
        let _: UserResponse = try await client.request(APIEndpoints.login, method: "POST", body: ["email": "test@example.test", "password": "synthetic-password"])
        XCTAssertEqual(store.value?.cookieValue, "synthetic-cookie")
        XCTAssertFalse(String(data: try JSONEncoder().encode(store.value), encoding: .utf8)!.contains("synthetic-password"))
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testUnauthorizedClearsSession() async throws {
        let store = MemoryStore()
        store.value = SessionCredentials(origin: "https://example.test", cookieName: "wg_session", cookieValue: "synthetic", expiresAt: Date().addingTimeInterval(120))
        let session = makeSession()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: store, session: session)
        StubProtocol.handler = { _ in (401, [:], Data()) }
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        do { let _: UserResponse = try await client.request(APIEndpoints.account); XCTFail("Should reject revoked session") }
        catch { XCTAssertEqual(error as? ClientError, .expiredSession) }
        XCTAssertNil(store.value)
    }
    @MainActor func testProtocolSwitchUsesCSRFNumericRevisionAndSameKeyAfterLostResponse() async throws {
        let session = makeSession()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        StubProtocol.handler = { _ in (200, ["Set-Cookie": "wg_session=synthetic; Path=/; Secure"], Self.bootstrapData) }
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        try await client.bootstrap()
        let operation = try ProtocolSwitchRequest(protocolName: "amneziawg", revision: 3)
        let repository = LiveConfigurationRepository(client: client)
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/internal/vpn/configs/\(self.id)/protocol")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "synthetic-csrf")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "wg_session=synthetic")
            var bytes = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let size = stream.read(&buffer, maxLength: buffer.count)
                    if size <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(size))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(body["protocol"] as? String, "amneziawg")
            XCTAssertEqual(body["revision"] as? Int, 3)
            XCTAssertFalse(body["revision"] is String)
            XCTAssertEqual(body["requestKey"] as? String, operation.requestKey)
            XCTAssertNotNil(UUID(uuidString: operation.requestKey))
            if calls == 1 { throw URLError(.timedOut) }
            return (202, [:], Data("{\"data\":{\"id\":\"\(self.id)\",\"protocol\":\"wireguard\",\"state\":\"provisioning\",\"canDownload\":false,\"canRename\":true,\"protocolRevision\":3,\"canSwitchProtocol\":false,\"protocolSwitch\":{\"pending\":true,\"target\":\"amneziawg\"}}}".utf8))
        }
        do { _ = try await repository.switchProtocol(id, request: operation); XCTFail("Expected lost response") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(calls, 1, "Mutation must not retry automatically")
        let pending = try await repository.switchProtocol(id, request: operation)
        XCTAssertTrue(pending.isSwitchingProtocol)
        XCTAssertFalse(pending.canDownload)
        XCTAssertEqual(pending.protocolSwitch?.target, "amneziawg")
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testDownloadPreservesServerFilenameAndBytes() async throws {
        let session = makeSession()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        let body = Data("[Interface]\nPrivateKey = SYNTHETIC_ONLY\n[Peer]\nEndpoint = example.test:51820".utf8)
        StubProtocol.handler = { _ in (200, ["Content-Type": "application/octet-stream", "Content-Disposition": "attachment; filename=\"uc-12-v2.conf\""], body) }
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        let file = try await LiveConfigurationRepository(client: client).download(id)
        XCTAssertEqual(file.filename, "uc-12-v2.conf")
        XCTAssertEqual(file.data, body)
    }
    @MainActor func testInvalidDownloadAndMutationAreNotRetried() async throws {
        let store = MemoryStore(); let session = makeSession()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: store, session: session)
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; return (200, ["Content-Type": "text/html"], Data("<html>login</html>".utf8)) }
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        do { _ = try await client.download(try APIEndpoints.configuration(id) + "/configuration"); XCTFail() }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        XCTAssertEqual(calls, 1)
        StubProtocol.handler = { _ in (200, ["Set-Cookie": "wg_session=synthetic; Path=/; Secure"], Self.bootstrapData) }
        try await client.bootstrap()
        calls = 0
        StubProtocol.handler = { _ in calls += 1; throw URLError(.timedOut) }
        do { let _: UserResponse = try await client.request(APIEndpoints.login, method: "POST", body: [:]); XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(calls, 1)
    }
    func testNotificationIDsAndPagination() throws {
        XCTAssertEqual(try APIEndpoints.notificationRead("ntf_01AAAAAAAAAAAAAAAAAAAAAAAA"), "/api/internal/notifications/ntf_01AAAAAAAAAAAAAAAAAAAAAAAA/read")
        for id in ["1", "../read-all", "ntf_01AAAAAAAAAAAAAAAAAAAAAAAA?user=2"] { XCTAssertThrowsError(try APIEndpoints.notificationRead(id)) }
        let data = Data("{\"data\":[{\"id\":\"ntf_01AAAAAAAAAAAAAAAAAAAAAAAA\",\"kind\":\"warning\",\"title\":\"Доступ\",\"body\":\"Полный текст сообщения\",\"isRead\":false,\"createdAt\":null}],\"meta\":{\"current_page\":1,\"last_page\":3}}".utf8)
        let page = try JSONDecoder().decode(NotificationPage.self, from: data)
        XCTAssertEqual(page.meta.lastPage, 3)
        XCTAssertEqual(page.data.first?.body, "Полный текст сообщения")
        XCTAssertEqual(page.data.first?.isRead, false)
    }
    @MainActor func testNotificationRequestUsesThirtyNewestItems() async throws {
        let session = makeSession()
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "page" }?.value, "1")
            XCTAssertEqual(query.first { $0.name == "perPage" }?.value, "30")
            XCTAssertEqual(query.first { $0.name == "status" }?.value, "all")
            return (200, [:], Data(#"{"data":[],"meta":{"current_page":1,"last_page":5}}"#.utf8))
        }
        _ = try await LiveNotificationRepository(client: client).page(1)
    }
    @MainActor func testNotificationReadMutationsUseSessionAndCSRF() async throws {
        let session = makeSession()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        StubProtocol.handler = { _ in (200, ["Set-Cookie": "wg_session=synthetic; Path=/; Secure"], Self.bootstrapData) }
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        try await client.bootstrap()
        let repository = LiveNotificationRepository(client: client)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "wg_session=synthetic")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "synthetic-csrf")
            if request.url!.path.hasSuffix("read-all") {
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, [:], Data("{\"data\":{\"updatedCount\":2,\"unreadCount\":0}}".utf8))
            }
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url!.path, "/api/internal/notifications/ntf_01AAAAAAAAAAAAAAAAAAAAAAAA/read")
            return (200, [:], Data("{\"data\":{\"id\":\"ntf_01AAAAAAAAAAAAAAAAAAAAAAAA\",\"kind\":\"info\",\"title\":\"Test\",\"body\":\"Text\",\"isRead\":true,\"createdAt\":null}}".utf8))
        }
        let read = try await repository.markRead("ntf_01AAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertTrue(read.isRead)
        let result = try await repository.markAllRead()
        XCTAssertEqual(result.unreadCount, 0)
    }
    @MainActor func testOfflineAndTimeoutRequestsAreBoundedAndNotRetried() async throws {
        let session = makeSession()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost] {
            var calls = 0
            StubProtocol.handler = { request in
                calls += 1
                XCTAssertEqual(request.timeoutInterval, APILimits.requestTimeout)
                throw URLError(code)
            }
            do { let _: UserResponse = try await client.request(APIEndpoints.account); XCTFail("Should return connection error") }
            catch { XCTAssertEqual((error as? URLError)?.code, code) }
            XCTAssertEqual(calls, 1)
        }
    }
    func testMessengerLinksRequireExpectedHostTokenAndUnexpiredLifetime() throws {
        let token = String(repeating: "a", count: 48)
        func link(_ url: String, expires: String = "2099-01-01T00:00:00Z") throws -> MessengerConnectionLink {
            try JSONDecoder().decode(MessengerConnectionLink.self, from: JSONSerialization.data(withJSONObject: ["url": url, "expiresAt": expires]))
        }
        for channel in MessengerChannel.allCases {
            let url = "https://\(channel.host)/undercore_bot?start=\(token)"
            XCTAssertEqual(try link(url).validatedURL(for: channel).absoluteString, url)
            XCTAssertThrowsError(try link(url, expires: "2000-01-01T00:00:00Z").validatedURL(for: channel))
            XCTAssertThrowsError(try link(url, expires: "invalid").validatedURL(for: channel))
            for invalid in [
                "http://\(channel.host)/bot?start=\(token)",
                "https://evil.test/bot?start=\(token)",
                "https://\(channel.host).evil.test/bot?start=\(token)",
                "https://user@\(channel.host)/bot?start=\(token)",
                url + "&start=" + token, url + "&other=value", url + "#fragment",
                "https://\(channel.host)/bot?start=short",
                "https://\(channel.host)/bot/other?start=\(token)"
            ] { XCTAssertThrowsError(try link(invalid).validatedURL(for: channel), invalid) }
        }
        XCTAssertThrowsError(try link("https://max.ru/bot?start=\(token)").validatedURL(for: .telegram))
    }
    @MainActor func testMessengerRepositoryStatusConnectAndEmptyDisconnectContract() async throws {
        let session = makeSession()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        StubProtocol.handler = { _ in (200, ["Set-Cookie": "wg_session=synthetic; Path=/; Secure"], Self.bootstrapData) }
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        try await client.bootstrap()
        let repository = LiveMessengerRepository(client: client)
        for channel in MessengerChannel.allCases {
            var calls = 0
            StubProtocol.handler = { request in
                calls += 1
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "wg_session=synthetic")
                if request.httpMethod == "GET" {
                    XCTAssertEqual(request.url?.path, channel.path)
                    // Existing bindings remain manageable when integration is disabled.
                    return (200, [:], Data(#"{"available":false,"connected":true,"account":{"username":"existing","displayName":"Test","connectedAt":null}}"#.utf8))
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "synthetic-csrf")
                if request.httpMethod == "POST" {
                    XCTAssertEqual(request.url?.path, channel.path + "/connect")
                    return (200, [:], try JSONSerialization.data(withJSONObject: ["url": "https://\(channel.host)/undercore_bot?start=\(String(repeating: "a", count: 48))", "expiresAt": "2099-01-01T00:00:00Z"]))
                }
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.url?.path, channel.path)
                return (204, [:], Data())
            }
            let status = try await repository.status(channel)
            XCTAssertTrue(status.connected); XCTAssertFalse(status.available)
            XCTAssertEqual(status.accountLabel, "@existing")
            let url = try await repository.connect(channel)
            XCTAssertEqual(url.host, channel.host)
            try await repository.disconnect(channel)
            XCTAssertEqual(calls, 3)
        }
    }
    @MainActor func testMessengerMutationsDoNotRetryAndDisconnectExpiresSession() async throws {
        let session = makeSession(); let store = MemoryStore()
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: store, session: session)
        StubProtocol.handler = { _ in (200, ["Set-Cookie": "wg_session=synthetic; Path=/; Secure"], Self.bootstrapData) }
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        try await client.bootstrap()
        let repository = LiveMessengerRepository(client: client)
        for disconnect in [false, true] {
            var calls = 0
            StubProtocol.handler = { _ in calls += 1; throw URLError(.timedOut) }
            do {
                if disconnect { try await repository.disconnect(.max) }
                else { _ = try await repository.connect(.telegram) }
                XCTFail("Expected timeout")
            } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            XCTAssertEqual(calls, 1)
        }
        StubProtocol.handler = { _ in (401, [:], Data()) }
        do { try await repository.disconnect(.max); XCTFail("Expected expired session") }
        catch { XCTAssertEqual(error as? ClientError, .expiredSession) }
        XCTAssertNil(store.value)
    }
    func testArticleImageReferencesOnlyRewriteUploadedImages() throws {
        let origin = URL(string: "https://example.test")!
        let html = #"<p><img src="/storage/instructions/images/a.png" alt="hello"></p><img src='https://example.test/storage/instructions/images/b.webp'><a href="https://example.test/guide">Link</a><img src="https://other.test/x.png">"#
        let result = ArticleImageReferences.rewrite(html, origin: origin)
        XCTAssertTrue(result.contains("undercore-image://images/storage/instructions/images/a.png"))
        XCTAssertTrue(result.contains("undercore-image://images/storage/instructions/images/b.webp"))
        XCTAssertTrue(result.contains(#"href="https://example.test/guide""#))
        XCTAssertTrue(result.contains("https://other.test/x.png"))
        for unsafe in ["http://example.test/storage/instructions/images/a.png", "https://other.test/storage/instructions/images/a.png", "/api/internal/me", "/storage/instructions/images/../a.png", "/storage/instructions/images/%61.png", "/storage/instructions/images/a.svg", "/storage/instructions/images/a.png?secret=x"] {
            XCTAssertNil(ArticleImageReferences.remoteURL(unsafe, origin: origin), unsafe)
        }
        XCTAssertNil(ArticleImageReferences.resolve(URL(string: "undercore-image://other/storage/instructions/images/a.png")!, origin: origin))
    }
    @MainActor func testArticleImagesSurviveReaderRecreationOfflineAndRespectRevisionAndLogout() async throws {
        let session = makeSession(); defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let origin = URL(string: "https://example.test")!
        let url = origin.appendingPathComponent("storage/instructions/images/a.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ["Content-Type": "image/png"], bytes)
        }
        let first = ArticleImageStore(directory: folder, origin: origin, session: session)
        let online = try await first.image(url, revision: "1:v1")
        XCTAssertEqual(online.data, bytes); XCTAssertEqual(calls, 1)
        StubProtocol.handler = { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        let nextReader = ArticleImageStore(directory: folder, origin: origin, session: session)
        let offline = try await nextReader.image(url, revision: "1:v1")
        XCTAssertEqual(offline.data, bytes); XCTAssertEqual(calls, 1, "Disk hit must not use network")
        do { _ = try await nextReader.image(url, revision: "1:v2"); XCTFail("New revision must not reuse old image") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        nextReader.clear()
        do { _ = try await nextReader.image(url, revision: "1:v1"); XCTFail("Old reader must be invalidated") }
        catch { XCTAssertTrue(error is CancellationError) }
        let newSession = ArticleImageStore(directory: folder, origin: origin, session: session)
        do { _ = try await newSession.image(url, revision: "1:v1"); XCTFail("Logout must delete persisted image") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }
    @MainActor func testArticleImagesRejectNonImageAndForeignResponses() async throws {
        let session = makeSession(); defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let origin = URL(string: "https://example.test")!
        let store = ArticleImageStore(directory: folder, origin: origin, session: session)
        StubProtocol.handler = { _ in (200, ["Content-Type": "image/png"], Data("<html>Sign in</html>".utf8)) }
        do { _ = try await store.image(origin.appendingPathComponent("storage/instructions/images/a.png"), revision: "v1"); XCTFail() }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        do { _ = try await store.image(URL(string: "https://other.test/storage/instructions/images/a.png")!, revision: "v1"); XCTFail() }
        catch { XCTAssertEqual(error as? ClientError, .invalidAddress) }
    }
    @MainActor func testVerificationResendUsesServerCooldownAndExplicitQuickRetry() async throws {
        let session = makeSession()
        defer { StubProtocol.handler = nil; session.invalidateAndCancel() }
        let client = try APIClient(baseURL: URL(string: "https://example.test")!, store: MemoryStore(), session: session)
        StubProtocol.handler = { _ in (200, ["Set-Cookie": "wg_session=synthetic; Path=/; Secure"], Self.bootstrapData) }
        try await client.bootstrap()
        let repository = LiveAuthRepository(client: client)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/internal/email/verification")
            XCTAssertEqual(request.url?.query, "quickResend=1")
            return (200, [:], Data(#"{"data":{"retryAfterSeconds":0,"isEmailVerified":false}}"#.utf8))
        }
        let initial = try await repository.verificationStatus()
        XCTAssertEqual(initial.retryAfterSeconds, 0)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/internal/email/verification-notification")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "synthetic-csrf")
            return (200, [:], Data(#"{"ok":true,"data":{"retryAfterSeconds":60,"isEmailVerified":false}}"#.utf8))
        }
        let resent = try await repository.resendEmail()
        XCTAssertEqual(resent.retryAfterSeconds, 60)
        StubProtocol.handler = { _ in (429, ["Retry-After": "3540"], Data(#"{"message":"Wait"}"#.utf8)) }
        do { _ = try await repository.resendEmail(); XCTFail("Rate limit ignored") }
        catch { XCTAssertEqual(error as? ClientError, .server(status: 429, message: "Wait", retryAfter: 3540)) }
    }
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
    private static var bootstrapData: Data {
        Data("{\"data\":{\"apiVersion\":1,\"csrfToken\":\"synthetic-csrf\",\"sessionCookieName\":\"wg_session\",\"sessionLifetimeSeconds\":7200,\"challenge\":{\"provider\":\"smartcaptcha\",\"siteKey\":\"public\",\"tokenField\":\"smart-token\",\"required\":true}}}".utf8)
    }
}
