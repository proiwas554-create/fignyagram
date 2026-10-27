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

private func handleSignal(_ signalNumber: Int32) {
    // Raw backtrace into the log: SIGABRT often comes from an Objective-C
    // exception or a library abort, and the symbolic stack is the only way to
    // see the actual frame.
    crashWrite("SIGNAL \(signalNumber)\n")
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    let count = backtrace(&frames, 64)
    let fd = open(crashLogPath(), O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 {
        backtrace_symbols_fd(&frames, count, fd)
        close(fd)
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
