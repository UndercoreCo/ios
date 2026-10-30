import UIKit
import WebKit
import UndercoreCore

private final class CaptchaMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: CaptchaViewController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}

final class CaptchaViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler {
    private let pageURL: URL
    private let tokenField: String
    private var completion: ((String) -> Void)?
    private var webView: WKWebView!
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let handler = CaptchaMessageHandler()
    private static let challengeDetent = UISheetPresentationController.Detent.Identifier("captcha-challenge")
    init(pageURL: URL, tokenField: String, completion: @escaping (String) -> Void) {
        self.pageURL = pageURL; self.tokenField = tokenField; self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Подтверждение"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self, action: #selector(loadChallenge))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Повторить проверку"
        if let sheet = navigationController?.sheetPresentationController {
            sheet.detents = [.medium(), .custom(identifier: Self.challengeDetent) { min(max(560, $0.maximumDetentValue * 0.65), $0.maximumDetentValue) }, .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        handler.owner = self
        configuration.userContentController.add(handler, name: "challenge")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false; webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.underPageBackgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        status.numberOfLines = 0; status.font = .preferredFont(forTextStyle: .callout)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .secondaryLabel; status.textAlignment = .center
        let feedback = UIStackView(arrangedSubviews: [spinner, status])
        feedback.axis = .vertical; feedback.spacing = 12
        feedback.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(feedback)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            feedback.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            feedback.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.inset),
            feedback.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.inset)
        ])
        loadChallenge()
    }
    @objc private func loadChallenge() {
        status.text = nil; spinner.startAnimating(); webView.isHidden = false
        guard var parts = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { showError(); return }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "theme" }
            + [.init(name: "theme", value: traitCollection.userInterfaceStyle == .dark ? "dark" : "light")]
        guard let url = parts.url else { showError(); return }
        webView.load(URLRequest(url: url))
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded, traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { loadChallenge() }
    }
    private func disconnect() {
        webView?.stopLoading(); webView?.configuration.userContentController.removeScriptMessageHandler(forName: "challenge")
        handler.owner = nil; completion = nil
    }
    private func close() { disconnect(); dismiss(animated: true) }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || view.window == nil { disconnect() }
    }
    private func showError() { spinner.stopAnimating(); webView.isHidden = true; status.text = CommonText.networkError }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showError() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showError() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { spinner.stopAnimating() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            showError(); decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true {
            decisionHandler(url.scheme == pageURL.scheme && url.host == pageURL.host && url.port == pageURL.port && url.path == pageURL.path ? .allow : .cancel)
        } else { decisionHandler(url.scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == pageURL.host,
              message.frameInfo.securityOrigin.protocol == "https",
              (pageURL.port.map { message.frameInfo.securityOrigin.port == $0 } ?? [0, 443].contains(message.frameInfo.securityOrigin.port)),
              webView.url?.path == pageURL.path,
              let data = message.body as? [String: String] else { return }
        if let event = data["event"] {
            switch event {
            case "challenge-visible": navigationController?.sheetPresentationController?.animateChanges {
                self.navigationController?.sheetPresentationController?.selectedDetentIdentifier = Self.challengeDetent
            }
            case "ready": spinner.stopAnimating()
            case "error": showError()
            default: break
            }
            return
        }
        guard data["field"] == tokenField, let token = data["token"], !token.isEmpty, token.utf8.count <= 8192 else { return }
        let callback = completion
        disconnect()
        dismiss(animated: true) { callback?(token) }
    }
}
