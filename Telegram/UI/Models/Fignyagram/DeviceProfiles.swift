import Foundation
import UIKit

enum DeviceTier: String {
    case legacy
    case older
    case modern
    case pro
    case unknown

    var title: String {
        switch self {
        case .legacy: return "Старое устройство"
        case .older: return "Среднее устройство"
        case .modern: return "Современное устройство"
        case .pro: return "Флагман"
        case .unknown: return "Неизвестное устройство"
        }
    }

    var recommendedMessages: Int {
        switch self {
        case .legacy: return 80
        case .older: return 120
        case .modern: return 160
        case .pro: return 200
        case .unknown: return 120
        }
    }

    var recommendedChats: Int {
        switch self {
        case .legacy: return 40
        case .older: return 60
        case .modern: return 80
        case .pro: return 100
        case .unknown: return 60
        }
    }

    var maxPixel: CGFloat {
        switch self {
        case .legacy: return 720
        case .older: return 1000
        case .modern: return 1280
        case .pro: return 1440
        case .unknown: return 1000
        }
    }

    var cacheMB: Int {
        switch self {
        case .legacy: return 24
        case .older: return 40
        case .modern: return 56
        case .pro: return 64
        case .unknown: return 40
        }
    }

    var decodeConcurrency: Int {
        switch self {
        case .legacy: return 1
        case .older: return 2
        case .modern: return 3
        case .pro: return 3
        case .unknown: return 2
        }
    }

    var recommendedProfile: HardwareProfile {
        switch self {
        case .legacy: return .battery
        case .older: return .balanced
        case .modern, .pro: return .performance
        case .unknown: return .balanced
        }
    }
}

struct DeviceProfile {
    let identifier: String
    let marketingName: String
    let tier: DeviceTier
    let memoryGB: Double
    let supportsProMotion: Bool

    var recommendedRefreshRate: Int { supportsProMotion ? 120 : 60 }
    var recommendedProfile: HardwareProfile { tier.recommendedProfile }
}

enum DeviceProfiles {
    static let current: DeviceProfile = detect()

    private static let names: [String: String] = [
        "iPhone8,1": "iPhone 6s",
        "iPhone8,2": "iPhone 6s Plus",
        "iPhone8,4": NSLocalizedString("Generated.a086d4e063da", comment: ""),
        "iPhone9,1": "iPhone 7",
        "iPhone9,3": "iPhone 7 Plus",
        "iPhone9,2": "iPhone 8",
        "iPhone9,4": "iPhone 8 Plus",
        "iPhone10,1": "iPhone 8",
        "iPhone10,3": "iPhone X",
        "iPhone10,2": "iPhone 8 Plus",
        "iPhone10,4": "iPhone 8",
        "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": NSLocalizedString("Generated.bf8f1dbb389d", comment: ""),
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,6": NSLocalizedString("Generated.a6dfef29db7d", comment: ""),
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
        "iPhone19,1": "iPhone 18 Pro",
        "iPhone19,2": "iPhone 18 Pro Max",
        "iPhone19,3": "iPhone Duo"
    ]

    private static let proMotionIdentifiers: Set<String> = [
        "iPhone14,2", "iPhone14,3",
        "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5",
        "iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2",
        "iPhone18,1", "iPhone18,2", "iPhone18,4", "iPhone19,1", "iPhone19,2"
    ]

    static func detect() -> DeviceProfile {
        var system = utsname()
        uname(&system)
        let raw = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let name = names[raw] ?? fallbackName(raw)
        let tier: DeviceTier
        if raw.hasPrefix("iPhone8,") || raw.hasPrefix("iPhone9,") || raw.hasPrefix("iPhone10,") {
            tier = .legacy
        } else if raw.hasPrefix("iPhone11,") || raw.hasPrefix("iPhone12,") {
            tier = .older
        } else if raw.hasPrefix("iPhone13,") || raw.hasPrefix("iPhone14,") {
            tier = .modern
        } else if raw.hasPrefix("iPhone15,") || raw.hasPrefix("iPhone16,") ||
                    raw.hasPrefix("iPhone17,") || raw.hasPrefix("iPhone18,") ||
                    raw.hasPrefix("iPhone19,") {
            tier = .pro
        } else {
            tier = .unknown
        }
        let memory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return DeviceProfile(
            identifier: raw,
            marketingName: name,
            tier: tier,
            memoryGB: memory,
            supportsProMotion: proMotionIdentifiers.contains(raw)
        )
    }

    private static func fallbackName(_ identifier: String) -> String {
        if identifier.hasPrefix("iPhone") { return "iPhone (\(identifier))" }
        if identifier.hasPrefix("iPad") { return "iPad" }
        return UIDevice.current.model
    }
}
