import Foundation
import UndercoreCore

@MainActor final class MessengerConnectionsViewModel {
    var isOffline = false
    private let repository: MessengerRepository
    private(set) var connections: [MessengerChannel: MessengerConnection] = [:]
    private(set) var busy: Set<MessengerChannel> = []
    private(set) var errors: [MessengerChannel: String] = [:]
    private(set) var awaitingConnection: Set<MessengerChannel> = []
    var onChange: (() -> Void)?
    var onSessionExpired: (() -> Void)?
    var onError: ((String) -> Void)?
    init(repository: MessengerRepository) { self.repository = repository }
    func refresh() async {
        async let telegram: Void = refresh(.telegram)
        async let max: Void = refresh(.max)
        _ = await (telegram, max)
    }
    func refresh(_ channel: MessengerChannel) async {
        guard !busy.contains(channel) else { return }
        busy.insert(channel); onChange?()
        defer { busy.remove(channel); onChange?() }
        do {
            let result = try await repository.status(channel)
            try Task.checkCancellation()
            connections[channel] = result; errors[channel] = nil
            if result.connected { awaitingConnection.remove(channel) }
        } catch is CancellationError { }
        catch { handle(error, channel: channel, showAlert: false) }
    }
    func connect(_ channel: MessengerChannel) async -> URL? {
        guard !isOffline, !busy.contains(channel), errors[channel] == nil,
              let status = connections[channel], status.available, !status.connected else { return nil }
        busy.insert(channel); onChange?()
        defer { busy.remove(channel); onChange?() }
        do {
            let url = try await repository.connect(channel)
            try Task.checkCancellation()
            awaitingConnection.insert(channel)
            return url // Opening the bot does not itself prove a connection.
        } catch is CancellationError { return nil }
        catch { handle(error, channel: channel, showAlert: true); return nil }
    }
    func disconnect(_ channel: MessengerChannel) async {
        guard !isOffline, !busy.contains(channel), connections[channel]?.connected == true else { return }
        busy.insert(channel); onChange?()
        defer { busy.remove(channel); onChange?() }
        do {
            try await repository.disconnect(channel)
            awaitingConnection.remove(channel)
            // Clear confirmed old state immediately, then observe the server again.
            connections[channel] = nil; errors[channel] = nil
            connections[channel] = try await repository.status(channel)
        } catch {
            if error as? ClientError == .expiredSession { handle(error, channel: channel, showAlert: false); return }
            // A timeout can happen after DELETE succeeded; don't claim failure before checking.
            do {
                let observed = try await repository.status(channel)
                connections[channel] = observed
                if !observed.connected { errors[channel] = nil; awaitingConnection.remove(channel); return }
            } catch ClientError.expiredSession { handle(ClientError.expiredSession, channel: channel, showAlert: false); return }
            catch { }
            handle(error, channel: channel, showAlert: true)
        }
    }
    private func handle(_ error: Error, channel: MessengerChannel, showAlert: Bool) {
        if (error as? URLError)?.code == .cancelled { return }
        if error as? ClientError == .expiredSession { onSessionExpired?(); return }
        errors[channel] = readableError(error)
        if showAlert { onError?(readableError(error)) }
    }
}

#if DEBUG
@MainActor final class PreviewMessengerRepository: MessengerRepository {
    private var telegramConnected = true
    func status(_ channel: MessengerChannel) async throws -> MessengerConnection {
        let connected = channel == .telegram && telegramConnected
        let value: [String: Any] = ["available": true, "connected": connected,
            "account": connected ? ["username": "preview_account", "displayName": "Preview"] : NSNull()]
        return try JSONDecoder().decode(MessengerConnection.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func connect(_ channel: MessengerChannel) async throws -> URL {
        throw ClientError.server(status: 503, message: "Это предпросмотр. Подключение бота здесь не выполняется.", retryAfter: nil)
    }
    func disconnect(_ channel: MessengerChannel) async throws { if channel == .telegram { telegramConnected = false } }
}
#endif
