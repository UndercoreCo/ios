import Foundation
import UndercoreCore

@MainActor final class ConfigurationsViewModel {
    var isOffline = false
    private let repository: ConfigurationRepository
    private(set) var packages: [VPNPage.Package] = []
    var items: [VPNConfiguration] { packages.flatMap { $0.slots.compactMap(\.config) } }
    private let activations: PendingActivationStore
    private var observingPackages = Set<String>()
    private(set) var removingIDs = Set<String>()
    private var removalPackages: [String: String] = [:]
    private var revision = 0
    private enum ActionKind: CaseIterable {
        case loading, adding, switching, removing, renaming, download, qr, checking
        func text(count: Int) -> String {
            switch self {
            case .loading: return "Обновляем подписки…"
            case .adding: return count == 1 ? "Добавляем устройство…" : "Добавляем устройства: \(count)…"
            case .switching: return count == 1 ? "Меняем протокол…" : "Меняем протокол у устройств: \(count)…"
            case .removing: return count == 1 ? "Удаляем устройство…" : "Удаляем устройства: \(count)…"
            case .renaming: return "Сохраняем название…"
            case .download: return "Загружаем конфигурацию…"
            case .qr: return "Готовим QR-код…"
            case .checking: return "Проверяем состояние устройств…"
            }
        }
    }
    private struct RunningAction {
        let kind: ActionKind
        let key: String
        let packageID: String?
    }
    private var runningAction: RunningAction?
    private(set) var observationPaused = false
    /// Derive activity from outstanding work, never from a previous success message.
    var operationMessages: [String] {
        guard !isOffline else { return [] }
        var tasks: [String: ActionKind] = [:]
        for package in packages {
            for slot in package.slots {
                guard let config = slot.config else { continue }
                let key = "\(package.id):\(slot.number)"
                if removingIDs.contains(config.id) || config.isDeleting { tasks[key] = .removing }
                else if config.isSwitchingProtocol { tasks[key] = .switching }
                else if config.state == "provisioning" { tasks[key] = .adding }
            }
            if observingPackages.contains(package.id), runningAction?.packageID != package.id,
               !tasks.keys.contains(where: { $0.hasPrefix(package.id + ":") }) {
                tasks[package.id] = .checking
            }
        }
        if let runningAction { tasks[runningAction.key] = runningAction.kind }
        return ActionKind.allCases.compactMap { kind in
            let count = tasks.values.filter { $0 == kind }.count
            return count > 0 ? kind.text(count: count) : nil
        }
    }
    private func begin(_ kind: ActionKind, configID: String? = nil, packageID: String? = nil, slot: Int? = nil) {
        var packageID = packageID
        var slot = slot
        if let configID, let package = packages.first(where: { $0.slots.contains { $0.config?.id == configID } }) {
            packageID = package.id; slot = package.slots.first(where: { $0.config?.id == configID })?.number
        }
        let key = packageID.flatMap { id in slot.map { "\(id):\($0)" } } ?? "foreground"
        runningAction = RunningAction(kind: kind, key: key, packageID: packageID)
        observationPaused = false
        state = ScreenState(isBusy: true)
    }
    private func finish() { runningAction = nil; state.isBusy = false }
    var activationOptions: [VPNProtocolOption] { protocols.filter { $0.available && ["wireguard", "amneziawg"].contains($0.id) }.sorted { $0.id == "amneziawg" && $1.id != "amneziawg" } }
    var hasPendingOperations: Bool {
        packages.contains { package in
            observingPackages.contains(package.id) || package.slots.contains {
                guard let config = $0.config else { return false }
                return removingIDs.contains(config.id) || config.isDeleting || config.isSwitchingProtocol || config.state == "provisioning"
            }
        }
    }
    private(set) var protocols: [VPNProtocolOption] = []
    private var switchRequests: [String: ProtocolSwitchRequest] = [:]
    var onProtocolReady: ((String) -> Void)?
    var onProtocolError: ((String) -> Void)?
    private(set) var page = 0
    private(set) var lastPage = 1
    private(set) var state = ScreenState() { didSet { onChange?() } }
    var onChange: (() -> Void)?
    var onSessionExpired: (() -> Void)?
    var onTransferProgress: ((String?) -> Void)?
    var onTransferError: ((String) -> Void)?
    var onQRCode: ((Data, String) -> Void)?
    var onDownload: ((ConfigurationDownload, String) -> Void)?
    init(repository: ConfigurationRepository, activations: PendingActivationStore? = nil) {
        self.repository = repository
        self.activations = activations ?? DefaultsPendingActivationStore()
    }
    func load(reset: Bool) async {
        guard !state.isBusy else { return }
        self.revision += 1
        begin(.loading)
        defer { finish() }
        do {
            let result = try await repository.page(reset ? 1 : page + 1)
            try Task.checkCancellation()
            protocols = result.protocols ?? []
            for package in result.packages { apply(package) }
            if reset {
                let byID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
                packages = result.packages.compactMap { byID[$0.id] }
            }
            page = result.pagination.page; lastPage = result.pagination.lastPage
        } catch { handle(error) }
    }
    func download(_ configuration: VPNConfiguration, qrCode: Bool = false) async {
        guard !isOffline else { return }
        guard !state.isBusy else { return }
        self.revision += 1
        begin(qrCode ? .qr : .download, configID: configuration.id)
        onTransferProgress?(qrCode ? "Готовим QR-код…" : "Загружаем конфигурацию…")
        defer { onTransferProgress?(nil); finish() }
        do {
            let data = try await repository.download(configuration.id)
            try Task.checkCancellation()
            onTransferProgress?(nil)
            if qrCode { onQRCode?(data.data, configuration.displayName) }
            else { onDownload?(data, configuration.applicationName) }
        } catch is CancellationError { }
        catch {
            onTransferProgress?(nil)
            if (error as? URLError)?.code != .cancelled {
                handle(error)
                if error as? ClientError != .expiredSession { onTransferError?(readableError(error)) }
            }
        }
    }
    func rename(_ configuration: VPNConfiguration, name: String) async {
        guard !isOffline else { return }
        guard !state.isBusy else { return }
        self.revision += 1
        begin(.renaming, configID: configuration.id)
        defer { finish() }
        do {
            let updated = try await repository.rename(configuration.id, name: name)
            replace(updated)
        } catch { handle(error) }
    }
    func switchProtocol(_ configuration: VPNConfiguration, to target: VPNProtocolOption) async {
        guard !isOffline else { return }
        guard !state.isBusy, let current = items.first(where: { $0.id == configuration.id }),
              current.protocolRevision == configuration.protocolRevision,
              current.switchOptions(from: protocols).contains(where: { $0.id == target.id }),
              let revision = current.protocolRevision else { return }
        self.revision += 1
        begin(.switching, configID: configuration.id)
        defer { finish() }
        do {
            let key = "\(current.id):\(revision):\(target.id)"
            let request = try switchRequests[key] ?? ProtocolSwitchRequest(protocolName: target.id, revision: revision)
            switchRequests[key] = request // A timeout retry must reuse the same operation identity.
            let updated = try await repository.switchProtocol(current.id, request: request)
            replace(updated)
            if !updated.isSwitchingProtocol && updated.protocolName == target.id && updated.canDownload {
                onProtocolReady?(updated.applicationName)
            }
        } catch {
            if error as? ClientError == .expiredSession { handle(error); return }
            // A lost response does not mean the server rejected the operation. Observe before retrying.
            do {
                let observed = try await repository.detail(current.id)
                replace(observed)
                if observed.isSwitchingProtocol {
                    return
                }
                if observed.protocolName == target.id && observed.canDownload {
                    onProtocolReady?(observed.applicationName); return
                }
            } catch ClientError.expiredSession { handle(ClientError.expiredSession); return }
            catch { /* Keep the original request error; no automatic mutation retry. */ }
            handle(error)
            onProtocolError?(readableError(error))
        }
    }
    func pauseObservation() {
        guard hasPendingOperations, !state.isBusy else { return }
        observationPaused = true
        onChange?()
    }
    func refreshPendingOperations() async -> Bool {
        guard !isOffline else { return false }
        guard !state.isBusy else { return true }
        let generation = revision
        let pending = packages.filter { package in
            observingPackages.contains(package.id) || package.slots.contains {
                guard let config = $0.config else { return false }
                return removingIDs.contains(config.id) || config.isDeleting || config.isSwitchingProtocol || config.state == "provisioning"
            }
        }
        for package in pending {
            do {
                let updated = try await repository.package(package.id)
                try Task.checkCancellation()
                guard !state.isBusy, revision == generation else { return true }
                apply(updated)
                for old in package.slots.compactMap(\.config).filter({ $0.isSwitchingProtocol }) {
                    if let new = updated.slots.compactMap(\.config).first(where: { $0.id == old.id }),
                       !new.isSwitchingProtocol, new.protocolName == old.protocolSwitch?.target, new.canDownload {
                        onProtocolReady?(new.applicationName)
                    }
                }
                onChange?()
            } catch is CancellationError { return false }
            catch {
                guard !state.isBusy, revision == generation else { return true }
                observationPaused = true
                handle(error); return false
            }
        }
        return hasPendingOperations
    }
    func pendingActivation(packageID: String, slot: Int) -> SlotActivationRequest? {
        activations.request(packageID: packageID, slot: slot)
    }
    func activate(packageID: String, slot: Int, protocolName: String) async {
        guard !isOffline else { return }
        guard !state.isBusy,
              let current = packages.first(where: { $0.id == packageID })?.slots.first(where: { $0.number == slot }),
              current.canActivate, !current.occupied,
              activationOptions.contains(where: { $0.id == protocolName }) else { return }
        self.revision += 1
        begin(.adding, packageID: packageID, slot: slot)
        defer { finish() }
        do {
            let request = try pendingActivation(packageID: packageID, slot: slot) ?? SlotActivationRequest(protocolName: protocolName)
            guard request.protocolName == protocolName else {
                state.message = "Сначала повторите прежний запрос добавления устройства или обновите список."; return
            }
            // Persist before sending: a lost response/relaunch must not create a new operation identity.
            try activations.save(request, packageID: packageID, slot: slot)
            observingPackages.insert(packageID)
            _ = try await repository.activate(packageID: packageID, slot: slot, request: request)
            let observed = try await repository.package(packageID)
            apply(observed)
        } catch {
            if error as? ClientError == .expiredSession { handle(error); return }
            do {
                let observed = try await repository.package(packageID)
                apply(observed)
                if observed.slots.first(where: { $0.number == slot })?.occupied == true {
                    return
                }
                // A definitive conflict plus a freshly observed free slot permits a NEW user action.
                if case ClientError.server(status: 409, message: _, retryAfter: _) = error {
                    activations.remove(packageID: packageID, slot: slot)
                }
            } catch ClientError.expiredSession { handle(ClientError.expiredSession); return }
            catch { /* Retain original error and operation identity. */ }
            handle(error)
            if error is URLError || error as? ClientError == .invalidResponse {
                state.message = "Не удалось подтвердить добавление. Обновите список. При повторной попытке проверим тот же запрос — второе устройство не создастся."
            }
        }
    }
    func remove(_ configuration: VPNConfiguration) async {
        guard !isOffline else { return }
        guard !state.isBusy, let current = items.first(where: { $0.id == configuration.id }),
              current.canDelete == true, !current.isDeleting, !removingIDs.contains(current.id),
              let package = packages.first(where: { $0.slots.contains { $0.config?.id == current.id } }) else { return }
        self.revision += 1
        begin(.removing, configID: configuration.id)
        defer { finish() }
        do {
            _ = try await repository.remove(current.id)
            removingIDs.insert(current.id)
            removalPackages[current.id] = package.id
            observingPackages.insert(package.id)
            apply(try await repository.package(package.id))
        } catch {
            if error as? ClientError == .expiredSession { handle(error); return }
            observingPackages.insert(package.id)
            do {
                let observed = try await repository.package(package.id)
                apply(observed)
                let config = observed.slots.compactMap(\.config).first { $0.id == current.id }
                if config == nil || config?.isDeleting == true {
                    return
                }
            } catch ClientError.expiredSession { handle(ClientError.expiredSession); return }
            catch { /* Retain original error and operation identity. */ }
            handle(error)
            if error is URLError || error as? ClientError == .invalidResponse {
                state.message = "Не удалось подтвердить удаление. Обновите список, чтобы проверить состояние устройства."
            }
        }
    }
    private func apply(_ package: VPNPage.Package) {
        let previous = packages.first { $0.id == package.id }
        let formerlyPending = previous?.slots.compactMap(\.config).filter { $0.isDeleting }.map(\.id) ?? []
        if let index = packages.firstIndex(where: { $0.id == package.id }) { packages[index] = package }
        else { packages.append(package) }
        // A snapshot is for display only; it must not acknowledge an uncertain server action.
        guard !isOffline else { return }
        observationPaused = false
        observingPackages.remove(package.id)
        for slot in package.slots where slot.occupied {
            activations.remove(packageID: package.id, slot: slot.number)
        }
        let present = Set(package.slots.compactMap { $0.config?.id })
        let acknowledged = Set(removalPackages.filter { $0.value == package.id }.map(\.key))
        let completed = acknowledged.union(formerlyPending).subtracting(present)
        removingIDs.subtract(completed)
        for id in completed { removalPackages.removeValue(forKey: id) }
        // Server now represents pending deletion itself; don't keep a local duplicate state.
        removingIDs.subtract(package.slots.compactMap { $0.config?.isDeleting == true ? $0.config?.id : nil })
        if state.message != nil { state.message = nil }
    }
    private func replace(_ configuration: VPNConfiguration) {
        for p in packages.indices {
            if let s = packages[p].slots.firstIndex(where: { $0.config?.id == configuration.id }) {
                packages[p].slots[s].config = configuration
            }
        }
    }
    private func handle(_ error: Error) {
        state.message = readableError(error)
        if error as? ClientError == .expiredSession { onSessionExpired?() }
    }
}
