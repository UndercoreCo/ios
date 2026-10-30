import XCTest
@testable import UndercoreVPNCore

final class TunnelDiagnosticsTests: XCTestCase {
    private func reply(run: UUID = UUID(), time: Date = Date(), count: Int = 1) -> TunnelStatusReply {
        let codes: [VPNDiagnosticCode] = [.health(.ok), .probe(.tls, .ok), .counters(handshake: true, sent: 123, received: 456)]
        return TunnelStatusReply(requestID: UUID(), runID: run, checkID: UUID(), codes: codes,
            observedAt: time, history: (0..<count).map { _ in TunnelCheckRecord(id: UUID(), time: time, codes: codes) })
    }
    func testIPCRejectsWrongRequestRunAndUnknownCodes() throws {
        let value = reply(), data = try JSONEncoder().encode(value)
        XCTAssertNotNil(TunnelStatusReply.decode(data, requestID: value.requestID, runID: value.runID))
        XCTAssertNil(TunnelStatusReply.decode(data, requestID: UUID(), runID: value.runID))
        XCTAssertNil(TunnelStatusReply.decode(data, requestID: value.requestID, runID: UUID()))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["codes"] = ["health=ok", "private_key=secret"]
        XCTAssertNil(TunnelStatusReply.decode(try JSONSerialization.data(withJSONObject: json), requestID: value.requestID, runID: nil))
        json["codes"] = ["health=ok", "health=tunnel_unreachable"]
        XCTAssertNil(TunnelStatusReply.decode(try JSONSerialization.data(withJSONObject: json), requestID: value.requestID, runID: nil))
    }
    func testHistoryBoundAndUnknownNestedFieldsCannotLeak() throws {
        let excessive = reply(count: 61)
        XCTAssertNil(TunnelStatusReply.decode(try JSONEncoder().encode(excessive), requestID: excessive.requestID, runID: nil))
        let value = reply(count: 60), data = try JSONEncoder().encode(value)
        XCTAssertLessThan(data.count, 65536)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["private_key"] = "secret-key"
        let decoded = try XCTUnwrap(TunnelStatusReply.decode(try JSONSerialization.data(withJSONObject: json), requestID: value.requestID, runID: nil))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("secret-key"))
        var checks = try XCTUnwrap(json["history"] as? [[String: Any]])
        checks[0]["codes"] = ["health=ok", "endpoint=hidden"]
        json["history"] = checks
        XCTAssertNil(TunnelStatusReply.decode(try JSONSerialization.data(withJSONObject: json), requestID: value.requestID, runID: nil))
    }
    func testCountersNeverExportRawEngineFields() throws {
        let counter = try XCTUnwrap(TunnelCounters.parse("private_key=secret\nendpoint=hidden\nlast_handshake_time_sec=100\ntx_bytes=123\nrx_bytes=456\n"))
        XCTAssertEqual(counter.diagnostic.wireValue, "stats=1,123,456")
        XCTAssertNil(TunnelCounters.parse("last_handshake_time_sec=100\ntx_bytes=123\nrx_bytes=456\nrx_bytes=1"))
        XCTAssertNil(VPNDiagnosticCode(wireValue: "stats=1,-1,456"))
    }
    func testArchiveDeduplicatesAndCapsRunsAndChecks() throws {
        var archive = TunnelDiagnosticArchive()
        let now = Date(), first = reply(time: now, count: 60)
        archive.ingest(first, now: now); archive.ingest(first, now: now)
        XCTAssertEqual(archive.sessions.count, 1)
        XCTAssertEqual(archive.sessions[0].checks.count, 60)
        archive.ingest(reply(run: first.runID, time: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        XCTAssertEqual(archive.sessions[0].checks.count, 60)
        for _ in 0..<15 { archive.ingest(reply(time: now), now: now) }
        XCTAssertEqual(archive.sessions.count, 10)
        let data = try JSONEncoder().encode(archive)
        XCTAssertEqual(TunnelDiagnosticArchive.load(data, now: now)?.sessions.count, 10)
        XCTAssertEqual(TunnelDiagnosticArchive.load(data, now: now.addingTimeInterval(8 * 86400))?.sessions.count, 0)
        XCTAssertNil(TunnelDiagnosticArchive.load(Data(repeating: 0, count: 1_048_577)))
    }
    func testArchiveRejectsDuplicateIDsInsteadOfCrashingOnMerge() throws {
        var archive = TunnelDiagnosticArchive()
        let value = reply(); archive.ingest(value)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        let checks = try XCTUnwrap(sessions[0]["checks"] as? [[String: Any]])
        sessions[0]["checks"] = checks + checks; json["sessions"] = sessions
        XCTAssertNil(TunnelDiagnosticArchive.load(try JSONSerialization.data(withJSONObject: json)))
    }
}
