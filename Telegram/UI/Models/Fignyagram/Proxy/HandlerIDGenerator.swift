import Foundation

/// Atomic, monotonically increasing identifier for proxy connections and
/// reconnect attempts. Replaces any hard-coded "0" session ids so log lines
/// and handler bookkeeping always refer to a real, unique slot.
final class HandlerIDGenerator: @unchecked Sendable {
    static let shared = HandlerIDGenerator()

    private let lock = NSLock()
    private var counter: Int64 = 1

    var next: Int64 {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }
}
