import UIKit

enum Theme {
    static let blue = UIColor(red: 0.09, green: 0.43, blue: 0.93, alpha: 1)
    static let inset: CGFloat = 24
    // Compact inset-grouped screens match the native Profile table.
    static let screenInset: CGFloat = 20
    static let gap: CGFloat = 16
    static let fieldHeight: CGFloat = 52
    static let radius: CGFloat = 16
    static let cardRadius: CGFloat = 28
}
enum CommonText {
    static let retry = "Попробовать снова"
    static let logout = "Выйти"
    static let cancel = "Отмена"
    static let configurations = "Конфигурации"
    static let loading = "Загружаем…"
    static let send = "Открыть в VPN-приложении"
    static let empty = "Конфигураций пока нет."
    static let networkError = "Не удалось связаться с сервером. Проверьте интернет и попробуйте снова."
    static let offlineTitle = "Данные не обновлены"
    static let offlineDescription = "Для добавления конфигурации и создания QR-кода нужен интернет."
}
