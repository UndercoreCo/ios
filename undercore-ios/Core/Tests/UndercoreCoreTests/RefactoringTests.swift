import XCTest
@testable import UndercoreCore

@MainActor final class RefactoringTests: XCTestCase {
    func testActivationIdentitySurvivesStoreRecreationAndRemovalIsSlotScoped() throws {
        let suite = "activation-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = try SlotActivationRequest(protocolName: "amneziawg")
        let store = DefaultsPendingActivationStore(defaults: defaults)
        try store.save(request, packageID: "first", slot: 1)
        try store.save(request, packageID: "first", slot: 2)
        try store.save(request, packageID: "second", slot: 1)
        let restored = DefaultsPendingActivationStore(defaults: defaults)
        XCTAssertEqual(restored.request(packageID: "first", slot: 1), request)
        restored.remove(packageID: "first", slot: 1)
        XCTAssertNil(store.request(packageID: "first", slot: 1))
        XCTAssertEqual(store.request(packageID: "first", slot: 2), request)
        XCTAssertEqual(store.request(packageID: "second", slot: 1), request)
        defaults.set(Data(#"{"protocol":"wireguard","requestKey":"invalid"}"#.utf8), forKey: "vpn.slot-activation.first.1")
        XCTAssertNil(store.request(packageID: "first", slot: 1))
    }

    func testPollerStopsAtBudgetAndNotifiesOnlyWhenExhausted() async {
        let finished = expectation(description: "bounded polling exhausted")
        var delays: [UInt64] = []
        var calls = 0
        let poller = BoundedPoller(sleep: { delays.append($0) })
        poller.start(plan: .pendingDevices, while: { true }, refresh: {
            calls += 1
            return true
        }, onExhausted: { finished.fulfill() })
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(calls, 24)
        XCTAssertEqual(delays, Array(repeating: 5_000_000_000, count: 24))
        XCTAssertFalse(poller.isRunning)
    }

    func testPollerDoesNotRefreshAfterCancellationDuringSleep() async {
        let sleeping = expectation(description: "sleep entered")
        let resumed = expectation(description: "sleep exited")
        var continuation: CheckedContinuation<Void, Never>?
        let poller = BoundedPoller(sleep: { _ in
            await withCheckedContinuation { continuation = $0; sleeping.fulfill() }
            resumed.fulfill()
        })
        var calls = 0
        poller.start(plan: .pendingDevices, while: { true }, refresh: {
            calls += 1
            return true
        }, onExhausted: { XCTFail("Cancellation is not exhaustion") })
        await fulfillment(of: [sleeping], timeout: 2)
        poller.cancel()
        continuation?.resume()
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(poller.isRunning)
    }

    func testPollerReplacementWaitsForOldRefreshToUnwind() async {
        let oldStarted = expectation(description: "old refresh started")
        let newStarted = expectation(description: "new refresh started")
        var continuation: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let poller = BoundedPoller(sleep: { _ in XCTFail("Completed operations must not poll again") })
        poller.start(plan: .messengerConnections, while: { true }, refresh: {
            events.append("old start")
            await withCheckedContinuation { continuation = $0; oldStarted.fulfill() }
            events.append("old end")
            return true
        }, onExhausted: { XCTFail("Cancelled run exhausted") })
        await fulfillment(of: [oldStarted], timeout: 2)
        poller.start(plan: .messengerConnections, while: { true }, refresh: {
            events.append("new start")
            newStarted.fulfill()
            return false
        }, onExhausted: { XCTFail("Completed run exhausted") })
        XCTAssertEqual(events, ["old start"])
        continuation?.resume()
        await fulfillment(of: [newStarted], timeout: 2)
        XCTAssertEqual(events, ["old start", "old end", "new start"])
        XCTAssertFalse(poller.isRunning)
    }

    func testTypedRequestsPreserveCaptchaFieldAndDeletionAcceptanceContract() throws {
        let registration = try APIRequests.register(name: "Test", email: "test@example.test", password: "secret",
                                                     challenge: (field: "smart-token", token: "challenge-value"))
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(registration.body))
        XCTAssertEqual(body["smart-token"], "challenge-value")
        XCTAssertEqual(registration.method, .post)
        XCTAssertEqual(registration.path, "/register")
        let deletion = try APIRequests.deleteAccount(password: "secret")
        XCTAssertEqual(deletion.expectedStatus, 202)
        XCTAssertEqual(deletion.method, .delete)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(deletion.body)), ["current_password": "secret"])
        XCTAssertFalse(APIRequests.account.allowCached)
    }
}
