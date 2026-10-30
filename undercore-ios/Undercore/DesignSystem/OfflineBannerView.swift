import UIKit

final class OfflineBannerView: UIView {
    private let subtitle = UILabel()
    func update(savedAt: Date?) {
        let text: String
        if let savedAt {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateStyle = .medium; formatter.timeStyle = .short
            text = "Сохранённые данные на " + formatter.string(from: savedAt)
        } else { text = "Не удалось связаться с Undercore" }
        subtitle.text = text
        accessibilityLabel = CommonText.offlineTitle + ". " + text
    }

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "configurations.offline-banner"
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = Theme.radius; layer.cornerCurve = .continuous
        let icon = UIImageView(image: UIImage(systemName: "arrow.clockwise.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)))
        icon.tintColor = .systemOrange; icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let title = UILabel()
        title.text = CommonText.offlineTitle
        title.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        subtitle.text = CommonText.offlineDescription
        subtitle.font = .preferredFont(forTextStyle: .footnote); subtitle.textColor = .secondaryLabel
        [title, subtitle].forEach { $0.numberOfLines = 0; $0.adjustsFontForContentSizeCategory = true }
        let text = UIStackView(arrangedSubviews: [title, subtitle]); text.axis = .vertical; text.spacing = 4
        let row = UIStackView(arrangedSubviews: [icon, text]); row.alignment = .top; row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        let bottom = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        bottom.priority = UILayoutPriority(999) // Parent stack collapses the banner when online.
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14), bottom
        ])
        isAccessibilityElement = true
        accessibilityLabel = CommonText.offlineTitle + ". " + CommonText.offlineDescription
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Use programmatic layout") }
}
