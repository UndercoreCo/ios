#if DEBUG
import UIKit
import UndercoreCore

@MainActor enum AppPreview {
    static func install(in window: UIWindow) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--preview-refresh-checks") {
            let interactive = args.contains("--preview-refresh-gesture")
            let host: UIViewController = interactive ? RefreshGesturePreview() : UIViewController()
            if interactive {
                let navigation = UINavigationController(rootViewController: host)
                navigation.navigationBar.prefersLargeTitles = true
                window.rootViewController = navigation
            } else {
                host.view.backgroundColor = .systemBackground
                window.rootViewController = host
            }
            window.makeKeyAndVisible()
            if !interactive { RefreshInteractionChecks.run(in: host) }
            if args.contains("--preview-support-sheet") {
                DispatchQueue.main.async { host.present(ProfileViewController.supportBrowser(), animated: false) }
            }
            return true
        }
        if args.contains("--preview-captcha-polish") {
            let host = UIViewController(); host.view.backgroundColor = .systemBackground
            window.rootViewController = host; window.makeKeyAndVisible()
            let challenge = CaptchaViewController(pageURL: URL(string: "https://undercore.ru/api/mobile/v1/challenge")!, tokenField: "smart-token") { _ in }
            let navigation = UINavigationController(rootViewController: challenge)
            navigation.modalPresentationStyle = .pageSheet
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                host.present(navigation, animated: false)
            }
            return true
        }
        if args.contains("--preview-auth-polish") {
            let repository = PreviewVerificationRepository()
            let challenge = try! JSONDecoder().decode(RegistrationChallenge.self, from: Data(#"{"provider":"smartcaptcha","siteKey":"test","tokenField":"smart-token","required":true}"#.utf8))
            let screen = AuthViewController(model: AuthViewModel(repository: repository, challenge: challenge))
            window.rootViewController = UINavigationController(rootViewController: screen); window.makeKeyAndVisible()
            Task { await VerificationPolishChecks.run(in: screen, showKeyboard: args.contains("--preview-keyboard")) }
            return true
        }
        if args.contains("--preview-notification-limit") {
            window.rootViewController = UIViewController(); window.makeKeyAndVisible()
            Task { await NotificationLimitChecks.run() }
            return true
        }
        if args.contains("--preview-notification-visibility") {
            let repository = PreviewNotificationRepository(extraUnread: 12)
            let model = NotificationsViewModel(repository: repository)
            let screen = NotificationsViewController(model: model, messengers: MessengerConnectionsViewModel(repository: PreviewMessengerRepository()))
            repository.onMarkRead = { [weak screen] id in
                precondition(screen?.visibleUnreadIDs(excludingAttempted: false).contains(id) == true, "An offscreen notification was marked read")
            }
            let navigation = UINavigationController(rootViewController: screen)
            navigation.navigationBar.prefersLargeTitles = true
            window.rootViewController = navigation; window.makeKeyAndVisible()
            Task { @MainActor in
                var expected = Set<String>()
                for _ in 0..<100 {
                    try? await Task.sleep(for: .milliseconds(50))
                    screen.view.layoutIfNeeded()
                    expected = Set(screen.visibleUnreadIDs())
                    if !expected.isEmpty { break }
                }
                precondition(!expected.isEmpty, "Notification screen did not become visible")
                screen.scrollViewDidScroll(screen.scroll)
                let scheduled = screen.visibilityScheduleCount
                for _ in 0..<100 { screen.scrollViewDidScroll(screen.scroll) }
                precondition(screen.visibilityScheduleCount == scheduled, "Scroll recreated a visibility task for unchanged cards")
                try? await Task.sleep(for: .seconds(1))
                precondition(!repository.markedIDs.isEmpty, "Visible notifications were not marked read")
                let previousCount = repository.markedIDs.count
                await model.markVisibleRead(repository.markedIDs)
                precondition(repository.markedIDs.count == previousCount, "Read acknowledgement was duplicated")
                precondition(model.items.last?.isRead == false)
                let bottom = max(-screen.scroll.adjustedContentInset.top, screen.scroll.contentSize.height - screen.scroll.bounds.height + screen.scroll.adjustedContentInset.bottom)
                screen.scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                try? await Task.sleep(for: .seconds(1))
                precondition(model.items.last?.isRead == true, "Visible notification was not marked read")
                precondition(model.items.contains { !$0.isRead }, "Unseen middle notifications were marked read")
                print("VISIBLE_NOTIFICATION_CHECKS PASS: dwell; visible-only acknowledgement; scroll; no duplicate requests; unseen messages remain unread")
            }
            return true
        }
        if args.contains("--preview-packages") {
            let screen = ConfigurationsViewController(model: ConfigurationsViewModel(repository: PreviewConfigurationRepository()))
            let nav = UINavigationController(rootViewController: screen)
            nav.view.tintColor = Theme.blue
            window.rootViewController = nav; window.makeKeyAndVisible()
            Task { await PackageChecks.run() }
            return true
        }
        if args.contains("--preview-account-recovery") || args.contains("--preview-account-deletion") {
            let repository = PreviewAccountManagementRepository()
            let screen: UIViewController
            if args.contains("--preview-account-deletion") {
                screen = AccountDeletionViewController(model: AccountDeletionViewModel(repository: repository))
            } else {
                screen = PasswordRecoveryViewController(model: PasswordRecoveryViewModel(repository: repository), email: "preview@example.test")
            }
            let nav = UINavigationController(rootViewController: screen)
            nav.view.tintColor = Theme.blue
            window.rootViewController = nav; window.makeKeyAndVisible()
            Task { await AccountManagementChecks.run() }
            return true
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-network-banner") {
            let network = PreviewNetworkStatus()
            let screen = ConfigurationsViewController(model: ConfigurationsViewModel(repository: PreviewConfigurationRepository()), network: network)
            window.rootViewController = UINavigationController(rootViewController: screen); window.makeKeyAndVisible()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                @MainActor func banner(in view: UIView) -> OfflineBannerView? {
                    if let result = view as? OfflineBannerView { return result }
                    return view.subviews.compactMap { banner(in: $0) }.first
                }
                guard let notice = banner(in: screen.view) else { preconditionFailure("Offline banner missing") }
                precondition(notice.isHidden)
                network.update(offline: true); precondition(!notice.isHidden && notice.bounds.height > 0)
                network.update(offline: true); precondition(!notice.isHidden)
                network.update(offline: false); precondition(notice.isHidden)
                network.update(offline: true)
                print("NETWORK BANNER PASS: online hidden; offline shown; repeated update; restored connection hides banner")
            }
            return true
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-offline-article") {
            Task { await OfflineArticleCheck.run(in: window) }
            return true
        }
        if args.contains("--preview-polish-checks") || args.contains("--preview-empty-packages") {
            StableCardChecks.run(in: window)
            Task { await ArticleImageChecks.run() }
            let repository = PreviewConfigurationRepository()
            repository.showsEmptyPage = args.contains("--preview-empty-packages")
            let configs = ConfigurationsViewController(model: ConfigurationsViewModel(repository: repository))
            configs.configureArticles(ArticlesViewModel(repository: PreviewArticleRepository(), origin: URL(string: "https://preview.example.test")!, userID: 0), origin: URL(string: "https://preview.example.test")!)
            let notices = NotificationsViewController(model: NotificationsViewModel(repository: PreviewNotificationRepository(empty: args.contains("--preview-empty-notifications"))), messengers: MessengerConnectionsViewModel(repository: PreviewMessengerRepository()))
            let tabs = AppTabBarController()
            let configNav = UINavigationController(rootViewController: configs)
            configNav.navigationBar.prefersLargeTitles = true
            configNav.tabBarItem = UITabBarItem(title: "Конфигурации", image: UIImage(systemName: "rectangle.stack"), tag: 0)
            let notificationNav = UINavigationController(rootViewController: notices)
            notificationNav.navigationBar.prefersLargeTitles = true
            notificationNav.tabBarItem = UITabBarItem(title: "Уведомления", image: UIImage(systemName: "bell"), tag: 1)
            let user = try! JSONDecoder().decode(Account.self, from: Data(#"{"id":0,"name":"Preview","email":"preview@example.test","isEmailVerified":true}"#.utf8))
            let profile = ProfileViewController(account: user)
            let profileNav = UINavigationController(rootViewController: profile)
            profileNav.navigationBar.prefersLargeTitles = true
            profileNav.tabBarItem = UITabBarItem(title: "Профиль", image: UIImage(systemName: "person.crop.circle"), tag: 2)
            tabs.configure([configNav, notificationNav, profileNav])
            if ProcessInfo.processInfo.arguments.contains("--preview-notifications") { tabs.selectSection(1) }
            window.rootViewController = tabs; window.makeKeyAndVisible()
            if args.contains("--preview-package-pager") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    tabs.view.layoutIfNeeded()
                    for index in [1, 2, 0] {
                        tabs.selectSection(index)
                        precondition(tabs.currentSection === tabs.rootSections[index])
                    }
                    precondition(!tabs.tabBar.isHidden && tabs.additionalSafeAreaInsets.bottom == 0)
                    notificationNav.tabBarItem.badgeValue = "3"; tabs.refreshBadge()
                    precondition(tabs.currentSection === configNav)
                    if args.contains("--preview-package-focus") {
                        configs.view.layoutIfNeeded()
                        @MainActor func pager(in view: UIView) -> PackagePagerView? {
                            if let result = view as? PackagePagerView { return result }
                            for child in view.subviews {
                                if let result = pager(in: child) { return result }
                            }
                            return nil
                        }
                        if let pager = pager(in: configs.view) {
                            if args.contains("--preview-second-package"), let dots = pager.subviews.compactMap({ $0 as? UIPageControl }).first {
                                let height = pager.intrinsicContentSize.height
                                dots.currentPage = 1; dots.sendActions(for: .valueChanged)
                                try? await Task.sleep(for: .milliseconds(400))
                                pager.setNeedsLayout(); pager.layoutIfNeeded()
                                precondition(abs(pager.intrinsicContentSize.height - height) < 1, "Changing package moved page control")
                            }
                            let y = pager.convert(.zero, to: configs.scroll).y - configs.scroll.adjustedContentInset.top - 44
                            configs.scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                        }
                    }
                    print("NATIVE_TAB_CHECKS PASS: standard tab bar; three destinations; retained controllers; notification badge")
                }
            }
            return true
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-messengers") {
            let model = MessengerConnectionsViewModel(repository: PreviewMessengerRepository())
            let screen = NotificationsViewController(model: NotificationsViewModel(repository: PreviewNotificationRepository()), messengers: model)
            let navigation = UINavigationController(rootViewController: screen)
            navigation.navigationBar.prefersLargeTitles = true
            navigation.view.tintColor = Theme.blue
            window.rootViewController = navigation; window.makeKeyAndVisible()
            return true
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-articles") {
            let origin = URL(string: "https://preview.example.test")!
            let articles = ArticlesViewModel(repository: PreviewArticleRepository(), origin: origin, userID: 0)
            let model = ConfigurationsViewModel(repository: PreviewConfigurationRepository())
            let screen = ConfigurationsViewController(model: model)
            let transfer = DocumentTransferService()
            model.onDownload = { [weak screen] data, name in
                guard let screen else { return }
                try? transfer.present(data: data, applicationName: name, from: screen, source: screen.view)
            }
            screen.configureArticles(articles, origin: origin)
            let navigation = UINavigationController(rootViewController: screen)
            window.rootViewController = navigation; window.makeKeyAndVisible()
            if ProcessInfo.processInfo.arguments.contains("--preview-transfer-guide") {
                DispatchQueue.main.async {
                    model.onDownload?(SyntheticConfiguration.make(amnezia: true), "AmneziaWG")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-article-detail") {
                DispatchQueue.main.async {
                    let sheet = ArticleSheetController(rootViewController: ArticleViewController(id: 1, model: articles, origin: origin))
                    sheet.sheetPresentationController?.detents = [.medium(), .large()]
                    sheet.sheetPresentationController?.prefersGrabberVisible = true
                    screen.present(sheet, animated: false)
                }
            }
            return true
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-startup") {
            let screen = StartupViewController()
            window.rootViewController = screen
            window.makeKeyAndVisible()
            if args.contains("--preview-startup-checks") {
                Task { await screen.verifyWaveLoading() }
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-startup-error") {
                screen.showError(CommonText.networkError)
            }
            return true
        }
        return false
    }
}
#endif

#if DEBUG
@MainActor private final class PreviewVerificationRepository: AuthRepository {
    var status = EmailVerificationStatus(retryAfterSeconds: 0, isEmailVerified: false)
    var sends = 0
    var failure: ClientError?
    func prepare() async throws -> Bootstrap {
        try JSONDecoder().decode(Bootstrap.self, from: Data(#"{"apiVersion":1,"csrfToken":"test","sessionCookieName":"test","sessionLifetimeSeconds":600,"challenge":{"provider":"smartcaptcha","siteKey":"test","tokenField":"smart-token","required":true}}"#.utf8))
    }
    func verificationStatus() async throws -> EmailVerificationStatus { if let failure { throw failure }; return status }
    func resendEmail() async throws -> EmailVerificationStatus {
        sends += 1
        if let failure { throw failure }
        status = .init(retryAfterSeconds: 60, isEmailVerified: false); return status
    }
    func currentAccount() async throws -> Account { throw ClientError.invalidResponse }
    func login(email: String, password: String) async throws -> Account { throw ClientError.invalidResponse }
    func register(name: String, email: String, password: String, challenge: (field: String, token: String)?) async throws -> Account { throw ClientError.invalidResponse }
    func verifyEmail(code: String) async throws -> Account { throw ClientError.invalidResponse }
    func logout() async throws { }
}
@MainActor private enum VerificationPolishChecks {
    static func run(in screen: AuthViewController, showKeyboard: Bool) async {
        var time = Date(timeIntervalSince1970: 0)
        let repository = PreviewVerificationRepository()
        let model = VerificationViewModel(repository: repository, now: { time })
        precondition(!model.canResend)
        await model.loadStatus(); precondition(model.canResend)
        await model.resend(); precondition(!model.canResend && model.retryAfterSeconds == 60)
        await model.resend(); precondition(repository.sends == 1)
        time.addTimeInterval(59); precondition(!model.canResend && model.retryAfterSeconds == 1)
        time.addTimeInterval(1); precondition(model.canResend)
        repository.failure = .server(status: 429, message: "Wait", retryAfter: 3500)
        await model.resend(); precondition(model.retryAfterSeconds == 3500 && !model.canResend)
        let reopened = VerificationViewModel(repository: repository, now: { time })
        repository.failure = nil; repository.status = .init(retryAfterSeconds: 3500, isEmailVerified: false)
        await reopened.loadStatus(); precondition(reopened.retryAfterSeconds == 3500 && !reopened.canResend)
        func fields(_ view: UIView) -> [InputField] {
            (view as? InputField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
        }
        let inputs = fields(screen.view)
        precondition(inputs.count == 3 && inputs.allSatisfy { $0.inputAccessoryView is UIToolbar })
        guard let email = inputs.first(where: { $0.placeholder == "Электронная почта" }), let password = inputs.first(where: { $0.placeholder == "Пароль" }) else { preconditionFailure("Auth fields missing") }
        try? await Task.sleep(for: .milliseconds(400))
        email.becomeFirstResponder(); _ = email.textFieldShouldReturn(email)
        precondition(password.isFirstResponder, "Next did not focus password")
        let button = (password.inputAccessoryView as! UIToolbar).items!.last!
        _ = UIApplication.shared.sendAction(button.action!, to: button.target, from: button, for: nil)
        precondition(!password.isFirstResponder, "Keyboard toolbar did not dismiss")
        if showKeyboard { email.becomeFirstResponder() }
        print("AUTH_POLISH_CHECKS PASS: server countdown; one resend; double tap; expiry; 429; reopen; next field; keyboard dismiss")
    }
}
/// Real recognizer and native scrolling for manual/simulator gesture checks; no network.
@MainActor private final class RefreshGesturePreview: UIViewController {
    private let scroll = UIScrollView()
    private let refresh = DeliberateRefreshControl()
    private let result = UILabel()
    private var requests = 0
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Проверка свайпа"
        view.backgroundColor = .systemGroupedBackground
        scroll.frame = view.bounds; scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scroll)
        result.font = .preferredFont(forTextStyle: .body)
        result.numberOfLines = 0; result.text = "Обновлений: 0"
        result.accessibilityIdentifier = "refresh-gesture-result"
        result.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(result)
        NSLayoutConstraint.activate([
            result.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            result.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            result.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            result.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -1000),
            result.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        refresh.attach(to: scroll) { [weak self] in
            guard let self else { return }
            self.requests += 1
            self.result.text = "Обновлений: \(self.requests) · выполняется"
            print("REFRESH_GESTURE accepted \(self.requests)")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refresh.endRefreshing()
                self.result.text = "Обновлений: \(self.requests) · завершено"
            }
        }
    }
}

@MainActor private enum RefreshInteractionChecks {
    static func run(in host: UIViewController) {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset.top = 96
        host.view.addSubview(scroll)
        host.view.layoutIfNeeded()
        defer { scroll.removeFromSuperview() }
        let refresh = DeliberateRefreshControl()
        var requests = 0
        refresh.attach(to: scroll) { requests += 1 }
        precondition(scroll.refreshControl == nil, "Idle UIKit control can arm and vibrate on a short pull")
        func begin(at offset: CGFloat = -96) {
            scroll.contentOffset.y = offset
            refresh.handlePan(state: .began, translation: 10)
        }
        func release(distance: CGFloat, travel: CGFloat) {
            scroll.contentOffset.y = -96 - distance
            refresh.handlePan(state: .changed, translation: 10 + travel)
            scroll.contentOffset.y = -96
            refresh.handlePan(state: .ended, translation: 0)
        }
        begin(); release(distance: 120, travel: 300)
        precondition(requests == 0, "Old short threshold still refreshes")
        precondition(scroll.refreshControl == nil && !refresh.isRefreshing, "Short gesture armed native feedback")
        begin(); release(distance: 180, travel: 40)
        precondition(requests == 0, "Inset/layout movement counted as a pull")
        begin()
        scroll.contentOffset.y = -300
        refresh.handlePan(state: .changed, translation: 360)
        precondition(scroll.refreshControl == nil && !refresh.isRefreshing, "UIKit armed before finger release")
        refresh.indicator.sendActions(for: .valueChanged)
        precondition(requests == 0, "Refresh began before release")
        release(distance: 30, travel: 80)
        precondition(requests == 0, "Reversed pull refreshed")
        begin(); scroll.contentOffset.y = -300
        refresh.handlePan(state: .cancelled, translation: 360)
        refresh.indicator.sendActions(for: .valueChanged)
        precondition(requests == 0, "Cancelled gesture refreshed")
        begin(); release(distance: 160, travel: 300)
        precondition(requests == 1, "Deliberate released pull did not refresh")
        precondition(scroll.refreshControl === refresh.indicator && refresh.isRefreshing, "Accepted pull lost the standard indicator")
        refresh.indicator.sendActions(for: .valueChanged)
        begin(); release(distance: 180, travel: 360)
        precondition(requests == 1, "In-flight refresh was duplicated")
        refresh.endRefreshing()
        precondition(scroll.refreshControl == nil && !refresh.isRefreshing, "Completed refresh kept UIKit's short trigger attached")
        refresh.indicator.sendActions(for: .valueChanged)
        precondition(requests == 1, "Late UIKit event reused a completed gesture")
        begin(at: 304); release(distance: 180, travel: 500)
        precondition(requests == 1, "Scrolling to the top counted towards the threshold")
        begin(at: 304); release(distance: 180, travel: 700)
        precondition(requests == 2, "Pull after scrolling to the top failed")
        refresh.endRefreshing()
        begin(); release(distance: 160, travel: 300)
        precondition(requests == 3, "Next gesture after completion failed")
        refresh.endRefreshing()
        let browser = ProfileViewController.supportBrowser()
        precondition(browser.modalPresentationStyle == .pageSheet)
        precondition(browser.sheetPresentationController?.selectedDetentIdentifier == .medium)
        precondition(browser.sheetPresentationController?.detents.count == 2)
        print("REFRESH_INTERACTION_CHECKS PASS: short, inset, reversed, cancelled, released, duplicate, late event, scroll-to-top, repeated; support medium/large sheet")
    }
}
#endif
