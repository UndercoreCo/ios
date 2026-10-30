#if DEBUG
import UIKit
import UndercoreCore

@MainActor final class PreviewAccountManagementRepository: AccountManagementRepository {
    var error: Error?
    var resets = 0
    var deletions = 0
    func requestPasswordReset(email: String) async throws {
        resets += 1
        try await Task.sleep(for: .milliseconds(30))
        if let error { throw error }
    }
    func requestDeletion(password: String) async throws {
        deletions += 1
        try await Task.sleep(for: .milliseconds(30))
        if let error { throw error }
    }
}

@MainActor enum AccountManagementChecks {
    static func run() async {
        let repo = PreviewAccountManagementRepository()
        let recovery = PasswordRecoveryViewModel(repository: repo)
        await recovery.send(email: " ")
        precondition(repo.resets == 0 && recovery.state.message != nil)
        async let first: Void = recovery.send(email: "preview@example.test")
        async let duplicate: Void = recovery.send(email: "preview@example.test")
        _ = await (first, duplicate)
        precondition(repo.resets == 1 && recovery.sent && !recovery.state.isBusy)
        await recovery.send(email: "preview@example.test")
        precondition(repo.resets == 1)

        let deletion = AccountDeletionViewModel(repository: repo)
        var accepted = 0
        deletion.onAccepted = { accepted += 1 }
        await deletion.submit(password: "")
        precondition(repo.deletions == 0)
        repo.error = ClientError.server(status: 422, message: "Пароль неверный", retryAfter: nil)
        await deletion.submit(password: "test")
        precondition(!deletion.accepted && accepted == 0 && deletion.state.message == "Пароль неверный")
        repo.error = AccountDeletionPreparationError(underlyingError: URLError(.timedOut))
        await deletion.submit(password: "test")
        precondition(!deletion.accepted && deletion.state.message?.hasPrefix("Запрос на удаление не отправлен.") == true)
        repo.error = URLError(.timedOut)
        await deletion.submit(password: "test")
        precondition(!deletion.accepted && deletion.state.message?.contains("Сервер мог принять") == true)
        repo.error = nil
        async let deleteFirst: Void = deletion.submit(password: "test")
        async let deleteDuplicate: Void = deletion.submit(password: "test")
        _ = await (deleteFirst, deleteDuplicate)
        precondition(repo.deletions == 4 && accepted == 1 && deletion.accepted && !deletion.state.isBusy)
        await deletion.submit(password: "test")
        precondition(repo.deletions == 4 && accepted == 1)
        print("ACCOUNT CHECK PASS: validation; duplicate taps; recovery success; deletion rejection; preparation failure; ambiguous timeout; single acceptance")
    }
}
#endif
