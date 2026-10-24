import Foundation

/// On-device stage logger. Writes short lines to
/// Documents/fignyagram_state.log so a freeze can be diagnosed without Xcode.
/// The file is capped at ~256 KB (old content trimmed), writes are serialized
/// on a background queue, and nothing here touches the main thread.
nonisolated enum DiagnosticsLog {
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "Fignyagram.diag", qos: .utility)
    private static var cachedURL: URL?

    static var fileURL: URL {
        lock.lock()
        defer { lock.unlock() }
        if let cachedURL { return cachedURL }
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("fignyagram_state.log")
        cachedURL = url
        return url
    }

    static func log(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        queue.async {
            let url = fileURL
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 256_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
