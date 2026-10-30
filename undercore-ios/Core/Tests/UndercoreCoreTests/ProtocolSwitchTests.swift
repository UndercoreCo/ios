import XCTest
@testable import UndercoreCore

final class ProtocolSwitchTests: XCTestCase {
    private func config(_ extra: [String: Any] = [:]) throws -> VPNConfiguration {
        let base: [String: Any] = ["id": "vpn_01AAAAAAAAAAAAAAAAAAAAAAAA", "protocol": "wireguard", "state": "active", "canDownload": true, "canRename": true]
        return try JSONDecoder().decode(VPNConfiguration.self, from: JSONSerialization.data(withJSONObject: base.merging(extra) { _, new in new }))
    }
    func testOptionsRespectServerPermissionsAvailabilityAndPendingState() throws {
        let options = try JSONDecoder().decode([VPNProtocolOption].self, from: Data("[{\"id\":\"wireguard\",\"label\":\"WireGuard\",\"available\":true},{\"id\":\"amneziawg\",\"label\":\"AmneziaWG\",\"available\":true},{\"id\":\"future\",\"label\":\"Future\",\"available\":true}]".utf8))
        XCTAssertTrue(try config().switchOptions(from: options).isEmpty)
        XCTAssertTrue(try config(["canSwitchProtocol": true]).switchOptions(from: options).isEmpty)
        let ready: [String: Any] = ["canSwitchProtocol": true, "protocolRevision": 0]
        XCTAssertEqual(try config(ready).switchOptions(from: options).map(\.id), ["amneziawg"])
        XCTAssertTrue(try config(ready.merging(["canSwitchProtocol": false]) { _, new in new }).switchOptions(from: options).isEmpty)
        XCTAssertTrue(try config(ready.merging(["protocolSwitch": ["pending": true, "target": "amneziawg"]]) { _, new in new }).switchOptions(from: options).isEmpty)
        XCTAssertTrue(try config(ready).switchOptions(from: []).isEmpty)
        let unavailable = try JSONDecoder().decode([VPNProtocolOption].self, from: Data("[{\"id\":\"amneziawg\",\"label\":\"AmneziaWG\",\"available\":false}]".utf8))
        XCTAssertTrue(try config(ready).switchOptions(from: unavailable).isEmpty)
    }
    func testRejectsUnsupportedProtocolAndNegativeRevision() {
        XCTAssertThrowsError(try ProtocolSwitchRequest(protocolName: "future", revision: 0))
        XCTAssertThrowsError(try ProtocolSwitchRequest(protocolName: "wireguard", revision: -1))
    }
}
