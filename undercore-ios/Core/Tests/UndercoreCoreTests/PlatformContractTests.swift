import Foundation
import XCTest
@testable import UndercoreCore

/// Decode actual, isolated Laravel test responses instead of hand-written API stubs.
final class PlatformContractTests: XCTestCase {
    func testBannerExpiryIsStrictAndAcceptsISO8601Precision() throws {
        let now = Date(timeIntervalSince1970: 1790942400)
        func article(_ expiry: String?) throws -> AppArticle {
            var json: [String: Any] = ["id": 1, "title": "News", "updatedAt": "2026-10-02T12:00:00Z", "tags": []]
            json["expiresAt"] = expiry
            return try JSONDecoder().decode(AppArticle.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertTrue(try article(nil).isVisible(at: now))
        XCTAssertFalse(try article("invalid").isVisible(at: now))
        let formatter = ISO8601DateFormatter()
        XCTAssertFalse(try article(formatter.string(from: now)).isVisible(at: now))
        XCTAssertTrue(try article(formatter.string(from: now.addingTimeInterval(1))).isVisible(at: now))
        formatter.formatOptions.insert(.withFractionalSeconds)
        XCTAssertTrue(try article(formatter.string(from: now.addingTimeInterval(0.5))).isVisible(at: now))
    }

    func testCurrentClientDecodesPlatformContractCaptures() throws {
        guard let directory = ProcessInfo.processInfo.environment["API_CONTRACT_OUTPUT"] else {
            throw XCTSkip("Set API_CONTRACT_OUTPUT to the isolated Laravel contract captures directory.")
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("platform-responses.json")
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var tested: Set<String> = []
        let decoder = JSONDecoder()
        for record in records {
            guard let name = record["name"] as? String,
                  let status = record["status"] as? Int, (200..<300).contains(status),
                  let payload = record["json"] else { continue }
            let data = try JSONSerialization.data(withJSONObject: payload)
            switch name {
            case "bootstrap":
                XCTAssertEqual(try decoder.decode(Envelope<Bootstrap>.self, from: data).data.apiVersion, 1)
            case "register", "login", "me":
                XCTAssertFalse(try decoder.decode(UserResponse.self, from: data).user.email.isEmpty)
            case "vpn", "package-page", "amnezia-page":
                let page = try decoder.decode(Envelope<VPNPage>.self, from: data).data
                XCTAssertFalse(page.configurations.isEmpty)
            case "detail", "rename", "state-active", "state-expired", "state-sync_error":
                _ = try decoder.decode(Envelope<VPNConfiguration>.self, from: data)
            case "article-banners":
                XCTAssertFalse(try decoder.decode(Envelope<[AppArticle]>.self, from: data).data.isEmpty)
            case "article-detail":
                XCTAssertNotNil(try decoder.decode(Envelope<AppArticle>.self, from: data).data.contentHtml)
            case "notification-page":
                XCTAssertFalse(try decoder.decode(NotificationPage.self, from: data).data.isEmpty)
            case "summary":
                XCTAssertGreaterThan(try decoder.decode(Envelope<NotificationSummary>.self, from: data).data.unreadCount, 0)
            case "notification", "read":
                _ = try decoder.decode(Envelope<UserNotification>.self, from: data)
            case "read-all":
                XCTAssertEqual(try decoder.decode(Envelope<NotificationReadResult>.self, from: data).data.unreadCount, 0)
            default: continue
            }
            tested.insert(name)
        }
        let required: Set<String> = ["article-banners", "article-detail", "bootstrap", "register", "login", "me", "vpn", "package-page", "amnezia-page", "detail", "rename", "state-active", "state-expired", "state-sync_error", "notification-page", "summary", "notification", "read", "read-all"]
        XCTAssertTrue(required.isSubset(of: tested), "Missing native consumer contract captures")
    }
}
