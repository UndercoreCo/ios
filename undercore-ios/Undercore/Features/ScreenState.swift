import Foundation
import UndercoreCore

struct ScreenState {
    var isBusy = false
    var message: String?
}
func readableError(_ error: Error) -> String {
    if let connection = error as? URLError {
        switch connection.code {
        case .notConnectedToInternet: return "Нет подключения к интернету. Проверьте Wi-Fi или мобильную связь и попробуйте снова."
        case .timedOut: return "Сервер не ответил вовремя. Возможно, соединение медленное. Попробуйте ещё раз."
        case .networkConnectionLost: return "Соединение прервалось. Проверьте интернет и попробуйте снова."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "Не удалось связаться с сервером. Проверьте соединение и попробуйте позже."
        default: break
        }
    }
    if let clientError = error as? ClientError { return clientError.localizedDescription }
    return CommonText.networkError
}
