import WebKit
import UndercoreCore

@MainActor final class ArticleImageHandler: NSObject, WKURLSchemeHandler {
    private let store: ArticleImageStore
    private let origin: URL
    var revision = ""
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(store: ArticleImageStore, origin: URL) { self.store = store; self.origin = origin }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let revision = revision
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            guard let requestURL = urlSchemeTask.request.url else {
                self.tasks.removeValue(forKey: key)
                urlSchemeTask.didFailWithError(ClientError.invalidAddress)
                return
            }
            let resource: ArticleImageResource?
            do {
                guard let url = ArticleImageReferences.resolve(requestURL, origin: self.origin) else { throw ClientError.invalidAddress }
                resource = try await self.store.image(url, revision: revision)
            } catch { resource = nil }
            // WebKit forbids callbacks after stop; everything here is serialized on MainActor.
            guard !Task.isCancelled, self.tasks[key] != nil else { return }
            let data: Data
            let mime: String
            if let resource {
                data = resource.data; mime = resource.mime
            } else {
                data = Data("<svg xmlns='http://www.w3.org/2000/svg' width='600' height='120'><rect width='600' height='120' rx='16' fill='#f2f2f7'/><text x='300' y='65' text-anchor='middle' font-family='sans-serif' font-size='20' fill='#777'>Не удалось загрузить изображение</text></svg>".utf8)
                mime = "image/svg+xml"
            }
            urlSchemeTask.didReceive(URLResponse(url: requestURL, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            guard !Task.isCancelled, self.tasks[key] != nil else { return }
            urlSchemeTask.didReceive(data)
            guard !Task.isCancelled, self.tasks.removeValue(forKey: key) != nil else { return }
            urlSchemeTask.didFinish()
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}

#if DEBUG
/// Real WebKit smoke check: seed with a mock download, recreate the model offline,
/// then render the actual reader with its normal CSP and JavaScript disabled.
@MainActor enum OfflineArticleCheck {
    static func run(in window: UIWindow) async {
        let origin = URL(string: "https://preview.example.test")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewImageDownload.self]
        let repository = OfflineArticleFixture()
        let online = ArticlesViewModel(repository: repository, origin: origin, userID: 0, cacheDirectory: directory, imageSession: URLSession(configuration: configuration))
        do {
            _ = try await online.images.image(origin.appendingPathComponent("storage/instructions/images/inline.png"), revision: "1:2026-10-03T10:00:00Z")
            await online.refresh()
            repository.offline = true
            configuration.protocolClasses = [PreviewImageOffline.self]
            let offline = ArticlesViewModel(repository: repository, origin: origin, userID: 0, cacheDirectory: directory, imageSession: URLSession(configuration: configuration))
            let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
            let article = ArticleViewController(id: 1, model: offline, origin: origin)
            let sheet = ArticleSheetController(rootViewController: article)
            sheet.sheetPresentationController?.detents = [.medium(), .large()]
            root.present(sheet, animated: false)
            try await Task.sleep(for: .seconds(3))
            guard let web = article.view.subviews.compactMap({ $0 as? WKWebView }).first else { preconditionFailure("Reader missing") }
            let passed = try await web.evaluateJavaScript("document.images.length === 1 && document.images[0].naturalWidth === 1 && document.images[0].src.startsWith('undercore-image:') && document.querySelector('h1') === null && document.body.lastElementChild.tagName === 'FOOTER' && getComputedStyle(document.body).backgroundColor === 'rgba(0, 0, 0, 0)'")
            precondition(passed as? Bool == true, "Offline image or cover removal failed: \(String(describing: passed))")
            precondition(web.scrollView.contentSize.width >= web.bounds.width * 0.95, "Compact reader viewport collapsed")
            sheet.sheetPresentationController?.selectedDetentIdentifier = .large
            try await Task.sleep(for: .seconds(1))
            precondition(web.scrollView.contentSize.width >= web.bounds.width * 0.95, "Expanded reader viewport collapsed")
            print("OFFLINE ARTICLE PASS: prefetched body on fresh model without network; cached inline image; no cover or duplicate heading; footer date; transparent background; compact/expanded viewport")
        } catch { preconditionFailure("Offline article check failed: \(error)") }
    }
}
private final class PreviewImageDownload: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class PreviewImageOffline: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
@MainActor private final class OfflineArticleFixture: ArticleRepository {
    var offline = false
    private let item = try! JSONDecoder().decode(AppArticle.self, from: Data(#"{"id":1,"title":"Статья без обложки","coverPath":"/storage/instructions/images/cover.png","updatedAt":"2026-10-03T10:00:00Z","publishedAt":"2026-10-03T10:00:00Z","tags":[],"contentHtml":"<p>Изображение ниже загружено из локального кэша без доступа к сети.</p><img src='/storage/instructions/images/inline.png' style='width:120px;height:80px;border:4px solid #176fef'><p>Текст статьи остаётся доступным.</p>"}"#.utf8))
    func banners() async throws -> [AppArticle] { if offline { throw URLError(.notConnectedToInternet) }; return [item] }
    func article(_ id: Int) async throws -> AppArticle { if offline { throw URLError(.notConnectedToInternet) }; return item }
}
#endif
