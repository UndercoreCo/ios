import UIKit

final class PrimaryButton: UIButton {
    init(_ title: String, primary: Bool = true) {
        super.init(frame: .zero)
        var config = primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        config.baseBackgroundColor = Theme.blue
        config.cornerStyle = .large
        config.contentInsets = .init(top: 16, leading: 16, bottom: 16, trailing: 16)
        configuration = config
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
}
final class InputField: UITextField, UITextFieldDelegate {
    weak var nextField: UITextField?
    var onReturn: (() -> Void)?
    init(_ placeholder: String, contentType: UITextContentType? = nil, secure: Bool = false) {
        super.init(frame: .zero)
        self.placeholder = placeholder
        textContentType = contentType
        isSecureTextEntry = secure
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        autocorrectionType = .no
        autocapitalizationType = .none
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = Theme.radius
        leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        leftViewMode = .always
        heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.fieldHeight).isActive = true
        accessibilityLabel = placeholder
        delegate = self
        returnKeyType = .done
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: self, action: #selector(hideKeyboard))]
        toolbar.items?.last?.accessibilityLabel = "Скрыть клавиатуру"
        toolbar.sizeToFit()
        inputAccessoryView = toolbar
    }
    @objc private func hideKeyboard() { resignFirstResponder() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let nextField, !nextField.isHidden, nextField.isEnabled { nextField.becomeFirstResponder() }
        else { resignFirstResponder(); onReturn?() }
        return false
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
}
class FormViewController: UIViewController {
    var horizontalContentInset: CGFloat { Theme.inset }
    var topContentInset: CGFloat { Theme.inset }
    let scroll = UIScrollView()
    let stack = UIStackView()
    let messageLabel = UILabel()
    let activity = UIActivityIndicatorView(style: .medium)
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if #available(iOS 17.0, *) { view.keyboardLayoutGuide.usesBottomSafeArea = false }
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = Theme.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: horizontalContentInset),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -horizontalContentInset),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: topContentInset),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.inset),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -horizontalContentInset * 2)
        ])
        messageLabel.font = .preferredFont(forTextStyle: .callout)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.textColor = .secondaryLabel
        activity.hidesWhenStopped = true
    }
    /// A fixed form centered above a separate footer, with keyboard-aware bounds.
    func centerContent(footer: UIView) {
        if #available(iOS 17.0, *) { view.keyboardLayoutGuide.usesBottomSafeArea = true }
        stack.removeFromSuperview()
        scroll.removeFromSuperview()
        view.addSubview(stack)
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)
        let region = UILayoutGuide(); view.addLayoutGuide(region)
        let center = stack.centerYAnchor.constraint(equalTo: region.centerYAnchor)
        center.priority = .defaultHigh
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.inset),
            footer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.inset),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            region.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            region.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -Theme.gap),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.inset),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.inset),
            stack.topAnchor.constraint(greaterThanOrEqualTo: region.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: region.bottomAnchor), center
        ])
    }
    func addText(_ text: String, style: UIFont.TextStyle = .body) {
        let label = UILabel()
        label.text = text; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(label)
    }
    func addFeedback(to container: UIStackView? = nil) {
        let container = container ?? stack
        container.addArrangedSubview(activity); container.addArrangedSubview(messageLabel)
    }
    func feedback(_ state: ScreenState, controls: [UIControl]) {
        messageLabel.text = state.message
        state.isBusy ? activity.startAnimating() : activity.stopAnimating()
        controls.forEach { $0.isEnabled = !state.isBusy }
        if let message = state.message { UIAccessibility.post(notification: .announcement, argument: message) }
    }
}

/// Appears only while requests or server-side device operations remain active.
final class OperationStatusView: UIStackView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let waitingIcon = UIImageView(image: UIImage(systemName: "clock"))
    private let label = UILabel()
    private let cancel = UIButton(type: .system)
    private var previousText: String?
    var onCancel: (() -> Void)?
    init() {
        super.init(frame: .zero)
        axis = .horizontal; alignment = .center; spacing = 10
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = .init(top: 12, left: 14, bottom: 12, right: 12)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16; layer.cornerCurve = .continuous
        accessibilityIdentifier = "package-operation-status"
        spinner.color = Theme.blue
        waitingIcon.tintColor = .secondaryLabel; waitingIcon.contentMode = .scaleAspectFit
        for indicator in [spinner, waitingIcon] {
            let width = indicator.widthAnchor.constraint(equalToConstant: 20)
            width.priority = UILayoutPriority(999); width.isActive = true
        }
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark.circle.fill")
        config.baseForegroundColor = .secondaryLabel
        cancel.configuration = config; cancel.accessibilityLabel = "Отменить загрузку"
        let width = cancel.widthAnchor.constraint(equalToConstant: 44); width.priority = UILayoutPriority(999); width.isActive = true
        let height = cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44); height.priority = UILayoutPriority(999); height.isActive = true
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        [spinner, waitingIcon, label, cancel].forEach { addArrangedSubview($0) }
        isHidden = true
    }
    required init(coder: NSCoder) { fatalError("Use programmatic layout") }
    func update(messages: [String], waiting: String?, cancellable: Bool) {
        isHidden = messages.isEmpty
        guard !messages.isEmpty else { spinner.stopAnimating(); previousText = nil; return }
        spinner.isHidden = waiting != nil; waitingIcon.isHidden = waiting == nil
        if waiting == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        cancel.isHidden = !cancellable
        let text = (messages + (waiting.map { [$0] } ?? [])).joined(separator: "\n")
        label.text = text
        if previousText != text {
            previousText = text
            if window != nil { UIAccessibility.post(notification: .announcement, argument: text) }
        }
    }
}

/// UIKit owns the tab controls, sizing, glass material and interactive animations.
final class AppTabBarController: UITabBarController {
    private(set) var rootSections: [UIViewController] = []
    func configure(_ controllers: [UIViewController]) {
        rootSections = controllers
        if #available(iOS 27.0, *) {
            let identifiers = [0: "configurations", 1: "notifications", 2: "profile", 3: "connection"]
            tabs = controllers.map { controller in
                let item = controller.tabBarItem!
                return UITab(title: item.title ?? "", image: item.image, identifier: identifiers[item.tag] ?? "section-\(item.tag)") { _ in controller }
            }
            if controllers.contains(where: { $0.tabBarItem.tag == 2 }) { prominentTabIdentifier = "profile" }
        } else {
            viewControllers = controllers
        }
        if #available(iOS 26.0, *) { tabBarMinimizeBehavior = .never }
    }
    var currentSection: UIViewController? {
        if #available(iOS 27.0, *) { return selectedTab?.viewController }
        return selectedViewController
    }
    func selectSection(_ index: Int) {
        guard rootSections.indices.contains(index) else { return }
        if #available(iOS 27.0, *) { selectedTab = tabs[index] }
        else { selectedIndex = index }
    }
    func selectSection(_ controller: UIViewController) {
        guard let index = rootSections.firstIndex(where: { $0 === controller }) else { return }
        selectSection(index)
    }
    func refreshBadge() {
        if #available(iOS 27.0, *) {
            for (tab, controller) in zip(tabs, rootSections) { tab.badgeValue = controller.tabBarItem.badgeValue }
        }
    }
}

/// UIKit owns the refreshing indicator; attach it only after accepting a released pull.
/// An attached idle UIRefreshControl otherwise arms (and vibrates) at UIKit's own threshold,
/// before our valueChanged handler can reject a short gesture.
final class DeliberateRefreshControl: NSObject {
    let indicator = UIRefreshControl()
    var isRefreshing: Bool { indicator.isRefreshing }
    private weak var scroll: UIScrollView?
    private var action: (() -> Void)?
    private var restingInset: CGFloat = 0
    private var initialTranslation: CGFloat = 0
    private var distanceToTop: CGFloat = 0
    private var lastDistance: CGFloat = 0
    private var lastTravel: CGFloat = 0
    private var gestureActive = false
    private var requestInFlight = false
    // App UX choices, not Apple-prescribed thresholds. Points are independent of pixel density.
    static let minimumDistance: CGFloat = 160
    private static let minimumFingerTravel: CGFloat = 240

    func attach(to scroll: UIScrollView, action: @escaping () -> Void) {
        self.scroll = scroll; self.action = action
        scroll.alwaysBounceVertical = true
        scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
    }
    @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
        handlePan(state: pan.state, translation: pan.translation(in: scroll).y)
    }
    // Kept separate from the recognizer so short, reversed and cancelled gestures can be checked.
    func handlePan(state: UIGestureRecognizer.State, translation: CGFloat) {
        guard let scroll else { return }
        switch state {
        case .began:
            gestureActive = !requestInFlight
            guard gestureActive else { return }
            restingInset = scroll.adjustedContentInset.top
            initialTranslation = translation
            distanceToTop = max(0, scroll.contentOffset.y + restingInset)
            lastDistance = 0; lastTravel = 0
        case .changed:
            guard gestureActive else { return }
            lastDistance = -scroll.contentOffset.y - restingInset
            lastTravel = translation - initialTranslation - distanceToTop
        case .ended:
            guard gestureActive else { return }
            gestureActive = false
            // Do not count scrolling to the top, large-title expansion or UIKit inset changes
            // as finger travel. Returning towards the top before release cancels the pull.
            // UIScrollView can reset translation/offset before delivering .ended to this target.
            // Use the most recent movement, not the maximum, so reversing still cancels.
            let distance = lastDistance
            let travel = lastTravel
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-refresh-gesture") {
                print("REFRESH_GESTURE release: distance=\(distance), travel=\(travel)")
            }
            #endif
            if distance >= Self.minimumDistance && travel >= Self.minimumFingerTravel {
                requestInFlight = true
                scroll.refreshControl = indicator
                indicator.beginRefreshing()
                action?()
            } else { endRefreshing() }
        case .cancelled, .failed:
            guard gestureActive else { return }
            gestureActive = false
            endRefreshing()
        default: break
        }
    }
    func endRefreshing() {
        requestInFlight = false
        indicator.endRefreshing()
        if scroll?.refreshControl === indicator { scroll?.refreshControl = nil }
    }
}

/// Compact, content-sized empty states shared by subscriptions and notifications.
final class EmptyStateView: UIStackView {
    init(_ text: String, symbol: String) {
        super.init(frame: .zero)
        axis = .vertical; alignment = .center; spacing = 16
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = .init(top: 32, left: 12, bottom: 32, right: 12)
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.preferredSymbolConfiguration = .init(pointSize: 32, weight: .regular)
        icon.tintColor = .tertiaryLabel; icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false
        let iconHeight = icon.heightAnchor.constraint(equalToConstant: 40)
        iconHeight.priority = .defaultHigh; iconHeight.isActive = true
        let label = UILabel(); label.text = text; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel; label.textAlignment = .center
        addArrangedSubview(icon); addArrangedSubview(label)
    }
    required init(coder: NSCoder) { fatalError("Use programmatic layout") }
}
