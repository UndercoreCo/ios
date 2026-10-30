import Foundation
import UndercoreCore

@MainActor final class AccountDeletionViewModel {
    private let repository: AccountManagementRepository
    var onState: ((ScreenState) -> Void)?
    var onAccepted: (() -> Void)?
    var onSessionExpired: (() -> Void)?
    private(set) var accepted = false
    private(set) var state = ScreenState() { didSet { onState?(state) } }
    init(repository: AccountManagementRepository) { self.repository = repository }
    func validate(password: String) -> Bool {
        guard !state.isBusy, !accepted else { return false }
        guard !password.isEmpty else { state.message = "Введите текущий пароль."; return false }
        return true
    }
    func submit(password: String) async {
        guard validate(password: password) else { return }
        state = ScreenState(isBusy: true)
        defer { state.isBusy = false }
        do {
            try await repository.requestDeletion(password: password)
            accepted = true
            onAccepted?()
        } catch ClientError.expiredSession { onSessionExpired?() }
        catch let error as AccountDeletionPreparationError {
            state.message = "Запрос на удаление не отправлен. " + readableError(error.underlyingError)
        }
        catch {
            if error is URLError || error is CancellationError || (error as? ClientError) == .invalidResponse {
                state.message = "Не удалось подтвердить результат. Сервер мог принять запрос на удаление. Не отправляйте его повторно сразу: закройте экран и проверьте вход в аккаунт. Если войти не удаётся, обратитесь в поддержку."
            } else { state.message = readableError(error) }
        }
    }
}
