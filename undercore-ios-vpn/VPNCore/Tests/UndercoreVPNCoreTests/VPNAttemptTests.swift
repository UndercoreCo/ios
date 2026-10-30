import XCTest
@testable import UndercoreVPNCore

final class VPNAttemptTests: XCTestCase {
    func testLogoutRejectsLateDownloadAndNextLoginCannotReuseIt() {
        var attempt = VPNAttempt()
        attempt.changeOwner(1)
        let first = attempt.begin()
        XCTAssertTrue(attempt.accepts(first, ownerID: 1))
        attempt.changeOwner(nil)
        XCTAssertFalse(attempt.accepts(first, ownerID: 1))
        attempt.changeOwner(1)
        XCTAssertFalse(attempt.accepts(first, ownerID: 1))
    }
    func testCancellationAndAccountSwitchRejectPendingStart() {
        var attempt = VPNAttempt()
        attempt.changeOwner(1)
        let cancelled = attempt.begin()
        attempt.cancel()
        XCTAssertFalse(attempt.accepts(cancelled, ownerID: 1))
        let firstOwner = attempt.begin()
        attempt.changeOwner(2)
        XCTAssertFalse(attempt.accepts(firstOwner, ownerID: 1))
        let second = attempt.begin()
        XCTAssertTrue(attempt.accepts(second, ownerID: 2))
        XCTAssertFalse(attempt.accepts(second, ownerID: 1))
    }
}
