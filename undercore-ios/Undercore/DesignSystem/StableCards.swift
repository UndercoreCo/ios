import UIKit
import UndercoreCore

/// Keeps the same view and controls for an item across loading, edits and pagination.
/// This is an incremental stack, not a virtualized collection; pagination remains in the repositories.
class StableCardStack: UIStackView {
    private var cards: [String: UIView] = [:]
    private(set) var ids: [String] = []
    func card(for id: String) -> UIView? { cards[id] }
    func reconcile(_ newIDs: [String], make: (String) -> UIView) {
        guard ids != newIDs else { return }
        let keep = Set(newIDs)
        for id in ids where !keep.contains(id) {
            if let card = cards.removeValue(forKey: id) { removeArrangedSubview(card); card.removeFromSuperview() }
        }
        for (index, id) in newIDs.enumerated() {
            let card: UIView
            if let existing = cards[id] { card = existing }
            else { card = make(id); cards[id] = card }
            if arrangedSubviews.indices.contains(index), arrangedSubviews[index] === card { continue }
            if card.superview === self { removeArrangedSubview(card) }
            insertArrangedSubview(card, at: index)
        }
        ids = newIDs
    }
    func preservingReadingPosition(in scroll: UIScrollView, keeping newIDs: [String], changes: () -> Void) {
        let canAnchor = !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating
            && scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1
        let keep = Set(newIDs)
        let anchor = canAnchor ? ids.compactMap { keep.contains($0) ? cards[$0] : nil }.first {
            $0.convert($0.bounds, to: scroll).maxY > scroll.contentOffset.y + scroll.adjustedContentInset.top
        } : nil
        let oldY = anchor.map { $0.convert($0.bounds, to: scroll).minY }
        let oldOffset = scroll.contentOffset
        changes()
        guard let anchor, let oldY else { return }
        scroll.superview?.layoutIfNeeded()
        let delta = anchor.convert(anchor.bounds, to: scroll).minY - oldY
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let y = min(maximum, max(minimum, oldOffset.y + delta))
        if abs(y - scroll.contentOffset.y) > 0.5 { scroll.setContentOffset(CGPoint(x: oldOffset.x, y: y), animated: false) }
    }
}

@MainActor enum CardText {
    static func label(_ style: UIFont.TextStyle) -> UILabel {
        let label = UILabel(); label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true
        return label
    }
    static let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    static let plain = ISO8601DateFormatter()
    static func expired(_ value: String?) -> Bool {
        guard let value, let date = fractional.date(from: value) ?? plain.date(from: value) else { return false }
        return date <= Date()
    }
    private static let dateFormatter = makeDateFormatter(time: false)
    private static let dateTimeFormatter = makeDateFormatter(time: true)
    private static func makeDateFormatter(time: Bool) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium; formatter.timeStyle = time ? .short : .none
        return formatter
    }
    static func date(_ value: String?, time: Bool = false) -> String {
        guard let value, let date = fractional.date(from: value) ?? plain.date(from: value) else { return "" }
        return (time ? dateTimeFormatter : dateFormatter).string(from: date)
    }
    static func style(_ card: UIStackView, bottom: CGFloat = 18) {
        card.axis = .vertical; card.spacing = 12; card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = .init(top: 18, left: 20, bottom: bottom, right: 20)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = Theme.cardRadius; card.layer.cornerCurve = .continuous
    }
}

/// Device controls use buttons and menus; horizontal gestures belong to the package pager.
final class PackageDeviceView: UIView {
    let nameLabel = CardText.label(.body)
    let detailLabel = CardText.label(.footnote)
    let menuButton = UIButton(type: .system)
    let addButton = UIButton(type: .system)
    let qrButton = UIButton(type: .system)
    var onImport: (() -> Void)?
    var onQR: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemGroupedBackground
        layer.cornerRadius = 18; layer.cornerCurve = .continuous
        detailLabel.textColor = .secondaryLabel
        var menu = UIButton.Configuration.plain(); menu.image = UIImage(systemName: "ellipsis")
        menuButton.configuration = menu; menuButton.showsMenuAsPrimaryAction = true
        menuButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        menuButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let labels = UIStackView(arrangedSubviews: [nameLabel, detailLabel]); labels.axis = .vertical; labels.spacing = 4
        let header = UIStackView(arrangedSubviews: [labels, menuButton]); header.spacing = 8; header.alignment = .center
        var primary = UIButton.Configuration.filled(); primary.baseBackgroundColor = Theme.blue
        primary.cornerStyle = .large
        primary.contentInsets = .init(top: 10, leading: 10, bottom: 10, trailing: 10)
        primary.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { original in
            var value = original; value.font = .preferredFont(forTextStyle: .subheadline); return value
        }
        addButton.configuration = primary
        var qr = UIButton.Configuration.tinted(); qr.baseBackgroundColor = Theme.blue
        qr.image = UIImage(systemName: "qrcode"); qr.cornerStyle = .large
        qrButton.configuration = qr; qrButton.accessibilityLabel = "Показать QR-код"
        qrButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let actions = UIStackView(arrangedSubviews: [addButton, qrButton]); actions.spacing = 8
        actions.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        addButton.addAction(UIAction { [weak self] _ in self?.onImport?() }, for: .touchUpInside)
        qrButton.addAction(UIAction { [weak self] _ in self?.onQR?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [header, actions]); stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
}

/// A subscription has few devices. A native stack measures all content synchronously;
/// no table estimates, nested scrolling or delayed contentSize updates enter the pager.
final class PackageDeviceStack: StableCardStack {
    private var protocols: [VPNProtocolOption] = []
    private var busy = false
    private var removingIDs = Set<String>()
    var onRename: ((VPNConfiguration) -> Void)?
    var onSwitch: ((VPNConfiguration, VPNProtocolOption) -> Void)?
    var onDelete: ((VPNConfiguration) -> Void)?
    var onDownload: ((VPNConfiguration, Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical; spacing = 10
    }
    required init(coder: NSCoder) { fatalError("Use programmatic layout") }
    private func canManage(_ item: VPNConfiguration) -> Bool { !busy && !item.isDeleting && !removingIDs.contains(item.id) }
    private func canDownload(_ item: VPNConfiguration) -> Bool { canManage(item) && item.canDownload && !item.isSwitchingProtocol }
    private func configure(_ cell: PackageDeviceView, item: VPNConfiguration) {
        let id = item.id
        cell.nameLabel.text = item.displayName
        let status: String
        if item.isDeleting || removingIDs.contains(id) { status = "Удаляется · место пока занято" }
        else if item.isSwitchingProtocol { status = "Меняем протокол…" }
        else { switch item.state {
        case "active": status = "Готово к работе"
        case "expired": status = "Срок закончился"
        case "provisioning": status = "Подготавливается"
        default: status = "Нужна проверка"
        } }
        let lastConnection = CardText.date(item.connection?.lastHandshakeAt, time: true)
        cell.detailLabel.text = "\(item.applicationName) · \(status)" + (lastConnection.isEmpty ? "" : "\nПоследнее подключение: " + lastConnection)
        cell.accessibilityIdentifier = item.id
        cell.menuButton.accessibilityLabel = "Действия: " + item.displayName
        cell.menuButton.menu = menu(for: item)
        cell.menuButton.isEnabled = !busy && !(cell.menuButton.menu?.children.isEmpty ?? true)
        cell.addButton.configuration?.title = "Добавить в \(item.applicationName)"
        cell.addButton.isEnabled = canDownload(item); cell.qrButton.isEnabled = canDownload(item)
        cell.qrButton.accessibilityLabel = "QR-код: " + item.displayName
        cell.onImport = { [weak self] in self?.onDownload?(item, false) }
        cell.onQR = { [weak self] in self?.onDownload?(item, true) }
    }
    private func menu(for item: VPNConfiguration) -> UIMenu {
        var actions: [UIMenuElement] = []
        if canManage(item) {
            if item.canRename {
                actions.append(UIAction(title: "Переименовать", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onRename?(item) })
            }
            let options = item.switchOptions(from: protocols)
            if !options.isEmpty {
                actions.append(UIMenu(title: "Сменить протокол", image: UIImage(systemName: "arrow.triangle.2.circlepath"), children: options.map { option in
                    UIAction(title: option.label) { [weak self] _ in self?.onSwitch?(item, option) }
                }))
            }
            if item.canDelete == true {
                actions.append(UIAction(title: "Удалить устройство", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.onDelete?(item) })
            }

        }
        return UIMenu(children: actions)
    }
    func update(_ configs: [VPNConfiguration], protocols: [VPNProtocolOption], busy: Bool, removingIDs: Set<String>) {
        self.protocols = protocols; self.busy = busy; self.removingIDs = removingIDs
        reconcile(configs.map(\.id)) { _ in PackageDeviceView(frame: .zero) }
        for item in configs {
            if let view = card(for: item.id) as? PackageDeviceView { configure(view, item: item) }
        }
    }
}

/// Owns stable device views while the package metadata and capacity refresh.
final class PackageCardView: UIStackView {
    private let title = CardText.label(.title2)
    private let capacity = CardText.label(.subheadline)
    private let expiry = CardText.label(.subheadline)
    private let note = CardText.label(.subheadline)
    private let emptyIcon = UIImageView(image: UIImage(systemName: "laptopcomputer.and.iphone"))
    private let noteHost = UIView()
    private let deviceSpacer = UIView()
    private var dateRow: UIStackView!
    private let add = PrimaryButton("Добавить")
    let devices = PackageDeviceStack(frame: .zero)
    private var activationSlot: Int?
    private struct Presentation: Equatable {
        let package: VPNPage.Package
        let protocols: [VPNProtocolOption]
        let busy: Bool
        let removingIDs: Set<String>
        let pendingSlots: Set<Int>
        let expiryText: String
        let expired: Bool
    }
    private var presentation: Presentation?
    var onContentChange: (() -> Void)?
    var onActivate: ((Int) -> Void)?
    var onRename: ((VPNConfiguration) -> Void)?
    var onSwitch: ((VPNConfiguration, VPNProtocolOption) -> Void)?
    var onDelete: ((VPNConfiguration) -> Void)?
    var onDownload: ((VPNConfiguration, Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame); CardText.style(self)
        layoutMargins = .init(top: 18, left: 20, bottom: 20, right: 20)
        title.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 18, weight: .semibold))
        title.accessibilityTraits = .header
        [expiry, note].forEach { $0.textColor = .secondaryLabel }
        let calendar = UIImageView(image: UIImage(systemName: "calendar"))
        calendar.tintColor = .secondaryLabel; calendar.contentMode = .scaleAspectFit
        calendar.widthAnchor.constraint(equalToConstant: 20).isActive = true
        calendar.heightAnchor.constraint(equalToConstant: 22).isActive = true
        dateRow = UIStackView(arrangedSubviews: [calendar, expiry]); dateRow.spacing = 8; dateRow.alignment = .top
        if #available(iOS 26.0, *) {
            var appearance = UIButton.Configuration.prominentGlass()
            appearance.title = "Добавить"
            appearance.baseBackgroundColor = Theme.blue
            appearance.contentInsets = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
            add.configuration = appearance
        }
        add.configuration?.image = UIImage(systemName: "plus")
        add.configuration?.imagePadding = 8
        add.accessibilityIdentifier = "package-add-device"
        add.addAction(UIAction { [weak self] _ in
            guard let self, let slot = self.activationSlot else { return }; self.onActivate?(slot)
        }, for: .touchUpInside)
        devices.onRename = { [weak self] in self?.onRename?($0) }
        devices.onSwitch = { [weak self] in self?.onSwitch?($0, $1) }
        devices.onDelete = { [weak self] in self?.onDelete?($0) }
        devices.onDownload = { [weak self] in self?.onDownload?($0, $1) }
        capacity.font = .preferredFont(forTextStyle: .subheadline)
        capacity.numberOfLines = 1
        capacity.adjustsFontSizeToFitWidth = false
        capacity.setContentCompressionResistancePriority(.required, for: .vertical)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        capacity.textColor = Theme.blue
        capacity.textAlignment = .center
        capacity.setContentHuggingPriority(.required, for: .horizontal)
        capacity.setContentCompressionResistancePriority(.required, for: .horizontal)
        let badge = UIView()
        badge.backgroundColor = Theme.blue.withAlphaComponent(0.12)
        badge.layer.cornerRadius = 16; badge.layer.cornerCurve = .continuous
        capacity.translatesAutoresizingMaskIntoConstraints = false; badge.addSubview(capacity)
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            capacity.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 12),
            capacity.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -12),
            capacity.topAnchor.constraint(equalTo: badge.topAnchor, constant: 7),
            capacity.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -7)
        ])
        let header = UIStackView(arrangedSubviews: [title, badge]); header.spacing = 10; header.alignment = .center
        emptyIcon.tintColor = .tertiaryLabel
        emptyIcon.contentMode = .scaleAspectFit
        emptyIcon.preferredSymbolConfiguration = .init(pointSize: 32, weight: .regular)
        emptyIcon.isAccessibilityElement = false
        let iconHeight = emptyIcon.heightAnchor.constraint(equalToConstant: 40)
        iconHeight.priority = .defaultHigh; iconHeight.isActive = true
        let noteContent = UIStackView(arrangedSubviews: [emptyIcon, note])
        noteContent.axis = .vertical; noteContent.spacing = 12
        noteContent.translatesAutoresizingMaskIntoConstraints = false; noteHost.addSubview(noteContent)
        NSLayoutConstraint.activate([
            noteContent.leadingAnchor.constraint(equalTo: noteHost.leadingAnchor), noteContent.trailingAnchor.constraint(equalTo: noteHost.trailingAnchor),
            noteContent.centerYAnchor.constraint(equalTo: noteHost.centerYAnchor),
            noteContent.topAnchor.constraint(greaterThanOrEqualTo: noteHost.topAnchor, constant: 24),
            noteContent.bottomAnchor.constraint(lessThanOrEqualTo: noteHost.bottomAnchor, constant: -24)
        ])
        let spacerHeight = deviceSpacer.heightAnchor.constraint(equalToConstant: 0); spacerHeight.priority = .defaultLow; spacerHeight.isActive = true
        deviceSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        [header, dateRow!, noteHost, devices, deviceSpacer, add].forEach { addArrangedSubview($0) }
        setCustomSpacing(0, after: deviceSpacer)
        setCustomSpacing(20, after: header)
        setCustomSpacing(20, after: dateRow)
        setCustomSpacing(20, after: devices)
    }
    required init(coder: NSCoder) { fatalError("Use programmatic layout") }
    func update(_ package: VPNPage.Package, protocols: [VPNProtocolOption], busy: Bool, removingIDs: Set<String>, pendingSlots: Set<Int>) {
        let expired = package.expired ?? CardText.expired(package.expiresAt)
        let date = CardText.date(package.expiresAt)
        let next = Presentation(package: package, protocols: protocols, busy: busy, removingIDs: removingIDs,
                                pendingSlots: pendingSlots, expiryText: date, expired: expired)
        guard presentation != next else { return }
        presentation = next
        defer { onContentChange?() }
        let count = package.deviceCount
        let noun = count % 100 >= 11 && count % 100 <= 14 ? "устройств" : (count % 10 == 1 ? "устройство" : (2...4).contains(count % 10) ? "устройства" : "устройств")
        title.text = "\(count) \(noun)"
        capacity.text = "Занято \(package.usedSlots) из \(count)"
        expiry.text = (expired ? "Срок закончился" : "Оплачено до") + (date.isEmpty ? "" : " " + date)
        let free = package.slots.filter { !$0.occupied && $0.config == nil && $0.canActivate }
        activationSlot = free.first(where: { pendingSlots.contains($0.number) })?.number ?? free.first?.number
        add.configuration?.title = activationSlot.map { pendingSlots.contains($0) ? "Проверить добавление" : "Добавить" }
        add.isHidden = activationSlot == nil || expired
        add.isEnabled = !busy && protocols.contains { $0.available && ["wireguard", "amneziawg"].contains($0.id) }
        let unavailable = package.slots.filter { $0.occupied && $0.config == nil }.count
        var notes: [String] = []
        if unavailable > 0 { notes.append("Часть устройств сейчас недоступна. Их места остаются занятыми.") }
        if package.usedSlots == 0 { notes.append("В этой подписке пока нет устройств") }
        if !expired && package.usedSlots < package.deviceCount && !protocols.contains(where: { $0.available }) {
            notes.append("Добавление временно недоступно.")
        }
        let empty = package.usedSlots == 0
        note.text = notes.joined(separator: empty ? "\n" : " "); noteHost.isHidden = notes.isEmpty
        note.textAlignment = empty ? .center : .natural
        emptyIcon.isHidden = !empty
        deviceSpacer.isHidden = empty
        setCustomSpacing(empty ? 0 : 20, after: dateRow)
        setCustomSpacing(empty ? 0 : 12, after: noteHost)
        let configs = package.slots.compactMap(\.config)
        devices.update(configs, protocols: protocols, busy: busy, removingIDs: removingIDs)
        devices.isHidden = configs.isEmpty
    }
}

final class NotificationCardView: UIStackView {
    private let tagLabel = CardText.label(.caption1)
    private let date = CardText.label(.caption1)
    private let title = CardText.label(.headline)
    private let body = CardText.label(.body)
    private let readStatus = CardText.label(.caption1)
    private var item: UserNotification?
    override init(frame: CGRect) {
        super.init(frame: frame); CardText.style(self, bottom: 12)
        date.textColor = .secondaryLabel; date.textAlignment = .right
        let metadata = UIStackView(arrangedSubviews: [tagLabel, date]); metadata.spacing = 8; metadata.alignment = .top
        [metadata, title, body].forEach { addArrangedSubview($0) }
        readStatus.textColor = .secondaryLabel
        addArrangedSubview(readStatus)
    }
    required init(coder: NSCoder) { fatalError("Use programmatic layout") }
    func update(_ value: UserNotification, busy: Bool) {
        if item != value {
            item = value; title.text = value.title; body.text = value.body
            date.text = CardText.date(value.createdAt, time: true)
            switch value.kind {
            case "success": tagLabel.text = "Успешно"; tagLabel.textColor = .systemGreen
            case "warning": tagLabel.text = "Внимание"; tagLabel.textColor = .systemOrange
            case "critical": tagLabel.text = "Важное"; tagLabel.textColor = .systemRed
            default: tagLabel.text = "Информация"; tagLabel.textColor = Theme.blue
            }
            readStatus.text = value.isRead ? "Прочитано" : "Новое"
        }
    }
}

#if DEBUG
/// Deterministic UI smoke checks; synthetic models only. Run with --preview-polish-checks.
@MainActor enum StableCardChecks {
    static func run(in window: UIWindow) {
        let host = UIViewController(); window.rootViewController = host; host.view.frame = window.bounds
        let scroll = UIScrollView(frame: host.view.bounds); scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(scroll)
        let list = StableCardStack(); list.axis = .vertical; list.spacing = 16
        list.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        let ids = (0..<50).map(String.init)
        var creations = 0
        let make: (String) -> UIView = { _ in
            creations += 1; let card = UIView(); card.heightAnchor.constraint(equalToConstant: 100).isActive = true; return card
        }
        list.reconcile(ids, make: make); host.view.layoutIfNeeded()
        let original = ids.map { ObjectIdentifier(list.card(for: $0)!) }
        for _ in 0..<100 { list.reconcile(ids, make: make) }
        precondition(creations == 50 && original == ids.map { ObjectIdentifier(list.card(for: $0)!) }, "Unchanged rows were recreated")
        scroll.setContentOffset(CGPoint(x: 0, y: 450), animated: false)
        let anchor = list.card(for: "4")!
        let before = anchor.convert(anchor.bounds, to: scroll).minY - scroll.contentOffset.y
        let fewer = Array(ids.dropFirst())
        list.preservingReadingPosition(in: scroll, keeping: fewer) { list.reconcile(fewer, make: make) }
        let after = anchor.convert(anchor.bounds, to: scroll).minY - scroll.contentOffset.y
        precondition(abs(after - before) < 1, "Removing a row above the reader moved their position")
        list.reconcile(Array(fewer.reversed()), make: make)
        precondition(list.arrangedSubviews.first === list.card(for: "49") && creations == 50, "Reorder recreated rows")
        list.reconcile([], make: make); precondition(list.arrangedSubviews.isEmpty && list.card(for: "4") == nil)

        let status = OperationStatusView()
        precondition(status.isHidden)
        status.update(messages: ["Добавляем устройство…", "Меняем протокол…"], waiting: nil, cancellable: false)
        precondition(!status.isHidden && status.arrangedSubviews.compactMap { $0 as? UIActivityIndicatorView }.first?.isAnimating == true)
        status.update(messages: ["Добавляем устройство…"], waiting: "Ожидаем подключения.", cancellable: false)
        precondition(status.arrangedSubviews.compactMap { $0 as? UIActivityIndicatorView }.first?.isAnimating == false)
        status.update(messages: [], waiting: nil, cancellable: false)
        precondition(status.isHidden)

        let pager = PackagePagerView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        host.view.addSubview(pager)
        pager.reconcile(["short", "tall"]) { id in
            let card = UIView(); card.heightAnchor.constraint(equalToConstant: id == "short" ? 100 : 240).isActive = true; return card
        }
        pager.layoutIfNeeded()
        let initialMeasurements = pager.measurementCount
        for _ in 0..<100 { pager.setNeedsLayout(); pager.layoutIfNeeded() }
        precondition(pager.measurementCount == initialMeasurements, "Unchanged layout remeasured package cards")
        pager.frame.size.width = 300; pager.setNeedsLayout(); pager.layoutIfNeeded()
        precondition(pager.measurementCount == initialMeasurements + 2, "Width change did not remeasure all packages")
        let firstCard = pager.card(for: "short")!
        let dots = pager.subviews.compactMap { $0 as? UIPageControl }.first!
        precondition(dots.numberOfPages == 2 && abs(pager.intrinsicContentSize.height - 276) < 1)
        dots.currentPage = 1; dots.sendActions(for: .valueChanged)
        pager.setNeedsLayout(); pager.layoutIfNeeded()
        precondition(abs(pager.intrinsicContentSize.height - 276) < 1 && firstCard.accessibilityElementsHidden)
        pager.reconcile(["tall", "short"]) { _ in preconditionFailure("Existing page recreated") }
        pager.layoutIfNeeded()
        precondition(dots.currentPage == 0 && pager.card(for: "short") === firstCard)
        pager.reconcile(["short"]) { _ in preconditionFailure("Existing page recreated") }
        pager.layoutIfNeeded()
        precondition(dots.currentPage == 0 && !firstCard.accessibilityElementsHidden && abs(pager.intrinsicContentSize.height - 136) < 1)
        pager.reconcile([]) { _ in preconditionFailure("Unexpected page") }
        pager.layoutIfNeeded(); precondition(dots.numberOfPages == 0)
        pager.removeFromSuperview()
        let insetPager = PackagePagerView(horizontalInset: 20)
        insetPager.frame = CGRect(x: 0, y: 0, width: 320, height: 276)
        host.view.addSubview(insetPager)
        insetPager.reconcile(["a", "b"]) { _ in
            let card = UIView(); card.heightAnchor.constraint(equalToConstant: 240).isActive = true; return card
        }
        insetPager.layoutIfNeeded()
        let viewport = insetPager.subviews.compactMap { $0 as? UIScrollView }.first!
        precondition(viewport.bounds.width == 320 && viewport.contentSize.width == 640)
        precondition(insetPager.card(for: "a")!.frame == CGRect(x: 20, y: 0, width: 280, height: 240))
        precondition(insetPager.card(for: "b")!.frame.minX == 340)
        viewport.contentOffset.x = 160
        let movingCard = insetPager.card(for: "a")!
        precondition(movingCard.convert(movingCard.bounds, to: insetPager).minX == -140,
                     "Moving packages must cross the body margin inside the full-width viewport")
        insetPager.removeFromSuperview()
        print("PACKAGE_PAGER_CHECKS PASS: selection; fixed page-control height; identity through reorder; removal; empty state")

        func config(_ name: String) -> VPNConfiguration {
            try! JSONDecoder().decode(VPNConfiguration.self, from: JSONSerialization.data(withJSONObject: [
                "id": "vpn_01AAAAAAAAAAAAAAAAAAAAAAAA", "name": name, "protocol": "wireguard", "state": "active",
                "expiresAt": "2027-01-01T00:00:00Z", "canDownload": true, "canRename": true, "canDelete": true
            ]))
        }
        let table = PackageDeviceStack(frame: .zero)
        table.update([config("Cached")], protocols: [], busy: false, removingIDs: [])
        table.update([config("Before")], protocols: [], busy: false, removingIDs: [])
        table.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
        host.view.addSubview(table)
        table.layoutIfNeeded()
        let cell = table.card(for: config("Before").id) as! PackageDeviceView
        precondition(cell.nameLabel.text == "Before", "Deferred layout lost the latest device content")
        func measureDevices() -> CGFloat {
            table.systemLayoutSizeFitting(CGSize(width: 320, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        }
        print("DEVICE_STACK_CHECKS PASS: latest content available before layout")
        let button = cell.menuButton
        for i in 0..<100 {
            table.update([config("Before")], protocols: [], busy: i % 2 == 0, removingIDs: [])
        }
        precondition(table.card(for: config("Before").id) === cell && cell.menuButton === button, "Refresh replaced a native row or menu")
        table.update([config("After")], protocols: [], busy: false, removingIDs: [])
        precondition(cell.nameLabel.text == "After")
        table.update([config("After")], protocols: [], busy: true, removingIDs: [])
        precondition(!button.isEnabled && !cell.addButton.isEnabled && !cell.qrButton.isEnabled, "Busy row remains actionable")
        table.update([config("After")], protocols: [], busy: false, removingIDs: [config("After").id])
        precondition(!button.isEnabled, "Pending removal remains actionable")
        precondition(cell.detailLabel.text?.contains("Удаляется") == true)
        table.update([config("After")], protocols: [], busy: false, removingIDs: [])
        let menuTitles = button.menu!.children.compactMap { ($0 as? UIAction)?.title }
        precondition(menuTitles == ["Переименовать", "Удалить устройство"])
        var imported: [Bool] = []
        table.onDownload = { item, qr in precondition(item.displayName == "After"); imported.append(qr) }
        cell.addButton.sendActions(for: .touchUpInside); cell.qrButton.sendActions(for: .touchUpInside)
        precondition(imported == [false, true])
        // The first handshake arrives after an already-visible, undated row.
        table.layoutIfNeeded()
        let undatedHeight = measureDevices()
        var connectedJSON = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(config("After"))) as! [String: Any]
        connectedJSON["connection"] = ["status": "confirmed", "lastHandshakeAt": "2026-10-05T12:15:03.000000Z", "checkedAt": "2026-10-05T12:16:05.000000Z"]
        let connected = try! JSONDecoder().decode(VPNConfiguration.self, from: JSONSerialization.data(withJSONObject: connectedJSON))
        table.update([connected], protocols: [], busy: false, removingIDs: [])
        table.layoutIfNeeded(); cell.layoutIfNeeded()
        precondition(cell.detailLabel.text?.contains("Последнее подключение:") == true, "Production timestamp was not formatted")
        print("CONNECTION_ROW_HEIGHT before=\(undatedHeight) after=\(measureDevices())")
        precondition(measureDevices() > undatedHeight + 10, "First handshake text is clipped by cached row height")
        precondition(table.card(for: config("Before").id) === cell, "Handshake refresh replaced the device row")
        table.update([config("After")], protocols: [], busy: false, removingIDs: [])
        table.layoutIfNeeded()
        precondition(abs(measureDevices() - undatedHeight) < 1, "Removed handshake left a stale row height")
        print("CONNECTION_ROW_CHECKS PASS: production timestamp; first handshake expands existing row; removal shrinks it; identity preserved")
        table.removeFromSuperview()

        // Regression: two devices gain multi-line handshake metadata after the pager's first measurement.
        func subscription(dated: Bool) -> VPNPage.Package {
            var second = connectedJSON
            second["id"] = "vpn_01BBBBBBBBBBBBBBBBBBBBBBBB"
            second["name"] = "MacBook Air"
            if !dated { second.removeValue(forKey: "connection") }
            let first = dated ? connectedJSON : try! JSONSerialization.jsonObject(with: JSONEncoder().encode(config("iPhone"))) as! [String: Any]
            let slots: [[String: Any]] = (1...6).map { number in
                let device: Any
                if number == 1 { device = first }
                else if number == 2 { device = second }
                else { device = NSNull() }
                return ["number": number, "occupied": number <= 2, "canActivate": number > 2, "config": device]
            }
            return try! JSONDecoder().decode(VPNPage.Package.self, from: JSONSerialization.data(withJSONObject: [
                "id": "vpk_01AAAAAAAAAAAAAAAAAAAAAAAA", "name": "6 устройств", "deviceCount": 6,
                "usedSlots": 2, "origin": "purchase", "expiresAt": "2027-10-05T00:00:00Z", "slots": slots
            ]))
        }
        let packagePager = PackagePagerView(horizontalInset: 20)
        packagePager.frame = CGRect(x: 0, y: 0, width: 390, height: 240)
        host.view.addSubview(packagePager)
        packagePager.reconcile(["subscription"]) { _ in PackageCardView(frame: .zero) }
        let packageCard = packagePager.card(for: "subscription") as! PackageCardView
        packageCard.update(subscription(dated: false), protocols: [], busy: false, removingIDs: [], pendingSlots: [])
        packagePager.layoutIfNeeded()
        let initialHeight = packagePager.intrinsicContentSize.height
        packageCard.update(subscription(dated: true), protocols: [], busy: false, removingIDs: [], pendingSlots: [])
        for width: CGFloat in [390, 320, 430, 390] {
            packagePager.frame.size.width = width
            packagePager.setNeedsLayout(); packagePager.layoutIfNeeded()
            let add = packageCard.arrangedSubviews.compactMap { $0 as? UIButton }.last!
            precondition(!add.isHidden && add.bounds.height >= 44, "Available subscription lost its add button")
            precondition(add.frame.maxY <= packageCard.bounds.height - 19, "Add button lies outside measured subscription")
            for device in packageCard.devices.arrangedSubviews {
                precondition(device.frame.maxY <= packageCard.devices.bounds.height + 1, "A device is clipped by its parent")
            }
            precondition(packagePager.intrinsicContentSize.height > initialHeight + 20, "Handshake metadata did not expand the pager")
        }
        packageCard.update(subscription(dated: false), protocols: [], busy: false, removingIDs: [], pendingSlots: [])
        packagePager.layoutIfNeeded()
        precondition(abs(packagePager.intrinsicContentSize.height - initialHeight) < 1, "Pager retained obsolete device height")
        packagePager.removeFromSuperview()
        print("PACKAGE_CONTENT_HEIGHT_CHECKS PASS: late handshake metadata; two devices; add button; width changes; shrinking")

        let notification = try! JSONDecoder().decode(UserNotification.self, from: Data(#"{"id":"ntf_01AAAAAAAAAAAAAAAAAAAAAAAA","kind":"info","title":"Synthetic","body":"Synthetic notification","isRead":false,"createdAt":null}"#.utf8))
        let notice = NotificationCardView(frame: .zero)
        notice.update(notification, busy: false)
        let size = CGSize(width: 320, height: UIView.layoutFittingCompressedSize.height)
        let beforeHeight = notice.systemLayoutSizeFitting(size, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        notice.update(notification.markingRead(), busy: false)
        let afterHeight = notice.systemLayoutSizeFitting(size, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        precondition(abs(beforeHeight - afterHeight) < 1, "Reading a notification changes footer height")
        print("STABLE_CARD_CHECKS PASS: 100 unchanged refreshes; zero replacement views; reorder/removal anchoring; current actions; busy controls; stable read height")
    }
}
#endif

/// Full-width paging keeps inset cards and their device rows stable through refreshes.
final class PackagePagerView: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private var horizontalInset: CGFloat = 0
    private let pages = UIPageControl()
    private var cards: [String: UIView] = [:]
    private(set) var ids: [String] = []
    private var selectedID: String?
    private var pageHeight: CGFloat = 240
    private var previousWidth: CGFloat = 0
    private var isLayingOut = false
    private var measuredHeights: [String: CGFloat] = [:]
    private var measuredCategory: UIContentSizeCategory?
    #if DEBUG
    private(set) var measurementCount = 0
    #endif
    private func invalidateHeight(for id: String) {
        measuredHeights.removeValue(forKey: id); setNeedsLayout()
    }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: pageHeight + 36) }
    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self; scroll.isPagingEnabled = true
        scroll.showsHorizontalScrollIndicator = false; scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = false; scroll.isDirectionalLockEnabled = true
        addSubview(scroll); addSubview(pages)
        pages.currentPageIndicatorTintColor = .label; pages.pageIndicatorTintColor = .tertiaryLabel
        pages.hidesForSinglePage = true; pages.accessibilityLabel = "Подписки"
        pages.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.selectPage(self.pages.currentPage, animated: !UIAccessibility.isReduceMotionEnabled)
        }, for: .valueChanged)
    }
    convenience init(horizontalInset: CGFloat) {
        self.init(frame: .zero)
        self.horizontalInset = horizontalInset
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    func card(for id: String) -> UIView? { cards[id] }
    func reconcile(_ newIDs: [String], make: (String) -> UIView) {
        let oldIndex = ids.firstIndex(of: selectedID ?? "") ?? 0
        guard ids != newIDs else { return }
        for id in ids where !newIDs.contains(id) {
            cards.removeValue(forKey: id)?.removeFromSuperview(); measuredHeights.removeValue(forKey: id)
        }
        for id in newIDs where cards[id] == nil {
            let card = make(id); cards[id] = card
            (card as? PackageCardView)?.onContentChange = { [weak self] in self?.invalidateHeight(for: id) }
        }
        ids = newIDs
        if !ids.contains(selectedID ?? "") { selectedID = ids.isEmpty ? nil : ids[min(oldIndex, ids.count - 1)] }
        pages.numberOfPages = ids.count; pages.currentPage = ids.firstIndex(of: selectedID ?? "") ?? 0
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isLayingOut, bounds.width > 0 else { return }
        isLayingOut = true; defer { isLayingOut = false }
        let width = bounds.width
        let cardWidth = max(1, width - horizontalInset * 2)
        let category = traitCollection.preferredContentSizeCategory
        if previousWidth != width || measuredCategory != category {
            measuredHeights.removeAll(); measuredCategory = category
        }
        var heights: [CGFloat] = []
        for (index, id) in ids.enumerated() {
            guard let card = cards[id] else { continue }
            if measuredHeights[id] == nil {
                // Measure only changed content, or all cards after a width/text-size change.
                card.frame = CGRect(x: CGFloat(index) * width + horizontalInset, y: 0, width: cardWidth, height: max(card.bounds.height, 240))
                // Attach only after sizing; a cached page may be created before its pager is laid out.
                if card.superview !== scroll { scroll.addSubview(card) }
                let height = ceil(card.systemLayoutSizeFitting(CGSize(width: cardWidth, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
                card.frame.size.height = height; card.layoutIfNeeded()
                measuredHeights[id] = height
                #if DEBUG
                measurementCount += 1
                #endif
            }
            heights.append(measuredHeights[id] ?? 0)
            card.accessibilityElementsHidden = id != selectedID
        }
        let current = min(pages.currentPage, max(0, heights.count - 1))
        let height = heights.max() ?? 0
        for (index, id) in ids.enumerated() {
            cards[id]?.frame = CGRect(x: CGFloat(index) * width + horizontalInset, y: 0, width: cardWidth, height: height)
            cards[id]?.layoutIfNeeded()
        }
        if abs(pageHeight - height) > 0.5 { pageHeight = height; invalidateIntrinsicContentSize() }
        scroll.frame = CGRect(x: 0, y: 0, width: width, height: pageHeight)
        scroll.contentSize = CGSize(width: width * CGFloat(ids.count), height: pageHeight)
        pages.frame = CGRect(x: 0, y: pageHeight + 4, width: width, height: 32)
        if !scroll.isTracking && !scroll.isDecelerating {
            scroll.contentOffset = CGPoint(x: CGFloat(current) * width, y: 0)
        } else if previousWidth != width { scroll.contentOffset.x = CGFloat(current) * width }
        previousWidth = width
    }
    private func selectPage(_ index: Int, animated: Bool) {
        guard ids.indices.contains(index) else { return }
        selectedID = ids[index]; pages.currentPage = index
        scroll.setContentOffset(CGPoint(x: CGFloat(index) * bounds.width, y: 0), animated: animated)
        if !animated { setNeedsLayout() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishPaging() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { finishPaging() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { setNeedsLayout() }
    private func finishPaging() {
        guard bounds.width > 0 else { return }
        selectPage(min(max(0, Int((scroll.contentOffset.x / bounds.width).rounded())), max(0, ids.count - 1)), animated: false)
    }
    func preservingReadingPosition(in outer: UIScrollView, keeping: [String], changes: () -> Void) {
        // The pager stays in place; do not anchor to a different, off-screen package.
        changes(); setNeedsLayout()
    }
}
