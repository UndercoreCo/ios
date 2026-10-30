import Foundation
import UndercoreCore

@MainActor final class PasswordRecoveryViewModel {
    private let repository: AccountManagementRepository
    var onState: ((ScreenState) -> Void)?
    private(set) var sent = false
    private(set) var state = ScreenState() { didSet { onState?(state) } }
    init(repository: AccountManagementRepository) { self.repository = repository }
    func send(email: String) async {
        guard !state.isBusy, !sent else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { state.message = "Введите почту, указанную при регистрации."; return }
        state = ScreenState(isBusy: true)
        defer { state.isBusy = false }
        do {
            try await repository.requestPasswordReset(email: email)
            sent = true
            state.message = "Письмо отправлено. Откройте ссылку в письме и задайте новый пароль на сайте Undercore. Затем вернитесь в приложение и войдите. Если письма нет, проверьте папку «Спам»."
        } catch { state.message = readableError(error) }
    }
}
