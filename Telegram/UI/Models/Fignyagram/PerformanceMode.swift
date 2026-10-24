import Foundation
import Combine

enum PerformanceLevel: String, CaseIterable, Identifiable {
    case light
    case balanced
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Лёгкая"
        case .balanced: return "Средняя"
        case .maximum: return "Максимальная"
        }
    }

    var maxMessages: Int {
        switch self {
        case .light: return 150
        case .balanced: return 100
        case .maximum: return 80
        }
    }

    var maxChats: Int {
        switch self {
        case .light: return 80
        case .balanced: return 50
        case .maximum: return 40
        }
    }

    var maxPixel: CGFloat {
        switch self {
        case .light: return 900
        case .balanced: return 640
        case .maximum: return 480
        }
    }

    var cacheLimit: Int {
        switch self {
        case .light: return 48 * 1024 * 1024
        case .balanced: return 32 * 1024 * 1024
        case .maximum: return 24 * 1024 * 1024
        }
    }

    var decodeConcurrency: Int {
        self == .maximum ? 1 : 2
    }
}

@MainActor
final class PerformanceMode: ObservableObject {
    static let shared = PerformanceMode()

    private static let key = "maximumPerformanceMode"
    private static let levelKey = "performanceModeLevel"

    @Published var isEnabled: Bool {
        didSet { save() }
    }

    @Published var level: PerformanceLevel {
        didSet { save() }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
        level = PerformanceLevel(rawValue: UserDefaults.standard.string(forKey: Self.levelKey) ?? "") ?? .balanced
        ImageCache.setPerformanceMode(isEnabled, level: level)
    }

    private func save() {
        UserDefaults.standard.set(isEnabled, forKey: Self.key)
        UserDefaults.standard.set(level.rawValue, forKey: Self.levelKey)
        ImageCache.setPerformanceMode(isEnabled, level: level)
    }
}
