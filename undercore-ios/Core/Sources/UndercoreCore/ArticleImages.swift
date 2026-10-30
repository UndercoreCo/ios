import Foundation
import CryptoKit

public enum ArticleImageReferences {
    public static let scheme = "undercore-image"
    public static func remoteURL(_ value: String, origin: URL) -> URL? {
        guard let url = URL(string: value, relativeTo: origin)?.absoluteURL,
              url.scheme == "https", url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: "^/storage/instructions/images/[A-Za-z0-9_-]+\\.(png|jpe?g|webp)\\z", options: .regularExpression) != nil,
              url.absoluteString == origin.appendingPathComponent(String(url.path.dropFirst())).absoluteString else { return nil }
        return url
    }
    /// The server produces sanitized Markdown HTML with quoted img src attributes.
    /// Only uploaded instruction images use the cache; anchors and other markup stay unchanged.
    public static func rewrite(_ html: String, origin: URL) -> String {
        let pattern = #"(?i)(<img\b[^>]*?\s+src\s*=\s*)(["'])([^"']*)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        var output = html
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let valueRange = Range(match.range(at: 3), in: html),
                  let url = remoteURL(String(html[valueRange]), origin: origin),
                  let replaceRange = Range(match.range(at: 3), in: output) else { continue }
            output.replaceSubrange(replaceRange, with: "\(scheme)://images\(url.path)")
        }
        return output
    }
    public static func resolve(_ url: URL, origin: URL) -> URL? {
        guard url.scheme == scheme, url.host == "images", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.absoluteString == "\(scheme)://images\(url.path)" else { return nil }
        return remoteURL(url.path, origin: origin)
    }
}

public struct ArticleImageResource: Codable, Sendable {
    public let data: Data
    public let mime: String
}
private struct SavedArticleImage: Codable, Sendable {
    let savedAt: Date
    let resource: ArticleImageResource
}

/// Anonymous public uploads only. Account-scoped files, revision-specific keys and bounded disk use.
@MainActor public final class ArticleImageStore {
    private let directory: URL
    private let origin: URL
    private let session: URLSession
    private var generation = 0
    private var invalidated = false
    public init(directory: URL, origin: URL, session: URLSession? = nil) {
        self.directory = directory; self.origin = origin
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        }
    }
    public func image(_ url: URL, revision: String) async throws -> ArticleImageResource {
        guard !invalidated else { throw CancellationError() }
        guard let url = ArticleImageReferences.remoteURL(url.absoluteString, origin: origin) else { throw ClientError.invalidAddress }
        let version = generation
        let file = cacheFile(url, revision: revision)
        let cached = await ArticleImageFiles.read(file)
        try Task.checkCancellation()
        guard version == generation else { throw CancellationError() }
        if let cached, Self.valid(cached.data, mime: cached.mime) { return cached }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.setValue("image/png,image/jpeg,image/webp", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard version == generation else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
              data.count <= 8 * 1024 * 1024, let mime = http.mimeType,
              Self.valid(data, mime: mime) else { throw ClientError.invalidResponse }
        let resource = ArticleImageResource(data: data, mime: mime)
        ArticleImageFiles.write(SavedArticleImage(savedAt: Date(), resource: resource), to: file)
        return resource
    }
    /// Disk-only lookup lets native covers restore before the carousel is displayed.
    public func cachedImage(_ url: URL, revision: String) async -> ArticleImageResource? {
        guard !invalidated, let url = ArticleImageReferences.remoteURL(url.absoluteString, origin: origin) else { return nil }
        let version = generation
        let cached = await ArticleImageFiles.read(cacheFile(url, revision: revision))
        guard !Task.isCancelled, version == generation, let cached, Self.valid(cached.data, mime: cached.mime) else { return nil }
        return cached
    }
    private func cacheFile(_ url: URL, revision: String) -> URL {
        let key = SHA256.hash(data: Data((revision + "|" + url.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    public func clear() { invalidated = true; generation += 1; ArticleImageFiles.clear(directory) }
    fileprivate static func valid(_ data: Data, mime: String) -> Bool {
        switch mime {
        case "image/png": return data.starts(with: [137,80,78,71,13,10,26,10])
        case "image/jpeg": return data.starts(with: [255,216,255])
        case "image/webp": return data.count >= 12 && String(data: data.prefix(4), encoding: .ascii) == "RIFF" && String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WEBP"
        default: return false
        }
    }
}

@MainActor private enum ArticleImageFiles {
    private static let queue = DispatchQueue(label: "ru.undercore.article-images", qos: .utility)
    static func read(_ file: URL) async -> ArticleImageResource? {
        await withCheckedContinuation { continuation in
            queue.async {
                assert(!Thread.isMainThread)
                let result: ArticleImageResource? = autoreleasepool {
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                          let size = attrs[.size] as? NSNumber, size.intValue <= 12 * 1024 * 1024,
                          let data = try? Data(contentsOf: file),
                          let saved = try? JSONDecoder().decode(SavedArticleImage.self, from: data),
                          saved.savedAt <= Date(), Date().timeIntervalSince(saved.savedAt) < 7 * 86400,
                          saved.resource.data.count <= 8 * 1024 * 1024 else { return nil }
                    return saved.resource
                }
                continuation.resume(returning: result)
            }
        }
    }
    static func write(_ value: SavedArticleImage, to file: URL) {
        queue.async {
            assert(!Thread.isMainThread)
            autoreleasepool {
                let directory = file.deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try JSONEncoder().encode(value).write(to: file, options: articleCacheWriteOptions)
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
                    let entries = files.compactMap { url -> (URL, Int, Date)? in
                        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                        return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
                    }.sorted { $0.2 < $1.2 }
                    var total = entries.reduce(0) { $0 + $1.1 }
                    for (url, size, date) in entries {
                        if total > 64 * 1024 * 1024 || Date().timeIntervalSince(date) > 7 * 86400 {
                            try? FileManager.default.removeItem(at: url); total -= size
                        }
                    }
                } catch { /* Optional image cache must not block rendering. */ }
            }
        }
    }
    static func clear(_ directory: URL) { queue.async { try? FileManager.default.removeItem(at: directory) } }
}
