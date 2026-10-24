import Foundation

enum DevicePerformance {
    /// iPhone 7 Plus, older iPads and other 2–3 GB devices.
    static var isLowMemory: Bool {
        ProcessInfo.processInfo.physicalMemory <= 3 * 1024 * 1024 * 1024
    }

    static var isVeryLowMemory: Bool {
        ProcessInfo.processInfo.physicalMemory <= 2 * 1024 * 1024 * 1024
    }
}
