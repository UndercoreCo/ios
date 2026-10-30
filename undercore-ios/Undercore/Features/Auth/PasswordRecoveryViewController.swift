import UIKit

final class PasswordRecoveryViewController: FormViewController {
    private let model: PasswordRecoveryViewModel
    private let emailField = InputField("Электронная почта", contentType: .emailAddress)
    private let sendButton = PrimaryButton("Отправить письмо")
    private let doneButton = PrimaryButton("Вернуться ко входу", primary: false)
    init(model: PasswordRecoveryViewModel, email: String) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        emailField.text = email
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Восстановление доступа"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
        addText("Забыли пароль?", style: .title2)
        addText("Укажите почту вашего аккаунта. Мы отправим ссылку для установки нового пароля.")
        emailField.keyboardType = .emailAddress
        emailField.accessibilityIdentifier = "recovery.email"
        sendButton.accessibilityIdentifier = "recovery.send"
        [emailField, sendButton].forEach { stack.addArrangedSubview($0) }
        addFeedback()
        stack.addArrangedSubview(doneButton); doneButton.isHidden = true
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        model.onState = { [weak self] state in
            guard let self else { return }
            self.feedback(state, controls: [self.emailField, self.sendButton])
            self.emailField.isEnabled = !state.isBusy && !self.model.sent
            self.sendButton.isHidden = self.model.sent
            self.doneButton.isHidden = !self.model.sent
            self.navigationItem.leftBarButtonItem?.isEnabled = !state.isBusy
            self.navigationController?.isModalInPresentation = state.isBusy
        }
    }
    @objc private func send() {
        let email = emailField.text ?? ""
        view.endEditing(true)
        Task { [weak self] in await self?.model.send(email: email) }
    }
    @objc private func close() { guard !model.state.isBusy else { return }; dismiss(animated: true) }
}
