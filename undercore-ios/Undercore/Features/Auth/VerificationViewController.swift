import UIKit
import UndercoreCore

final class VerificationViewController: FormViewController {
    private var countdown: Timer?
    private var statusTask: Task<Void, Never>?
    private let retryStatus = UIButton(type: .system)
    private let model: VerificationViewModel
    private let email: String
    private let codeField = InputField("Код из письма", contentType: .oneTimeCode)
    private let verifyButton = PrimaryButton("Подтвердить почту")
    private let resendButton = PrimaryButton("Отправить код ещё раз", primary: false)
    var onDeleteAccount: (() -> Void)?
    private let deleteAccountButton = UIButton(type: .system)
    var onLogout: (() -> Void)?
    init(model: VerificationViewModel, email: String) { self.model = model; self.email = email; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Подтвердите почту"
        addText("Введите код из письма", style: .title1)
        addText("Код подтверждения приходит на \(email). Если письмо не пришло, проверьте папку «Спам» или запросите новый код.")
        codeField.keyboardType = .numberPad
        codeField.onReturn = { [weak self] in self?.verify() }
        [codeField, verifyButton, resendButton].forEach { stack.addArrangedSubview($0) }
        verifyButton.addTarget(self, action: #selector(verify), for: .touchUpInside)
        resendButton.addTarget(self, action: #selector(resend), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: CommonText.logout, style: .plain, target: self, action: #selector(logout))
        addFeedback()
        retryStatus.setTitle("Проверить возможность отправки", for: .normal)
        retryStatus.addAction(UIAction { [weak self] _ in self?.refreshStatus() }, for: .touchUpInside)
        stack.addArrangedSubview(retryStatus)
        deleteAccountButton.setTitle("Удалить аккаунт", for: .normal)
        deleteAccountButton.tintColor = .systemRed
        deleteAccountButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        deleteAccountButton.addAction(UIAction { [weak self] _ in self?.onDeleteAccount?() }, for: .touchUpInside)
        stack.addArrangedSubview(deleteAccountButton)
        model.onState = { [weak self] state in
            guard let self else { return }
            self.feedback(state, controls: [self.codeField, self.verifyButton, self.resendButton, self.deleteAccountButton])
            self.navigationItem.rightBarButtonItem?.isEnabled = !state.isBusy
            self.updateResend()
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateResend(); refreshStatus()
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateResend() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatus), name: UIScene.didActivateNotification, object: nil)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countdown?.invalidate(); countdown = nil
        statusTask?.cancel(); statusTask = nil
        NotificationCenter.default.removeObserver(self, name: UIScene.didActivateNotification, object: nil)
    }
    @objc private func refreshStatus() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            await self?.model.loadStatus()
            self?.statusTask = nil
        }
    }
    private func updateResend() {
        let seconds = model.retryAfterSeconds
        resendButton.configuration?.title = seconds > 0 ? "Отправить повторно через \(seconds) с" : "Отправить код ещё раз"
        resendButton.isEnabled = model.canResend
        retryStatus.isHidden = model.statusLoaded || model.state.isBusy
    }
    @objc private func logout() { guard !model.state.isBusy else { return }; onLogout?() }
    @objc private func verify() {
        let code = codeField.text ?? ""
        view.endEditing(true)
        Task { [weak self] in await self?.model.verify(code) }
    }
    @objc private func resend() { Task { [weak self] in await self?.model.resend() } }
}
