import Foundation

/// Bounded on-device snapshots. No account, server, profile or device identifiers.
public struct TunnelDiagnosticArchive: Codable {
    public struct Session: Codable {
        public let runID: UUID
        public var updatedAt: Date
        public var checks: [TunnelCheckRecord]
    }
    public private(set) var sessions: [Session] = []
    public init() {}
    public mutating func ingest(_ reply: TunnelStatusReply, now: Date = Date()) {
        prune(now: now)
        guard !reply.history.isEmpty else { return }
        let old = sessions.first { $0.runID == reply.runID }?.checks ?? []
        var checks = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        for check in reply.history { checks[check.id] = check }
        sessions.removeAll { $0.runID == reply.runID }
        let merged = checks.values.filter { $0.time <= now.addingTimeInterval(60) && $0.time >= now.addingTimeInterval(-7 * 86400) }
            .sorted { $0.time < $1.time }.suffix(60)
        sessions.append(Session(runID: reply.runID, updatedAt: now, checks: Array(merged)))
        sessions = Array(sessions.suffix(10))
    }
    public mutating func prune(now: Date = Date()) {
        sessions.removeAll { $0.updatedAt < now.addingTimeInterval(-7 * 86400) || $0.updatedAt > now.addingTimeInterval(60) }
    }
    public static func load(_ data: Data, now: Date = Date()) -> Self? {
        guard data.count <= 1_048_576, var value = try? JSONDecoder().decode(Self.self, from: data),
              value.sessions.count <= 10, Set(value.sessions.map(\.runID)).count == value.sessions.count,
              value.sessions.allSatisfy({ $0.checks.count <= 60 && $0.checks.allSatisfy(\.isValid)
                  && Set($0.checks.map(\.id)).count == $0.checks.count }) else { return nil }
        value.prune(now: now)
        return value
    }
}
