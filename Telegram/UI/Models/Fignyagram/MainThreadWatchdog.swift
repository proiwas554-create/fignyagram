import Foundation
import UIKit

@_silgen_name("FignyagramInstallMainThreadSampler")
private func FignyagramInstallMainThreadSampler()

@_silgen_name("FignyagramSampleMainThread")
private func FignyagramSampleMainThread()

/// Detects main-thread hangs and dumps the exact stack trace to
/// Documents/mainthread_hang_<timestamp>.txt. A background timer pings the main
/// thread; if the main thread stops answering for 3 seconds, the watchdog
/// writes `Thread.main.callStackSymbols` once per hang — no crash, no impact
/// when the app is healthy.
@MainActor
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    private var pingTimer: Timer?
    private var lastPong: CFAbsoluteTime = 0
    private var dumped = false
    private var heartbeatTick = 0

    func start() {
        guard pingTimer == nil else { return }
        FignyagramInstallMainThreadSampler()
        lastPong = CFAbsoluteTimeGetCurrent()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ping() }
        }
        Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                let last = await MainActor.run(resultType: Double.self) { self.lastPong }
                let elapsed = now - last
                if elapsed > 3.0 {
                    // Signal straight from the background thread: going through
                    // MainActor.run made the sample fire only after the main
                    // thread had already unblocked.
                    FignyagramSampleMainThread()
                    // A hung main thread cannot report its own stack; dumping on
                    // the main actor only produces noise after it unblocks. Keep
                    // a coarse record instead of hundreds of files.
                    await self.dumpMainThreadStack(elapsed: elapsed)
                } else {
                    await MainActor.run { self.dumped = false }
                }
                await MainActor.run {
                    self.heartbeatTick += 1
                    if self.heartbeatTick % 20 == 0 {
                        DiagnosticsLog.log(String(format: "HEARTBEAT mainAge=%.2f", elapsed))
                    }
                }
            }
        }
    }

    private func ping() {
        lastPong = CFAbsoluteTimeGetCurrent()
    }

    private var lastDump: CFAbsoluteTime = 0

    private func dumpMainThreadStack(elapsed: Double) {
        guard !dumped else { return }
        dumped = true
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDump > 120 else { return }
        lastDump = now
        let stack = Thread.callStackSymbols.joined(separator: "\n")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mainthread_hang_\(Int(Date().timeIntervalSince1970)).txt")
        let report = "elapsed=\(String(format: "%.1f", elapsed))s\n" + stack
        try? report.write(to: url, atomically: true, encoding: .utf8)
        NSLog("Fignyagram main-thread hang detected, stack dumped to %@", url.path)
    }
}
