import Foundation
import UndercoreCore

@MainActor final class NotificationsViewModel {
    var isOffline = false
    private let repository: NotificationRepository
    private(set) var items: [UserNotification] = []
    private(set) var unreadCount = 0 { didSet { onUnreadCount?(unreadCount); onChange?() } }
    private(set) var state = ScreenState() { didSet { onChange?() } }
    private var revision = 0
    private var refreshingSummary = false
    private var readingIDs = Set<String>()
    private var confirmedReadIDs = Set<String>()
    var onChange: (() -> Void)?
    var onUnreadCount: ((Int) -> Void)?
    var onSessionExpired: (() -> Void)?
    init(repository: NotificationRepository) { self.repository = repository }
    func load() async {
        guard !state.isBusy else { return }
        revision += 1
        state = ScreenState(isBusy: true)
        defer { state.isBusy = false }
        do {
            let response = try await repository.page(1)
            try Task.checkCancellation()
            var known = Set<String>()
            items = response.data.filter { known.insert($0.id).inserted }
                .prefix(NotificationPage.recentLimit)
                .map { confirmedReadIDs.contains($0.id) ? $0.markingRead() : $0 }
            confirmedReadIDs.formIntersection(Set(items.map(\.id)))
            if !isOffline { try await updateSummary() }
        } catch { handle(error) }
    }
    func refreshUnread() async {
        guard !state.isBusy, !refreshingSummary else { return }
        refreshingSummary = true
        defer { refreshingSummary = false }
        do { try await updateSummary() }
        catch { if error as? ClientError == .expiredSession { onSessionExpired?() } }
    }
    private func updateSummary() async throws {
        let version = revision
        let summary = try await repository.summary()
        guard version == revision else { return }
        unreadCount = max(0, summary.unreadCount)
    }
    /// Reading visible cards is quiet and does not block scrolling or recreate the list.
    func markVisibleRead(_ ids: [String]) async {
        guard !isOffline else { return }
        guard !state.isBusy else { return }
        var changed = false
        for id in ids {
            guard !Task.isCancelled else { break }
            guard !readingIDs.contains(id), let item = items.first(where: { $0.id == id }), !item.isRead else { continue }
            readingIDs.insert(id)
            do {
                let updated = try await repository.markRead(id)
                if updated.isRead {
                    revision += 1
                    confirmedReadIDs.insert(id)
                    let wasUnread = items.first(where: { $0.id == id })?.isRead == false
                    if let index = items.firstIndex(where: { $0.id == id }) { items[index] = updated }
                    if wasUnread { unreadCount = max(0, unreadCount - 1) }
                    changed = true
                }
            } catch {
                if error as? ClientError == .expiredSession { onSessionExpired?() }
                // A later visit/refresh retries; no request loop and no noisy alert while reading.
            }
            readingIDs.remove(id)
        }
        if changed {
            do { try await updateSummary() }
            catch { if error as? ClientError == .expiredSession { onSessionExpired?() } }
        }
    }
    func markAllRead() async {
        guard !isOffline else { return }
        guard !state.isBusy, unreadCount > 0 else { return }
        revision += 1
        state = ScreenState(isBusy: true)
        defer { state.isBusy = false }
        do {
            let result = try await repository.markAllRead()
            confirmedReadIDs.formUnion(items.map(\.id))
            items = items.map { $0.markingRead() }
            unreadCount = max(0, result.unreadCount)
        } catch { handle(error) }
    }
    private func handle(_ error: Error) {
        state.message = readableError(error)
        if error as? ClientError == .expiredSession { onSessionExpired?() }
    }
}

#if DEBUG
@MainActor final class PreviewNotificationRepository: NotificationRepository {
    private var items: [UserNotification] = []
    private(set) var markedIDs: [String] = []
    private(set) var requestedPages: [Int] = []
    var onMarkRead: ((String) -> Void)?
    init(extraUnread: Int = 0, empty: Bool = false) {
        var entries: [[String: Any]] = [
            ["id": "ntf_01M3TZ9N7HZF25T1YFYDFMCGRW", "kind": "success", "title": "Конфигурация готова", "body": "Добавьте конфигурацию в AmneziaWG. Если приложение уже установлено, это займёт всего несколько шагов.", "isRead": false, "createdAt": "2026-10-01T06:00:00Z"],
            ["id": "ntf_01M3TYFNEW53H5A1VNH8BHHDPH", "kind": "warning", "title": "Скоро закончится доступ", "body": "Доступ к VPN действует до 4 октября. Продлить его можно в личном кабинете на сайте Undercore.", "isRead": false, "createdAt": "2026-09-30T15:20:00Z"],
            ["id": "ntf_01M3TYFNEW53H5A1VNH8BHHDPJ", "kind": "info", "title": "Добро пожаловать в Undercore", "body": "Здесь будут появляться важные сообщения о вашем доступе и работе VPN.", "isRead": true, "createdAt": "2026-09-29T09:00:00Z"]
        ]
        for number in 0..<extraUnread {
            entries.append(["id": "preview-notification-\(number)", "kind": "info", "title": "Тестовое сообщение \(number)", "body": "Сообщение ниже экрана не должно отмечаться прочитанным, пока его не увидели.", "isRead": false, "createdAt": "2026-10-04T09:00:00Z"])
        }
        if empty { entries = [] }
        items = (try? JSONDecoder().decode([UserNotification].self, from: JSONSerialization.data(withJSONObject: entries))) ?? []
    }
    func page(_ page: Int) async throws -> NotificationPage {
        requestedPages.append(page)
        return try JSONDecoder().decode(NotificationPage.self, from: JSONEncoderPreview.page(items))
    }
    func summary() async throws -> NotificationSummary {
        try JSONDecoder().decode(NotificationSummary.self, from: JSONSerialization.data(withJSONObject: ["unreadCount": items.filter { !$0.isRead }.count]))
    }
    func markRead(_ id: String) async throws -> UserNotification {
        onMarkRead?(id)
        markedIDs.append(id)
        let index = items.firstIndex { $0.id == id }!
        items[index] = items[index].markingRead(); return items[index]
    }
    func markAllRead() async throws -> NotificationReadResult {
        let count = items.filter { !$0.isRead }.count; items = items.map { $0.markingRead() }
        return try JSONDecoder().decode(NotificationReadResult.self, from: JSONSerialization.data(withJSONObject: ["unreadCount": 0, "updatedCount": count]))
    }
    private enum JSONEncoderPreview {
        static func page(_ items: [UserNotification]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["data": items.map { ["id": $0.id, "kind": $0.kind, "title": $0.title, "body": $0.body, "isRead": $0.isRead, "createdAt": $0.createdAt ?? ""] as [String: Any] }, "meta": ["current_page": 1, "last_page": 1]])
        }
    }
}
@MainActor enum NotificationLimitChecks {
    static func run() async {
        let repository = PreviewNotificationRepository(extraUnread: 100)
        let model = NotificationsViewModel(repository: repository)
        await model.load()
        precondition(model.items.count == 30 && model.items.last?.id == "preview-notification-26")
        precondition(model.unreadCount > 30, "Account unread total was incorrectly truncated")
        let ids = model.items.map(\.id)
        await model.markVisibleRead([ids[0], "preview-notification-99"])
        precondition(repository.markedIDs == [ids[0]], "An unloaded notification was marked read")
        await model.load()
        precondition(model.items.map(\.id) == ids && model.items[0].isRead)
        precondition(repository.requestedPages == [1, 1], "Loaded archive pages inside the app")
        print("NOTIFICATION_LIMIT_CHECKS PASS: capped at 30; first page only; refresh replaces; read state; global unread total")
    }
}
#endif
