import Foundation
import Darwin

/// Low-level reconnect gate backed by POSIX monotonic clock.
///
/// The proxy runs above Swift's Network.framework, but the same rules as a
/// C++ interceptor apply: if a reconnect is attempted faster than the backoff
/// window, `tryEnter()` fails and the caller must reject the socket with a
/// connection reset instead of dialing upstream.
///
/// Reference C++ equivalent:
///
///     static int retry_count = 0;
///     static std::chrono::steady_clock::time_point next_allowed{};
///     bool gate_enter() {
///         auto now = std::chrono::steady_clock::now();
///         if (now < next_allowed) return false;
///         return true;
///     }
///     void gate_failure() {
///         retry_count++;
///         double delay = std::min(30.0, std::pow(2.0, std::min(retry_count, 6)))
///                      + (double(rand()) / RAND_MAX);
///         next_allowed = std::chrono::steady_clock::now()
///                      + std::chrono::duration<double>(delay);
///     }
final class SocketGate: @unchecked Sendable {
    static let shared = SocketGate()

    private let lock = NSLock()
    private var failures = 0
    private var nextAllowed: Double = 0

    private var monotonicNow: Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    /// `true` — reconnect allowed; `false` — reject the socket (caller sends
    /// an immediate reset so the peer paces its own retries).
    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return monotonicNow >= nextAllowed
    }

    /// Called on every upstream failure: 1s → 2s → 4s … → 30s + jitter.
    func recordFailure() {
        lock.lock()
        defer { lock.unlock() }
        failures += 1
        let delay = min(30.0, pow(2.0, Double(min(failures, 6)))) + Double.random(in: 0.0...1.0)
        nextAllowed = monotonicNow + delay
    }

    /// Called when a bridge stays alive: reset the counter and open the gate.
    func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }
        failures = 0
        nextAllowed = 0
    }
}
