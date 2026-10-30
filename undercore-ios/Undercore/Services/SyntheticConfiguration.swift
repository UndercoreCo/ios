#if DEBUG
import Foundation
import UndercoreCore
import CryptoKit

enum SyntheticConfiguration {
    static func make(amnezia: Bool) -> ConfigurationDownload {
        let privateKey = Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString()
        let publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let extra = amnezia ? "Jc = 4\nJmin = 40\nJmax = 70\nS1 = 120\nS2 = 80\nH1 = 100000001\nH2 = 100000002\nH3 = 100000003\nH4 = 100000004\n" : ""
        let data = Data("[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.254.254.2/32\n\(extra)\n[Peer]\nPublicKey = \(publicKey)\nAllowedIPs = 192.0.2.1/32\nEndpoint = 192.0.2.1:51820\n".utf8)
        return try! ConfigurationDownload(data: data, filename: amnezia ? "uc-test-awg-v1.conf" : "uc-test-wg-v1.conf")
    }
}
#endif

#if DEBUG
@MainActor final class PreviewConfigurationRepository: ConfigurationRepository {
    static let packageID = "vpk_01AAAAAAAAAAAAAAAAAAAAAAAA"
    static let configID = "vpn_01AAAAAAAAAAAAAAAAAAAAAAAA"
    var showsEmptyPage = false
    var occupied = true
    var activeProtocol = "amneziawg"
    var deleting = false
    var switchPending = false
    var switchSucceeds = false
    var activationTimeout = false
    var failObservation = false
    var activations: [SlotActivationRequest] = []
    var removals = 0
    var onRead: (() async -> Void)?
    private func decode<T: Decodable>(_ value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func configuration() -> [String: Any] {
        var value: [String: Any] = ["id": Self.configID, "name": "Мой iPhone", "protocol": activeProtocol,
            "state": "active", "expiresAt": "2027-10-04T05:34:13.000Z", "canDownload": !deleting,
            "canRename": !deleting, "canDelete": !deleting, "canSwitchProtocol": !deleting, "protocolRevision": 0]
        if ProcessInfo.processInfo.arguments.contains("--preview-active-operations") { value["state"] = "provisioning" }
        if deleting { value["deletion"] = ["status": "pending"] }
        if switchPending || ProcessInfo.processInfo.arguments.contains("--preview-protocol-pending") {
            value["protocolSwitch"] = ["pending": true, "target": "wireguard"]
            value["canSwitchProtocol"] = false; value["canDownload"] = false
        }
        return value
    }
    private func packageJSON() -> [String: Any] {
        ["id": Self.packageID, "name": "Подписка на 3 устройства", "deviceCount": 3,
         "usedSlots": occupied ? (ProcessInfo.processInfo.arguments.contains("--preview-device-blocks") ? 2 : 1) : 0, "origin": "purchase", "expiresAt": "2027-10-04T05:34:13.000Z",
         "autoRenewal": ["enabled": true],
         "slots": (1...3).map { number -> [String: Any] in
             let used = occupied && (number == 1 || (number == 2 && ProcessInfo.processInfo.arguments.contains("--preview-device-blocks")))
             var item = configuration()
             if number == 2 { item["id"] = "vpn_01BBBBBBBBBBBBBBBBBBBBBBBB"; item["name"] = "Рабочий MacBook"; item["protocol"] = "wireguard" }
             if number == 2 && ProcessInfo.processInfo.arguments.contains("--preview-active-operations") {
                 item["state"] = "active"; item["protocolSwitch"] = ["pending": true, "target": "amneziawg"]
             }
             return ["number": number, "occupied": used, "canActivate": !used,
                     "config": used ? item : NSNull()]
         }]
    }
    func page(_ number: Int) async throws -> VPNPage {
        var packages = showsEmptyPage ? [] : [packageJSON()]
        if !showsEmptyPage && ProcessInfo.processInfo.arguments.contains("--preview-package-pager") {
            var empty = packageJSON()
            empty["id"] = "vpk_01CCCCCCCCCCCCCCCCCCCCCCCC"; empty["deviceCount"] = 1; empty["usedSlots"] = 0
            empty["slots"] = [["number": 1, "occupied": false, "canActivate": true, "config": NSNull()]]
            packages.append(empty)
        }
        return try decode(["configs": [], "packages": packages,
            "automaticConnectionAvailable": ProcessInfo.processInfo.arguments.contains("--preview-automatic-vpn"), "protocols": [
            ["id": "wireguard", "label": "WireGuard", "available": true],
            ["id": "amneziawg", "label": "AmneziaWG", "available": true]], "pagination": ["page": 1, "lastPage": 1]])
    }
    func package(_ id: String) async throws -> VPNPage.Package {
        let snapshot: VPNPage.Package = try decode(packageJSON())
        if let onRead { await onRead() }
        if failObservation { throw URLError(.notConnectedToInternet) }
        return snapshot
    }
    func activate(packageID: String, slot: Int, request: SlotActivationRequest) async throws -> VPNConfiguration {
        activations.append(request)
        try await Task.sleep(for: .milliseconds(30))
        if activationTimeout { throw URLError(.timedOut) }
        occupied = true; activeProtocol = request.protocolName
        return try decode(configuration())
    }
    func remove(_ id: String) async throws -> DeviceRemovalReceipt {
        removals += 1
        try await Task.sleep(for: .milliseconds(30))
        deleting = true
        return try decode(["id": id, "status": "pending"])
    }
    func detail(_ id: String) async throws -> VPNConfiguration { try decode(configuration()) }
    func download(_ id: String) async throws -> ConfigurationDownload { SyntheticConfiguration.make(amnezia: true) }
    func rename(_ id: String, name: String) async throws -> VPNConfiguration { try await detail(id) }
    func switchProtocol(_ id: String, request: ProtocolSwitchRequest) async throws -> VPNConfiguration {
        if switchSucceeds { switchPending = true; return try await detail(id) }
        throw ClientError.server(status: 503, message: "Это только предпросмотр. Реальные конфигурации не изменяются.", retryAfter: nil)
    }
}

@MainActor enum PackageChecks {
    static func run() async {
        let suite = "package-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let repo = PreviewConfigurationRepository()
        let model = ConfigurationsViewModel(repository: repo, activations: DefaultsPendingActivationStore(defaults: defaults))
        await model.load(reset: true)
        precondition(model.packages.count == 1 && model.items.count == 1)
        precondition(model.operationMessages.isEmpty && model.state.message == nil)
        var activityHistory: [String] = []
        model.onChange = { [weak model] in activityHistory += model?.operationMessages ?? [] }
        let config = model.items[0]
        await model.rename(config, name: "Renamed")
        await model.download(config)
        await model.download(config, qrCode: true)
        precondition(activityHistory.contains("Сохраняем название…") && activityHistory.contains("Загружаем конфигурацию…") && activityHistory.contains("Готовим QR-код…"))
        precondition(model.operationMessages.isEmpty)
        repo.switchSucceeds = true
        await model.switchProtocol(config, to: model.protocols.first { $0.id == "wireguard" }!)
        precondition(model.operationMessages == ["Меняем протокол…"])
        model.pauseObservation()
        precondition(model.observationPaused, "Exhausted observation kept showing active work")
        repo.switchPending = false; repo.activeProtocol = "wireguard"
        _ = await model.refreshPendingOperations()
        precondition(!model.observationPaused)
        precondition(model.operationMessages.isEmpty && model.state.message == nil)
        async let first: Void = model.remove(config)
        async let duplicate: Void = model.remove(config)
        _ = await (first, duplicate)
        precondition(repo.removals == 1 && model.items[0].isDeleting)
        precondition(model.operationMessages == ["Удаляем устройство…"])
        repo.failObservation = true
        _ = await model.refreshPendingOperations()
        precondition(model.observationPaused && !model.operationMessages.isEmpty)
        repo.failObservation = false
        _ = await model.refreshPendingOperations()
        precondition(!model.observationPaused && model.state.message == nil)
        precondition(model.packages[0].slots[0].occupied && !model.packages[0].slots[0].canActivate)
        _ = await model.refreshPendingOperations()
        precondition(repo.removals == 1, "Polling retried destructive mutation")
        repo.occupied = false
        _ = await model.refreshPendingOperations()
        precondition(model.items.isEmpty && model.packages[0].slots[0].canActivate)
        precondition(model.operationMessages.isEmpty && model.state.message == nil)
        precondition(model.packages[0].expiresAt == "2027-10-04T05:34:13.000Z")
        repo.deleting = false; repo.activationTimeout = true; repo.failObservation = true
        async let add: Void = model.activate(packageID: PreviewConfigurationRepository.packageID, slot: 1, protocolName: "wireguard")
        async let addDuplicate: Void = model.activate(packageID: PreviewConfigurationRepository.packageID, slot: 1, protocolName: "wireguard")
        _ = await (add, addDuplicate)
        precondition(repo.activations.count == 1 && model.items.isEmpty)
        precondition(activityHistory.contains("Добавляем устройство…"))
        let restored = ConfigurationsViewModel(repository: repo, activations: DefaultsPendingActivationStore(defaults: defaults))
        await restored.load(reset: true)
        precondition(restored.pendingActivation(packageID: PreviewConfigurationRepository.packageID, slot: 1) == repo.activations[0])
        await restored.activate(packageID: PreviewConfigurationRepository.packageID, slot: 1, protocolName: "amneziawg")
        precondition(repo.activations.count == 1, "Changed protocol reused ambiguous identity")
        repo.activationTimeout = false; repo.failObservation = false
        await restored.activate(packageID: PreviewConfigurationRepository.packageID, slot: 1, protocolName: "wireguard")
        precondition(repo.activations.count == 2 && repo.activations[0] == repo.activations[1])
        precondition(restored.items.count == 1 && restored.pendingActivation(packageID: PreviewConfigurationRepository.packageID, slot: 1) == nil)
        // A slow poll started before a mutation must not overwrite its result.
        repo.deleting = true
        await restored.load(reset: true)
        repo.onRead = { try? await Task.sleep(for: .milliseconds(100)) }
        async let poll: Bool = restored.refreshPendingOperations()
        try? await Task.sleep(for: .milliseconds(10))
        repo.deleting = false
        await restored.load(reset: true)
        _ = await poll
        precondition(!restored.items[0].isDeleting, "Stale poll overwrote newer list")
        repo.onRead = nil; repo.failObservation = true
        await restored.remove(restored.items[0])
        precondition(restored.removingIDs.contains(PreviewConfigurationRepository.configID), "Lost read freed accepted removal")
        precondition(restored.packages[0].slots[0].occupied)
        repo.failObservation = false; repo.occupied = false
        _ = await restored.refreshPendingOperations()
        precondition(restored.items.isEmpty && restored.removingIDs.isEmpty && !restored.hasPendingOperations)
        precondition(restored.operationMessages.isEmpty && restored.state.message == nil)
        let cachedRepo = PreviewConfigurationRepository()
        let pending = try! SlotActivationRequest(protocolName: "amneziawg")
        defaults.set(try! JSONEncoder().encode(pending), forKey: "vpn.slot-activation.\(PreviewConfigurationRepository.packageID).1")
        let cachedModel = ConfigurationsViewModel(repository: cachedRepo, activations: DefaultsPendingActivationStore(defaults: defaults))
        cachedModel.isOffline = true
        await cachedModel.load(reset: true)
        precondition(cachedModel.pendingActivation(packageID: PreviewConfigurationRepository.packageID, slot: 1) == pending, "Snapshot acknowledged an uncertain activation")
        await cachedModel.remove(cachedModel.items[0])
        await cachedModel.activate(packageID: PreviewConfigurationRepository.packageID, slot: 1, protocolName: "amneziawg")
        precondition(cachedRepo.removals == 0 && cachedRepo.activations.isEmpty)
        cachedModel.isOffline = false
        await cachedModel.load(reset: true)
        precondition(cachedModel.pendingActivation(packageID: PreviewConfigurationRepository.packageID, slot: 1) == nil)
        print("OFFLINE OPERATION CHECK PASS: snapshot never acknowledges pending actions; mutations blocked; fresh state reconciles")
        print("OPERATION_STATUS_CHECKS PASS: rename; download; QR; adding; pending switch/removal; completion clears activity")
        print("PACKAGE CHECKS PASS: grouped slots; duplicate taps; pending revoke retains slot; confirmed release; expiry preserved; timeout replay across relaunch; no mutation polling; stale read discarded")
    }
}
#endif
