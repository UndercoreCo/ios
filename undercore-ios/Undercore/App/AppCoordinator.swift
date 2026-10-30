import UIKit
import SafariServices
import UndercoreCore

@MainActor final class AppCoordinator {
    let navigation = UINavigationController()
    private let auth: AuthRepository
    #if UNDERCORE_VPN
    private let vpn = IOSTunnelController()
    private weak var vpnScreen: VPNViewController?
    private var accountNavigation: UINavigationController?
    #endif
    private let configurations: ConfigurationRepository
    private let notifications: NotificationRepository
    private var articlesModel: ArticlesViewModel?
    private var notificationsModel: NotificationsViewModel?
    private let client: APIClient
    private let transfer: DocumentTransferService
    private var tabs: AppTabBarController?
    private var configurationsNavigation: UINavigationController?
    private var activeNavigation: UINavigationController {
        #if UNDERCORE_VPN
        if let accountNavigation, accountNavigation.presentingViewController != nil { return accountNavigation }
        #endif
        return tabs?.currentSection as? UINavigationController ?? navigation
    }
    private var account: Account?
    private var pendingConfiguration: String?
    private let network = NetworkStatusMonitor()
    private var reconnecting = false
    private var recoveryTask: Task<Void, Never>?
    private var connectivityUpdate: (() -> Void)?
    private var reloadScreens: (() -> Void)?
    private var loading = false
    private var sessionGeneration = 0
    init(client: APIClient, auth: AuthRepository, configurations: ConfigurationRepository, notifications: NotificationRepository, transfer: DocumentTransferService) {
        self.notifications = notifications; self.client = client; self.auth = auth; self.configurations = configurations; self.transfer = transfer
        navigation.navigationBar.prefersLargeTitles = true
        navigation.view.tintColor = Theme.blue
        client.onOfflineChange = { [weak self] in
            self?.connectivityUpdate?()
            self?.scheduleConnectionRecovery()
        }
        network.onChange = { [weak self] offline in
            guard let self, self.account != nil else { return }
            if offline { self.client.setOffline(true) }
            else if self.client.isOffline { self.reconnect() }
        }
        network.start()
    }
    /// One bounded retry per transition to cached data, including transient VPN route changes.
    private func scheduleConnectionRecovery() {
        recoveryTask?.cancel()
        guard client.isOffline, account != nil else { return }
        let generation = sessionGeneration
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.sessionGeneration == generation, self.client.isOffline,
                  UIApplication.shared.applicationState == .active else { return }
            self.reconnect()
        }
    }
    private func reconnect() {
        guard !reconnecting, !loading, account != nil else { return }
        reconnecting = true
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            defer { self.reconnecting = false }
            do {
                let fresh = try await self.client.verifyOnlineSession()
                guard generation == self.sessionGeneration else { return }
                self.client.setOffline(false)
                if fresh.id != self.account?.id || !fresh.isEmailVerified { self.route(fresh); return }
                self.account = fresh
                await PushNotificationsController.shared.refresh()
                self.connectivityUpdate?(); self.reloadScreens?(); self.refreshNotifications()
            } catch ClientError.expiredSession {
                guard generation == self.sessionGeneration else { return }
                self.sessionExpired()
            } catch ClientError.server(status: 403, message: _, retryAfter: _) {
                guard generation == self.sessionGeneration else { return }
                try? self.client.clearSession()
                self.sessionExpired()
            } catch {
                guard generation == self.sessionGeneration else { return }
                // Keep read-only mode until the server has confirmed the session.
                self.client.setOffline(true)
            }
        }
    }
    func start() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-configurations"),
           let user = try? JSONDecoder().decode(Account.self, from: Data("{\"id\":0,\"name\":\"Rustam\",\"email\":\"preview@example.test\",\"isEmailVerified\":true}".utf8)) {
            route(user)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-auth"),
           let challenge = try? JSONDecoder().decode(RegistrationChallenge.self, from: Data("{\"provider\":\"none\",\"siteKey\":\"\",\"tokenField\":\"smart-token\",\"required\":false}".utf8)) {
            showAuth(challenge)
            return
        }
        #endif
        guard !loading else { return }; loading = true
        #if UNDERCORE_VPN
        navigation.dismiss(animated: false)
        accountNavigation = nil
        #endif
        navigation.setNavigationBarHidden(true, animated: false)
        tabs = nil; configurationsNavigation = nil; notificationsModel = nil
        let generation = sessionGeneration
        let screen = StartupViewController()
        screen.onRetry = { [weak self] in self?.start() }
        navigation.setViewControllers([screen], animated: false)
        Task { [weak self, weak screen] in
            guard let self else { return }
            defer { self.loading = false; screen?.stopLoading() }
            guard let screen else { return }
            await self.restoreSession(on: screen, generation: generation)
        }
    }

    private func restoreSession(on screen: StartupViewController, generation: Int) async {
        do {
            await client.prepareOfflineCache()
            _ = try await auth.prepare()
            guard sessionGeneration == generation else { return }
            do {
                let user = try await auth.currentAccount()
                guard canFinishStartup(screen, generation: generation) else { return }
                client.setOffline(false)
                route(user)
            } catch ClientError.expiredSession {
                let fresh = try await auth.prepare()
                guard canFinishStartup(screen, generation: generation) else { return }
                showAuth(fresh.challenge)
            }
        } catch {
            if error.isOfflineTransportError, let cached = await client.restoreOfflineAccount() {
                guard canFinishStartup(screen, generation: generation) else { return }
                route(cached)
            } else {
                guard canFinishStartup(screen, generation: generation) else { return }
                screen.showError(readableError(error))
            }
        }
    }

    private func canFinishStartup(_ screen: StartupViewController, generation: Int) -> Bool {
        sessionGeneration == generation && navigation.topViewController === screen
    }

    private func showAuth(_ challenge: RegistrationChallenge) {
        sessionGeneration += 1
        account = nil
        PushNotificationsController.shared.unbind(preservePendingOpen: true)
        let model = AuthViewModel(repository: auth, challenge: challenge)
        let screen = AuthViewController(model: model)
        model.onAccount = { [weak self] in self?.route($0) }
        screen.onChallenge = { [weak self, weak screen] callback in
            guard let self, let screen, let url = try? self.client.url(for: APIEndpoints.challenge) else { return }
            let challengeScreen = CaptchaViewController(pageURL: url, tokenField: challenge.tokenField, completion: callback)
            let modal = UINavigationController(rootViewController: challengeScreen)
            modal.modalPresentationStyle = .pageSheet
            modal.sheetPresentationController?.detents = [.medium(), .large()]
            modal.sheetPresentationController?.prefersGrabberVisible = true
            screen.present(modal, animated: true)
        }
        screen.onPasswordRecovery = { [weak self, weak screen] email in
            guard let self, let screen else { return }
            let recovery = PasswordRecoveryViewController(model: PasswordRecoveryViewModel(repository: LiveAccountManagementRepository(client: self.client)), email: email)
            screen.present(UINavigationController(rootViewController: recovery), animated: true)
        }
        screen.onDocument = { [weak screen] url in
            screen?.present(SFSafariViewController(url: url), animated: true)
        }
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.setViewControllers([screen], animated: true)
    }
    private func route(_ user: Account) {
        if account?.id != user.id { articlesModel?.clearCache() }
        sessionGeneration += 1
        account = user
        #if UNDERCORE_VPN
        vpn.bindOwner(user.isEmailVerified ? user.id : nil)
        vpn.onSessionExpired = { [weak self] in self?.sessionExpired() }
        #endif
        let generation = sessionGeneration
        if !user.isEmailVerified {
            showVerification(for: user, generation: generation)
            return
        }
        var repository = configurations
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-configurations") { repository = PreviewConfigurationRepository() }
        #endif
        let model = ConfigurationsViewModel(repository: repository)
        let screen = ConfigurationsViewController(model: model)
        screen.usesSharedConnectivity = true
        screen.onReconnect = { [weak self] in self?.reconnect() }
        model.isOffline = client.isOffline
        let articles = ArticlesViewModel(repository: LiveArticleRepository(client: client), origin: client.baseURL, userID: user.id)
        articlesModel = articles
        articles.onSessionExpired = sessionExpiryHandler(generation: generation)
        screen.configureArticles(articles, origin: client.baseURL)
        model.onSessionExpired = sessionExpiryHandler(generation: generation)
        configureTransfer(model, screen: screen)
        var notificationRepository = notifications
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-configurations") { notificationRepository = PreviewNotificationRepository() }
        #endif
        let notificationModel = NotificationsViewModel(repository: notificationRepository)
        notificationsModel = notificationModel
        notificationModel.isOffline = client.isOffline
        notificationModel.onSessionExpired = sessionExpiryHandler(generation: generation)
        var messengerRepository: MessengerRepository = LiveMessengerRepository(client: client)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-configurations") { messengerRepository = PreviewMessengerRepository() }
        #endif
        let messengerModel = MessengerConnectionsViewModel(repository: messengerRepository)
        messengerModel.isOffline = client.isOffline
        messengerModel.onSessionExpired = sessionExpiryHandler(generation: generation)
        let notificationScreen = NotificationsViewController(model: notificationModel, messengers: messengerModel)
        notificationScreen.onReconnect = { [weak self] in self?.reconnect() }
        let notificationNavigation = sectionNavigation(root: notificationScreen)
        notificationNavigation.tabBarItem = UITabBarItem(title: "Уведомления", image: UIImage(systemName: "bell"), tag: 1)
        notificationModel.onUnreadCount = { [weak self, weak notificationNavigation] count in
            guard self?.sessionGeneration == generation else { return }
            notificationNavigation?.tabBarItem.badgeValue = count > 0 ? String(count) : nil
            self?.tabs?.refreshBadge()
        }
        let profile = ProfileViewController(account: user)
        profile.onDeleteAccount = { [weak self] in self?.showAccountDeletion() }
        profile.onLogout = { [weak self] in self?.logout() }
        let configsNavigation = sectionNavigation(root: screen)
        let profileNavigation = UINavigationController(rootViewController: profile)
        for nav in [configsNavigation, profileNavigation, notificationNavigation] {
            nav.navigationBar.prefersLargeTitles = true
            nav.view.tintColor = Theme.blue
        }
        configsNavigation.tabBarItem = UITabBarItem(title: CommonText.configurations, image: UIImage(systemName: "rectangle.stack"), tag: 0)
        profileNavigation.tabBarItem = UITabBarItem(title: "Профиль", image: UIImage(systemName: "person.crop.circle"), tag: 2)
        let tabs = AppTabBarController()
        #if UNDERCORE_VPN
        let connectionScreen = VPNViewController(tunnel: vpn, repository: repository, client: client, ownerID: user.id)
        vpnScreen = connectionScreen
        let connectionNavigation = sectionNavigation(root: connectionScreen)
        connectionNavigation.navigationBar.prefersLargeTitles = true
        connectionNavigation.view.tintColor = Theme.blue
        connectionNavigation.tabBarItem = UITabBarItem(title: "Подключение", image: UIImage(systemName: "shield"), selectedImage: UIImage(systemName: "shield.fill"))
        connectionNavigation.tabBarItem.tag = 3
        accountNavigation = profileNavigation
        profile.loadViewIfNeeded()
        profile.title = "Аккаунт"
        profile.onDiagnostics = { [weak self, weak profile] source in
            guard let self, let profile else { return }
            Task { @MainActor in
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent("Undercore-diagnostics.json")
                    let report = try await self.vpn.diagnosticReport(client: self.client)
                    try report.write(to: file, options: .atomic)
                    let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = source
                    share.popoverPresentationController?.sourceRect = source.bounds
                    share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: directory) }
                    profile.present(share, animated: true)
                } catch { self.alert("Не удалось подготовить диагностику.") }
            }
        }
        profile.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak profileNavigation] _ in
            profileNavigation?.dismiss(animated: true)
        })
        tabs.configure([connectionNavigation, configsNavigation, notificationNavigation])
        #else
        tabs.configure([configsNavigation, notificationNavigation, profileNavigation])
        #endif
        tabs.view.tintColor = Theme.blue
        if #available(iOS 26.0, *) { tabs.tabBarMinimizeBehavior = .never }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-notifications") { tabs.selectSection(notificationNavigation) }
        #if !UNDERCORE_VPN
        if ProcessInfo.processInfo.arguments.contains("--preview-profile") { tabs.selectSection(profileNavigation) }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--preview-qr"), let qr = try? QRCodeViewController(data: SyntheticConfiguration.make(amnezia: true).data, name: "Тестовый QR-код") {
            configsNavigation.pushViewController(qr, animated: false)
        }
        #endif
        self.tabs = tabs; configurationsNavigation = configsNavigation
        configureConnectivity(screen: screen, notifications: notificationScreen, profile: profile, generation: generation)
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.setViewControllers([tabs], animated: true)
        // Warm metadata for tabs that have not been opened yet, without marking anything read.
        Task { [weak self] in
            await notificationModel.load()
            guard self?.sessionGeneration == generation else { return }
            await messengerModel.refresh()
        }
        PushNotificationsController.shared.bind(client: client, ownerID: user.id)
        refreshNotifications()
        if let id = pendingConfiguration { pendingConfiguration = nil; showConfiguration(id) }
    }
    private func sectionNavigation(root: UIViewController) -> UINavigationController {
        #if UNDERCORE_VPN
        let section = AccountNavigationController(rootViewController: root)
        section.onAccount = { [weak self] in self?.showAccount() }
        return section
        #else
        return UINavigationController(rootViewController: root)
        #endif
    }

    #if UNDERCORE_VPN
    func showAccount() {
        guard let accountNavigation, let tabs, tabs.presentedViewController == nil else { return }
        accountNavigation.modalPresentationStyle = .pageSheet
        tabs.present(accountNavigation, animated: true)
    }
    #endif

    private func sessionExpiryHandler(generation: Int) -> () -> Void {
        { [weak self] in
            guard let self, self.sessionGeneration == generation else { return }
            self.sessionExpired()
        }
    }

    private func showVerification(for user: Account, generation: Int) {
        let model = VerificationViewModel(repository: auth)
        let screen = VerificationViewController(model: model, email: user.email)
        model.onAccount = { [weak self] in self?.route($0) }
        model.onSessionExpired = sessionExpiryHandler(generation: generation)
        screen.onLogout = { [weak self] in self?.logout() }
        screen.onDeleteAccount = { [weak self] in self?.showAccountDeletion() }
        navigation.setNavigationBarHidden(false, animated: false)
        navigation.setViewControllers([screen], animated: true)
    }

    private func configureTransfer(_ model: ConfigurationsViewModel, screen: ConfigurationsViewController) {
        model.onDownload = { [weak self, weak screen] data, name in
            guard let self, let screen, self.activeNavigation.topViewController === screen else { return }
            do { try self.transfer.present(data: data, applicationName: name, from: screen, source: screen.view) }
            catch { self.alert(error.localizedDescription) }
        }
        model.onQRCode = { [weak self, weak screen] data, name in
            guard let self, let screen, self.activeNavigation.topViewController === screen else { return }
            do {
                let qr = try QRCodeViewController(data: data, name: name)
                screen.present(UINavigationController(rootViewController: qr), animated: true)
            } catch { self.alert(error.localizedDescription) }
        }
    }

    private func configureConnectivity(screen: ConfigurationsViewController,
                                       notifications notificationScreen: NotificationsViewController,
                                       profile: ProfileViewController, generation: Int) {
        connectivityUpdate = { [weak self, weak screen, weak notificationScreen, weak profile] in
            guard let self, self.sessionGeneration == generation else { return }
            #if UNDERCORE_VPN
            self.vpnScreen?.updateConnectivity()
            #endif
            screen?.updateConnectivity(offline: self.client.isOffline, savedAt: self.client.cachedDate(for: APIEndpoints.configurationPage(1)))
            notificationScreen?.updateConnectivity(offline: self.client.isOffline, savedAt: self.client.cachedDate(for: APIEndpoints.notificationPage(1)))
            if let account = self.account { profile?.updateAccount(account) }
            profile?.updateConnectivity(offline: self.client.isOffline, savedAt: self.client.cachedDate(for: APIEndpoints.account))
        }
        reloadScreens = { [weak screen, weak notificationScreen] in
            screen?.refreshAfterReconnect(); notificationScreen?.refreshAfterReconnect()
        }
        connectivityUpdate?()
    }

    func openPushNotification(_ id: String) {
        guard account?.isEmailVerified == true, let tabs,
              let section = tabs.rootSections.first(where: { $0.tabBarItem.tag == 1 }) as? UINavigationController else { return }
        navigation.dismiss(animated: false)
        tabs.selectSection(section)
        section.popToRootViewController(animated: false)
        let generation = sessionGeneration
        Task { [weak self, weak section] in
            guard let self, let section else { return }
            do {
                // Fetch under the current account; never trust message content or URLs from a push.
                let response: Envelope<UserNotification> = try await self.client.request(APIRequests.notification(id))
                guard generation == self.sessionGeneration, tabs.currentSection === section else { return }
                let detail = FormViewController(); detail.loadViewIfNeeded(); detail.title = "Уведомление"
                detail.addText(response.data.title, style: .title2)
                detail.addText(response.data.body)
                section.pushViewController(detail, animated: true)
                _ = try? await self.notifications.markRead(id)
                self.refreshNotifications()
            } catch {
                guard generation == self.sessionGeneration else { return }
                self.alert(readableError(error))
            }
        }
    }
    func receivedPushNotification() {
        Task { [weak self] in await self?.notificationsModel?.load() }
    }
    func refreshNotifications() {
        if client.isOffline { reconnect() }
        Task { [weak self] in await self?.articlesModel?.refresh() }
        Task { [weak self] in await self?.notificationsModel?.refreshUnread() }
    }
    private func sessionExpired() {
        PushNotificationsController.shared.unbind()
        #if UNDERCORE_VPN
        vpn.bindOwner(nil)
        #endif
        articlesModel?.clearCache(); articlesModel = nil; sessionGeneration += 1; account = nil; transfer.clearFiles(); start() }
    private func showAccountDeletion() {
        let generation = sessionGeneration
        let model = AccountDeletionViewModel(repository: LiveAccountManagementRepository(client: client))
        let screen = AccountDeletionViewController(model: model)
        model.onSessionExpired = { [weak self, weak screen] in
            guard let self, self.sessionGeneration == generation else { return }
            screen?.dismiss(animated: true) { self.sessionExpired() }
        }
        model.onAccepted = { [weak self] in
            guard let self, self.sessionGeneration == generation else { return }
            self.accountDeletionAccepted()
        }
        activeNavigation.present(UINavigationController(rootViewController: screen), animated: true)
    }
    private func accountDeletionAccepted() {
        PushNotificationsController.shared.unbind()
        #if UNDERCORE_VPN
        vpn.bindOwner(nil)
        #endif
        sessionGeneration += 1
        articlesModel?.clearCache(); articlesModel = nil
        notificationsModel = nil; account = nil; pendingConfiguration = nil
        transfer.clearFiles(); tabs = nil; configurationsNavigation = nil
        navigation.dismiss(animated: false)
        navigation.setNavigationBarHidden(true, animated: false)
        let receipt = FormViewController()
        receipt.loadViewIfNeeded()
        receipt.addText("Запрос на удаление принят", style: .title1)
        receipt.addText("Вход в аккаунт заблокирован. Сервер завершит отзыв VPN-доступов и удаление данных. Завершение обработки может занять некоторое время.")
        let button = PrimaryButton("Ко входу")
        receipt.stack.addArrangedSubview(button)
        receipt.addFeedback()
        navigation.setViewControllers([receipt], animated: false)
        // Even if protected storage is temporarily unavailable, never return to the account UI
        // or resend the destructive request. Retry only local session cleanup.
        _ = clearDeletedSession(receipt)
        button.addAction(UIAction { [weak self, weak receipt] _ in
            guard let self, let receipt, self.clearDeletedSession(receipt) else { return }
            self.start()
        }, for: .touchUpInside)
    }
    private func clearDeletedSession(_ receipt: FormViewController) -> Bool {
        do { try client.clearSession(); receipt.messageLabel.text = nil; return true }
        catch { receipt.messageLabel.text = "Не удалось очистить сохранённый вход на устройстве. Разблокируйте iPhone и нажмите «Ко входу» ещё раз."; return false }
    }
    private func logout() {
        let alert = UIAlertController(title: "Выйти из аккаунта?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CommonText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: CommonText.logout, style: .destructive) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                #if UNDERCORE_VPN
                self.vpn.disconnect()
                #endif
                do { await PushNotificationsController.shared.prepareLogout(); try await self.auth.logout(); PushNotificationsController.shared.unbind(); self.articlesModel?.clearCache(); self.articlesModel = nil; self.sessionGeneration += 1; self.account = nil; self.pendingConfiguration = nil; self.transfer.clearFiles(); self.start() }
                catch ClientError.expiredSession { self.sessionExpired() }
                catch { PushNotificationsController.shared.resumeAfterFailedLogout(); self.alert(readableError(error)) }
            }
        })
        activeNavigation.present(alert, animated: true)
    }
    @discardableResult func open(_ url: URL) -> Bool {
        #if DEBUG
        let allowSynthetic = true
        #else
        let allowSynthetic = false
        #endif
        #if UNDERCORE_VPN
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "undercore-vpn" else { return false }
        components.scheme = "undercore"
        guard let url = components.url else { return false }
        #endif
        guard let link = DeepLink.parse(url, allowSynthetic: allowSynthetic) else { return false }
        switch link {
        case .configuration(let id):
            if account?.isEmailVerified == true { showConfiguration(id) } else { pendingConfiguration = id }
        case .syntheticTest(let format): showTest(amnezia: format == "awg")
        }
        return true
    }
    private func showConfiguration(_ id: String) {
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let config = try await self.configurations.detail(id)
                guard self.sessionGeneration == generation, self.account?.isEmailVerified == true else { return }
                let screen = TransferViewController(service: self.transfer, applicationName: config.applicationName) { [configurations = self.configurations] in try await configurations.download(id) }
                screen.onSessionExpired = { [weak self] in self?.sessionExpired() }
                if let navigation = self.configurationsNavigation { self.tabs?.selectSection(navigation) }
                (self.configurationsNavigation ?? self.navigation).pushViewController(screen, animated: true)
            } catch ClientError.expiredSession {
                guard self.sessionGeneration == generation else { return }
                self.pendingConfiguration = id; self.sessionExpired()
            }
            catch {
                guard self.sessionGeneration == generation else { return }
                self.alert(readableError(error))
            }
        }
    }
    private func showTest(amnezia: Bool = false) {
        #if DEBUG
        let screen = TransferViewController(service: transfer, applicationName: amnezia ? "AmneziaWG" : "WireGuard") { SyntheticConfiguration.make(amnezia: amnezia) }
        screen.loadViewIfNeeded()
        screen.addText("Случайный тестовый конфиг. Интернет через него не заработает; после проверки удалите туннель.", style: .footnote)
        navigation.pushViewController(screen, animated: true)
        #endif
    }
    private func alert(_ message: String) {
        let alert = UIAlertController(title: AppConfiguration.name, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Понятно", style: .default))
        activeNavigation.present(alert, animated: true)
    }
}
