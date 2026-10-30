import Foundation

public struct PollingPlan {
    let intervalNanoseconds: UInt64
    let attempts: Int
    let refreshImmediately: Bool

    public static let pendingDevices = PollingPlan(intervalNanoseconds: 5_000_000_000, attempts: 24, refreshImmediately: false)
    public static let messengerConnections = PollingPlan(intervalNanoseconds: 2_000_000_000, attempts: 3, refreshImmediately: true)
}

/// Serial, cancellable observation. Cancelling never starts or retries a mutation.
@MainActor public final class BoundedPoller {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let sleep: (UInt64) async throws -> Void
    public var isRunning: Bool { task.map { !$0.isCancelled } ?? false }

    public init() { sleep = { try await Task.sleep(nanoseconds: $0) } }
    init(sleep: @escaping (UInt64) async throws -> Void) { self.sleep = sleep }
    deinit { task?.cancel() }

    public func cancel() {
        generation = UUID()
        task?.cancel()
    }

    public func start(plan: PollingPlan, while shouldContinue: @escaping @MainActor () -> Bool,
                      refresh: @escaping @MainActor () async -> Bool,
                      onExhausted: @escaping @MainActor () -> Void = {}) {
        let previous = task
        previous?.cancel()
        let current = UUID()
        generation = current
        let sleep = self.sleep
        task = Task { [weak self] in
            // A cancelled request can still be unwinding. Wait before touching shared model state.
            await previous?.value
            defer { if self?.generation == current { self?.task = nil } }
            guard !Task.isCancelled, shouldContinue() else { return }
            if plan.refreshImmediately {
                guard await refresh(), !Task.isCancelled else { return }
            }
            for _ in 0..<plan.attempts {
                guard !Task.isCancelled, shouldContinue() else { return }
                do { try await sleep(plan.intervalNanoseconds) } catch { return }
                guard !Task.isCancelled, shouldContinue(), await refresh() else { return }
            }
            guard !Task.isCancelled, self?.generation == current else { return }
            onExhausted()
        }
    }
}
