import Foundation

private typealias TDLogCallback = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

@_silgen_name("td_execute")
private func td_execute(_ query: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("td_set_log_verbosity_level")
private func td_set_log_verbosity_level(_ level: Int32)

@_silgen_name("td_set_log_message_callback")
private func td_set_log_message_callback(_ maxVerbosity: Int32, _ callback: TDLogCallback?)

private let tdLogQueue = DispatchQueue(label: "fignyagram.tdlib.logtap")

private let tdLogURL: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("tdlib_call.log")
}()

private func tdLogWrite(_ text: String, _ level: Int32) {
    let line = String(format: "%.3f [%d] %@\n", Date().timeIntervalSince1970, level, text)
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: tdLogURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}

private var tdLogSeen: Int32 = 0

func tdLogTapSeenCount() -> Int32 { tdLogSeen }

private func tdLogCallback(_ level: Int32, _ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    tdLogSeen &+= 1
    if tdLogSeen % 500 == 0 {
        let beat = "tap heartbeat seen=\(tdLogSeen) level=\(level)"
        tdLogQueue.async { tdLogWrite(beat, level) }
    }
    let text = String(cString: message)
    let interesting = level <= 2
        || text.contains("Call")
        || text.contains("call")
        || text.contains("phone")
        || text.contains("DH ")
        || text.contains("dh_")
        || text.contains("NetQuery")
    guard interesting else { return }
    tdLogQueue.async { tdLogWrite(text, level) }
}

/// Receives TDLib's own log through the official C callback and stores the
/// call-related lines in Documents/tdlib_call.log. This is the only reliable way
/// to see the CallActor's DH/confirm steps on a device: the default stderr
/// stream is not flushed after client initialisation.
enum TDLibLogTap {
    private static var started = false

    static func install() {
        guard !started else { return }
        started = true
        try? Data().write(to: tdLogURL)
        td_set_log_message_callback(5, tdLogCallback)
        td_set_log_verbosity_level(5)
        let json = "{\"@type\":\"setLogStream\",\"log_stream\":{\"@type\":\"logStreamFile\",\"path\":\""
            + tdLogURL.path
            + "\",\"max_file_size\":5242880,\"redirect_stderr\":false}}"
        let result: String = json.withCString { ptr in
            guard let answer = td_execute(ptr) else { return "<nil>" }
            return String(cString: answer)
        }
        let verbositySet: String = "{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":5}".withCString { ptr in
            guard let answer = td_execute(ptr) else { return "<nil>" }
            return String(cString: answer)
        }
        let verbosityGet: String = "{\"@type\":\"getLogVerbosityLevel\"}".withCString { ptr in
            guard let answer = td_execute(ptr) else { return "<nil>" }
            return String(cString: answer)
        }
        NSLog("Fignyagram TDLib log tap -> %@ setLogStream=%@ setVerbosity=%@ getVerbosity=%@",
              tdLogURL.path, result, verbositySet, verbosityGet)
    }
}
