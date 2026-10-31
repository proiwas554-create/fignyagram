import Foundation
import UIKit

private func crashLogPath() -> String {
    let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    return (docs as NSString).appendingPathComponent("fignyagram_crash.log")
}

private func crashWrite(_ text: String) {
    text.withCString { ptr in
        let fd = open(crashLogPath(), O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            _ = write(fd, ptr, strlen(ptr))
            close(fd)
        }
    }
}

private func handleUncaughtException(_ exception: NSException) {
    crashWrite("EXCEPTION \(exception.name.rawValue)\nreason: \(exception.reason ?? "-")\n" +
               exception.callStackSymbols.joined(separator: "\n") + "\n")
}

/// Async-signal-safe writer: the file descriptor and path are opened once at
/// install time, so a crash inside malloc/AttributeGraph cannot deadlock while
/// we format Swift strings.
private var crashFD: Int32 = -1

private func crashFDPath() {
    guard crashFD < 0 else { return }
    let path = crashLogPath()
    crashFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
}

private func handleSignal(_ signalNumber: Int32) {
    // No Swift strings, no allocation: only write(2) on the pre-opened fd.
    if crashFD < 0 { crashFDPath() }
    if crashFD >= 0 {
        var line = [UInt8]("SIGNAL \n".utf8)
        line.insert(contentsOf: Array(String(signalNumber).utf8), at: 7)
        line.withUnsafeBufferPointer { buffer in
            _ = write(crashFD, buffer.baseAddress, buffer.count)
        }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&frames, 64)
        backtrace_symbols_fd(&frames, count, crashFD)
    }
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// Writes uncaught exceptions and fatal signals to Documents/fignyagram_crash.log.
enum CrashLogger {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        // Start every launch with a fresh crash log: the old file was appended
        // forever, so stale exceptions from previous builds looked like new
        // crashes. Only the current run is recorded now.
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? Data("---- launch \(version) (\(build)) \(stamp) ----\n".utf8)
            .write(to: URL(fileURLWithPath: crashLogPath()))
        crashFDPath()
        NSSetUncaughtExceptionHandler(handleUncaughtException)
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig, handleSignal)
        }
    }

    static func append(_ text: String) {
        let url = URL(fileURLWithPath: crashLogPath())
        let data = Data(("---- \(Date()) ----\n" + text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
