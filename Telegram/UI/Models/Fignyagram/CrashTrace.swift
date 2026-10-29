import Foundation

/// Writes a breadcrumb trail and uncaught exceptions to Documents so a crash on
/// an old device can be diagnosed without Xcode attached.
nonisolated enum CrashTrace {
    private static let queue = DispatchQueue(label: "fignyagram.crashtrace", qos: .background)
    private static let url: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("launch_trace.log")
    }()

    static func step(_ name: String) {
        let stamp = Foundation.Date().timeIntervalSince1970
        let line = "\(stamp) \(name)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let text = "EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")\n" +
                exception.callStackSymbols.joined(separator: "\n") + "\n"
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? text.write(to: documents.appendingPathComponent("crash.log"),
                            atomically: true, encoding: .utf8)
        }
    }
}
