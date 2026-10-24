import Foundation

/// Thread-safe source of the current debounce interval. The thermal controller
/// (MainActor) writes through `update`, background/parsing lanes read through
/// `current` without hopping to the main actor.
final class AdaptiveDebounceProvider: @unchecked Sendable {
    static let shared = AdaptiveDebounceProvider()

    private let lock = NSLock()
    private var interval: TimeInterval = 0.08

    var current: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return interval
    }

    func update(_ newValue: TimeInterval) {
        lock.lock()
        interval = newValue
        lock.unlock()
    }
}

/// Debouncer whose delay is read at scheduling time from
/// `AdaptiveDebounceProvider`. Unlike `.debounce(for:scheduler:)` or a fixed
/// `Task.sleep`, each call picks the interval that is valid RIGHT NOW, so a
/// thermal-state change applies to the very next burst without any fixed-window
/// reconfiguration or micro-stalls.
///
/// Generation counter under an NSLock keeps cancellation race-free from any
/// thread: only the newest scheduled burst runs, and only once.
final class AdaptiveDebouncer {
    private let lock = NSLock()
    private var generation = 0

    func schedule(_ work: @escaping @MainActor () -> Void) {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()

        let interval = AdaptiveDebounceProvider.shared.current

        Task.detached(priority: .utility) { [weak self] in
            let nanos = UInt64(max(interval, 0.01) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }

            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.generation == gen
            self.lock.unlock()
            guard isCurrent else { return }

            await MainActor.run { work() }
        }
    }

    func cancelAll() {
        lock.lock()
        generation += 1
        lock.unlock()
    }
}
