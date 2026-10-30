import UIKit
import UndercoreCore

final class AuthViewController: FormViewController {
    private let header = UIStackView()
    private let policy = UITextView()
    private var hiddenFooterHeight: NSLayoutConstraint?
    private let model: AuthViewModel
    private var registering = false
    private let switchModeButton = PrimaryButton("Зарегистрироваться", primary: false)
    private let nameField = InputField("Имя", contentType: .name)
    private let emailField = InputField("Электронная почта", contentType: .username)
    private let passwordField = InputField("Пароль", contentType: .password, secure: true)
    private let submitButton = PrimaryButton("Войти")
    private let forgotButton = UIButton(type: .system)
    var onPasswordRecovery: ((String) -> Void)?
    var onChallenge: ((@escaping (String) -> Void) -> Void)?
    var onDocument: ((URL) -> Void)?
    init(model: AuthViewModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        let logo = UIImageView(image: UIImage(named: "StartupIcon")?.withRenderingMode(.alwaysOriginal))
        logo.contentMode = .scaleAspectFit
        logo.accessibilityLabel = "Логотип Undercore"
        logo.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let brand = UILabel(); brand.text = AppConfiguration.name
        brand.font = .preferredFont(forTextStyle: .title1); brand.textAlignment = .center
        brand.adjustsFontForContentSizeCategory = true
        header.addArrangedSubview(logo); header.addArrangedSubview(brand)
        header.axis = .vertical; header.spacing = 12
        stack.addArrangedSubview(header); stack.setCustomSpacing(32, after: header)
        nameField.nextField = emailField; nameField.returnKeyType = .next
        emailField.nextField = passwordField; emailField.returnKeyType = .next
        passwordField.returnKeyType = .go
        passwordField.onReturn = { [weak self] in self?.submit() }
        emailField.keyboardType = .emailAddress
        [nameField, emailField, passwordField, submitButton].forEach { stack.addArrangedSubview($0) }
        submitButton.addTarget(self, action: #selector(submit), for: .touchUpInside)
        switchModeButton.addTarget(self, action: #selector(changeMode), for: .touchUpInside)
        stack.addArrangedSubview(switchModeButton)
        forgotButton.setTitle("Забыли пароль?", for: .normal)
        forgotButton.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        forgotButton.titleLabel?.adjustsFontForContentSizeCategory = true
        forgotButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        forgotButton.addTarget(self, action: #selector(recoverPassword), for: .touchUpInside)
        stack.addArrangedSubview(forgotButton)
        stack.setCustomSpacing(4, after: switchModeButton)
        addFeedback()
        messageLabel.isHidden = true
        policy.isEditable = false; policy.isScrollEnabled = false; policy.backgroundColor = .clear
        policy.textContainerInset = .zero; policy.textContainer.lineFragmentPadding = 0
        policy.adjustsFontForContentSizeCategory = true
        policy.delegate = self
        let copy = "Политика обработки персональных данных и условия оферты."
        let text = NSMutableAttributedString(string: copy, attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel])
        for (label, url) in [("условия оферты", AppConfiguration.offerURL), ("Политика обработки персональных данных", AppConfiguration.privacyURL)] {
            text.addAttribute(.link, value: url, range: (copy as NSString).range(of: label))
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        policy.attributedText = text
        policy.linkTextAttributes = [.foregroundColor: UIColor.secondaryLabel, .underlineStyle: NSUnderlineStyle.single.rawValue]
        centerContent(footer: policy)
        hiddenFooterHeight = policy.heightAnchor.constraint(equalToConstant: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        model.onState = { [weak self] state in
            guard let self else { return }
            self.messageLabel.isHidden = state.message == nil
            self.feedback(state, controls: [self.switchModeButton, self.nameField, self.emailField, self.passwordField, self.submitButton, self.forgotButton])
        }
        updateMode()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-register") { changeMode() }
        #endif
    }
    #if DEBUG
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if ProcessInfo.processInfo.arguments.contains("--preview-keyboard") { emailField.becomeFirstResponder() }
    }
    #endif
    @objc private func keyboardChanged(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let visible = view.convert(frame, from: nil).intersects(view.bounds)
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) {
            self.stack.spacing = visible ? 8 : Theme.gap
            self.header.isHidden = visible
            self.policy.isHidden = visible
            self.hiddenFooterHeight?.isActive = visible
            self.view.layoutIfNeeded()
        }
    }
    @objc private func changeMode() {
        guard !model.state.isBusy else { return }
        view.endEditing(true)
        registering.toggle()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) {
            self.updateMode()
            self.view.layoutIfNeeded()
        }
    }
    private func updateMode() {
        nameField.isHidden = !registering
        forgotButton.isHidden = registering
        passwordField.textContentType = registering ? .newPassword : .password
        submitButton.configuration?.title = registering ? "Создать аккаунт" : "Войти"
        switchModeButton.configuration?.title = registering ? "Уже есть аккаунт? Войти" : "Зарегистрироваться"
        messageLabel.text = nil
        messageLabel.isHidden = true
    }
    @objc private func recoverPassword() {
        guard !model.state.isBusy else { return }
        view.endEditing(true)
        passwordField.text = nil
        onPasswordRecovery?(emailField.text ?? "")
    }
    @objc private func submit() {
        guard !model.state.isBusy else { return }
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (emailField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.text ?? ""
        view.endEditing(true)
        guard model.validate(name: name, email: email, password: password, registering: registering) else { return }
        if registering, model.challenge.required {
            onChallenge? { [weak self] token in self?.performSubmit(name: name, email: email, password: password, registering: true, token: token) }
        } else { performSubmit(name: name, email: email, password: password, registering: registering) }
    }
    private func performSubmit(name: String, email: String, password: String, registering: Bool, token: String? = nil) {
        passwordField.text = nil
        Task { [weak self] in await self?.model.submit(name: name, email: email, password: password, registering: registering, token: token) }
    }
}

extension AuthViewController: UITextViewDelegate {
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        onDocument?(URL)
        return false
    }
}
