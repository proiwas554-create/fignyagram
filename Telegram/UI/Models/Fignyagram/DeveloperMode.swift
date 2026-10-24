import Foundation
import Combine

@MainActor
final class DeveloperMode: ObservableObject {
    static let shared = DeveloperMode()
    private static let key = "developerModeUnlocked"

    @Published private(set) var isUnlocked: Bool

    private init() {
        isUnlocked = UserDefaults.standard.bool(forKey: Self.key)
    }

    func unlock() {
        guard !isUnlocked else { return }
        isUnlocked = true
        UserDefaults.standard.set(true, forKey: Self.key)
    }

    func lock() {
        isUnlocked = false
        UserDefaults.standard.set(false, forKey: Self.key)
    }
}
