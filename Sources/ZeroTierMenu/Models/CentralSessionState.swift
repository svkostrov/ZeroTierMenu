import Foundation

enum CentralSessionState: Equatable {
    case unknown
    case authenticated
    case needsLogin

    var title: String {
        switch self {
        case .unknown:
            return "Сессия Central: неизвестно"
        case .authenticated:
            return "Сессия Central: активна"
        case .needsLogin:
            return "Сессия Central: нужен вход"
        }
    }
}
