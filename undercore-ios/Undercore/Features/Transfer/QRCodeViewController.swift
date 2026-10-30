import UIKit
import CoreImage.CIFilterBuiltins

final class QRCodeViewController: UIViewController {
    private let image: UIImage
    private let configurationName: String
    private let imageView = UIImageView()
    init(data: Data, name: String) throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else {
            throw NSError(domain: "Undercore.QR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать QR-код."])
        }
        image = UIImage(cgImage: cgImage)
        configurationName = name
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "QR-код"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let title = UILabel(); title.text = configurationName; title.font = .preferredFont(forTextStyle: .headline); title.numberOfLines = 0; title.textAlignment = .center; title.adjustsFontForContentSizeCategory = true
        imageView.image = image; imageView.contentMode = .scaleAspectFit
        imageView.layer.magnificationFilter = .nearest
        imageView.accessibilityLabel = "QR-код VPN-конфигурации"
        let paper = UIView(); paper.backgroundColor = .white; paper.layer.cornerRadius = Theme.radius
        imageView.translatesAutoresizingMaskIntoConstraints = false; paper.addSubview(imageView)
        let hint = UILabel(); hint.text = "Откройте VPN-приложение на другом устройстве и отсканируйте код. На этом телефоне используйте «Добавить в приложение»."; hint.numberOfLines = 0; hint.font = .preferredFont(forTextStyle: .callout); hint.textColor = .secondaryLabel; hint.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [title, paper, hint]); stack.axis = .vertical; stack.spacing = Theme.gap; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.inset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.inset),
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.inset),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.inset),
            paper.heightAnchor.constraint(equalTo: paper.widthAnchor),
            imageView.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 20), imageView.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -20),
            imageView.topAnchor.constraint(equalTo: paper.topAnchor, constant: 20), imageView.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -20)
        ])
        let preferredWidth = stack.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -Theme.inset * 2)
        preferredWidth.priority = .defaultHigh; preferredWidth.isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(hideCode), name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showCode), name: UIScene.didActivateNotification, object: nil)
    }
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        imageView.isHidden = view.window?.windowScene?.activationState != .foregroundActive
    }
    @objc private func hideCode(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        imageView.isHidden = true
    }
    @objc private func showCode(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        imageView.isHidden = false
    }
}
