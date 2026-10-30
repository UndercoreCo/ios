import Foundation
import UndercoreCore

@MainActor final class AuthViewModel {
    private let repository: AuthRepository
    let challenge: RegistrationChallenge
    var onState: ((ScreenState) -> Void)?
    var onAccount: ((Account) -> Void)?
    private(set) var state = ScreenState() { didSet { onState?(state) } }
    init(repository: AuthRepository, challenge: RegistrationChallenge) { self.repository = repository; self.challenge = challenge }
    func validate(name: String, email: String, password: String, registering: Bool) -> Bool {
        guard !state.isBusy else { return false }
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty {
            state.message = "Введите почту и пароль."; return false
        }
        if registering, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.message = "Введите своё имя."; return false
        }
        if registering, password.count < 8 { state.message = "Для регистрации нужен пароль не короче 8 символов."; return false }
        return true
    }
    func submit(name: String, email: String, password: String, registering: Bool, token: String? = nil) async {
        guard validate(name: name, email: email, password: password, registering: registering) else { return }
        state = ScreenState(isBusy: true)
        defer { state.isBusy = false }
        do {
            // Refresh CSRF before an explicit submit; POST requests are never automatically retried.
            _ = try await repository.prepare()
            let account: Account
            if registering {
                if challenge.required, token == nil { state.message = "Пройдите проверку для регистрации."; return }
                account = try await repository.register(name: name, email: email, password: password,
                    challenge: token.map { (field: challenge.tokenField, token: $0) })
            } else { account = try await repository.login(email: email, password: password) }
            onAccount?(account)
        } catch { state.message = readableError(error) }
    }
}
