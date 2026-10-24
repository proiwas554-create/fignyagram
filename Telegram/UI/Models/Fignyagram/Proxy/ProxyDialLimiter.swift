import Foundation

/// Caps concurrent upstream dials. TDLib may open several connections at once
/// (DC2 + media); each used to run its own CF/WS/TCP dial with timeouts in
/// parallel, which spiked CPU and made the UI janky. A global slot of 2 keeps
/// the proxy smooth without losing throughput.
actor ProxyDialLimiter {
    static let shared = ProxyDialLimiter()
    private var active = 0

    func withSlot<T>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        while active >= 3 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        active += 1
        defer { active -= 1 }
        return try await operation()
    }
}
