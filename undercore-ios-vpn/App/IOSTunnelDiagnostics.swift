import UIKit
import NetworkExtension
import UndercoreCore
import UndercoreVPNCore

/// Observes the extension; never starts/stops a tunnel or selects a server.
@MainActor final class IOSTunnelDiagnostics {
    private weak var session: NETunnelProviderSession?
    private var generation = UUID()
    private var poll: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var inFlight = false
    private var archive = TunnelDiagnosticArchive()
    private var snapshot: TunnelStatusReply?
    private var ipcAvailable = false
    var onChange: (() -> Void)?
    private let file: URL?

    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VPNDiagnostics/history.json")
        if let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 1_048_576, let data = try? Data(contentsOf: file),
           let saved = TunnelDiagnosticArchive.load(data) { archive = saved }
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.schedulePolling() }
            })
        }
    }
    deinit { poll?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }

    func attach(_ session: NETunnelProviderSession?) {
        if self.session !== session {
            generation = UUID(); self.session = session; snapshot = nil; ipcAvailable = false
        }
        if session?.status != .connected { snapshot = nil; ipcAvailable = false; generation = UUID() }
        schedulePolling()
    }
    private func schedulePolling() {
        poll?.cancel(); poll = nil
        guard UIApplication.shared.applicationState == .active, session?.status == .connected else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }
    var health: VPNDiagnosticCode.Health? {
        guard ipcAvailable, let snapshot, Date().timeIntervalSince(snapshot.observedAt) >= -60,
              Date().timeIntervalSince(snapshot.observedAt) <= 120 else { return nil }
        return snapshot.health
    }
    var detail: String {
        switch health {
        case .ok: return "Доступ через VPN проверен"
        case .checking: return "Проверяем доступ к интернету…"
        case .dns: return "VPN отвечает, но DNS не работает"
        case .name_unavailable: return "VPN отвечает, проверка сайтов не прошла"
        case .network_unavailable: return "Сеть недоступна. Проверьте Wi-Fi или мобильную связь"
        case .tunnel_unreachable: return "VPN-сервер не отвечает при работающей сети"
        case .egress_unconfirmed: return "VPN-сервер отвечает, доступ к интернету не подтверждён"
        case .source_unconfirmed: return "Не удалось подтвердить доступ к интернету"
        case .degraded: return "Недостаточно данных для проверки VPN"
        case nil: return "Состояние туннеля уточняется"
        }
    }
    func refresh() async {
        guard !inFlight, let session, session.status == .connected else { return }
        inFlight = true
        defer { inFlight = false }
        let token = generation
        let request = TunnelStatusRequest(command: .status)
        let data = await send(request, to: session)
        guard token == generation, self.session === session, session.status == .connected else { return }
        guard let data, let reply = TunnelStatusReply.decode(data, requestID: request.id, runID: snapshot?.runID) else {
            ipcAvailable = false; onChange?(); return
        }
        ipcAvailable = true; snapshot = reply
        if let last = reply.history.last,
           archive.sessions.first(where: { $0.runID == reply.runID })?.checks.last?.id != last.id {
            archive.ingest(reply)
            saveArchive()
        }
        onChange?()
    }
    private func send(_ request: TunnelStatusRequest, to session: NETunnelProviderSession) async -> Data? {
        await withCheckedContinuation { continuation in
            var completed = false
            let finish: (Data?) -> Void = { data in
                guard !completed else { return }; completed = true
                continuation.resume(returning: data)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                finish(nil)
            }
            do {
                try session.sendProviderMessage(JSONEncoder().encode(request)) { data in
                    Task { @MainActor in finish(data) }
                }
            } catch { finish(nil) }
        }
    }
    private func saveArchive() {
        guard var file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(archive).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        } catch { /* An unavailable archive must not affect the VPN. */ }
    }
    func report(client: APIClient) async throws -> Data {
        await refresh()
        archive.prune(); saveArchive()
        struct Report: Encodable {
            let version: Int
            let generatedAt: Date
            let cachedDataMode: Bool
            let events: [APIDiagnostics.Event]
            let systemTunnelStatus: Int
            let extensionResponding: Bool
            let health: String?
            let observedAt: Date?
            let tunnel: TunnelDiagnosticArchive
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Report(version: 2, generatedAt: Date(), cachedDataMode: client.isOffline,
            events: client.diagnostics.events, systemTunnelStatus: session?.status.rawValue ?? NEVPNStatus.disconnected.rawValue,
            extensionResponding: ipcAvailable, health: health?.rawValue, observedAt: snapshot?.observedAt, tunnel: archive))
    }
}
