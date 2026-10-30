import Foundation

public struct AppArticle: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let excerpt: String?
    public let coverPath: String?
    public let publishedAt: String?
    public let expiresAt: String?
    public let updatedAt: String
    public let tags: [String]
    public let contentHtml: String?

    public func isVisible(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt) else { return false }
        return date > now
    }
}

@MainActor public protocol ArticleRepository {
    func banners() async throws -> [AppArticle]
    func article(_ id: Int) async throws -> AppArticle
}

@MainActor public final class LiveArticleRepository: ArticleRepository {
    private let client: APIClient
    public init(client: APIClient) { self.client = client }
    public func banners() async throws -> [AppArticle] {
        let result: Envelope<[AppArticle]> = try await client.request(APIRequests.articles)
        return result.data
    }
    public func article(_ id: Int) async throws -> AppArticle {
        guard id > 0 else { throw ClientError.invalidAddress }
        let result: Envelope<AppArticle> = try await client.request(APIRequests.article(id))
        return result.data
    }
}

/// Account-scoped article bodies. A refreshed feed invalidates edits and removals.
@MainActor public final class ArticleDetailCache {
    private struct Entry: Codable, Sendable { let savedAt: Date; let article: AppArticle }
    private let url: URL
    private let lifetime: TimeInterval = 30 * 24 * 3600
    private var entries: [Int: Entry] = [:]

    private var restored = false
    private var generation = 0
    private var restoreTask: Task<[Int: Entry]?, Never>?

    public init(url: URL) { self.url = url }

    /// Disk access and decoding run on the shared serial cache queue, never on MainActor.
    public func restore() async {
        guard !restored else { return }
        let version = generation
        if restoreTask == nil {
            let url = url
            restoreTask = Task { await ArticleCacheFileIO.read([Int: Entry].self, from: url) }
        }
        let saved = await restoreTask?.value
        guard version == generation, !restored else { return }
        entries = saved ?? [:]; restored = true; restoreTask = nil
    }

    public func article(matching summary: AppArticle, at now: Date = Date()) -> AppArticle? {
        guard let entry = entries[summary.id], entry.article.updatedAt == summary.updatedAt,
              entry.savedAt <= now, now.timeIntervalSince(entry.savedAt) < lifetime,
              summary.isVisible(at: now), entry.article.isVisible(at: now) else { return nil }
        return entry.article
    }

    public func store(_ article: AppArticle, at now: Date = Date()) {
        guard article.contentHtml != nil else { return }
        generation += 1; restored = true
        entries = entries.filter { $0.value.savedAt <= now && now.timeIntervalSince($0.value.savedAt) < lifetime }
        entries[article.id] = Entry(savedAt: now, article: article)
        // Bound disk and memory use to the feed's maximum number of banners.
        if entries.count > 20, let oldest = entries.min(by: { $0.value.savedAt < $1.value.savedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        persist()
    }

    public func retain(matching summaries: [AppArticle], at now: Date = Date()) {
        generation += 1; restored = true
        entries = entries.filter { id, entry in
            summaries.contains { $0.id == id && $0.updatedAt == entry.article.updatedAt && $0.isVisible(at: now) }
                && entry.savedAt <= now && now.timeIntervalSince(entry.savedAt) < lifetime
        }
        persist()
    }

    public func clear() {
        generation += 1; restored = true; restoreTask?.cancel(); restoreTask = nil
        entries = [:]
        ArticleCacheFileIO.remove(url)
    }

    private func persist() {
        ArticleCacheFileIO.write(entries, to: url)
    }
}
