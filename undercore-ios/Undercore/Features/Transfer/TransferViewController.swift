import UIKit
import UndercoreCore

final class TransferViewController: FormViewController {
    private let service: DocumentTransferService
    private let model: TransferViewModel
    private let applicationName: String
    private let send = PrimaryButton(CommonText.send)
    var onSessionExpired: (() -> Void)? { didSet { model.onSessionExpired = onSessionExpired } }
    init(service: DocumentTransferService, applicationName: String, loader: @escaping () async throws -> ConfigurationDownload) {
        self.service = service; self.applicationName = applicationName; self.model = TransferViewModel(loader: loader)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Установка конфигурации"
        addText("Добавим подключение", style: .title1)
        addText("Нажмите кнопку и выберите \(applicationName) в списке приложений. Подтвердите добавление в самом VPN-приложении.")
        send.addTarget(self, action: #selector(transfer), for: .touchUpInside)
        stack.addArrangedSubview(send); addFeedback()
        model.onState = { [weak self] state in
            guard let self else { return }
            self.feedback(state, controls: [self.send])
        }
        model.onData = { [weak self] data in
            guard let self, self.view.window != nil,
                  self.navigationController?.topViewController === self else { throw CancellationError() }
            try self.service.present(data: data, applicationName: self.applicationName, from: self, source: self.send)
        }
    }
    @objc private func transfer() { Task { [weak self] in await self?.model.load() } }
}
