import UIKit
import WebKit
import SafariServices
import UndercoreCore

/// One material behind both the navigation bar and transparent article content.
final class ArticleSheetController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        backdrop.isUserInteractionEnabled = false
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, at: 0)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.compactScrollEdgeAppearance = appearance
    }
}

final class ArticleViewController: UIViewController, WKNavigationDelegate {
    // Reuse the anonymous in-memory resource cache between article readers.
    // Never use the account's authenticated cookie store or persist web data.
    private static let resourceStore = WKWebsiteDataStore.nonPersistent()
    private var imageHandler: ArticleImageHandler!
    private var hasStarted = false
    private let id: Int
    private let model: ArticlesViewModel
    private let origin: URL
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let message = UILabel()
    private let retry = PrimaryButton(CommonText.retry, primary: false)
    private var web: WKWebView!
    private var task: Task<Void, Never>?
    private var renderTimeout: Task<Void, Never>?
    init(id: Int, model: ArticlesViewModel, origin: URL) {
        self.id = id; self.model = model; self.origin = origin
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = model.items.first(where: { $0.id == id })?.title
        // Let the native sheet supply one continuous background behind the reader.
        view.backgroundColor = .clear
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.resourceStore
        imageHandler = ArticleImageHandler(store: model.images, origin: origin)
        configuration.setURLSchemeHandler(imageHandler, forURLScheme: ArticleImageReferences.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: .zero, configuration: configuration)
        // Avoid the nonopaque + systemBackground combination (WebKit 319180).
        // Both native surfaces and HTML must be clear; otherwise a white rectangle remains.
        web.isOpaque = false; web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self; web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        message.font = .preferredFont(forTextStyle: .callout); message.textColor = .secondaryLabel
        message.numberOfLines = 0; message.textAlignment = .center
        let status = UIStackView(arrangedSubviews: [spinner, message, retry])
        status.axis = .vertical; status.spacing = 16; status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(status)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor), status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -48),
            message.widthAnchor.constraint(equalTo: status.widthAnchor)
        ])
        retry.addAction(UIAction { [weak self] _ in self?.loadArticle() }, for: .touchUpInside)
        message.isHidden = true; retry.isHidden = true
        spinner.startAnimating()
    }
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard !hasStarted else { return }
        hasStarted = true
        view.layoutIfNeeded()
        loadArticle()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            task?.cancel(); renderTimeout?.cancel(); web.stopLoading()
        }
    }
    private func loadArticle() {
        task?.cancel(); renderTimeout?.cancel(); web.stopLoading(); web.isHidden = true; message.isHidden = true; retry.isHidden = true; spinner.startAnimating()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let article = try await model.article(id)
                try Task.checkCancellation()
                title = article.title
                imageHandler.revision = "\(article.id):\(article.updatedAt)"
                web.loadHTMLString(document(article), baseURL: origin)
                renderTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.web.stopLoading(); self?.renderFailure()
                }
            } catch {
                guard !Task.isCancelled else { return }
                spinner.stopAnimating(); message.isHidden = false
                if case ClientError.server(let status, _, _) = error, status == 404 {
                    message.text = "Эта публикация больше недоступна."
                } else { message.text = readableError(error); retry.isHidden = false }
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { renderTimeout?.cancel(); spinner.stopAnimating(); message.isHidden = true; retry.isHidden = true; web.isHidden = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { renderFailure() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { renderFailure() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { renderFailure() }
    private func renderFailure() { renderTimeout?.cancel(); web.isHidden = true; spinner.stopAnimating(); message.text = "Не удалось открыть статью."; message.isHidden = false; retry.isHidden = false }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .other && (url.absoluteString == "about:blank" || (url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port && ["", "/"].contains(url.path) && url.query == nil)) {
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, url.scheme == "https", url.user == nil, url.password == nil {
            present(SFSafariViewController(url: url), animated: true)
        }
    }
    private func document(_ item: AppArticle) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
        }
        let date = item.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }.map {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateStyle = .long
            return formatter.string(from: $0)
        } ?? ""
        let footer = date.isEmpty ? "" : "<footer class=date>\(escape(date))</footer>"
        return """
        <!doctype html><html lang="ru"><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src undercore-image: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer"><style>
        :root{color-scheme:light dark}html{width:100%;background:transparent;-webkit-text-size-adjust:100%}*{box-sizing:border-box}body{width:100%;font:-apple-system-body;color:#171719;background:transparent;margin:0;padding:20px 24px 40px;overflow-wrap:anywhere}
        h1{font:-apple-system-title1;font-weight:700}h2,h3{line-height:1.25}p,li{line-height:1.55}p,ul,ol,blockquote,pre,table{margin:20px 0}
        a{color:#176fef}img{display:block;max-width:100%;height:auto;margin:20px auto;border-radius:16px}
        .date{font:-apple-system-footnote;color:#777;margin-top:32px}pre{padding:16px;background:#f2f2f7;border-radius:12px;overflow:auto;white-space:pre}table{display:block;overflow:auto;border-collapse:collapse}td,th{border:1px solid #999;padding:8px}blockquote{border-left:3px solid #aaa;padding-left:16px}
        @media(prefers-color-scheme:dark){body{color:#f2f2f7}pre{background:#1c1c1e}.date{color:#999}a{color:#5ba0ff}}
        </style></head><body>\(ArticleImageReferences.rewrite(item.contentHtml ?? "", origin: origin))\(footer)</body></html>
        """
    }
}
