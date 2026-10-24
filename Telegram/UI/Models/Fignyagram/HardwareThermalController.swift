import Foundation
import Combine
import UIKit

/// Iron safety valve: watches ProcessInfo thermal state and low-power mode and
/// scales concurrency back before iOS dims the screen or kills the app.
/// Never disables features — it only reduces parallelism and debounce rate.
@MainActor
final class HardwareThermalController: ObservableObject {
    static let shared = HardwareThermalController()

    enum Level: Int, Comparable {
        case normal = 0
        case fair = 1
        case serious = 2
        case critical = 3
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    @Published private(set) var level: Level = .normal
    /// Debounce window for chat-list rebuilds; grows when the device is hot so
    /// bursts of store ticks are folded together even harder.
    @Published private(set) var debounceInterval: TimeInterval = 0.08 {
        didSet { AdaptiveDebounceProvider.shared.update(debounceInterval) }
    }

    private var observers: [NSObjectProtocol] = []

    private init() {
        level = Self.level(for: ProcessInfo.processInfo.thermalState)
        AdaptiveDebounceProvider.shared.update(debounceInterval)
        apply()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.level = Self.level(for: ProcessInfo.processInfo.thermalState)
                self?.apply()
            }
        })
        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        })
    }

    private static func level(for state: ProcessInfo.ThermalState) -> Level {
        switch state {
        case .nominal: return .normal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .normal
        }
    }

    /// Applies concurrency caps. Features stay enabled; only thread counts and
    /// refresh cadence change.
    func apply() {
        let effective = ProcessInfo.processInfo.isLowPowerModeEnabled
            ? max(level, .fair)
            : level

        switch effective {
        case .normal:
            ImageCache.applyHardwareTuning(
                maxPixel: 1280, cacheMB: 64, concurrency: 2, qos: .userInitiated
            )
            debounceInterval = 0.08
        case .fair:
            ImageCache.applyHardwareTuning(
                maxPixel: 1000, cacheMB: 48, concurrency: 2, qos: .utility
            )
            debounceInterval = 0.10
        case .serious:
            // Single decode thread: E-cores only, P-cores stay free for UI.
            ImageCache.applyHardwareTuning(
                maxPixel: 800, cacheMB: 32, concurrency: 1, qos: .utility
            )
            debounceInterval = 0.15
        case .critical:
            ImageCache.applyHardwareTuning(
                maxPixel: 640, cacheMB: 24, concurrency: 1, qos: .background
            )
            debounceInterval = 0.25
        }
    }
}
