import Foundation
import Combine

@MainActor
final class GlobalSearchPreferences: ObservableObject {
    static let shared = GlobalSearchPreferences()
    private static let key = "globalSearchEnabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.key) }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }
}
