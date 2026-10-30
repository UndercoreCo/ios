import UIKit

final class AccountDeletionViewController: FormViewController {
    private let model: AccountDeletionViewModel
    private let passwordField = InputField("Текущий пароль", contentType: .password, secure: true)
    private let deleteButton = PrimaryButton("Удалить аккаунт")
    init(model: AccountDeletionViewModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Удаление аккаунта"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
        addText("Удалить аккаунт Undercore?", style: .title2)
        addText("Аккаунт будет удалён и на сайте, и в приложении. Доступ к VPN-конфигурациям будет отозван. Это действие нельзя отменить.")
        addText("Для подтверждения введите текущий пароль.", style: .callout)
        deleteButton.configuration?.baseBackgroundColor = .systemRed
        deleteButton.accessibilityIdentifier = "account.delete"
        [passwordField, deleteButton].forEach { stack.addArrangedSubview($0) }
        addFeedback()
        deleteButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        model.onState = { [weak self] state in
            guard let self else { return }
            self.feedback(state, controls: [self.passwordField, self.deleteButton])
            self.deleteButton.isEnabled = !state.isBusy && !self.model.accepted
            self.navigationItem.leftBarButtonItem?.isEnabled = !state.isBusy
            self.navigationController?.isModalInPresentation = state.isBusy
        }
    }
    @objc private func close() { guard !model.state.isBusy else { return }; passwordField.text = nil; dismiss(animated: true) }
    @objc private func confirm() {
        guard model.validate(password: passwordField.text ?? "") else { return }
        view.endEditing(true)
        let alert = UIAlertController(title: "Удалить аккаунт навсегда?", message: "Вы потеряете доступ к аккаунту и его VPN-конфигурациям. Восстановление пароля не восстановит удалённый аккаунт.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CommonText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить аккаунт", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let password = self.passwordField.text ?? ""
            self.passwordField.text = nil
            Task { await self.model.submit(password: password) }
        })
        present(alert, animated: true)
    }
}
