import Foundation
import Combine
import Darwin
import UIKit

// MARK: - Developer performance switches
//
// `PerformanceMode` is the app-wide performance singleton. The developer hub
// needs a handful of persisted switches on top of it; they are stored with the
// same keys `@AppStorage` would use, so the rest of the app (FPS overlay, TDLib
// logging) observes exactly the same values.

@MainActor
extension PerformanceMode {
    enum DeveloperKey {
        static let metal = "dev.useMetalCoreImage"
        static let batch = "dev.enableBatchRendering"
        static let decode = "dev.decodeConcurrency"
        static let fps = "showFPS"
        static let verbose = "developerVerboseLogs"
    }

    /// Render effects through Metal-backed CoreImage filters.
    var useMetalCoreImage: Bool {
        get { UserDefaults.standard.boolIfPresent(forKey: DeveloperKey.metal) ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: DeveloperKey.metal)
        }
    }

    /// Batch layer changes inside a single CATransaction.
    var enableBatchRendering: Bool {
        get { UserDefaults.standard.boolIfPresent(forKey: DeveloperKey.batch) ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: DeveloperKey.batch)
        }
    }

    /// Number of parallel image decoders.
    var decodeConcurrency: Int {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: DeveloperKey.decode) != nil else { return 1 }
            return max(1, defaults.integer(forKey: DeveloperKey.decode))
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(max(1, newValue), forKey: DeveloperKey.decode)
        }
    }

    /// FPS overlay in the chat list (shared with `ContentView`).
    var showFPS: Bool {
        get { UserDefaults.standard.boolIfPresent(forKey: DeveloperKey.fps) ?? false }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: DeveloperKey.fps)
        }
    }

    /// Verbose TDLib logging.
    var developerVerboseLogs: Bool {
        get { UserDefaults.standard.boolIfPresent(forKey: DeveloperKey.verbose) ?? false }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: DeveloperKey.verbose)
        }
    }

    /// Drops the expensive rendering paths without touching the UI up front.
    func applyLightProfile() {
        useMetalCoreImage = false
        enableBatchRendering = false
        decodeConcurrency = 1
    }
}

private extension UserDefaults {
    func boolIfPresent(forKey key: String) -> Bool? {
        guard object(forKey: key) != nil else { return nil }
        return bool(forKey: key)
    }
}

// MARK: - Duo simulator

/// Orientation of the Duo interface simulator. Works exactly the same on a
/// physical iPhone and in the Xcode simulator (plain UserDefaults state).
enum DuoSimulationOrientation: String, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: return "Вертикальная"
        case .landscape: return "Горизонтальная"
        }
    }
}

enum DuoSimulationKeys {
    static let active = "isDuoSimulationActive"
    static let orientation = "duoSimulationOrientation"
    static let foldWidth = "duoFoldWidth"
}

// MARK: - Device identity (desktop override)

/// UIKit keeps reporting iPad traits on Mac Catalyst: `UIDevice.model` is
/// "iPad", the idiom is unknown and the screen claims 60 Hz even on a 120 Hz
/// ProMotion panel. The developer hub must describe the real host, so the
/// desktop values are overridden explicitly.
@MainActor
enum DeviceIdentity {
    static var model: String {
        #if targetEnvironment(macCatalyst)
        return "MacBook"
        #else
        return UIDevice.current.model
        #endif
    }

    static var deviceClass: String {
        #if targetEnvironment(macCatalyst)
        return "Apple Silicon (macOS)"
        #else
        return "iOS Device"
        #endif
    }

    static var maxRefreshRate: Int {
        #if targetEnvironment(macCatalyst)
        // Catalyst clamps -[UIScreen maximumFramesPerSecond] to 60; the host
        // display runs at 120 Hz (ProMotion / 120 Hz desktop panels).
        return 120
        #else
        return UIScreen.main.maximumFramesPerSecond
        #endif
    }
}

// MARK: - Live system monitor

/// Samples real process metrics once per second: resident memory, CPU load and
/// the number of OS threads owned by the app. Values are what the developer hub
/// prints, nothing is simulated.
@MainActor
final class DeveloperMonitor: ObservableObject {
    static let shared = DeveloperMonitor()

    @Published private(set) var memoryMB: Double = 0
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var threadCount: Int = 0
    @Published private(set) var lastUpdate: Date = .distantPast

    /// Human-readable host description (desktop-aware).
    var deviceModel: String { DeviceIdentity.model }
    var deviceClass: String { DeviceIdentity.deviceClass }
    var maxRefreshRate: Int { DeviceIdentity.maxRefreshRate }

    private struct CPUTicks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        var total: UInt64 { user + system + idle + nice }
        var busy: UInt64 { user + system + nice }
    }

    private var ticker: Task<Void, Never>?
    private var previousTicks: CPUTicks?

    private init() {}

    func start() {
        guard ticker == nil else { return }
        refreshNow()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.refreshNow()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    func refreshNow() {
        memoryMB = Self.residentMemoryMB()
        cpuPercent = Self.cpuLoad(after: &previousTicks)
        threadCount = Self.liveThreadCount()
        lastUpdate = Date()
    }

    // MARK: - Metrics

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576.0
    }

    private static func cpuLoad(after previous: inout CPUTicks?) -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info, cpuCount > 0 else { return 0 }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            user &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            system &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            idle &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            nice &+= UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        let current = CPUTicks(user: user, system: system, idle: idle, nice: nice)
        defer { previous = current }

        guard let previous else { return 0 }
        let totalDelta = current.total &- previous.total
        let busyDelta = current.busy &- previous.busy
        guard totalDelta > 0 else { return 0 }
        return min(100, max(0, Double(busyDelta) / Double(totalDelta) * 100))
    }

    private static func liveThreadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        defer {
            let size = vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), size)
        }
        return Int(count)
    }
}
