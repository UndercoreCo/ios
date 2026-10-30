import Foundation

// Complete data protection is available on iOS; macOS package tests use atomic writes.
var articleCacheWriteOptions: Data.WritingOptions {
    #if os(iOS)
    [.atomic, .completeFileProtection]
    #else
    [.atomic]
    #endif
}

/// All article files share one FIFO queue. Calls enqueue synchronously on MainActor:
/// a logout deletion cannot be overtaken by an earlier queued save, even across cache instances.
@MainActor enum ArticleCacheFileIO {
    private static let queue = DispatchQueue(label: "ru.undercore.article-cache", qos: .utility)
    private static let maximumBytes = 8 * 1024 * 1024

    static func read<Value: Decodable & Sendable>(_ type: Value.Type, from url: URL) async -> Value? {
        let limit = maximumBytes
        return await withCheckedContinuation { continuation in
            queue.async {
                assert(!Thread.isMainThread)
                let result: Value? = autoreleasepool {
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let size = attributes[.size] as? NSNumber, size.intValue <= limit,
                          let bytes = try? Data(contentsOf: url), bytes.count <= limit else { return nil }
                    return try? JSONDecoder().decode(type, from: bytes)
                }
                continuation.resume(returning: result)
            }
        }
    }
    static func write<Value: Encodable & Sendable>(_ value: Value, to url: URL) {
        let limit = maximumBytes
        queue.async {
            assert(!Thread.isMainThread)
            autoreleasepool {
                guard let bytes = try? JSONEncoder().encode(value), bytes.count <= limit else { return }
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url, options: articleCacheWriteOptions)
                    var protectedURL = url
                    var resourceValues = URLResourceValues(); resourceValues.isExcludedFromBackup = true
                    try protectedURL.setResourceValues(resourceValues)
                } catch { /* Optional cache must not prevent article display. */ }
            }
        }
    }
    static func remove(_ url: URL) {
        queue.async {
            assert(!Thread.isMainThread)
            try? FileManager.default.removeItem(at: url)
        }
    }
    // A read-only barrier for tests; UI never waits for disk writes or deletion.
    static func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

/// Preserves the existing feed JSON format, account-specific path and 30-day offline lifetime.
@MainActor public final class ArticleFeedCache {
    private struct Snapshot: Codable, Sendable { let savedAt: Date; let items: [AppArticle] }
    private let url: URL
    private var generation = 0
    public init(url: URL) { self.url = url }
    public func load(at now: Date = Date()) async -> [AppArticle]? {
        let version = generation
        let cached = await ArticleCacheFileIO.read(Snapshot.self, from: url)
        guard version == generation, let cached, cached.savedAt <= now,
              now.timeIntervalSince(cached.savedAt) < 30 * 24 * 3600 else { return nil }
        return cached.items.filter { $0.isVisible(at: now) }
    }
    public func store(_ items: [AppArticle], at now: Date = Date()) {
        generation += 1
        ArticleCacheFileIO.write(Snapshot(savedAt: now, items: items), to: url)
    }
    public func clear() {
        generation += 1
        ArticleCacheFileIO.remove(url)
    }
}
