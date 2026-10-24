import SwiftUI
import QuartzCore

private final class FPSProxy: NSObject {
    var onUpdate: ((Double) -> Void)?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frames = 0

    func start() {
        stop()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
        frames = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        frames += 1
        let elapsed = link.timestamp - lastTimestamp
        if elapsed >= 1 {
            onUpdate?(Double(frames) / elapsed)
            frames = 0
            lastTimestamp = link.timestamp
        }
    }
}

struct FPSOverlayView: View {
    @State private var fps: Double = 0
    @State private var proxy = FPSProxy()

    var body: some View {
        Text("FPS \(Int(fps.rounded()))")
            .font(.caption2.monospacedDigit().bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
            .onAppear {
                proxy.onUpdate = { fps = $0 }
                proxy.start()
            }
            .onDisappear { proxy.stop() }
    }
}
