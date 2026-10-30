import Foundation

@MainActor public protocol PendingActivationStore {
    func request(packageID: String, slot: Int) -> SlotActivationRequest?
    func save(_ request: SlotActivationRequest, packageID: String, slot: Int) throws
    func remove(packageID: String, slot: Int)
}

/// Keeps the operation identity across timeouts and app restarts. Contains no VPN keys.
@MainActor public final class DefaultsPendingActivationStore: PendingActivationStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func request(packageID: String, slot: Int) -> SlotActivationRequest? {
        guard let data = defaults.data(forKey: key(packageID, slot)),
              let request = try? JSONDecoder().decode(SlotActivationRequest.self, from: data),
              UUID(uuidString: request.requestKey) != nil,
              ["wireguard", "amneziawg"].contains(request.protocolName) else { return nil }
        return request
    }

    public func save(_ request: SlotActivationRequest, packageID: String, slot: Int) throws {
        defaults.set(try JSONEncoder().encode(request), forKey: key(packageID, slot))
    }

    public func remove(packageID: String, slot: Int) {
        defaults.removeObject(forKey: key(packageID, slot))
    }

    private func key(_ packageID: String, _ slot: Int) -> String {
        "vpn.slot-activation.\(packageID).\(slot)"
    }
}
