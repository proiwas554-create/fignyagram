import Foundation

/// Low-level queue split so that heavy, latency-tolerant work is pushed onto
/// energy-efficient cores while the UI keeps the performance cores.
///
/// Swift Concurrency `Task.detached(priority:)` still lets the OS migrate work;
/// dispatch queues with an explicit QoS are the strongest pinning primitive
/// available from app code (the OS may still move threads, but scheduler
/// targeting sticks to the requested core class).
enum HardwareQueues {
    /// TDLib message parsing, JSON decoding, cache bookkeeping. E-cores.
    static let parsing = DispatchQueue(
        label: "com.fignyagram.parsing",
        qos: .utility,
        attributes: .concurrent
    )

    /// File metadata and disk writes (music library, GIF index). E-cores.
    static let storage = DispatchQueue(
        label: "com.fignyagram.storage",
        qos: .utility
    )

    /// Image decode: user-facing, must complete quickly but off the main
    /// thread. Runs on P-cores with a small concurrency cap.
    static let imageDecode = DispatchQueue(
        label: "com.fignyagram.imageDecode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Off-main audio session activation (AVAudioSession.setActive blocks).
    static let audioSession = DispatchQueue(
        label: "com.fignyagram.audioSession",
        qos: .userInitiated
    )

    /// Send a piece of work to the parsing lane from any context.
    static func parse<T>(_ work: @escaping () -> T, completion: @escaping (T) -> Void) {
        parsing.async { completion(work()) }
    }
}
