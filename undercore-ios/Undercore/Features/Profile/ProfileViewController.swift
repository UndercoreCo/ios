import UIKit
import SafariServices
import UndercoreCore

final class ProfileViewController: UITableViewController {
    private var isOffline = false
    private let offlineBanner = OfflineBannerView()
    private let offlineHeader = UIView()
    func updateConnectivity(offline: Bool, savedAt: Date?) {
        isOffline = offline; loadViewIfNeeded()
        offlineBanner.update(savedAt: savedAt); offlineBanner.isHidden = !offline
        tableView.tableHeaderView = offline ? offlineHeader : nil
        sizeOfflineBanner(); tableView.reloadData()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); sizeOfflineBanner() }
    private func sizeOfflineBanner() {
        guard isOffline else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let height = offlineHeader.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        if offlineHeader.frame.size != CGSize(width: width, height: height) {
            offlineHeader.frame = CGRect(x: 0, y: 0, width: width, height: height)
            tableView.tableHeaderView = offlineHeader
        }
    }
    func updateAccount(_ account: Account) { self.account = account; if isViewLoaded { tableView.reloadData() } }
    private var account: Account
    private let support: [(title: String, detail: String?, icon: String, url: URL)] = [
        ("Написать в Telegram", "@undercore_support", "paperplane", AppConfiguration.supportTelegramURL),
        ("Написать в WhatsApp", "@undercore_support", "message", AppConfiguration.supportWhatsAppURL),
        ("Написать на почту", AppConfiguration.supportEmail, "envelope", AppConfiguration.supportEmailURL),
        ("Отправить запрос через сайт", nil, "globe", AppConfiguration.supportWebsiteURL)
    ]
    var onDeleteAccount: (() -> Void)?
    var onLogout: (() -> Void)?
    var onDiagnostics: ((UIView) -> Void)?
    init(account: Account) {
        self.account = account
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        offlineBanner.translatesAutoresizingMaskIntoConstraints = false
        offlineHeader.addSubview(offlineBanner)
        NSLayoutConstraint.activate([
            offlineBanner.leadingAnchor.constraint(equalTo: offlineHeader.leadingAnchor, constant: Theme.screenInset),
            offlineBanner.trailingAnchor.constraint(equalTo: offlineHeader.trailingAnchor, constant: -Theme.screenInset),
            offlineBanner.topAnchor.constraint(equalTo: offlineHeader.topAnchor),
            offlineBanner.bottomAnchor.constraint(equalTo: offlineHeader.bottomAnchor, constant: -Theme.gap)
        ])
        title = "Профиль"
        navigationItem.largeTitleDisplayMode = .always
        tableView.backgroundColor = .systemGroupedBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 5 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 1 { return support.count }
        if section == 2 && onDiagnostics != nil { return 2 }
        return 1
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 1 ? "Поддержка" : nil }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        content.directionalLayoutMargins = .init(top: 18, leading: 20, bottom: 18, trailing: 20)
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .callout)
        content.secondaryTextProperties.color = .secondaryLabel
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        switch indexPath.section {
        case 0:
            content.text = account.name; content.secondaryText = account.email
            cell.selectionStyle = .none
        case 1:
            let link = support[indexPath.row]
            content.text = link.title; content.secondaryText = link.detail
            content.image = UIImage(systemName: link.icon); content.imageProperties.tintColor = Theme.blue
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityTraits = .button
        case 2:
            if indexPath.row == 0 {
                content.text = "О приложении"; content.secondaryText = AppConfiguration.name + " · " + AppConfiguration.version
                cell.selectionStyle = .none
            } else {
                content.text = "Диагностика"
                content.image = UIImage(systemName: "doc.text.magnifyingglass")
                content.imageProperties.tintColor = Theme.blue
                cell.accessoryType = .disclosureIndicator
                cell.accessibilityTraits = .button
            }
        case 4:
            content.text = "Удалить аккаунт"; content.textProperties.color = .systemRed
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityTraits = .button
        default:
            content.text = CommonText.logout; content.textProperties.color = .systemRed
            cell.accessibilityTraits = .button
        }
        if isOffline && [1, 4].contains(indexPath.section) { cell.isUserInteractionEnabled = false; content.textProperties.color = .tertiaryLabel }
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if isOffline && [1, 4].contains(indexPath.section) { return }
        if indexPath.section == 2 && indexPath.row == 1 {
            onDiagnostics?(tableView.cellForRow(at: indexPath) ?? tableView)
            return
        }
        if indexPath.section == 4 { onDeleteAccount?(); return }
        if indexPath.section == 3 { onLogout?(); return }
        guard indexPath.section == 1 else { return }
        let url = support[indexPath.row].url
        if url == AppConfiguration.supportWebsiteURL {
            present(Self.supportBrowser(), animated: true)
        } else {
            UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                guard !opened else { return }
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: "Не удалось открыть ссылку", message: "Проверить контакты и отправить запрос можно на сайте Undercore.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Открыть поддержку", style: .default) { [weak self] _ in
                        self?.present(Self.supportBrowser(), animated: true)
                    })
                    alert.addAction(UIAlertAction(title: CommonText.cancel, style: .cancel))
                    self?.present(alert, animated: true)
                }
            }
        }
    }
    static func supportBrowser() -> SFSafariViewController {
        let browser = SFSafariViewController(url: AppConfiguration.supportWebsiteURL)
        browser.dismissButtonStyle = .close
        browser.modalPresentationStyle = .pageSheet
        if let sheet = browser.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        return browser
    }

}
