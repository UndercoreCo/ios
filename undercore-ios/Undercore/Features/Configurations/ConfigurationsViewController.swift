import UIKit
import UndercoreCore

final class ConfigurationsViewController: FormViewController {
    var onReconnect: (() -> Void)?

    override var horizontalContentInset: CGFloat { 0 }
    override var topContentInset: CGFloat { 0 }
    private var articles: ArticlesViewModel?
    private var carousel: ArticleCarouselView?
    private let headingLabel = UILabel()
    private let offlineBanner = OfflineBannerView()
    var usesSharedConnectivity = false
    func updateConnectivity(offline: Bool, savedAt: Date?) {
        model.isOffline = offline
        loadViewIfNeeded()
        offlineBanner.update(savedAt: savedAt)
        showOfflineBanner(offline)
        if offline { stopPolling() }
        render()
    }
    func refreshAfterReconnect() { reload() }
    private let network: NetworkStatusObserving
    private var articleOrigin: URL?
    func configureArticles(_ model: ArticlesViewModel, origin: URL) { articles = model; articleOrigin = origin }
    private let model: ConfigurationsViewModel
    private var transferTask: Task<Void, Never>?
    private let poller = BoundedPoller()
    private var isVisible = false
    #if DEBUG
    private var previewProtocolShown = false
    private var previewPackageActionShown = false
    #endif
    private let operationStatus = OperationStatusView()
    private var transferMessage: String?
    private var isOffline = false
    private let content = PackagePagerView(horizontalInset: Theme.screenInset)
    private let emptyState = EmptyStateView("Пока нет оплаченных подписок", symbol: "rectangle.stack")
    private let emptyStateHost = UIView()
    private let purchase = PrimaryButton("Купить")
    // The future purchase coordinator supplies this action; no purchase entry point is exposed today.
    var onPurchase: (() -> Void)? { didSet { if isViewLoaded { render() } } }
    private var renderedPackages: [VPNPage.Package] = []
    private let refresh = DeliberateRefreshControl()
    private let moreHost = UIStackView()
    private let more = PrimaryButton("Показать ещё", primary: false)
    init(model: ConfigurationsViewModel, network: NetworkStatusObserving? = nil) {
        self.model = model; self.network = network ?? NetworkStatusMonitor()
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = CommonText.configurations
        #if UNDERCORE_VPN
        navigationItem.title = CommonText.configurations
        #else
        navigationItem.title = "Undercore"
        #endif
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        if let articles, let origin = articleOrigin {
            let carousel = ArticleCarouselView(origin: origin)
            self.carousel = carousel
            stack.addArrangedSubview(carousel)
            carousel.onSelect = { [weak self, weak articles] id in
                guard let self, let articles else { return }
                let detail = ArticleViewController(id: id, model: articles, origin: origin)
                let sheet = ArticleSheetController(rootViewController: detail)
                sheet.sheetPresentationController?.detents = [.medium(), .large()]
                sheet.sheetPresentationController?.prefersGrabberVisible = true
                self.present(sheet, animated: true)
            }
            articles.onChange = { [weak self, weak carousel, weak articles] in
                carousel?.update(articles?.items ?? [])
                self?.render()
            }
            carousel.update(articles.items)
        }
        headingLabel.text = "Подписки"
        headingLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 24, weight: .bold))
        headingLabel.adjustsFontForContentSizeCategory = true
        headingLabel.numberOfLines = 0
        headingLabel.accessibilityTraits = .header
        let body = UIStackView()
        body.axis = .vertical; body.spacing = Theme.gap
        body.isLayoutMarginsRelativeArrangement = true
        body.insetsLayoutMarginsFromSafeArea = false
        body.layoutMargins = .init(top: 0, left: Theme.screenInset, bottom: 0, right: Theme.screenInset)
        stack.addArrangedSubview(body)
        body.addArrangedSubview(headingLabel)
        body.addArrangedSubview(offlineBanner)
        body.addArrangedSubview(operationStatus)
        body.addArrangedSubview(messageLabel)
        messageLabel.isHidden = true
        operationStatus.onCancel = { [weak self] in self?.transferTask?.cancel() }
        view.backgroundColor = .systemGroupedBackground
        refresh.attach(to: scroll) { [weak self] in self?.reload() }
        more.addTarget(self, action: #selector(loadMore), for: .touchUpInside)
        body.addArrangedSubview(emptyStateHost)
        stack.addArrangedSubview(content)
        moreHost.axis = .vertical
        moreHost.isLayoutMarginsRelativeArrangement = true
        moreHost.insetsLayoutMarginsFromSafeArea = false
        moreHost.layoutMargins = .init(top: 0, left: Theme.screenInset, bottom: 0, right: Theme.screenInset)
        moreHost.addArrangedSubview(more)
        stack.addArrangedSubview(moreHost)
        installEmptyState()
        model.onTransferProgress = { [weak self] message in self?.showTransferProgress(message) }
        model.onTransferError = { [weak self] message in
            let alert = UIAlertController(title: "Не удалось загрузить конфигурацию", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Понятно", style: .default))
            self?.present(alert, animated: true)
        }
        model.onProtocolError = { [weak self] message in
            guard let self, self.isVisible, self.presentedViewController == nil else { return }
            let alert = UIAlertController(title: "Не удалось подтвердить смену", message: message + " Обновите список, чтобы проверить состояние конфигурации.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Понятно", style: .default))
            self.present(alert, animated: true)
        }
        model.onProtocolReady = { [weak self] app in
            guard let self, self.isVisible, self.presentedViewController == nil else { return }
            let alert = UIAlertController(title: "Протокол изменён", message: "Добавьте новую конфигурацию в \(app). Прежняя конфигурация больше не работает. Срок доступа сохранён.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Понятно", style: .default))
            self.present(alert, animated: true)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDeactivated), name: UIScene.willDeactivateNotification, object: nil)
        model.onChange = { [weak self] in self?.render(); self?.startPolling() }
        render(); reload()
        network.onChange = { [weak self] offline in self?.showOfflineBanner(offline) }
        if !usesSharedConnectivity { network.start() }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-loading") {
            DispatchQueue.main.async { [weak self] in self?.showTransferProgress("Готовим QR-код…") }
        }
        #endif
    }
    private func installEmptyState() {
        emptyState.isUserInteractionEnabled = false // Pull to refresh still reaches the scroll view.
        emptyState.accessibilityIdentifier = "packages-empty-state"
        emptyStateHost.isHidden = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        purchase.translatesAutoresizingMaskIntoConstraints = false
        purchase.isHidden = true
        purchase.accessibilityIdentifier = "packages-buy"
        purchase.addAction(UIAction { [weak self] _ in self?.onPurchase?() }, for: .touchUpInside)
        emptyStateHost.addSubview(emptyState); view.addSubview(purchase)
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: emptyStateHost.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: emptyStateHost.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: emptyStateHost.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: emptyStateHost.bottomAnchor),
            purchase.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.screenInset),
            purchase.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.screenInset),
            purchase.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }
    private func showOfflineBanner(_ offline: Bool) {
        isOffline = offline
        updateOperationStatus()
        guard offlineBanner.isHidden == offline else { return }
        content.preservingReadingPosition(in: scroll, keeping: content.ids) {
            offlineBanner.isHidden = !offline
            view.layoutIfNeeded()
        }
        if offline, isVisible {
            UIAccessibility.post(notification: .announcement, argument: offlineBanner.accessibilityLabel)
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { [weak self] in await self?.articles?.refresh() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        startPolling()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        stopPolling()
    }
    @objc private func becameActive(_ notification: Notification) {
        guard isVisible, let scene = notification.object as? UIScene, scene === view.window?.windowScene else { return }
        reload()
    }
    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        stopPolling()
    }
    @objc private func stopPolling() { poller.cancel() }

    private var canObserveOperations: Bool {
        !isOffline && isVisible && view.window?.windowScene?.activationState == .foregroundActive
            && model.hasPendingOperations && !model.observationPaused
    }

    private func startPolling() {
        guard canObserveOperations, !poller.isRunning else { return }
        poller.start(plan: .pendingDevices, while: { [weak self] in
            self?.canObserveOperations == true
        }, refresh: { [weak self] in
            guard let model = self?.model else { return false }
            return await model.refreshPendingOperations()
        }, onExhausted: { [weak self] in
            self?.model.pauseObservation()
        })
    }
    @objc private func reload() {
        if isOffline { onReconnect?() }

        Task { [weak self] in await self?.model.load(reset: true) }
        Task { [weak self] in await self?.articles?.refresh() }
    }
    @objc private func loadMore() { Task { [weak self] in await self?.model.load(reset: false) } }
    private func render() {
        let ids = model.packages.map(\.id)
        let update = { [self] in
            self.content.reconcile(ids) { [weak self] _ in
                let card = PackageCardView(frame: .zero)
                card.onRename = { [weak self] config in self?.rename(config) }
                card.onSwitch = { [weak self] config, target in self?.confirmProtocolSwitch(config, to: target) }
                card.onDelete = { [weak self] config in self?.confirmRemoval(config) }
                card.onDownload = { [weak self] config, qr in
                    self?.transferTask = Task { [weak self] in await self?.model.download(config, qrCode: qr) }
                }
                return card
            }
            for package in self.model.packages {
                guard let card = self.content.card(for: package.id) as? PackageCardView else { continue }
                let pending = Set(package.slots.filter { self.model.pendingActivation(packageID: package.id, slot: $0.number) != nil }.map(\.number))
                card.update(package, protocols: self.model.protocols, busy: self.model.state.isBusy || self.isOffline,
                    removingIDs: self.model.removingIDs, pendingSlots: pending)
                card.onActivate = { [weak self] slot in
                    guard let self, let current = self.model.packages.first(where: { $0.id == package.id }) else { return }
                    self.chooseProtocol(package: current, slot: slot)
                }
            }
            self.content.isHidden = ids.isEmpty

        }
        if renderedPackages != model.packages {
            content.preservingReadingPosition(in: scroll, keeping: ids, changes: update)
            renderedPackages = model.packages
        } else { update() }
        let isEmpty = ids.isEmpty && model.page > 0 && !model.state.isBusy && model.state.message == nil
        emptyStateHost.isHidden = !isEmpty
        purchase.isHidden = !isEmpty || onPurchase == nil
        purchase.isEnabled = onPurchase != nil
        headingLabel.isHidden = ids.isEmpty
        carousel?.isHidden = articles?.items.isEmpty ?? true
        view.backgroundColor = isEmpty ? .systemBackground : .systemGroupedBackground
        moreHost.isHidden = ids.isEmpty || model.page >= model.lastPage
        if !model.state.isBusy { refresh.endRefreshing() }
        more.isEnabled = !model.state.isBusy
        messageLabel.text = model.state.message
        messageLabel.isHidden = model.state.message == nil
        updateOperationStatus()
        #if DEBUG
        if !previewPackageActionShown, let package = model.packages.first {
            if ProcessInfo.processInfo.arguments.contains("--preview-removal-confirm"), let config = model.items.first {
                previewPackageActionShown = true
                DispatchQueue.main.async { [weak self] in self?.confirmRemoval(config) }
            } else if ProcessInfo.processInfo.arguments.contains("--preview-slot-choice"), let slot = package.slots.first(where: { $0.canActivate }) {
                previewPackageActionShown = true
                DispatchQueue.main.async { [weak self] in self?.chooseProtocol(package: package, slot: slot.number) }
            }
        }
        if !previewProtocolShown, ProcessInfo.processInfo.arguments.contains("--preview-protocol-confirm"),
           let config = model.items.first, let target = config.switchOptions(from: model.protocols).first {
            previewProtocolShown = true
            DispatchQueue.main.async { [weak self] in self?.confirmProtocolSwitch(config, to: target) }
        }
        if !model.items.isEmpty, ProcessInfo.processInfo.arguments.contains("--preview-scrolled") {
            view.layoutIfNeeded()
            scroll.setContentOffset(CGPoint(x: 0, y: 220), animated: false)
        }
        #endif
    }
    private func showTransferProgress(_ message: String?) {
        transferMessage = message
        updateOperationStatus()
    }
    private func updateOperationStatus() {
        var messages = model.operationMessages
        if let transferMessage, !messages.contains(transferMessage) { messages.append(transferMessage) }
        let waiting = isOffline ? "Ожидаем подключения к интернету." : model.observationPaused ? "Потяните экран вниз, чтобы проверить состояние." : nil
        operationStatus.update(messages: messages, waiting: waiting, cancellable: transferMessage != nil)
    }
    private func confirmProtocolSwitch(_ configuration: VPNConfiguration, to target: VPNProtocolOption) {
        let alert = UIAlertController(title: "Перейти на \(target.label)?",
            message: "Для «\(configuration.displayName)» будет создана новая конфигурация. После смены старое подключение перестанет работать — добавьте новое в \(target.label). Срок доступа и автопродление сохранятся.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CommonText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: "Сменить протокол", style: .default) { [weak self] _ in
            Task { await self?.model.switchProtocol(configuration, to: target) }
        })
        present(alert, animated: true)
    }
    private func chooseProtocol(package: VPNPage.Package, slot: Int) {
        let pending = model.pendingActivation(packageID: package.id, slot: slot)
        let options = model.activationOptions.filter { pending == nil || $0.id == pending?.protocolName }
        let alert = UIAlertController(title: pending == nil ? "Добавить устройство" : "Повторить проверку добавления?",
            message: options.isEmpty ? "Сейчас нет доступного протокола. Обновите список позже."
                : pending == nil ? "Выберите приложение для подключения. Будет занято одно место в подписке."
                : "Отправим тот же запрос. Если устройство уже создано, сервер вернёт его конфигурацию.", preferredStyle: .alert)
        for option in options {
            alert.addAction(UIAlertAction(title: option.label, style: .default) { [weak self] _ in
                Task { await self?.model.activate(packageID: package.id, slot: slot, protocolName: option.id) }
            })
        }
        alert.addAction(UIAlertAction(title: CommonText.cancel, style: .cancel))
        present(alert, animated: true)
    }
    private func confirmRemoval(_ configuration: VPNConfiguration) {
        let alert = UIAlertController(title: "Удалить «\(configuration.displayName)»?",
            message: "Подключение по этой конфигурации перестанет работать. После отзыва доступа место в подписке освободится для другого устройства. Подписка, срок доступа и настройки автопродления сохранятся. Конфигурацию в WireGuard или AmneziaWG нужно убрать вручную.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CommonText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить устройство", style: .destructive) { [weak self] _ in
            Task { await self?.model.remove(configuration) }
        })
        present(alert, animated: true)
    }
    private func rename(_ configuration: VPNConfiguration) {
        let alert = UIAlertController(title: "Название конфигурации", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = configuration.name; $0.placeholder = "Например, мой iPhone" }
        alert.addAction(UIAlertAction(title: CommonText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            Task { await self?.model.rename(configuration, name: name) }
        })
        present(alert, animated: true)
    }
}
