import Foundation
import UndercoreCore

@MainActor final class VerificationViewModel {
    private let repository: AuthRepository
    private let now: () -> Date
    private var retryUntil: Date?
    private(set) var statusLoaded = false
    private(set) var state = ScreenState() { didSet { onState?(state) } }
    var onState: ((ScreenState) -> Void)?
    var onAccount: ((Account) -> Void)?
    var onSessionExpired: (() -> Void)?
    var retryAfterSeconds: Int { max(0, Int(ceil(retryUntil?.timeIntervalSince(now()) ?? 0))) }
    var canResend: Bool { statusLoaded && !state.isBusy && retryAfterSeconds == 0 }
    init(repository: AuthRepository, now: @escaping () -> Date = Date.init) { self.repository = repository; self.now = now }
    func loadStatus() async {
        guard !state.isBusy else { return }
        await run {
            _ = try await self.repository.prepare()
            let status = try await self.repository.verificationStatus()
            try Task.checkCancellation()
            self.apply(status)
            if status.isEmailVerified { self.onAccount?(try await self.repository.currentAccount()) }
        }
    }
    private func apply(_ status: EmailVerificationStatus) {
        retryUntil = now().addingTimeInterval(TimeInterval(max(0, status.retryAfterSeconds)))
        statusLoaded = true
    }
    func verify(_ code: String) async {
        guard !state.isBusy else { return }
        guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else { state.message = "Введите 6 цифр из письма."; return }
        await run {
            _ = try await self.repository.prepare()
            self.onAccount?(try await self.repository.verifyEmail(code: code))
        }
    }
    func resend() async {
        guard canResend else { return }
        await run {
            _ = try await self.repository.prepare()
            let status = try await self.repository.resendEmail()
            try Task.checkCancellation()
            self.apply(status)
            if status.isEmailVerified { self.onAccount?(try await self.repository.currentAccount()) }
            else { self.state.message = "Новый код отправлен. Используйте код из последнего письма." }
        }
    }
    private func run(_ operation: () async throws -> Void) async {
        state = ScreenState(isBusy: true)
        defer { state.isBusy = false }
        do { try await operation() }
        catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            if case let ClientError.server(_, _, retryAfter) = error, let retryAfter {
                retryUntil = now().addingTimeInterval(TimeInterval(max(0, retryAfter)))
            }
            state.message = readableError(error)
            if error as? ClientError == .expiredSession { onSessionExpired?() }
        }
    }
}
