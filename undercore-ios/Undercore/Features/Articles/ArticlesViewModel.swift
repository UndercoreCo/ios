import Foundation
import UndercoreCore

@MainActor final class ArticlesViewModel {
    private let repository: ArticleRepository
    private let origin: URL
    private(set) var images: ArticleImageStore
    private let makeImages: () -> ArticleImageStore
    private let feed: ArticleFeedCache
    private var cacheRestored = false
    private var restoreTask: Task<[AppArticle]?, Never>?
    private var feedRevision = 0
    private let details: ArticleDetailCache
    private var generation = 0
    private var loading = false
    private(set) var items: [AppArticle] = []
    var onChange: (() -> Void)?
    var onSessionExpired: (() -> Void)?

    init(repository: ArticleRepository, origin: URL, userID: Int, cacheDirectory: URL? = nil, imageSession: URLSession? = nil) {
        self.repository = repository; self.origin = origin
        let directory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Articles", isDirectory: true)
        let cacheURL = directory.appendingPathComponent("\(origin.host ?? "unknown")-\(origin.port ?? 443)-\(userID).json")
        details = ArticleDetailCache(url: cacheURL.appendingPathExtension("details"))
        feed = ArticleFeedCache(url: cacheURL)
        makeImages = { ArticleImageStore(directory: cacheURL.appendingPathExtension("images"), origin: origin, session: imageSession) }
        images = makeImages()
    }

    private func restoreCache() async {
        guard !cacheRestored else { return }
        let version = generation
        if restoreTask == nil {
            let feed = feed
            restoreTask = Task { await feed.load() }
        }
        await details.restore()
        let saved = await restoreTask?.value
        guard version == generation, !cacheRestored else { return }
        cacheRestored = true; restoreTask = nil
        if let saved {
            let visible = saved.filter { $0.isVisible() }
            await ArticleImages.shared.restore(visible, origin: origin)
            guard version == generation, !Task.isCancelled else { return }
            items = visible; onChange?()
        }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        let generation = generation
        defer { loading = false }
        await restoreCache()
        guard generation == self.generation, !Task.isCancelled else { return }
        items = items.filter { $0.isVisible() }; onChange?()
        do {
            let banners = try await repository.banners().filter { $0.isVisible() }
            guard generation == self.generation, !Task.isCancelled else { return }
            await ArticleImages.shared.restore(banners, origin: origin)
            guard generation == self.generation, !Task.isCancelled else { return }
            items = banners; feedRevision += 1
            details.retain(matching: items)
            feed.store(items)
            onChange?()
            // Download the small feed's instruction bodies once per revision for offline reading.
            for summary in items.prefix(20) where details.article(matching: summary) == nil {
                guard generation == self.generation, !Task.isCancelled else { return }
                do { _ = try await article(summary.id) }
                catch { break } // Stop on connectivity/rate-limit errors; never loop or retry automatically.
            }
        } catch ClientError.expiredSession {
            guard generation == self.generation else { return }
            clearCache(); onSessionExpired?()
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            // Editorial content must never prevent users from accessing configurations.
            if case ClientError.server(let status, _, _) = error, [403, 404].contains(status) { clearCache() }
        }
    }

    func article(_ id: Int) async throws -> AppArticle {
        let generation = generation
        await restoreCache()
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        if let summary = items.first(where: { $0.id == id }), let cached = details.article(matching: summary) { return cached }
        let revision = feedRevision
        do {
            let article = try await repository.article(id)
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
            // A feed refresh can edit/remove a publication while its body is in flight.
            if revision != feedRevision {
                guard let summary = items.first(where: { $0.id == id }), summary.updatedAt == article.updatedAt else { throw CancellationError() }
            }
            guard article.isVisible() else { throw ClientError.invalidResponse }
            details.store(article)
            return article
        } catch ClientError.expiredSession {
            guard generation == self.generation else { throw CancellationError() }
            clearCache(); onSessionExpired?(); throw ClientError.expiredSession
        } catch {
            guard generation == self.generation else { throw CancellationError() }
            if revision == feedRevision, case ClientError.server(let status, _, _) = error, [403, 404].contains(status) {
                items.removeAll { $0.id == id }; feedRevision += 1
                details.retain(matching: items); feed.store(items); onChange?()
            }
            throw error
        }
    }
    func clearCache() {
        generation += 1; feedRevision += 1; cacheRestored = true
        restoreTask?.cancel(); restoreTask = nil
        items = []; details.clear(); feed.clear(); images.clear(); images = makeImages(); onChange?()
    }
}

#if DEBUG
@MainActor final class PreviewArticleRepository: ArticleRepository {
    private let items: [AppArticle] = (1...3).map { id in
        let json = """
        {"id":\(id),"title":"Как подключиться к VPN на iPhone","excerpt":"Три простых шага","updatedAt":"2026-10-02T10:00:00Z","publishedAt":"2026-10-02T10:00:00Z","tags":["Инструкция"],"contentHtml":"<h2>Начнём</h2><p>Установите <strong>AmneziaWG</strong> и добавьте конфигурацию.</p><ol><li>Откройте приложение</li><li>Импортируйте конфигурацию</li><li>Включите подключение</li></ol><blockquote>Теперь всё готово.</blockquote>"}
        """
        return try! JSONDecoder().decode(AppArticle.self, from: Data(json.utf8))
    }
    func banners() async throws -> [AppArticle] { items }
    func article(_ id: Int) async throws -> AppArticle { items[0] }
}
#endif
