import XCTest
@testable import UndercoreCore

final class ArticleCacheTests: XCTestCase {
    private func article(revision: String = "v1", expiresAt: String? = nil) throws -> AppArticle {
        var json: [String: Any] = ["id": 1, "title": "Article", "updatedAt": revision, "tags": [], "contentHtml": "<p>Cached body</p>"]
        json["expiresAt"] = expiresAt
        return try JSONDecoder().decode(AppArticle.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @MainActor func testBodySurvivesRecreationAndExpiresAfterOneHour() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(); let item = try article()
        ArticleDetailCache(url: url).store(item, at: now)
        let restored = ArticleDetailCache(url: url); await restored.restore()
        XCTAssertEqual(restored.article(matching: item, at: now.addingTimeInterval(3599)), item)
        XCTAssertNil(restored.article(matching: item, at: now.addingTimeInterval(30 * 24 * 3600)))
        XCTAssertNil(restored.article(matching: item, at: now.addingTimeInterval(-1)))
    }

    @MainActor func testEditedRemovedAndExpiredPublicationsAreNotServed() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(); let original = try article(); let edited = try article(revision: "v2")
        let cache = ArticleDetailCache(url: url); await cache.restore(); cache.store(original, at: now)
        XCTAssertNil(cache.article(matching: edited, at: now))
        cache.retain(matching: [edited], at: now)
        let restored = ArticleDetailCache(url: url); await restored.restore()
        XCTAssertNil(restored.article(matching: original, at: now))
        cache.store(original, at: now); cache.retain(matching: [], at: now)
        let removed = ArticleDetailCache(url: url); await removed.restore()
        XCTAssertNil(removed.article(matching: original, at: now))
        let expired = try article(expiresAt: "2000-01-01T00:00:00Z")
        cache.store(expired, at: now)
        XCTAssertNil(cache.article(matching: expired, at: now))
        await ArticleCacheFileIO.flush()
    }

    @MainActor func testAccountIsolationAndLogoutRemoveMemoryAndDiskContent() async throws {
        let first = location(); let second = location()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let item = try article(); let cache = ArticleDetailCache(url: first)
        cache.store(item)
        let anotherAccount = ArticleDetailCache(url: second); await anotherAccount.restore()
        XCTAssertNil(anotherAccount.article(matching: item))
        XCTAssertNotNil(cache.article(matching: item))
        cache.clear()
        XCTAssertNil(cache.article(matching: item))
        let restored = ArticleDetailCache(url: first); await restored.restore()
        XCTAssertNil(restored.article(matching: item))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }
    @MainActor func testQueuedSavesCannotRecreateFilesAfterLogout() async throws {
        let url = location(); let feedURL = location()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: feedURL) }
        let cache = ArticleDetailCache(url: url); let feed = ArticleFeedCache(url: feedURL)
        for revision in 0..<100 {
            let item = try article(revision: String(revision))
            cache.store(item); feed.store([item])
        }
        cache.clear(); feed.clear()
        await ArticleCacheFileIO.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: feedURL.path))
        let restoredFeed = await ArticleFeedCache(url: feedURL).load()
        XCTAssertNil(restoredFeed)
    }
    @MainActor func testRestoreDoesNotResurrectClearedMemoryAndLatestWriteWins() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        let old = try article(); let new = try article(revision: "new")
        ArticleDetailCache(url: url).store(old)
        let cache = ArticleDetailCache(url: url)
        let restoring = Task { await cache.restore() }
        await Task.yield()
        cache.clear()
        await restoring.value
        XCTAssertNil(cache.article(matching: old))
        cache.store(new)
        let fresh = ArticleDetailCache(url: url); await fresh.restore()
        XCTAssertEqual(fresh.article(matching: new), new)
        XCTAssertNil(fresh.article(matching: old))
    }
    @MainActor func testFeedKeepsLegacyFormatExpiryAndAccountIsolation() async throws {
        let url = location(); let other = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(); let item = try article()
        // Bytes written by the previous synchronous cache are still readable.
        let legacy: [String: Any] = ["savedAt": now.timeIntervalSinceReferenceDate,
            "items": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let feed = ArticleFeedCache(url: url)
        let valid = await feed.load(at: now.addingTimeInterval(3599))
        let expired = await feed.load(at: now.addingTimeInterval(30 * 24 * 3600))
        let future = await feed.load(at: now.addingTimeInterval(-1))
        let isolated = await ArticleFeedCache(url: other).load()
        XCTAssertEqual(valid, [item]); XCTAssertNil(expired); XCTAssertNil(future); XCTAssertNil(isolated)
        feed.store([try article(expiresAt: "2000-01-01T00:00:00Z")], at: now)
        let filtered = await feed.load(at: now)
        XCTAssertEqual(filtered, [])
    }
    @MainActor func testCorruptOrUnavailableCacheIsOptional() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid json".utf8).write(to: url)
        let details = ArticleDetailCache(url: url); await details.restore()
        XCTAssertNil(details.article(matching: try article()))
        let feed = await ArticleFeedCache(url: url).load()
        XCTAssertNil(feed)
        let impossible = url.appendingPathComponent("cannot-write-under-a-file")
        let memory = ArticleDetailCache(url: impossible); let item = try article()
        memory.store(item); await ArticleCacheFileIO.flush()
        XCTAssertEqual(memory.article(matching: item), item)
    }
}
