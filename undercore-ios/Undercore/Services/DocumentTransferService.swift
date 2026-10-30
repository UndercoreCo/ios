import UIKit
import UndercoreCore

@MainActor final class DocumentTransferService: NSObject, @preconcurrency UIDocumentInteractionControllerDelegate {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(AppConfiguration.temporaryDirectoryName, isDirectory: true)
    private var document: UIDocumentInteractionController?
    private weak var presenter: UIViewController?
    private var guide: UIView?
    override init() { super.init(); clearFiles() }
    func clearFiles() { removeGuide(); try? FileManager.default.removeItem(at: directory) }
    func present(data: ConfigurationDownload, applicationName: String, from presenter: UIViewController, source: UIView) throws {
        guard data.data.count <= AppConfiguration.maxConfigurationBytes else { throw TransferError.invalidFile }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(data.filename)
        try data.data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        self.presenter = presenter
        let controller = UIDocumentInteractionController(url: url)
        controller.uti = AppConfiguration.configurationUTI
        controller.delegate = self
        document = controller
        showGuide(applicationName: applicationName, in: presenter.view)
        guard controller.presentOpenInMenu(from: source.bounds, in: source, animated: true) else {
            removeGuide()
            throw TransferError.noApplication
        }
    }
    private func showGuide(applicationName: String, in host: UIView) {
        removeGuide()
        let guide = TransferGuideView(applicationName: applicationName)
        guide.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: host.leadingAnchor), guide.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            guide.topAnchor.constraint(equalTo: host.topAnchor), guide.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutIfNeeded()
        self.guide = guide
        UIAccessibility.post(notification: .announcement, argument: guide.instructions)
    }
    private func removeGuide() { guide?.removeFromSuperview(); guide = nil }
    func documentInteractionControllerDidDismissOpenInMenu(_ controller: UIDocumentInteractionController) {
        guard controller === document else { return }
        removeGuide()
    }
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController { presenter ?? UIViewController() }
    enum TransferError: Error, LocalizedError {
        case noApplication, invalidFile
        var errorDescription: String? { self == .noApplication ? "iOS не предложила VPN-приложение. Установите WireGuard или AmneziaWG и попробуйте снова." : "Не удалось подготовить конфигурацию." }
    }
}

/// Remains behind the system picker, without adding another confirmation step.
private final class TransferGuideView: UIView {
    let instructions: String
    init(applicationName: String) {
        instructions = "В меню ниже выберите \(applicationName). Если его нет — пролистайте ряд приложений и нажмите «Ещё»."
        super.init(frame: .zero)
        backgroundColor = .systemGroupedBackground
        isUserInteractionEnabled = false
        let title = UILabel()
        title.text = "Добавляем в \(applicationName)"
        title.font = .preferredFont(forTextStyle: .title2)
        title.accessibilityTraits = .header
        let steps = UILabel()
        steps.text = instructions
        steps.font = .preferredFont(forTextStyle: .body)
        let footer = UILabel()
        footer.text = "Включите новую конфигурацию. Старую удалите после проверки."
        footer.font = .preferredFont(forTextStyle: .callout)
        footer.textColor = .secondaryLabel
        [title, steps, footer].forEach { $0.numberOfLines = 0; $0.adjustsFontForContentSizeCategory = true }
        let text = UIStackView(arrangedSubviews: [title, steps, footer])
        text.axis = .vertical; text.spacing = 12
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Theme.inset),
            text.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Theme.inset),
            text.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: Theme.inset)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
}
