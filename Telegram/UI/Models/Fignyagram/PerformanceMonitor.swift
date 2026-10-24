import Foundation
import Combine
import Darwin

@MainActor
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()

    @Published private(set) var memoryMB: Double = 0
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var threadCount: Int = 0
    @Published private(set) var loadedMessages: Int = 0
    @Published private(set) var loadedChats: Int = 0
    @Published private(set) var cacheBytes: Int64 = 0

    private var timer: Timer?
    private var previousCPUTime: Double?
    private var previousSampleDate: Date?

    private init() {}

    /// Sampling runs only while the developer screen is visible, so the
    /// one-second timer never competes with scrolling in normal use.
    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sample() {
        memoryMB = currentMemoryMB()
        threadCount = currentThreadCount()
        loadedMessages = ChatStore.shared.messages.values.reduce(0) { $0 + $1.count }
        loadedChats = ChatStore.shared.chats.count
        cacheBytes = CacheManager.shared.totalBytes

        let now = Date()
        let cpu = currentCPUTime()
        if let previousCPUTime, let previousSampleDate {
            let wall = now.timeIntervalSince(previousSampleDate)
            if wall > 0 {
                cpuPercent = max(0, (cpu - previousCPUTime) / wall * 100)
            }
        }
        previousCPUTime = cpu
        previousSampleDate = now
    }

    private func currentMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    private func currentCPUTime() -> Double {
        var info = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }

    private func currentThreadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS else { return 0 }
        if let threads {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: threads),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            )
        }
        return Int(count)
    }
}
