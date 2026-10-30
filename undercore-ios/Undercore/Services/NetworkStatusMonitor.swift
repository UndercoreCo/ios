import Foundation
import Network

@MainActor protocol NetworkStatusObserving: AnyObject {
    var onChange: ((Bool) -> Void)? { get set }
    func start()
}

/// A device-path hint for UI only. It does not prove that the API is reachable.
@MainActor final class NetworkStatusMonitor: NetworkStatusObserving {
    var onChange: ((Bool) -> Void)?
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ru.undercore.network-status", qos: .utility)
    private var started = false
    private var offline: Bool?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            // requiresConnection can be an on-demand path: do not claim it is offline.
            let offline = path.status == .unsatisfied
            Task { @MainActor [weak self] in
                guard let self, self.offline != offline else { return }
                self.offline = offline
                self.onChange?(offline)
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

#if DEBUG
@MainActor final class PreviewNetworkStatus: NetworkStatusObserving {
    var onChange: ((Bool) -> Void)?
    private(set) var offline = false
    func start() { onChange?(offline) }
    func update(offline: Bool) { self.offline = offline; onChange?(offline) }
}
#endif
