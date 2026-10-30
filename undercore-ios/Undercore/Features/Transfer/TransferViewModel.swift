import Foundation
import UndercoreCore

@MainActor final class TransferViewModel {
    private let loader: () async throws -> ConfigurationDownload
    private(set) var state = ScreenState() { didSet { onState?(state) } }
    var onState: ((ScreenState) -> Void)?
    var onData: ((ConfigurationDownload) throws -> Void)?
    var onSessionExpired: (() -> Void)?
    init(loader: @escaping () async throws -> ConfigurationDownload) { self.loader = loader }
    func load() async {
        guard !state.isBusy else { return }
        state = ScreenState(isBusy: true)
        defer { state.isBusy = false }
        do {
            let data = try await loader()
            try onData?(data)
            state.message = "После передачи проверьте, появилось ли подключение в VPN-приложении."
        } catch {
            state.message = (error as? DocumentTransferService.TransferError)?.localizedDescription ?? readableError(error)
            if error as? ClientError == .expiredSession { onSessionExpired?() }
        }
    }
}
