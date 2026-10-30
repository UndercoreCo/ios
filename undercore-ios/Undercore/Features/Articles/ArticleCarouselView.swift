import UIKit
import ImageIO
import UndercoreCore

/// Anonymous cover downloads use no account cookies and accept only our image path.
@MainActor final class ArticleImages {
    static let shared = ArticleImages()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession?
    private let directory: URL
    private var pending: [String: Task<UIImage?, Never>] = [:]
    init(session: URLSession? = nil, directory: URL? = nil) {
        self.session = session
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArticleCovers", isDirectory: true)
        cache.totalCostLimit = 16 * 1024 * 1024
    }
    private func key(_ url: URL, revision: String) -> String { revision + "|" + url.absoluteString }
    func cached(path: String?, origin: URL, revision: String) -> UIImage? {
        guard let path, let url = ArticleImageReferences.remoteURL(path, origin: origin) else { return nil }
        return cache.object(forKey: key(url, revision: revision) as NSString)
    }
    /// Restore saved covers before publishing the feed; never wait for network here.
    func restore(_ items: [AppArticle], origin: URL) async {
        let store = ArticleImageStore(directory: directory, origin: origin, session: session)
        for item in items {
            guard !Task.isCancelled else { return }
            guard let path = item.coverPath, let url = ArticleImageReferences.remoteURL(path, origin: origin),
                  cached(path: path, origin: origin, revision: item.updatedAt) == nil,
                  let resource = await store.cachedImage(url, revision: item.updatedAt),
                  let image = await ArticleImageDecoder.shared.decode(resource.data) else { continue }
            save(image, key: key(url, revision: item.updatedAt))
        }
    }
    func image(path: String?, origin: URL, revision: String = "") async -> UIImage? {
        guard let path, let url = ArticleImageReferences.remoteURL(path, origin: origin) else { return nil }
        let key = key(url, revision: revision)
        if let existing = cache.object(forKey: key as NSString) { return existing }
        if let task = pending[key] {
            let image = await task.value
            return Task.isCancelled ? nil : image
        }
        let task = Task { () -> UIImage? in
            let store = ArticleImageStore(directory: self.directory, origin: origin, session: self.session)
            guard let resource = try? await store.image(url, revision: revision),
                  let image = await ArticleImageDecoder.shared.decode(resource.data) else { return nil }
            self.save(image, key: key)
            return image
        }
        pending[key] = task
        let image = await task.value
        pending.removeValue(forKey: key)
        return Task.isCancelled ? nil : image
    }
    private func save(_ image: UIImage, key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }
}

private actor ArticleImageDecoder {
    static let shared = ArticleImageDecoder()
    func decode(_ data: Data) -> UIImage? {
        #if DEBUG
        precondition(!Thread.isMainThread, "Cover decoding must not block the UI thread")
        #endif
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 900
                  ] as CFDictionary), !Task.isCancelled else { return nil }
            return UIImage(cgImage: image)
        }
    }
}

final class ArticleCarouselView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let layout = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let origin: URL
    private let pages = UIPageControl()
    private var preferredHeight: NSLayoutConstraint!
    private var previousWidth: CGFloat = 0
    private var currentPage = 0
    private var dragStartOffset: CGFloat = 0
    private var items: [AppArticle] = []
    var onSelect: ((Int) -> Void)?
    init(origin: URL) {
        self.origin = origin
        super.init(frame: .zero)
        layout.scrollDirection = .horizontal; layout.minimumLineSpacing = 12
        layout.sectionInset = .init(top: 0, left: Theme.screenInset, bottom: 0, right: Theme.screenInset)
        collection.contentInsetAdjustmentBehavior = .never
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.decelerationRate = .fast
        collection.dataSource = self; collection.delegate = self
        collection.register(ArticleCell.self, forCellWithReuseIdentifier: "article")
        collection.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collection)
        pages.translatesAutoresizingMaskIntoConstraints = false; addSubview(pages)
        pages.currentPageIndicatorTintColor = .label
        pages.pageIndicatorTintColor = .tertiaryLabel
        pages.hidesForSinglePage = true
        pages.accessibilityLabel = "Статьи"
        pages.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.currentPage = self.pages.currentPage
            self.collection.setContentOffset(CGPoint(x: CGFloat(self.currentPage) * self.pageStride, y: 0), animated: !UIAccessibility.isReduceMotionEnabled)
        }, for: .valueChanged)
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: leadingAnchor), collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.topAnchor.constraint(equalTo: topAnchor), collection.bottomAnchor.constraint(equalTo: pages.topAnchor, constant: -4),
            pages.centerXAnchor.constraint(equalTo: centerXAnchor), pages.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            pages.heightAnchor.constraint(equalToConstant: 32), pages.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        preferredHeight = heightAnchor.constraint(equalToConstant: 250); preferredHeight.priority = .defaultHigh; preferredHeight.isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    func update(_ items: [AppArticle]) {
        isHidden = items.isEmpty
        guard self.items != items else { return }
        let selectedID = self.items.indices.contains(currentPage) ? self.items[currentPage].id : nil
        self.items = items; isHidden = items.isEmpty
        currentPage = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        pages.numberOfPages = items.count; pages.currentPage = currentPage
        collection.reloadData()
        previousWidth = 0
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = cardWidth
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        // Reserve only the space the titles need, rather than an unused second line.
        let titleHeight = items.map { item in
            ceil(min(font.lineHeight * 2, (item.title as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil).height))
        }.max() ?? ceil(font.lineHeight)
        let height = ceil(width * 9 / 16) + titleHeight + 6 + 4 + 32
        if abs(preferredHeight.constant - height) > 0.5 {
            preferredHeight.constant = height
            layout.invalidateLayout()
        }
        if previousWidth != bounds.width {
            previousWidth = bounds.width
            // Give the last card the same leading alignment as every other page.
            layout.sectionInset.right = max(Theme.screenInset, bounds.width - Theme.screenInset - width)
            layout.invalidateLayout()
            collection.layoutIfNeeded()
            collection.setContentOffset(CGPoint(x: CGFloat(currentPage) * pageStride, y: 0), animated: false)
        }
    }
    private var pageStride: CGFloat { cardWidth + layout.minimumLineSpacing }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        currentPage = min(max(0, Int((scrollView.contentOffset.x / pageStride).rounded())), max(0, items.count - 1))
        dragStartOffset = scrollView.contentOffset.x
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let distance = scrollView.contentOffset.x - dragStartOffset
        let direction: Int
        if abs(velocity.x) > 0.2 { direction = velocity.x > 0 ? 1 : -1 }
        else if abs(distance) > min(40, pageStride * 0.15) { direction = distance > 0 ? 1 : -1 }
        else { direction = 0 }
        currentPage = min(max(0, currentPage + direction), max(0, items.count - 1))
        pages.currentPage = currentPage
        targetContentOffset.pointee = CGPoint(x: CGFloat(currentPage) * pageStride, y: 0)
    }
    private var cardWidth: CGFloat { min(340, max(200, (bounds.width - Theme.screenInset * 2) * 0.86)) * 0.82 }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "article", for: indexPath) as! ArticleCell
        cell.configure(items[indexPath.item], origin: origin)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { onSelect?(items[indexPath.item].id) }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: cardWidth, height: collectionView.bounds.height)
    }
}

private final class ArticleCell: UICollectionViewCell {
    private let cover = UIImageView()
    private let title = UILabel()
    private var download: Task<Void, Never>?
    private var representedCover: String?
    override init(frame: CGRect) {
        super.init(frame: frame)
        cover.contentMode = .scaleAspectFill; cover.clipsToBounds = true
        cover.backgroundColor = .secondarySystemGroupedBackground
        cover.layer.cornerRadius = 22; cover.layer.cornerCurve = .continuous
        title.font = .preferredFont(forTextStyle: .subheadline); title.numberOfLines = 2
        title.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [cover, title]); stack.axis = .vertical; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor, multiplier: 9.0 / 16.0)
        ])
        isAccessibilityElement = true; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
    override func prepareForReuse() { super.prepareForReuse(); download?.cancel(); cover.image = nil; representedCover = nil }
    func configure(_ item: AppArticle, origin: URL) {
        title.text = item.title
        accessibilityLabel = item.title
        let key = origin.absoluteString + "|" + (item.coverPath ?? "") + "|" + (item.updatedAt)
        if representedCover == key, cover.image != nil { return }
        download?.cancel()
        if representedCover != key { cover.image = nil }
        representedCover = key
        if let image = ArticleImages.shared.cached(path: item.coverPath, origin: origin, revision: item.updatedAt) {
            cover.image = image
            return
        }
        download = Task { [weak self] in
            let image = await ArticleImages.shared.image(path: item.coverPath, origin: origin, revision: item.updatedAt)
            guard !Task.isCancelled, self?.representedCover == key else { return }
            self?.cover.image = image
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-articles") { self?.cover.image = UIImage(named: "StartupIcon") }
            #endif
        }
    }
}

#if DEBUG
@MainActor enum ArticleImageChecks {
    static func run() async {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900))
        let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        }
        let result = await ArticleImageDecoder.shared.decode(data)
        precondition(result != nil && max(result!.size.width, result!.size.height) <= 900)
        let invalid = await ArticleImageDecoder.shared.decode(Data("not an image".utf8))
        precondition(invalid == nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoverCheckProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = ArticleImages(session: session, directory: directory)
        let origin = URL(string: "https://preview.example.test")!
        async let first = images.image(path: "/storage/instructions/images/shared.png", origin: origin)
        async let second = images.image(path: "/storage/instructions/images/shared.png", origin: origin)
        let results = await (first, second)
        precondition(results.0 != nil && results.1 != nil)
        _ = await images.image(path: "/storage/instructions/images/shared.png", origin: origin)
        precondition(CoverCheckProtocol.count == 1, "Cover requests were not coalesced/cached")
        let relaunched = ArticleImages(session: session, directory: directory)
        let saved = await relaunched.image(path: "/storage/instructions/images/shared.png", origin: origin)
        precondition(saved != nil && CoverCheckProtocol.count == 1, "Relaunch downloaded a saved cover")
        let restored = ArticleImages(session: session, directory: directory)
        let article = try! JSONDecoder().decode(AppArticle.self, from: Data(#"{"id":1,"title":"Cover","excerpt":"","tags":[],"updatedAt":"","coverPath":"/storage/instructions/images/shared.png"}"#.utf8))
        await restored.restore([article], origin: origin)
        precondition(restored.cached(path: article.coverPath, origin: origin, revision: "") != nil,
                     "Disk cover was not ready synchronously before feed display")
        _ = await relaunched.image(path: article.coverPath, origin: origin, revision: "new")
        precondition(CoverCheckProtocol.count == 2, "Changed cover revision reused stale pixels")
        print("ARTICLE_IMAGE_CHECKS PASS: persistent cache; disk prewarm; revision invalidation; background decode; max 900 pixels; invalid data rejected; concurrent requests coalesced; cache reused")
    }
}
private final class CoverCheckProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

#endif
