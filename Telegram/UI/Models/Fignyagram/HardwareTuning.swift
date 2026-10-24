import Foundation
import Combine
import UIKit

enum HardwareProfile: String, CaseIterable, Identifiable {
    case battery, balanced, performance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .battery: return "Экономия"
        case .balanced: return "Баланс"
        case .performance: return "Производительность"
        }
    }
}

@MainActor
final class HardwareTuning: ObservableObject {
    static let shared = HardwareTuning()
    private static let key = "hardwareProfile"
    private static let autoKey = "hardwareAutoThrottle"

    @Published private(set) var profile: HardwareProfile
    @Published private(set) var thermalState: ProcessInfo.ThermalState
    @Published private(set) var device = DeviceProfiles.current
    @Published var maxPerformance: Bool {
        didSet {
            UserDefaults.standard.set(maxPerformance, forKey: "maxPerformanceMode")
            apply()
        }
    }

    @Published var autoThrottle: Bool {
        didSet {
            UserDefaults.standard.set(autoThrottle, forKey: Self.autoKey)
            apply()
        }
    }

    private var observers: [NSObjectProtocol] = []

    private init() {
        profile = HardwareProfile(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? DeviceProfiles.current.recommendedProfile
        thermalState = ProcessInfo.processInfo.thermalState
        maxPerformance = UserDefaults.standard.bool(forKey: "maxPerformanceMode")
        autoThrottle = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
        observe()
        apply()
    }

    var isLowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    func setProfile(_ value: HardwareProfile) {
        profile = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.key)
        apply()
    }

    func apply() {
        let effective: HardwareProfile
        if autoThrottle && (thermalState == .serious || thermalState == .critical || isLowPower) {
            effective = .battery
        } else {
            effective = profile
        }

        switch effective {
        case .battery:
            ImageCache.applyHardwareTuning(
                maxPixel: min(640, device.tier.maxPixel),
                cacheMB: min(24, device.tier.cacheMB),
                concurrency: 1, qos: .utility
            )
        case .balanced:
            ImageCache.applyHardwareTuning(
                maxPixel: min(1000, device.tier.maxPixel),
                cacheMB: min(40, device.tier.cacheMB),
                concurrency: min(2, device.tier.decodeConcurrency),
                qos: .userInitiated
            )
        case .performance:
            ImageCache.applyHardwareTuning(
                maxPixel: device.tier.maxPixel,
                cacheMB: device.tier.cacheMB,
                concurrency: device.tier.decodeConcurrency,
                qos: .userInitiated
            )
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalState = ProcessInfo.processInfo.thermalState
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
}
