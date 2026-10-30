import UIKit
import UndercoreCore

/// Native connection tab. The system owns the tab bar, menus and glass buttons.
final class VPNViewController: UIViewController {
    private let tunnel: IOSTunnelController
    private let repository: ConfigurationRepository
    private let client: APIClient
    private let ownerID: Int
    private let statusLabel = CardText.label(.title2)
    private let statusDetail = CardText.label(.subheadline)
    private let statusIcon = UIImageView()
    private let picker = UIButton(type: .system)
    private let connectButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let messageLabel = CardText.label(.footnote)
    private var items: [VPNConfiguration] = []
    private var automaticAvailable = false
    private var selectedID: String?
    private var page = 0
    private var lastPage = 1
    private var loading = false
    private var loadMessage: String?
    private var loadTask: Task<Void, Never>?
    private var foreground: NSObjectProtocol?

    init(tunnel: IOSTunnelController, repository: ConfigurationRepository, client: APIClient, ownerID: Int) {
        self.tunnel = tunnel; self.repository = repository; self.client = client; self.ownerID = ownerID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    deinit { if let foreground { NotificationCenter.default.removeObserver(foreground) }; loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Keep the screen heading independent from the navigation controller's tab title.
        navigationItem.title = "Undercore"
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = .systemGroupedBackground
        configureLayout()
        connectButton.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .touchUpInside)
        moreButton.addAction(UIAction { [weak self] _ in self?.load(reset: false) }, for: .touchUpInside)
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewIfLoaded?.window != nil else { return }
                await self.tunnel.refresh()
                self.render()
            }
        }
    }

    private func configureLayout() {
        let scroll = UIScrollView()
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let body = UIView(); body.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(body)

        let caption = CardText.label(.footnote)
        caption.text = "Подключение"; caption.textColor = .secondaryLabel
        var selection = UIButton.Configuration.plain()
        selection.background.backgroundColor = .secondarySystemGroupedBackground
        selection.background.cornerRadius = 22
        selection.contentInsets = .init(top: 16, leading: 18, bottom: 16, trailing: 18)
        selection.image = UIImage(systemName: "chevron.up.chevron.down")
        selection.imagePlacement = .trailing; selection.imagePadding = 12
        selection.titleAlignment = .leading; selection.titlePadding = 4
        selection.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = .preferredFont(forTextStyle: .body); return attributes
        }
        selection.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = .preferredFont(forTextStyle: .footnote); attributes.foregroundColor = .secondaryLabel; return attributes
        }
        picker.configuration = selection; picker.showsMenuAsPrimaryAction = true
        picker.contentHorizontalAlignment = .fill
        picker.accessibilityIdentifier = "vpn.configuration-picker"
        moreButton.configuration = .plain(); moreButton.configuration?.title = "Ещё конфигурации"
        let selectionStack = UIStackView(arrangedSubviews: [caption, picker, moreButton])
        selectionStack.axis = .vertical; selectionStack.spacing = 8

        statusIcon.contentMode = .scaleAspectFit
        statusIcon.isAccessibilityElement = false
        statusIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 96, weight: .light)
        statusIcon.heightAnchor.constraint(equalToConstant: 116).isActive = true
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "vpn.status"
        statusDetail.textAlignment = .center; statusDetail.textColor = .secondaryLabel
        let center = UIStackView(arrangedSubviews: [statusIcon, statusLabel, statusDetail])
        center.axis = .vertical; center.alignment = .center; center.spacing = 12
        center.setCustomSpacing(24, after: statusIcon)
        statusLabel.widthAnchor.constraint(lessThanOrEqualTo: center.widthAnchor).isActive = true
        statusDetail.widthAnchor.constraint(lessThanOrEqualTo: center.widthAnchor).isActive = true

        var primary: UIButton.Configuration
        if #available(iOS 26.0, *) { primary = .prominentGlass() }
        else { primary = .filled() }
        primary.baseBackgroundColor = Theme.blue; primary.baseForegroundColor = .white
        primary.cornerStyle = .capsule; primary.buttonSize = .large
        primary.imagePadding = 10
        primary.contentInsets = .init(top: 18, leading: 24, bottom: 18, trailing: 24)
        primary.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = .preferredFont(forTextStyle: .headline); return attributes
        }
        connectButton.configuration = primary
        connectButton.accessibilityIdentifier = "vpn.connect"
        messageLabel.textColor = .secondaryLabel; messageLabel.textAlignment = .center
        let footer = UIStackView(arrangedSubviews: [messageLabel, connectButton])
        footer.axis = .vertical; footer.spacing = 14

        for element in [selectionStack, center, footer] {
            element.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(element)
            element.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Theme.screenInset).isActive = true
            element.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Theme.screenInset).isActive = true
        }
        let viewportHeight = body.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        viewportHeight.priority = .defaultHigh
        let centered = statusIcon.centerYAnchor.constraint(equalTo: body.centerYAnchor, constant: -48)
        centered.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor), viewportHeight,
            selectionStack.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
            picker.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            center.topAnchor.constraint(greaterThanOrEqualTo: selectionStack.bottomAnchor, constant: 28), centered,
            footer.topAnchor.constraint(greaterThanOrEqualTo: center.bottomAnchor, constant: 28),
            footer.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -24),
            connectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tunnel.onChange = { [weak self] in self?.render() }
        render()
        load(reset: true)
        Task { await tunnel.refresh() }
    }
    func updateConnectivity() { render() }
    private func available(_ item: VPNConfiguration) -> Bool {
        item.canDownload && !item.isDeleting && !item.isSwitchingProtocol && ["wireguard", "amneziawg"].contains(item.protocolName)
    }
    private func load(reset: Bool) {
        guard !loading else { return }
        loading = true; loadMessage = nil; render()
        let next = reset ? 1 : page + 1
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loading = false; self.render() }
            do {
                let result = try await self.repository.page(next)
                try Task.checkCancellation()
                guard result.pagination.page == next, result.pagination.lastPage >= next else { throw ClientError.invalidResponse }
                if reset { self.items = []; self.automaticAvailable = result.automaticConnectionAvailable == true }
                for item in result.configurations {
                    if let index = self.items.firstIndex(where: { $0.id == item.id }) { self.items[index] = item }
                    else { self.items.append(item) }
                }
                self.page = next; self.lastPage = result.pagination.lastPage
                if let selectedID, !self.items.contains(where: { $0.id == selectedID && self.available($0) }) { self.selectedID = nil }
                if self.selectedID == nil && !self.automaticAvailable {
                    let usable = self.items.filter(self.available)
                    if let active = self.tunnel.configurationID, usable.contains(where: { $0.id == active }) { self.selectedID = active }
                    else if usable.count == 1 && self.page == self.lastPage { self.selectedID = usable[0].id }
                }
                self.loadMessage = self.items.isEmpty && !self.automaticAvailable ? "Пока нет подключений. Добавьте устройство в подписку во вкладке «Конфигурации»." : nil
            } catch is CancellationError { }
            catch ClientError.expiredSession { self.tunnel.onSessionExpired?() }
            catch { self.loadMessage = readableError(error) }
        }
    }
    private func toggle() {
        if tunnel.isActive || tunnel.isBusy { tunnel.disconnect(); return }
        guard (selectedID == nil && automaticAvailable) || items.contains(where: { $0.id == selectedID && available($0) }) else { return }
        Task { await tunnel.connect(selectedID: selectedID, deviceName: UIDevice.current.model, ownerID: ownerID, repository: repository, client: client) }
    }
    private func render() {
        guard isViewLoaded else { return }
        if tunnel.isActive, let id = tunnel.configurationID {
            selectedID = tunnel.isAutomaticConnection ? nil : id
        }
        let connected = tunnel.status == .connected
        let transitioning = tunnel.isBusy || [.connecting, .reasserting, .disconnecting].contains(tunnel.status)
        statusLabel.text = tunnel.statusText
        statusIcon.image = UIImage(systemName: tunnel.internetVerified ? "checkmark.shield.fill" : "shield.lefthalf.filled")
        statusIcon.tintColor = tunnel.internetVerified ? Theme.blue : .tertiaryLabel
        statusDetail.text = connected ? tunnel.healthText : (transitioning ? "Это может занять несколько секунд" : "Нажмите кнопку, чтобы включить VPN")
        connectButton.configuration?.showsActivityIndicator = transitioning
        let selected = items.first { $0.id == selectedID }
        picker.configuration?.title = selected?.displayName ?? (selectedID != nil ? "Текущее подключение" : (automaticAvailable ? "Автоматически" : "Выбрать конфигурацию"))
        picker.configuration?.subtitle = selected?.applicationName ?? (selectedID == nil && automaticAvailable ? "Этот iPhone" : nil)
        picker.configuration?.showsActivityIndicator = loading
        picker.accessibilityLabel = "Подключение"
        picker.accessibilityValue = selected.map { "\($0.displayName), \($0.applicationName)" } ?? (automaticAvailable ? "Автоматически, этот iPhone" : "Не выбрано")
        var actions: [UIMenuElement] = []
        if automaticAvailable {
            actions.append(UIAction(title: "Автоматически — этот iPhone", state: selectedID == nil ? .on : .off) { [weak self] _ in
                self?.selectedID = nil; self?.render()
            })
        }
        actions += items.map { item in
            UIAction(title: "\(item.displayName) · \(item.applicationName)", attributes: available(item) ? [] : [.disabled], state: selectedID == item.id ? .on : .off) { [weak self] _ in
                self?.selectedID = item.id; self?.render()
            }
        }
        picker.menu = UIMenu(children: actions)
        picker.isEnabled = !loading && !tunnel.isBusy && !tunnel.isActive && (automaticAvailable || !items.isEmpty)
        connectButton.configuration?.title = tunnel.isBusy ? "Отменить" : (tunnel.isActive ? "Отключиться" : "Подключиться")
        connectButton.isEnabled = tunnel.isActive || tunnel.isBusy || (!loading && ((selectedID == nil && automaticAvailable) || selected.map(available) == true))
        moreButton.isHidden = page >= lastPage || page == 0
        moreButton.isEnabled = !loading
        messageLabel.text = tunnel.message ?? loadMessage ?? (client.isOffline && !tunnel.isActive && !tunnel.isBusy ? "Данные пока не обновлены. Нажмите «Подключиться», чтобы проверить связь с Undercore." : nil)
        messageLabel.isHidden = messageLabel.text == nil
    }
}

/// Keep the same native account action on every screen pushed inside a main tab.
final class AccountNavigationController: UINavigationController, UINavigationControllerDelegate {
    var onAccount: (() -> Void)?
    private lazy var accountButton: UIBarButtonItem = {
        let button = UIBarButtonItem(image: UIImage(systemName: "person.crop.circle"), primaryAction: UIAction { [weak self] _ in self?.onAccount?() })
        button.accessibilityLabel = "Аккаунт"
        button.accessibilityIdentifier = "navigation.account"
        return button
    }()
    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }
    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        let otherActions = (viewController.navigationItem.rightBarButtonItems ?? []).filter { $0 !== accountButton }
        viewController.navigationItem.rightBarButtonItems = [accountButton] + otherActions
    }
}
