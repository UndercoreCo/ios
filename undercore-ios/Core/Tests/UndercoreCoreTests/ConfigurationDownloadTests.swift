import XCTest
@testable import UndercoreCore

final class ConfigurationDownloadTests: XCTestCase {
    func testPreservesServerIdentityAndVersion() throws {
        for name in ["uc-1-v1.conf", "uc-2-v1.conf", "uc-1-v2.conf", "config-01.conf"] {
            let value = try ConfigurationDownload.filename(from: "attachment; filename=\"\(name)\"")
            let data = Data("SYNTHETIC_ONLY".utf8)
            let file = try ConfigurationDownload(data: data, filename: value)
            XCTAssertEqual(file.filename, name)
            XCTAssertEqual(file.data, data)
        }
    }
    func testRejectsTrailingNewlines() {
        XCTAssertThrowsError(try ConfigurationDownload(data: Data(), filename: "uc-1-v1.conf\n"))
    }
    func testRejectsMissingUnsafeOrOverlongNamesInsteadOfReusingConfig01() {
        for header in [nil, "attachment", "attachment; filename=\"../x.conf\"", "attachment; filename=\"/x.conf\"", "attachment; filename=\"phone.conf.txt\"", "attachment; filename=\"1234567890123456.conf\""] {
            XCTAssertThrowsError(try ConfigurationDownload.filename(from: header))
        }
    }
}
