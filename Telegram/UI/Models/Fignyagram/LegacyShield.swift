import Foundation

/// Legacy device shield: decides how aggressively we trade visual effects for
/// memory and CPU on older hardware (A11 and older, ≤3 GB RAM).
@MainActor
final class LegacyShield {
    static let shared = LegacyShield()

    /// Nonisolated so background caches (ImageCache) can read it safely.
    static let isLegacyDevice: Bool = computeLegacy()
    let isLegacy: Bool
    let modelIdentifier: String

    private init() {
        modelIdentifier = Self.hardwareModel()
        isLegacy = Self.isLegacyDevice
        CallDiag.log("legacy shield: model=\(modelIdentifier) legacy=\(isLegacy)")
    }

    nonisolated static func computeLegacy() -> Bool {
        let model = hardwareModel()
        let ram = ProcessInfo.processInfo.physicalMemory
        let legacyModels = ["iPhone8,", "iPhone9,", "iPhone10,"]   // 6s … 8 (A9–A11)
        return ram <= 3 * 1024 * 1024 * 1024 || legacyModels.contains { model.hasPrefix($0) }
    }

    var usesFlatSurfaces: Bool {
        isLegacy || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var translationDebounce: UInt64 { isLegacy ? 300_000_000 : 150_000_000 }
    var messageTranslationDebounce: UInt64 { isLegacy ? 300_000_000 : 200_000_000 }

    nonisolated private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            if let value = element.value as? Int8, value != 0 {
                result.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
    }
}
