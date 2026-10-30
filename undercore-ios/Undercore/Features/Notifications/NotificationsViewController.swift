import UIKit
import SafariServices
import UserNotifications
import UndercoreCore

final class NotificationsViewController: FormViewController, UIScrollViewDelegate {
    var onReconnect: (() -> Void)?

    private let pushButton = PrimaryButton("Включить уведомления", primary: false)
    private let offlineBanner = OfflineBannerView()
    private var isOffline = false
    func updateConnectivity(offline: Bool, savedAt: Date?) {
        isOffline = offline; model.isOffline = offline; messengers?.isOffline = offline
        loadViewIfNeeded()
        offlineBanner.update(savedAt: savedAt); offlineBanner.isHidden = !offline
        if offline { cancelVisibleReadCheck(); markingTask?.cancel(); stopRefresh() }
        render(); renderMessengerConnections()
    }
    func refreshAfterReconnect() { reload() }

    override var horizontalContentInset: CGFloat { Theme.screenInset }
    override var topContentInset: CGFloat { 0 }
    private let messengers: MessengerConnectionsViewModel?
    private let messengerPoller = BoundedPoller()
    private let messengerCard = UIStackView()
    private let messengerHint = UILabel()
    private var messengerButtons: [MessengerChannel: MessengerConnectionButton] = [:]
    private let model: NotificationsViewModel
    private let content = StableCardStack()
    private let emptyLabel = EmptyStateView("Пока нет уведомлений", symbol: "bell")
    private var renderedItems: [UserNotification] = []
    private let refresh = DeliberateRefreshControl()
    private var visibilityTask: Task<Void, Never>?
    private var visibilityCandidates = Set<String>()
    #if DEBUG
    private(set) var visibilityScheduleCount = 0
    #endif
    private var markingTask: Task<Void, Never>?
    private var isVisible = false
    private var attemptedReads = Set<String>()
    private let archive = PrimaryButton("Все уведомления на сайте", primary: false)
    private lazy var readAll = UIBarButtonItem(title: "Прочитать всё", style: .plain, target: self, action: #selector(markAll))
    init(model: NotificationsViewModel, messengers: MessengerConnectionsViewModel? = nil) {
        self.model = model; self.messengers = messengers
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Уведомления"
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = readAll
        view.backgroundColor = .systemGroupedBackground
        scroll.delegate = self
        refresh.attach(to: scroll) { [weak self] in self?.reload() }
        archive.addTarget(self, action: #selector(openArchive), for: .touchUpInside)
        content.axis = .vertical; content.spacing = Theme.gap
        emptyLabel.accessibilityIdentifier = "notifications-empty-state"
        stack.addArrangedSubview(offlineBanner)
        pushButton.addAction(UIAction { _ in Task { await PushNotificationsController.shared.requestPermission() } }, for: .touchUpInside)
        stack.addArrangedSubview(pushButton)
        NotificationCenter.default.addObserver(self, selector: #selector(renderPush), name: PushNotificationsController.changed, object: nil)
        renderPush()
        configureMessengers()
        stack.addArrangedSubview(content); stack.addArrangedSubview(emptyLabel); stack.addArrangedSubview(archive); addFeedback()
        model.onChange = { [weak self] in self?.render() }
        render()
    }
    @objc private func renderPush() {
        let push = PushNotificationsController.shared
        let enabled = [.authorized, .provisional, .ephemeral].contains(push.status)
        pushButton.configuration?.title = push.message ?? (enabled ? "Уведомления включены" : (push.status == .denied ? "Разрешить уведомления в настройках" : "Включить уведомления"))
        pushButton.configuration?.image = UIImage(systemName: enabled ? "bell.badge" : "bell")
        pushButton.configuration?.imagePadding = 8
        pushButton.isEnabled = !enabled || push.message != nil
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reload() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); isVisible = true; refreshConnections(); attemptedReads.removeAll(); scheduleVisibleReads()
        NotificationCenter.default.addObserver(self, selector: #selector(sceneActive), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneInactive), name: UIScene.willDeactivateNotification, object: nil)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); isVisible = false; stopRefresh()
        cancelVisibleReadCheck(); markingTask?.cancel()
        NotificationCenter.default.removeObserver(self, name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIScene.willDeactivateNotification, object: nil)
    }
    @objc private func sceneActive() { refreshConnections(); scheduleVisibleReads() }
    @objc private func sceneInactive() { stopRefresh(); cancelVisibleReadCheck(); markingTask?.cancel() }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); scheduleVisibleReads() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scheduleVisibleReads() }
    private var canObserve: Bool {
        guard !isOffline, isVisible, view.window?.windowScene?.activationState == .foregroundActive else { return false }
        var parent: UIViewController? = self
        while let controller = parent {
            if controller.presentedViewController != nil { return false }; parent = controller.parent
        }
        return true
    }
    func visibleUnreadIDs(excludingAttempted: Bool = true) -> [String] {
        guard canObserve, !model.state.isBusy else { return [] }
        let viewport = CGRect(x: scroll.contentOffset.x, y: scroll.contentOffset.y + scroll.adjustedContentInset.top,
                              width: scroll.bounds.width, height: max(0, scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom))
        return model.items.filter { item in
            guard !item.isRead, (!excludingAttempted || !attemptedReads.contains(item.id)), let card = content.card(for: item.id) else { return false }
            let frame = card.convert(card.bounds, to: scroll)
            return frame.height > 0 && viewport.intersection(frame).height >= min(120, frame.height * 0.5)
        }.map(\.id)
    }
    private func cancelVisibleReadCheck() {
        visibilityTask?.cancel(); visibilityTask = nil; visibilityCandidates.removeAll()
    }
    private func scheduleVisibleReads() {
        guard canObserve, markingTask == nil else { cancelVisibleReadCheck(); return }
        let candidates = Set(visibleUnreadIDs())
        guard candidates != visibilityCandidates else { return }
        cancelVisibleReadCheck()
        guard !candidates.isEmpty else { return }
        visibilityCandidates = candidates
        #if DEBUG
        visibilityScheduleCount += 1
        #endif
        visibilityTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation() } catch { return }
            guard let self else { return }
            self.visibilityTask = nil; self.visibilityCandidates.removeAll()
            guard self.canObserve else { return }
            let ids = self.visibleUnreadIDs().filter { candidates.contains($0) }
            guard !ids.isEmpty else { return }
            self.attemptedReads.formUnion(ids)
            self.markingTask = Task { [weak self] in
                guard let self else { return }
                await self.model.markVisibleRead(ids)
                self.markingTask = nil; self.scheduleVisibleReads()
            }
        }
    }
    @objc private func reload() {
        if isOffline { onReconnect?() }
        refreshConnections(); attemptedReads.removeAll()
        Task { [weak self] in await self?.model.load() }
    }
    @objc private func openArchive() {
        guard !isOffline else { return }
        present(SFSafariViewController(url: AppConfiguration.notificationsWebsiteURL), animated: true)
    }
    @objc private func markAll() { Task { [weak self] in await self?.model.markAllRead() } }
    private func render() {
        let ids = model.items.map(\.id)
        let update = {
            self.content.reconcile(ids) { _ in
                let card = NotificationCardView(frame: .zero)
                return card
            }
            for item in self.model.items {
                (self.content.card(for: item.id) as? NotificationCardView)?.update(item, busy: self.model.state.isBusy)
            }
            self.content.isHidden = ids.isEmpty
            self.emptyLabel.isHidden = !ids.isEmpty || self.model.state.isBusy || self.model.state.message != nil
        }
        if renderedItems != model.items {
            content.preservingReadingPosition(in: scroll, keeping: ids, changes: update)
            renderedItems = model.items
        } else { update() }
        archive.isEnabled = !isOffline
        readAll.isEnabled = !isOffline && model.unreadCount > 0 && !model.state.isBusy
        if !model.state.isBusy { refresh.endRefreshing() }
        feedback(model.state, controls: [])
        scheduleVisibleReads()
    }
    private func configureMessengers() {
        guard let messengers else { return }
        CardText.style(messengerCard)
        messengerHint.text = "Подключите бот уведомлений, чтобы оставаться на связи"
        messengerHint.font = .preferredFont(forTextStyle: .subheadline)
        messengerHint.adjustsFontForContentSizeCategory = true
        messengerHint.textColor = .secondaryLabel; messengerHint.numberOfLines = 0
        messengerCard.addArrangedSubview(messengerHint)
        for channel in MessengerChannel.allCases {
            let button = MessengerConnectionButton()
            button.addAction(UIAction { [weak self] _ in self?.selectMessenger(channel) }, for: .touchUpInside)
            messengerButtons[channel] = button; messengerCard.addArrangedSubview(button)
        }
        stack.addArrangedSubview(messengerCard)
        messengers.onChange = { [weak self] in self?.renderMessengerConnections() }
        messengers.onError = { [weak self] in self?.showMessengerError($0) }
        renderMessengerConnections()
    }
    private func renderMessengerConnections() {
        guard let messengers else { return }
        for channel in MessengerChannel.allCases {
            guard let button = messengerButtons[channel] else { continue }
            let status = messengers.connections[channel]
            var appearance = UIListContentConfiguration.subtitleCell()
            appearance.text = channel.title
            appearance.image = UIImage(systemName: channel == .telegram ? "paperplane" : "bubble.left")
            appearance.imageProperties.preferredSymbolConfiguration = .init(pointSize: 24, weight: .regular, scale: .medium)
            appearance.imageProperties.reservedLayoutSize = .init(width: 32, height: 32)
            appearance.imageToTextPadding = 12
            appearance.textToSecondaryTextVerticalPadding = 4
            appearance.directionalLayoutMargins = .init(top: 10, leading: 0, bottom: 10, trailing: 0)
            appearance.imageProperties.tintColor = .label
            appearance.textProperties.font = .preferredFont(forTextStyle: .body)
            appearance.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            appearance.secondaryTextProperties.color = .secondaryLabel
            let busy = messengers.busy.contains(channel)
            if busy { appearance.secondaryText = "Проверяем…" }
            else if messengers.errors[channel] != nil || status == nil { appearance.secondaryText = "Не удалось проверить · Повторить" }
            else if status?.connected == true { appearance.secondaryText = ["Подключён", status?.accountLabel].compactMap { $0 }.joined(separator: " · ") }
            else if status?.available == false { appearance.secondaryText = "Временно недоступно" }
            else { appearance.secondaryText = messengers.awaitingConnection.contains(channel) ? "Ожидаем подключения" : "Подключить" }
            button.update(appearance, busy: busy)
            button.isEnabled = !isOffline && !messengers.busy.contains(channel) && (status?.available != false || status?.connected == true || messengers.errors[channel] != nil)
        }
    }
    @objc private func stopRefresh() {
        messengerPoller.cancel()
        renderMessengerConnections()
    }

    @objc private func refreshConnections() {
        guard let messengers, isVisible, isViewLoaded, view.window != nil else { return }
        // Refresh once on return, then briefly observe delayed bot webhook confirmation.
        messengerPoller.start(plan: .messengerConnections, while: { [weak self] in
            guard let self else { return false }
            return !self.isOffline && self.isVisible
        }, refresh: { [weak self, weak messengers] in
            guard let self, let messengers else { return false }
            await messengers.refresh()
            self.renderMessengerConnections()
            return !messengers.awaitingConnection.isEmpty
        })
    }
    private func selectMessenger(_ channel: MessengerChannel) {
        guard !isOffline, let messengers, !messengers.busy.contains(channel) else { return }
        guard messengers.errors[channel] == nil, let status = messengers.connections[channel] else {
            refreshConnections(); return
        }
        if status.connected {
            let alert = UIAlertController(title: "Отключить \(channel.title)?", message: "Уведомления Undercore больше не будут приходить в этот мессенджер. Его можно подключить снова в любое время.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отключить", style: .destructive) { [weak self] _ in
                guard self?.isVisible == true else { return }
                Task { await messengers.disconnect(channel) }
            })
            alert.addAction(UIAlertAction(title: CommonText.cancel, style: .cancel))
            present(alert, animated: true)
        } else if status.available {
            let alert = UIAlertController(title: "Подключить \(channel.title)", message: "Откроется бот Undercore. Нажмите «Начать» в чате, затем вернитесь в приложение — мы проверим подключение.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Открыть бота", style: .default) { [weak self] _ in
                guard let self else { return }
                Task { [self] in
                    guard let url = await messengers.connect(channel), self.view.window != nil else { return }
                    UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                        guard !opened else { return }
                        DispatchQueue.main.async {
                            self?.showMessengerError("Не удалось открыть мессенджер. Убедитесь, что он установлен, и попробуйте ещё раз.")
                        }
                    }
                }
            })
            alert.addAction(UIAlertAction(title: CommonText.cancel, style: .cancel))
            present(alert, animated: true)
        }
    }
    private func showMessengerError(_ message: String) {
        guard view.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Не удалось выполнить действие", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Понятно", style: .default))
        present(alert, animated: true)
    }

}

/// Native list layout reserves an equal image column regardless of SF Symbol width.
private final class MessengerConnectionButton: UIButton {
    private let content = UIListContentView(configuration: .subtitleCell())
    private let activity = UIActivityIndicatorView(style: .medium)
    init() {
        super.init(frame: .zero)
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        activity.translatesAutoresizingMaskIntoConstraints = false
        activity.hidesWhenStopped = true
        addSubview(content); addSubview(activity)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            activity.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            activity.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    func update(_ appearance: UIListContentConfiguration, busy: Bool) {
        var appearance = appearance
        if busy { appearance.imageProperties.tintColor = .clear }
        content.configuration = appearance
        if busy { activity.startAnimating() } else { activity.stopAnimating() }
        accessibilityLabel = appearance.text
        accessibilityValue = appearance.secondaryText
    }
}
