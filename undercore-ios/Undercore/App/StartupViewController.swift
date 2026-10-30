import UIKit
import Lottie

/// Presentation only; session restoration and retry remain in the coordinator.
final class StartupViewController: UIViewController {
    var onRetry: (() -> Void)?
    private let activity = UIActivityIndicatorView(style: .medium)
    private let caption = UILabel()
    private let retry = PrimaryButton(CommonText.retry)
    private let waves = LottieAnimationView(animation: nil, configuration: LottieConfiguration(renderingEngine: .coreAnimation))
    private var animationTask: Task<Void, Never>?
    private var isLoading = true
    private var isVisible = false
    private var shouldReduceMotion: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-startup-reduced-motion") { return true }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    deinit { animationTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.03, green: 0.23, blue: 0.60, alpha: 1)
        // The artwork is light in the centre in both themes; use dark text
        // locally so the loading/error message remains readable in dark mode.
        overrideUserInterfaceStyle = .light
        installWaves()

        let icon = UIImageView(image: UIImage(named: "StartupIcon"))
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = true
        icon.accessibilityLabel = AppConfiguration.name
        icon.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(icon)

        let foreground = UIColor(red: 0.04, green: 0.10, blue: 0.22, alpha: 1)
        activity.color = foreground
        activity.hidesWhenStopped = true
        caption.text = "загружаем..."
        caption.textColor = foreground
        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.adjustsFontForContentSizeCategory = true
        caption.textAlignment = .center
        caption.numberOfLines = 0
        retry.isHidden = true
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let feedback = UIStackView(arrangedSubviews: [activity, caption, retry])
        feedback.axis = .vertical
        feedback.alignment = .center
        feedback.spacing = 12
        feedback.setCustomSpacing(20, after: caption)
        feedback.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(feedback)

        let center = icon.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        center.priority = .defaultHigh
        let width = feedback.widthAnchor.constraint(equalToConstant: 320)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor), center,
            icon.widthAnchor.constraint(equalToConstant: 104),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            icon.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.gap),
            feedback.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 28),
            feedback.centerXAnchor.constraint(equalTo: view.centerXAnchor), width,
            feedback.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -Theme.inset * 2),
            feedback.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: Theme.inset * -1),
            caption.widthAnchor.constraint(equalTo: feedback.widthAnchor),
            retry.widthAnchor.constraint(lessThanOrEqualTo: feedback.widthAnchor)
        ])
        activity.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        updateWavePlayback()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        updateWavePlayback()
    }

    private func installWaves() {
        // An identical static first frame covers decoding and Reduce Motion.
        // Both resources are bundled, so launch does not need the network.
        let poster = UIImageView(image: UIImage(named: "StartupWavesPoster"))
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        waves.contentMode = .scaleAspectFill
        waves.clipsToBounds = true
        waves.loopMode = .loop
        waves.backgroundBehavior = .pauseAndRestore
        for background in [poster, waves] {
            background.isUserInteractionEnabled = false
            background.accessibilityElementsHidden = true
            background.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(background)
            NSLayoutConstraint.activate([
                background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                background.topAnchor.constraint(equalTo: view.topAnchor),
                background.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        let center = NotificationCenter.default
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification,
                     UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            center.addObserver(self, selector: #selector(playbackEnvironmentChanged(_:)), name: name, object: nil)
        }
        guard let url = Bundle.main.url(forResource: "undercore-waves", withExtension: "json") else { return }
        animationTask = Task { [weak self] in
            let animation = await Task.detached(priority: .userInitiated) {
                try? LottieAnimation.from(data: Data(contentsOf: url))
            }.value
            guard !Task.isCancelled, let self, self.isLoading, let animation else { return }
            self.waves.animation = animation
            self.updateWavePlayback()
        }
    }

    @objc private func playbackEnvironmentChanged(_ notification: Notification) {
        if notification.name == UIApplication.willResignActiveNotification {
            waves.pause()
        } else {
            updateWavePlayback()
        }
    }

    private func updateWavePlayback() {
        if isVisible, isLoading, waves.animation != nil,
           UIApplication.shared.applicationState == .active, !shouldReduceMotion {
            if !waves.isAnimationPlaying { waves.play() }
        } else {
            waves.pause()
        }
    }

    func stopLoading() {
        isLoading = false
        animationTask?.cancel()
        animationTask = nil
        activity.stopAnimating()
        waves.pause()
    }

    func showError(_ message: String) {
        loadViewIfNeeded()
        stopLoading()
        caption.text = message
        retry.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    #if DEBUG
    func verifyWaveLoading() async {
        for _ in 0..<100 where waves.animation == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        precondition(waves.animation != nil, "Bundled Lottie did not decode")
        precondition(waves.currentRenderingEngine == .coreAnimation, "Waves must use the native Core Animation renderer")
        let initial = waves.currentProgress
        try? await Task.sleep(for: .milliseconds(250))
        if !shouldReduceMotion {
            precondition(waves.isAnimationPlaying && waves.currentProgress != initial, "Visible loading waves did not advance")
        } else {
            precondition(!waves.isAnimationPlaying, "Reduce Motion must keep waves still")
        }
        isVisible = false
        updateWavePlayback()
        precondition(!waves.isAnimationPlaying, "Hidden loading screen kept animating")
        isVisible = true
        updateWavePlayback()
        playbackEnvironmentChanged(Notification(name: UIApplication.willResignActiveNotification))
        precondition(!waves.isAnimationPlaying, "Inactive application kept animating")
        updateWavePlayback()
        showError(CommonText.networkError)
        precondition(!waves.isAnimationPlaying && !activity.isAnimating && !retry.isHidden)
        let stopped = waves.currentProgress
        updateWavePlayback()
        try? await Task.sleep(for: .milliseconds(100))
        precondition(!waves.isAnimationPlaying && waves.currentProgress == stopped, "Error state resumed waves")
        print("STARTUP_WAVES_CHECKS PASS: bundled JSON; Core Animation; motion preference; hidden/inactive pause; error stops animation and preserves retry")
    }
    #endif
}
