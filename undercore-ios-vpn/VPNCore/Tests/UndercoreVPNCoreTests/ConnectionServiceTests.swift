import XCTest
import UndercoreCore
@testable import UndercoreVPNCore

@MainActor final class ConnectionServiceTests: XCTestCase {
    let origin = URL(string: "https://vpn.example.test")!
    let id = "vpn_01AAAAAAAAAAAAAAAAAAAAAAAA"
    let account = #"{"user":{"id":7,"name":"Test","email":"test@example.test","isEmailVerified":true}}"#
    let bootstrap = #"{"data":{"apiVersion":1,"csrfToken":"synthetic-csrf","sessionCookieName":"session","sessionLifetimeSeconds":86400,"challenge":{"provider":"none","siteKey":"","tokenField":"smart-token","required":false}}}"#
    var defaults: UserDefaults!
    var suite: String!
    override func setUp() {
        super.setUp(); suite = "VPN-tests-" + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite); VPNHTTP.install([]); super.tearDown()
    }
    var path: String { "/api/internal/vpn/configs/" + id }
    var config: String {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        return "[Interface]\nPrivateKey = \(key)\nAddress = 10.99.0.2/32\n[Peer]\nPublicKey = \(key)\nEndpoint = vpn.example.test:51820\nAllowedIPs = 0.0.0.0/0\n"
    }
    func metadata(state: String = "active", version: Int? = 1, available: Bool = true) -> String {
        "{\"data\":{\"id\":\"\(id)\",\"name\":\"iPhone\",\"protocol\":\"amneziawg\",\"state\":\"\(state)\",\"canDownload\":\(available),\"canRename\":true,\"connectionManifestVersion\":\(version.map(String.init) ?? "null")}}"
    }
    func manifest(change: (inout [String: Any]) -> Void = { _ in }) throws -> String {
        var value: [String: Any] = ["schema_version":1, "device_id":id, "connection_id":"connection_1", "node_id":"lab",
            "protocol":"amneziawg", "state":"active", "expires_at":"2099-01-01T00:00:00.000Z", "revision":1,
            "configuration":["protocol":"amneziawg", "version":1, "format":"awg-quick", "data":config]]
        change(&value)
        return String(decoding: try JSONSerialization.data(withJSONObject: ["data":value]), as: UTF8.self)
    }
    private var initial: [VPNHTTP.Reply] { [.init(APIEndpoints.bootstrap, bootstrap), .init(APIEndpoints.account, account)] }
    func service() throws -> VPNConnectionService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VPNHTTP.self]; configuration.httpCookieStorage = nil
        let api = try APIClient(baseURL: origin, store: VPNTestSession(), session: URLSession(configuration: configuration))
        return VPNConnectionService(client: api, repository: LiveConfigurationRepository(client: api),
            devices: VPNDeviceStore(origin: origin, defaults: defaults), sleep: {})
    }
    func prepare(_ service: VPNConnectionService, selected: String? = nil, owner: Int = 7,
                 check: () throws -> Void = {}) async throws -> PreparedVPNConnection {
        try await service.prepare(selectedID: selected, ownerID: owner, name: "iPhone", check: check)
    }

    func testAutomaticCreationThenRepeatUsesSameDeviceWithoutAnotherSlotRequest() async throws {
        let accepted = VPNHTTP.Reply(APIEndpoints.connectDevice, metadata(), status: 202, inspect: { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "synthetic-csrf")
            let json = Self.body(request)
            XCTAssertEqual(Set(json.keys), ["deviceKey", "name"])
            XCTAssertNotNil(UUID(uuidString: json["deviceKey"] as! String))
        })
        let manifest = VPNHTTP.Reply(path + "/connection-manifest", try manifest(), inspect: { request in
            let json = Self.body(request)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(json["schema_version"] as? Int, 1)
            XCTAssertNil(json["device_id"])
            let offers = json["capabilities"] as! [[String: Any]]
            XCTAssertEqual(offers.count, 1); XCTAssertEqual(offers[0]["protocol"] as? String, "amneziawg")
        })
        VPNHTTP.install(initial + [accepted, .init(path, metadata()), manifest,
            .init(APIEndpoints.account, account), .init(path, metadata()), manifest])
        let service = try service()
        for _ in 0..<2 {
            let result = try await prepare(service)
            XCTAssertEqual(result.configuration.id, id)
            XCTAssertEqual(result.material.data, Data(config.utf8))
            XCTAssertEqual(result.material.revision, 1)
        }
        XCTAssertEqual(VPNHTTP.remaining, 0)
        let stored = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("vpn.automatic-device.") }.values.compactMap { $0 as? Data }
        XCTAssertEqual(stored.count, 1)
        XCTAssertFalse(String(decoding: stored[0], as: UTF8.self).contains("PrivateKey"))
    }

    func testLostCreationResponseAndProcessRestartReuseSameKey() async throws {
        var keys: [String] = []
        let inspect: (URLRequest) -> Void = { keys.append(Self.body($0)["deviceKey"] as! String) }
        VPNHTTP.install(initial + [.init(APIEndpoints.connectDevice, "", error: .timedOut, inspect: inspect)])
        do { _ = try await prepare(service()); XCTFail("Timeout ignored") } catch { XCTAssertTrue(error is URLError) }
        VPNHTTP.install(initial + [.init(APIEndpoints.connectDevice, metadata(), status: 202, inspect: inspect),
            .init(path, metadata()), .init(path + "/connection-manifest", try manifest())])
        _ = try await prepare(service())
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(keys[0], keys[1]); XCTAssertEqual(VPNHTTP.remaining, 0)
    }

    func testWrongOwnerAndUnverifiedAccountCannotCreateDevice() async throws {
        for user in [account.replacingOccurrences(of: "\"id\":7", with: "\"id\":8"), account.replacingOccurrences(of: "true", with: "false")] {
            VPNHTTP.install([initial[0], .init(APIEndpoints.account, user)])
            do { _ = try await prepare(service()); XCTFail("Account guard bypassed") } catch {}
            XCTAssertEqual(VPNHTTP.remaining, 0)
            XCTAssertNil(defaults.data(forKey: "vpn.automatic-device.\(origin.absoluteString).7"))
        }
    }

    func testNoSlotAndPaymentErrorsNeverGenerateAnotherKeyOrRetry() async throws {
        for status in [403, 409, 422, 429, 503] {
            let record = try VPNDeviceStore(origin: origin, defaults: defaults).registration(owner: 7)
            VPNHTTP.install(initial + [.init(APIEndpoints.connectDevice, "{}", status: status)])
            do { _ = try await prepare(service()); XCTFail("Rejected request accepted") } catch {}
            XCTAssertEqual(try VPNDeviceStore(origin: origin, defaults: defaults).registration(owner: 7).key, record.key)
            XCTAssertEqual(VPNHTTP.remaining, 0)
        }
    }

    func testProvisioningPollsOnlyDetailAndSurvivesCancellationWithoutNewSlot() async throws {
        var cancelled = false
        VPNHTTP.install(initial + [.init(APIEndpoints.connectDevice, metadata(state: "provisioning", available: false), status: 202),
            .init(path, metadata(state: "provisioning", available: false)),
            .init(path, metadata(), inspect: { _ in cancelled = true })])
        do { _ = try await prepare(service(), check: { if cancelled { throw CancellationError() } }); XCTFail("Cancelled preparation accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        VPNHTTP.install(initial + [.init(path, metadata()), .init(path + "/connection-manifest", try manifest())])
        _ = try await prepare(service())
        XCTAssertEqual(VPNHTTP.remaining, 0)
    }

    func testProvisioningHasBoundedPolling() async throws {
        let pending = metadata(state: "provisioning", available: false)
        VPNHTTP.install(initial + [.init(APIEndpoints.connectDevice, pending, status: 202)] + Array(repeating: .init(path, pending), count: 16))
        do { _ = try await prepare(service()); XCTFail("Pending device accepted") }
        catch { XCTAssertTrue(error is VPNPreparationError) }
        XCTAssertEqual(VPNHTTP.remaining, 0)
    }

    func testManifestFailuresNeverFallbackToFileOrCreateNewSlot() async throws {
        for status in [403, 404, 409, 410, 429, 503] {
            VPNHTTP.install(initial + [.init(path, metadata()), .init(path + "/connection-manifest", "{}", status: status)])
            do { _ = try await prepare(service(), selected: id); XCTFail("Manifest failure ignored") } catch {}
            XCTAssertEqual(VPNHTTP.remaining, 0)
        }
    }

    func testCSRFRefreshRepeatsOwnerCheckBeforeRetry() async throws {
        VPNHTTP.install(initial + [.init(path, metadata()), .init(path + "/connection-manifest", "{}", status: 419),
            initial[0], .init(APIEndpoints.account, account.replacingOccurrences(of: "\"id\":7", with: "\"id\":8"))])
        do { _ = try await prepare(service(), selected: id); XCTFail("Wrong account retry") }
        catch { XCTAssertEqual(error as? ClientError, .expiredSession) }
        XCTAssertEqual(VPNHTTP.remaining, 0)
    }

    func testUnsupportedVersionAndUnavailableMetadataNeverReachManifest() async throws {
        for value in [metadata(version: 2), metadata(state: "expired", available: false)] {
            VPNHTTP.install(initial + [.init(path, value)])
            do { _ = try await prepare(service(), selected: id); XCTFail("Unavailable metadata accepted") } catch {}
            XCTAssertEqual(VPNHTTP.remaining, 0)
        }
    }

    func testSecondCSRFRejectionStopsWithoutUnboundedReplay() async throws {
        let rejected: [VPNHTTP.Reply] = initial + [.init(path, metadata()), .init(path + "/connection-manifest", "{}", status: 419)]
        VPNHTTP.install(rejected + rejected)
        do { _ = try await prepare(service(), selected: id); XCTFail("Repeated CSRF rejection ignored") }
        catch let ClientError.server(status, _, _) { XCTAssertEqual(status, 419) }
        XCTAssertEqual(VPNHTTP.remaining, 0)
    }

    func testRevokedAutomaticBindingDoesNotConsumeAnotherSlot() async throws {
        let store = VPNDeviceStore(origin: origin, defaults: defaults)
        try store.bind(id, owner: 7)
        VPNHTTP.install(initial + [.init(path, metadata(state: "revoked", available: false))])
        do { _ = try await prepare(service()); XCTFail("Revoked binding accepted") } catch {}
        XCTAssertEqual(try store.registration(owner: 7).configurationID, id)
        XCTAssertEqual(VPNHTTP.remaining, 0)
    }

    func testMaterialExpiryCanBeRecheckedImmediatelyBeforeTunnelStart() async throws {
        VPNHTTP.install(initial + [.init(path, metadata()), .init(path + "/connection-manifest", try manifest())])
        let result = try await prepare(service(), selected: id)
        XCTAssertThrowsError(try result.material.checkValidity(at: .distantFuture))
    }

    func testOptionalCapabilitiesDecodeWithoutBreakingOlderResponses() throws {
        let base = #"{"configs":[],"packages":[],"pagination":{"page":1,"lastPage":1}}"#
        let old = try JSONDecoder().decode(VPNPage.self, from: Data(base.utf8))
        XCTAssertNil(old.automaticConnectionAvailable)
        var payload = try JSONSerialization.jsonObject(with: Data(base.utf8)) as! [String: Any]
        payload["automaticConnectionAvailable"] = true
        let current = try JSONDecoder().decode(VPNPage.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(current.automaticConnectionAvailable, true)
        let response = try JSONDecoder().decode(Envelope<VPNConfiguration>.self, from: Data(metadata().utf8))
        XCTAssertEqual(response.data.connectionManifestVersion, 1)
    }

    func testManifestIdentityExpiryProtocolAndSecretsAreValidated() async throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["device_id"] = "vpn_01BBBBBBBBBBBBBBBBBBBBBBBB" }, { $0["revision"] = 0 },
            { $0["expires_at"] = "2000-01-01T00:00:00.000Z" }, { $0["protocol"] = "trusttunnel" },
            { $0["schema_version"] = 2 }, { $0["node_id"] = "../lab" },
            { $0["configuration"] = ["protocol":"amneziawg", "version":1, "format":"awg-quick", "data":"SYNTHETIC_SECRET_INVALID"] }
        ]
        for mutate in mutations {
            VPNHTTP.install(initial + [.init(path, metadata()), .init(path + "/connection-manifest", try manifest(change: mutate))])
            do { _ = try await prepare(service(), selected: id); XCTFail("Invalid manifest accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_SECRET")) }
            XCTAssertEqual(VPNHTTP.remaining, 0)
        }
    }

    func testManifestRequiresNoStoreAndJSON() async throws {
        for headers in [["Content-Type":"application/json"], ["Content-Type":"text/html", "Cache-Control":"no-store"]] {
            VPNHTTP.install(initial + [.init(path, metadata()), .init(path + "/connection-manifest", try manifest(), headers: headers)])
            do { _ = try await prepare(service(), selected: id); XCTFail("Unsafe response accepted") } catch {}
            XCTAssertEqual(VPNHTTP.remaining, 0)
        }
    }

    func testExplicitLegacySelectionStillWorksWithoutManifest() async throws {
        VPNHTTP.install(initial + [.init(path, metadata(version: nil)), .init(path + "/configuration", config,
            headers: ["Content-Type":"application/octet-stream", "Content-Disposition":"attachment; filename=\"uc-1-v1.conf\""])])
        let result = try await prepare(service(), selected: id)
        XCTAssertEqual(result.material.data, Data(config.utf8)); XCTAssertNil(result.material.revision)
        XCTAssertEqual(VPNHTTP.remaining, 0)
    }

    func testDeviceStoreSeparatesAccountsAndOriginsAndDoesNotResetCorruption() throws {
        let store = VPNDeviceStore(origin: origin, defaults: defaults)
        XCTAssertNotEqual(try store.registration(owner: 7).key, try store.registration(owner: 8).key)
        let other = VPNDeviceStore(origin: URL(string: "https://other.example.test")!, defaults: defaults)
        XCTAssertNotEqual(try store.registration(owner: 7).key, try other.registration(owner: 7).key)
        defaults.set("broken", forKey: "vpn.automatic-device.\(origin.absoluteString).7")
        XCTAssertThrowsError(try store.registration(owner: 7))
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        if let data = request.httpBody { return try! JSONSerialization.jsonObject(with: data) as! [String: Any] }
        let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = stream.read(&bytes, maxLength: bytes.count)
        return try! JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as! [String: Any]
    }
}

private final class VPNTestSession: SessionStore {
    var value: SessionCredentials? = .init(origin: "https://vpn.example.test", cookieName: "session", cookieValue: "synthetic", expiresAt: Date().addingTimeInterval(86400))
    func load() throws -> SessionCredentials? { value }
    func save(_ value: SessionCredentials) throws { self.value = value }
    func clear() throws { value = nil }
}
private final class VPNHTTP: URLProtocol, @unchecked Sendable {
    struct Reply {
        let path: String; let body: String; var status: Int; var headers: [String: String]
        var error: URLError.Code?; var inspect: ((URLRequest) -> Void)?
        init(_ path: String, _ body: String, status: Int = 200,
             headers: [String: String] = ["Content-Type":"application/json", "Cache-Control":"private, no-store"],
             error: URLError.Code? = nil, inspect: ((URLRequest) -> Void)? = nil) {
            self.path = path; self.body = body; self.status = status; self.headers = headers; self.error = error; self.inspect = inspect
        }
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    static var remaining: Int { lock.lock(); defer { lock.unlock() }; return replies.count }
    static func install(_ value: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst(); Self.lock.unlock()
        guard let reply else { XCTFail("Unexpected HTTP request"); client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        XCTAssertEqual(request.url?.path, reply.path); reply.inspect?(request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
