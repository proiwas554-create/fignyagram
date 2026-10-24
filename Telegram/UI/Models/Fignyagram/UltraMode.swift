import Foundation
import Combine

/// Extreme low-overhead mode. Keeps messaging, proxy and the music player,
/// but removes decorative/auxiliary UI and heavily reduces caches and limits.
@MainActor
final class UltraMode: ObservableObject {
    static let shared = UltraMode()
    private static let key = "ultraOptimizationEnabled"

    @Published private(set) var isEnabled: Bool

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
        if isEnabled {
            PerformanceMode.shared.isEnabled = true
            PerformanceMode.shared.level = .maximum
        }
        apply()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.key)
        if enabled {
            PerformanceMode.shared.isEnabled = true
            PerformanceMode.shared.level = .maximum
        }
        apply()
    }

    func toggle() { setEnabled(!isEnabled) }

    private func apply() {
        ImageCache.setUltraMode(isEnabled)
        if !isEnabled {
            HardwareTuning.shared.apply()
        }
    }
}
