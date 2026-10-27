import Foundation

/// Diagnostics for the 1-on-1 call pipeline. Writes short, structured lines to
/// Documents/call_diag.log so a failed call can be analysed without Xcode.
/// Never logs keys, passwords or message payloads — only sizes and states.
enum CallDiag {
    private static let lock = NSLock()
    private static let writeQueue = DispatchQueue(label: "fignyagram.calldiag.write", qos: .utility)
    private static let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("call_diag.log")
    }()

    static func log(_ message: String) {
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, message)
        // File writes happen off the calling thread: callbacks fire on the
        // audio/video threads and blocking them showed up as input lag.
        writeQueue.async {
            lock.lock()
            defer { lock.unlock() }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) { handle.write(data) }
                try? handle.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? Data().write(to: url)
    }
}
