import Foundation

/// Redirects stdout/stderr to Documents/console.log so TDLib's own internal log
/// (CallActor DH steps, request errors) can be read from the device without a
/// debugger. Sensitive payloads never go through TDLib's log at verbosity 2.
enum ConsoleCapture {
    private(set) static var logURL: URL?

    static func install() {
        guard logURL == nil else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("console.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
        logURL = url
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDERR_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
        NSLog("Fignyagram console capture -> %@", url.path)
    }
}
