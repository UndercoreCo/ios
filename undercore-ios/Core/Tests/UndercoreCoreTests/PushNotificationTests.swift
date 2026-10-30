import XCTest
@testable import UndercoreCore

final class PushNotificationTests: XCTestCase {
    func testPayloadAcceptsOnlyNotificationIdentifier() {
        let id = "ntf_01K00000000000000000000000"
        XCTAssertEqual(PushNotificationPayload.notificationID(["notificationID": id, "url": "https://untrusted.example"]), id)
        for value in ["", "../me", "ntf_01K00000000000000000000000/read", "https://example.com"] {
            XCTAssertNil(PushNotificationPayload.notificationID(["notificationID": value]))
            XCTAssertThrowsError(try APIRequests.notification(value))
        }
        XCTAssertNil(PushNotificationPayload.notificationID(["notificationID": 123]))
    }
    func testTokensPreserveLeadingZeroesAndVariableLengths() {
        XCTAssertEqual(PushNotificationPayload.token(Data([0, 1, 15, 16, 255])), "00010f10ff")
        XCTAssertEqual(PushNotificationPayload.token(Data(repeating: 0xAB, count: 48)).count, 96)
    }
    func testRegistrationAndRemovalUseDedicatedMutationRoutes() throws {
        let device = PushDeviceRegistration(installationID: "installation", topic: "ru.undercore.ios.vpn", environment: "sandbox", token: "00abcd")
        let request = try APIRequests.registerPushDevice(device)
        XCTAssertEqual(request.path, APIEndpoints.pushDevice)
        XCTAssertEqual(request.method, .post)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as! [String: String]
        XCTAssertEqual(body["token"], "00abcd")
        XCTAssertNil(body["userID"])
        let removal = try APIRequests.unregisterPushDevice(installationID: "installation", topic: device.topic)
        XCTAssertEqual(removal.method, .delete)
        XCTAssertEqual(removal.path, APIEndpoints.pushDevice)
    }
    func testNotificationFetchIsNeverServedFromOfflineCache() throws {
        let id = "ntf_01K00000000000000000000000"
        let request = try APIRequests.notification(id)
        XCTAssertEqual(request.path, APIEndpoints.notifications + "/" + id)
        XCTAssertFalse(request.allowCached)
    }
}
